import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless half of the MakerWorld plugin: polling, notifications, and the
// shared state the bar pill / popup (BarWidget.qml, Panel.qml) read back.
//
// Every `pollSeconds` it asks the (unofficial) Bambu Cloud account API how many
// unread items sit in each category, and keeps the per-category totals on
// `unreadByType` for the pill. The first poll after startup is adopted
// silently as a baseline; after that, any category whose count went up triggers
// a fetch of the recent message list, and each unseen item in an enabled
// category raises one omarchy notification. A slower timer tracks the point
// balance (`points`) and notifies when it rises.
//
// Credentials come from ~/.config/omarchy/makerworld/token.json, written by
// bin/makerworld-login. On a 401 the service runs bin/makerworld-refresh and
// retries; if that fails it sets connState "expired" and tells the user once.
//
// Settings: the bar widget's shell.json entry wins; anything unset there falls
// back to ~/.config/omarchy/makerworld/config.json, then to built-in defaults.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.dreed47.makerworld"

  // ---- Paths ----------------------------------------------------------
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string confDir: {
    var xdg = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    var b = xdg !== "" ? xdg : (home + "/.config")
    return b + "/omarchy/makerworld"
  }
  readonly property string tokenFile: confDir + "/token.json"
  readonly property string configFile: confDir + "/config.json"
  function cli(name) { return pluginDir + "bin/" + name }

  // ---- Config: shell.json widget entry over config.json over defaults ----
  property var configJsonRaw: ({})
  readonly property var shellEntry: {
    var sc = shell ? shell.shellConfig : null
    if (!sc) return ({})
    try {
      if (sc.bar && sc.bar.layout) {
        var secs = ["left", "center", "right"]
        for (var s = 0; s < secs.length; s++) {
          var arr = sc.bar.layout[secs[s]] || []
          for (var i = 0; i < arr.length; i++)
            if (arr[i] && String(arr[i].id) === root.pluginId) return arr[i]
        }
      }
      var plugs = sc.plugins || []
      for (var j = 0; j < plugs.length; j++)
        if (plugs[j] && String(plugs[j].id) === root.pluginId) return plugs[j]
    } catch (e) {}
    return ({})
  }
  // `shell.shellConfig` does not reliably re-notify when `omarchy-bar set`
  // rewrites a nested bar-layout entry, so the popup's settings toggles would
  // not take effect until a shell restart. Watch shell.json directly and pull
  // our widget's entry from it; this wins over `shellEntry`.
  readonly property string shellJsonPath: {
    var xdg = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    return (xdg !== "" ? xdg : (home + "/.config")) + "/omarchy/shell.json"
  }
  property var shellJsonEntry: ({})

  readonly property var cfg: Model.normalizedConfig(
    Model.mergeRaw(Model.mergeRaw(configJsonRaw, shellEntry), shellJsonEntry))

  FileView {
    path: root.configFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.configJsonRaw = JSON.parse(text()) || ({}) }
      catch (e) { root.configJsonRaw = ({}) }
    }
    onLoadFailed: root.configJsonRaw = ({})
    onFileChanged: reload()
  }

  FileView {
    path: root.shellJsonPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var sj = JSON.parse(text())
        var found = null
        var secs = ["left", "center", "right"]
        if (sj && sj.bar && sj.bar.layout) {
          for (var s = 0; s < secs.length; s++) {
            var arr = sj.bar.layout[secs[s]] || []
            for (var i = 0; i < arr.length; i++)
              if (arr[i] && String(arr[i].id) === root.pluginId) found = arr[i]
          }
        }
        root.shellJsonEntry = found || ({})
      } catch (e) { root.shellJsonEntry = ({}) }
    }
    onLoadFailed: root.shellJsonEntry = ({})
    onFileChanged: reload()
  }

  // ---- Token (token.json, live-reloaded) ----------------------------
  property string accessToken: ""
  property string region: "global"
  property double tokenExp: 0
  property bool refreshFailedNotified: false

  FileView {
    id: tokenView
    path: root.tokenFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var t = JSON.parse(text())
        root.accessToken = String(t.accessToken || "")
        root.region = Model.normalizedRegion(t.region || root.cfg.region)
        root.tokenExp = parseFloat(t.accessTokenExp || 0) || 0
      } catch (e) {
        root.accessToken = ""
      }
      root.refreshFailedNotified = false
      if (root.accessToken === "") {
        root.connState = "notoken"
      } else {
        root.connState = "init"
        // Bambu's access token is an opaque string, not a JWT, so tokenExp is
        // usually 0 (unknown). Only pre-emptively refresh when we actually
        // have an expiry to act on; otherwise rely on a 401 to trigger it.
        if (root.tokenExp > 0 && Model.tokenNeedsRefresh(root.tokenExp, Math.floor(Date.now() / 1000)))
          Qt.callLater(root.beginRefresh)
        else {
          Qt.callLater(root.pollCounts)
          Qt.callLater(root.pollProfile)
        }
      }
    }
    onLoadFailed: { root.accessToken = ""; root.connState = "notoken" }
    onFileChanged: reload()
  }

  // ---- Derived ------------------------------------------------------
  readonly property bool canPoll: accessToken !== ""
  readonly property var notifyTypes: cfg.notifyTypes || Model.KNOWN_TYPES
  readonly property int pollMs: Math.max(120, cfg.pollSeconds || 300) * 1000
  readonly property int profileMs: Math.max(5, cfg.profileMinutes || 15) * 60 * 1000
  readonly property bool notifyPoints: cfg.notify && notifyTypes.indexOf("points") !== -1
  readonly property bool notifyFollows: cfg.notify && notifyTypes.indexOf("follow") !== -1

  // ---- Live state the bar pill / popup read -----------------------
  property var unreadByType: ({})
  property int unreadTotal: 0
  property int apiUnreadTotal: 0   // API grand total (mostly print jobs); debug only
  property double points: -1
  property int followerCount: -1
  property int boostTokens: -1
  property int totalDownloads: -1
  property int totalLikes: -1
  property string profileName: ""
  property string profileHandle: ""
  // "init" | "ok" | "expired" | "notoken"
  property string connState: "init"

  // Set by the popup while it is open, so a poll that lands during that time
  // is treated as already seen (no "new" highlight for what you're looking at).
  property bool panelOpen: false

  // ---- "New since you last opened the popup" --------------------
  //
  // Separate baseline from the notification diff: `seen*` is cleared by
  // opening the popup, not by a poll, so the bar pill reflects your attention
  // rather than MakerWorld's server read-state.
  readonly property int newUnread: Model.riseOver(unreadTotal, state.seenUnread)
  readonly property real pointsDelta: Model.riseOver(points, state.seenPoints)
  readonly property int newFollowers: Model.riseOver(followerCount, state.seenFans)
  readonly property bool hasNew: newUnread > 0 || pointsDelta > 0 || newFollowers > 0

  function markSeen() {
    if (unreadTotal >= 0) state.seenUnread = unreadTotal
    if (points >= 0) state.seenPoints = points
    if (followerCount >= 0) state.seenFans = followerCount
  }

  // ---- Persisted state (survives a shell reload) -------------------
  PersistentProperties {
    id: state
    reloadableId: "omarchy-makerworld"
    property string lastCountsJson: ""   // JSON of byType map from parseCounts
    property double lastTotal: -1
    property string seenIdsJson: "[]"    // ring buffer of notified message ids
    property double lastPoints: -1
    property double lastFanCount: -1
    property double lastBoostCount: -1
    property double lastDownloads: -1
    property double lastLikes: -1
    property string boostWarnedId: ""    // boostingRightId we've already warned about
    property double seenUnread: -1       // pill "new" baseline (cleared on popup open)
    property double seenPoints: -1
    property double seenFans: -1
    property bool baselined: false
  }

  function seenIds() {
    try { var a = JSON.parse(state.seenIdsJson); return Array.isArray(a) ? a : [] }
    catch (e) { return [] }
  }

  // ---- HTTP helpers ----------------------------------------------
  //
  // curl carries the auth header and appends the HTTP status after a marker so
  // onStreamFinished can tell 200 from 401 (curl without -f still prints the
  // error body, which we want for logging). `--max-filesize` and `--max-redirs 0`
  // keep a hostile or broken endpoint from flooding the long-lived shell with
  // an unbounded body or bouncing the bearer token to another origin; the
  // collectors also drop anything over `maxBodyBytes` defensively.
  readonly property int maxBodyBytes: 8000000
  function curlArgs(url, extra) {
    var a = ["curl", "-sS", "--max-time", "20",
      "--max-filesize", String(root.maxBodyBytes), "--max-redirs", "0",
      "-H", "Authorization: Bearer " + root.accessToken,
      "-H", "User-Agent: bambu_network_agent/01.09.05.01",
      "-H", "Accept: application/json"]
    if (extra) for (var i = 0; i < extra.length; i++) a.push(extra[i])
    a.push("-w"); a.push("\n__HTTP__%{http_code}"); a.push(url)
    return a
  }

  // Shared guard for every collector: reject an over-cap body outright.
  function bodyTooBig(s) {
    return String(s || "").length > root.maxBodyBytes
  }

  function dbg(label, s) {
    if (root.cfg && root.cfg.debug) console.log("[makerworld]", label, String(s).slice(0, 1800))
  }

  function onAuthFail() {
    root.connState = "expired"
    root.beginRefresh()
  }

  // ---- Poll: unread counts -------------------------------------
  function pollCounts() {
    if (!canPoll || countsProc.running) return
    countsProc.command = curlArgs(Model.urlMessageCount(root.region))
    countsProc.running = true
  }

  Process {
    id: countsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.bodyTooBig(text)) { root.dbg("oversized response"); return }
        var r = Model.splitHttp(text)
        if (r.status === 401 || r.status === 403) { root.onAuthFail(); return }
        if (r.status < 200 || r.status >= 300 || r.body === "") return
        try {
          var json = JSON.parse(r.body)
          root.dbg("counts", r.body)
          if (Model.isAuthError(json)) { root.onAuthFail(); return }
          root.handleCounts(json)
        } catch (e) { root.dbg("counts parse error", e) }
      }
    }
  }

  function handleCounts(json) {
    var parsed = Model.parseCounts(json)
    var prev = {}
    try { prev = JSON.parse(state.lastCountsJson || "{}") || {} } catch (e) {}

    // Always publish the current numbers for the pill / popup. `parsed.total`
    // is the sum of the categories we surface - NOT the API's unreadTotal,
    // which is mostly print-job notifications.
    root.unreadByType = parsed.byType
    root.unreadTotal = parsed.total
    root.apiUnreadTotal = parsed.apiUnreadTotal
    root.connState = "ok"
    root.refreshFailedNotified = false

    // Pill "new" baseline: seed on first sight, follow the count down (things
    // read elsewhere), and stay glued to it while the popup is open.
    if (state.seenUnread < 0 || root.unreadTotal < state.seenUnread || root.panelOpen)
      state.seenUnread = root.unreadTotal

    if (!state.baselined) {
      state.lastCountsJson = JSON.stringify(parsed.byType)
      state.lastTotal = root.unreadTotal
      state.baselined = true
      return
    }

    var up = Model.diffCounts(prev, parsed.byType)
    state.lastCountsJson = JSON.stringify(parsed.byType)
    state.lastTotal = root.unreadTotal

    if (!root.cfg.notify) return
    // Page only the notification categories whose class actually went up and
    // is enabled. `up` classes map to the app's `type=` category params.
    var params = {}
    for (var i = 0; i < up.length; i++) {
      if (root.notifyTypes.indexOf(up[i]) === -1) continue
      params[Model.categoryParamForClass(up[i])] = true
    }
    var q = []
    for (var k in params) q.push(parseInt(k, 10))
    if (q.length) { root.fetchQueue = q; root.pumpFetch() }
  }

  // ---- Poll: recent message list (for notification text) ---------
  property var fetchQueue: []
  function pumpFetch() {
    if (messagesProc.running || root.fetchQueue.length === 0) return
    var cat = root.fetchQueue.shift()
    var limit = Math.max(10, (root.cfg.maxBurst || 5) * 3)
    messagesProc.command = curlArgs(Model.urlMessages(root.region, limit, 0, cat))
    messagesProc.running = true
  }

  Process {
    id: messagesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.bodyTooBig(text)) { root.dbg("oversized response"); return }
        var r = Model.splitHttp(text)
        if (r.status === 401 || r.status === 403) { root.onAuthFail(); return }
        if (r.status >= 200 && r.status < 300 && r.body !== "") {
          try {
            var json = JSON.parse(r.body)
            root.dbg("messages", r.body)
            if (Model.isAuthError(json)) { root.onAuthFail(); return }
            root.handleMessages(json)
          } catch (e) { root.dbg("messages parse error", e) }
        }
        Qt.callLater(root.pumpFetch)   // next queued category, if any
      }
    }
  }

  function handleMessages(json) {
    var list = Model.extractMessages(json)
    if (!list.length) return
    var fresh = Model.selectFresh(list, root.seenIds(), root.notifyTypes,
      root.cfg.maxBurst || 5, root.region)
    if (!fresh.length) return

    var newIds = []
    for (var i = 0; i < fresh.length; i++) {
      var f = fresh[i]
      root.enqueueNotify(f.title, f.body, Model.glyphFor(f.cls), f.url)
      newIds.push(f.id)
    }
    state.seenIdsJson = JSON.stringify(Model.mergeSeen(root.seenIds(), newIds, 300))
  }

  // ---- Poll: profile (point balance + display name) --------------
  function pollProfile() {
    if (!canPoll || profileProc.running) return
    profileProc.command = curlArgs(Model.urlProfile(root.region))
    profileProc.running = true
  }

  Process {
    id: profileProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.bodyTooBig(text)) { root.dbg("oversized response"); return }
        var r = Model.splitHttp(text)
        if (r.status === 401 || r.status === 403) { root.onAuthFail(); return }
        if (r.status < 200 || r.status >= 300 || r.body === "") return
        try {
          var json = JSON.parse(r.body)
          root.dbg("profile", r.body)
          root.handleProfile(json)
        } catch (e) { root.dbg("profile parse error", e) }
      }
    }
  }

  function handleProfile(json) {
    var name = Model.parseProfileName(json)
    if (name !== "") root.profileName = name
    var handle = Model.parseProfileHandle(json)
    if (handle !== "") root.profileHandle = handle

    var pts = Model.parsePoints(json)
    if (pts !== null) {
      root.points = pts
      root.connState = "ok"
      if (root.notifyPoints && state.lastPoints >= 0 && pts > state.lastPoints) {
        var delta = pts - state.lastPoints
        root.enqueueNotify("MakerWorld points",
          "+" + delta + "  (balance " + Model.groupNum(pts) + ")",
          Model.glyphFor("points"),
          Model.siteBase(root.region) + "/en/my/points")
      }
      state.lastPoints = pts
      if (state.seenPoints < 0 || pts < state.seenPoints || root.panelOpen) state.seenPoints = pts
    }

    // ---- Follower alerts (diff fanCount) ----
    var fans = Model.parseFollowerCount(json)
    if (fans !== null) {
      root.followerCount = fans
      if (root.notifyFollows && state.lastFanCount >= 0 && fans > state.lastFanCount) {
        var gained = fans - state.lastFanCount
        root.enqueueNotify(
          gained === 1 ? "New follower" : gained + " new followers",
          "You now have " + Model.groupNum(fans) + " followers on MakerWorld",
          Model.glyphFor("follow"),
          Model.followersUrl(root.region, root.profileHandle))
      }
      state.lastFanCount = fans
      if (state.seenFans < 0 || fans < state.seenFans || root.panelOpen) state.seenFans = fans
    }

    // ---- Boost tokens: count change + expiry warning ----
    var boost = Model.parseBoostCount(json)
    if (boost !== null) {
      root.boostTokens = boost
      if (root.notifyPoints && state.lastBoostCount >= 0 && boost > state.lastBoostCount) {
        root.enqueueNotify(
          boost === 1 ? "Boost token available" : boost + " boost tokens available",
          "Spend it on a design before it expires",
          Model.glyphFor("points"), Model.boostPageUrl(root.region))
      }
      if (boost !== state.lastBoostCount) state.boostWarnedId = ""   // fresh token can warn again
      state.lastBoostCount = boost
      if (boost > 0 && root.notifyPoints && cfg.boostExpiryWarnDays > 0)
        Qt.callLater(root.checkBoostExpiry)
    }

    // ---- Download / like milestones ----
    var doWarn = root.cfg.notify && root.cfg.notifyMilestones
    var dl = Model.profileStat(json, "downloads")
    if (dl !== null) {
      root.totalDownloads = dl
      if (doWarn) root.maybeMilestone("downloads", state.lastDownloads, dl)
      state.lastDownloads = dl
    }
    var lk = Model.profileStat(json, "likes")
    if (lk !== null) {
      root.totalLikes = lk
      if (doWarn) root.maybeMilestone("likes", state.lastLikes, lk)
      state.lastLikes = lk
    }
  }

  function maybeMilestone(metric, prev, cur) {
    var m = Model.highestMilestoneCrossed(prev, cur)
    if (m <= 0) return
    root.enqueueNotify("MakerWorld milestone",
      "Your models passed " + Model.groupNum(m) + " " + Model.STAT_LABEL[metric],
      Model.STAT_GLYPH[metric], Model.myModelsUrl(root.region))
  }

  // ---- Boost-token expiry warning -------------------------------
  //
  // MakerWorld sends a `pointBoostingRightExpireRemind` message ~a week out;
  // we also read the original grant's `expireAt`. When a token is within the
  // warn window and we have not warned about that boostingRightId yet, fire
  // one notification. Only runs while `boost > 0`.
  function checkBoostExpiry() {
    if (!canPoll || boostProc.running) return
    boostProc.command = curlArgs(Model.urlMessages(root.region, 50, 0, 3))
    boostProc.running = true
  }

  Process {
    id: boostProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.bodyTooBig(text)) { root.dbg("oversized response"); return }
        var r = Model.splitHttp(text)
        if (r.status < 200 || r.status >= 300 || r.body === "") return
        try {
          var list = Model.extractMessages(JSON.parse(r.body))
          var soon = Model.boostExpirySoonest(list, Date.now())
          if (!soon) return
          var daysMs = cfg.boostExpiryWarnDays * 86400 * 1000
          if ((soon.ms - Date.now()) > daysMs) return
          if (String(soon.rightId) === state.boostWarnedId) return
          root.enqueueNotify("Boost token expiring",
            "A boost token expires " + Model.untilTime(soon.ms, Date.now())
              + " (" + Model.isoDate(soon.iso) + ") - use it before it's gone",
            Model.glyphFor("points"), Model.boostPageUrl(root.region))
          state.boostWarnedId = String(soon.rightId)
        } catch (e) { root.dbg("boost expiry parse error", e) }
      }
    }
  }

  // ---- Mark all read (called by the popup) -----------------------
  function markAllRead() {
    if (!canPoll || markReadProc.running) return
    markReadProc.command = curlArgs(
      Model.apiBase(root.region) + Model.PATHS.messageRead,
      ["-X", "POST", "-H", "Content-Type: application/json", "-d", "{}"])
    markReadProc.running = true
  }

  Process {
    id: markReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.bodyTooBig(text)) { root.dbg("oversized response"); return }
        var r = Model.splitHttp(text)
        root.dbg("markread", String(r.status) + " " + r.body)
        if (r.status === 401 || r.status === 403) { root.onAuthFail(); return }
        // Optimistically clear locally, then re-poll for the real numbers.
        root.unreadByType = ({})
        root.unreadTotal = 0
        Qt.callLater(root.pollCounts)
      }
    }
  }

  // ---- Token refresh --------------------------------------
  function beginRefresh() {
    if (refreshProc.running) return
    refreshProc.command = [root.cli("makerworld-refresh")]
    refreshProc.running = true
  }

  Process {
    id: refreshProc
    onExited: function (code) {
      if (code === 0) {
        // token.json rewritten -> FileView.onFileChanged reloads it and
        // re-kicks the polls. Nothing to do here but clear the flag.
        root.refreshFailedNotified = false
        root.connState = "init"
        tokenView.reload()
      } else {
        root.connState = "expired"
        if (!root.refreshFailedNotified) {
          root.refreshFailedNotified = true
          root.enqueueNotify("MakerWorld sign-in expired",
            "Run  makerworld-login  to reconnect",
            Model.glyphFor("system"), "")
        }
      }
    }
  }

  // ---- Notification queue -------------------------------
  property var notifyQueue: []

  function enqueueNotify(headline, body, glyph, url) {
    if (!root.cfg.notify) return
    var cmd = ["omarchy-notification-send", "--app-name", "MakerWorld", "-u", "normal"]
    if (glyph && glyph !== "") { cmd.push("-g"); cmd.push(String(glyph)) }
    var to = parseInt(root.cfg.notifyTimeoutSeconds, 10) || 0
    if (to > 0) { cmd.push("-t"); cmd.push(String(to * 1000)) }
    cmd.push(String(headline))
    if (body && body !== "") cmd.push(String(body))
    if (root.cfg.openOnClick && url && url !== "") {
      cmd.push("--exec"); cmd.push("xdg-open"); cmd.push(String(url))
    }
    notifyQueue.push(cmd)
    runNextNotify()
    if (root.cfg.notifySound && root.cfg.notifySound !== "") playSound(root.cfg.notifySound)
  }

  Process {
    id: notifyProc
    onExited: root.runNextNotify()
  }
  function runNextNotify() {
    if (notifyProc.running || notifyQueue.length === 0) return
    notifyProc.command = notifyQueue.shift()
    notifyProc.running = true
  }

  Process { id: soundProc }
  property double lastSoundMs: 0
  function playSound(path) {
    if (soundProc.running) return
    var now = Date.now()
    if (now - lastSoundMs < 8000) return
    lastSoundMs = now
    soundProc.command = ["pw-play", String(path)]
    soundProc.running = true
  }

  // ---- Timers ---------------------------------------
  Timer {
    id: countTimer
    interval: root.pollMs
    running: root.canPoll
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollCounts()
  }

  Timer {
    id: profileTimer
    interval: root.profileMs
    running: root.canPoll
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollProfile()
  }

  onCanPollChanged: if (canPoll) { Qt.callLater(pollCounts); Qt.callLater(pollProfile) }

  // ---- IPC (testing + popup actions) --------------------
  IpcHandler {
    target: "makerworld"
    // Re-poll now, keeping the baseline (used by the popup's refresh).
    function refresh(): void { Qt.callLater(root.pollCounts); Qt.callLater(root.pollProfile) }
    // Drop the baseline so the next poll re-seeds without notifying, then poll.
    function poll(): void { root.resetBaselineAndPoll() }
    function markRead(): void { root.markAllRead() }
    function status(): string {
      return JSON.stringify({
        connState: root.connState,
        region: root.region,
        canPoll: root.canPoll,
        baselined: state.baselined,
        unreadTotal: root.unreadTotal,
        unreadByType: root.unreadByType,
        apiUnreadTotal: root.apiUnreadTotal,
        points: root.points,
        followerCount: root.followerCount,
        boostTokens: root.boostTokens,
        totalDownloads: root.totalDownloads,
        totalLikes: root.totalLikes,
        hasNew: root.hasNew,
        newUnread: root.newUnread,
        pointsDelta: root.pointsDelta,
        newFollowers: root.newFollowers,
        panelOpen: root.panelOpen,
        profileName: root.profileName,
        profileHandle: root.profileHandle,
        boostWarnedId: state.boostWarnedId,
        notify: root.cfg.notify,
        notifyTypes: root.notifyTypes
      })
    }
  }

  function resetBaselineAndPoll() {
    state.baselined = false
    Qt.callLater(root.pollCounts)
  }
}
