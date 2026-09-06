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
  readonly property var cfg: Model.normalizedConfig(Model.mergeRaw(configJsonRaw, shellEntry))

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

  // ---- Live state the bar pill / popup read -----------------------
  property var unreadByType: ({})
  property int unreadTotal: 0
  property int apiUnreadTotal: 0   // API grand total (mostly print jobs); debug only
  property double points: -1
  property string profileName: ""
  // "init" | "ok" | "expired" | "notoken"
  property string connState: "init"

  // ---- Persisted state (survives a shell reload) -------------------
  PersistentProperties {
    id: state
    reloadableId: "omarchy-makerworld"
    property string lastCountsJson: ""   // JSON of byType map from parseCounts
    property double lastTotal: -1
    property string seenIdsJson: "[]"    // ring buffer of notified message ids
    property double lastPoints: -1
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
  // error body, which we want for logging).
  function curlArgs(url, extra) {
    var a = ["curl", "-sS", "--max-time", "20",
      "-H", "Authorization: Bearer " + root.accessToken,
      "-H", "User-Agent: bambu_network_agent/01.09.05.01",
      "-H", "Accept: application/json"]
    if (extra) for (var i = 0; i < extra.length; i++) a.push(extra[i])
    a.push("-w"); a.push("\n__HTTP__%{http_code}"); a.push(url)
    return a
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

    var pts = Model.parsePoints(json)
    if (pts === null) return
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
        profileName: root.profileName,
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
