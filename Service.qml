import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless MakerWorld notifier.
//
// Every `pollSeconds` it asks the (unofficial) Bambu Cloud account API how many
// unread items sit in each category. The first poll after startup is adopted
// silently as a baseline; after that, any category whose count went up triggers
// a fetch of the recent message list, and each unseen item in an enabled
// category raises one omarchy notification. A slower timer watches the point
// balance on the profile and notifies when it rises.
//
// Credentials come from ~/.config/omarchy/makerworld/token.json, written by
// bin/makerworld-login. On a 401 the service runs bin/makerworld-refresh and
// retries; if that fails it tells the user once to sign in again.
//
// There is no bar widget yet (planned for the next release), so settings live
// in ~/.config/omarchy/makerworld/config.json rather than shell.json.
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

  // ---- Config (config.json, live-reloaded) ---------------------------
  property var cfg: Model.normalizedConfig(null)

  FileView {
    path: root.configFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.cfg = Model.normalizedConfig(JSON.parse(text())) }
      catch (e) { root.cfg = Model.normalizedConfig(null) }
    }
    onLoadFailed: root.cfg = Model.normalizedConfig(null)
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
      if (root.accessToken !== "") {
        if (Model.tokenNeedsRefresh(root.tokenExp, Math.floor(Date.now() / 1000)))
          Qt.callLater(root.beginRefresh)
        else
          Qt.callLater(root.pollCounts)
      }
    }
    onLoadFailed: root.accessToken = ""
    onFileChanged: reload()
  }

  // ---- Derived ------------------------------------------------------
  readonly property bool canPoll: accessToken !== "" && cfg.notify === true
  readonly property var notifyTypes: cfg.notifyTypes || Model.KNOWN_TYPES
  readonly property int pollMs: Math.max(120, cfg.pollSeconds || 300) * 1000
  readonly property int profileMs: Math.max(5, cfg.profileMinutes || 15) * 60 * 1000
  readonly property bool watchPoints: notifyTypes.indexOf("points") !== -1

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
  function curlArgs(url) {
    return ["curl", "-sS", "--max-time", "20",
      "-H", "Authorization: Bearer " + root.accessToken,
      "-H", "User-Agent: bambu_network_agent/01.09.05.01",
      "-H", "Accept: application/json",
      "-w", "\n__HTTP__%{http_code}", url]
  }

  function dbg(label, s) {
    if (root.cfg && root.cfg.debug) console.log("[makerworld]", label, String(s).slice(0, 1800))
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
        if (r.status === 401 || r.status === 403) { root.beginRefresh(); return }
        if (r.status < 200 || r.status >= 300 || r.body === "") return
        try {
          var json = JSON.parse(r.body)
          root.dbg("counts", r.body)
          if (Model.isAuthError(json)) { root.beginRefresh(); return }
          root.handleCounts(json)
        } catch (e) { root.dbg("counts parse error", e) }
      }
    }
  }

  function handleCounts(json) {
    var parsed = Model.parseCounts(json)
    var prev = {}
    try { prev = JSON.parse(state.lastCountsJson || "{}") || {} } catch (e) {}

    if (!state.baselined) {
      state.lastCountsJson = JSON.stringify(parsed.byType)
      state.lastTotal = parsed.total
      state.baselined = true
      return
    }

    var up = Model.diffCounts(prev, parsed.byType, state.lastTotal, parsed.total)
    state.lastCountsJson = JSON.stringify(parsed.byType)
    state.lastTotal = parsed.total

    // Only bother pulling the list if an *enabled* category moved.
    var relevant = false
    for (var i = 0; i < up.length; i++)
      if (root.notifyTypes.indexOf(up[i]) !== -1) { relevant = true; break }
    if (relevant) root.fetchMessages()
  }

  // ---- Poll: recent message list -----------------------------
  function fetchMessages() {
    if (messagesProc.running) return
    var limit = Math.max(10, (root.cfg.maxBurst || 5) * 3)
    messagesProc.command = curlArgs(Model.urlMessages(root.region, limit, 0))
    messagesProc.running = true
  }

  Process {
    id: messagesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = Model.splitHttp(text)
        if (r.status === 401 || r.status === 403) { root.beginRefresh(); return }
        if (r.status < 200 || r.status >= 300 || r.body === "") return
        try {
          var json = JSON.parse(r.body)
          root.dbg("messages", r.body)
          if (Model.isAuthError(json)) { root.beginRefresh(); return }
          root.handleMessages(json)
        } catch (e) { root.dbg("messages parse error", e) }
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

  // ---- Poll: point balance ----------------------------------
  function pollProfile() {
    if (!canPoll || !watchPoints || profileProc.running) return
    profileProc.command = curlArgs(Model.urlProfile(root.region))
    profileProc.running = true
  }

  Process {
    id: profileProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = Model.splitHttp(text)
        if (r.status === 401 || r.status === 403) { root.beginRefresh(); return }
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
    var pts = Model.parsePoints(json)
    if (pts === null) return
    if (state.lastPoints >= 0 && pts > state.lastPoints) {
      var delta = pts - state.lastPoints
      root.enqueueNotify("MakerWorld points",
        "+" + delta + "  (balance " + pts + ")",
        Model.glyphFor("points"),
        Model.siteBase(root.region) + "/en/my/points")
    }
    state.lastPoints = pts
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
        // re-kicks pollCounts. Nothing to do here but clear the flag.
        root.refreshFailedNotified = false
        tokenView.reload()
      } else if (!root.refreshFailedNotified) {
        root.refreshFailedNotified = true
        root.enqueueNotify("MakerWorld sign-in expired",
          "Run  makerworld-login  to reconnect",
          Model.glyphFor("system"),
          "")
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
    running: root.canPoll && root.watchPoints
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollProfile()
  }

  onCanPollChanged: if (canPoll) { Qt.callLater(pollCounts); if (watchPoints) Qt.callLater(pollProfile) }

  // Manual poke for testing: `omarchy-shell ipc call makerworld poll`
  IpcHandler {
    target: "makerworld"
    function poll(): void { root.resetBaselineAndPoll() }
    function status(): string {
      return JSON.stringify({
        hasToken: root.accessToken !== "",
        region: root.region,
        canPoll: root.canPoll,
        baselined: state.baselined,
        lastTotal: state.lastTotal,
        lastPoints: state.lastPoints,
        notifyTypes: root.notifyTypes
      })
    }
  }

  // Drop the baseline so the next poll re-seeds without notifying, then poll.
  function resetBaselineAndPoll() {
    state.baselined = false
    Qt.callLater(root.pollCounts)
  }
}
