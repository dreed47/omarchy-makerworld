import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup for the MakerWorld bar pill: point balance, unread breakdown, a list
// of recent activity (click to open on makerworld.com), "mark all read", and a
// compact settings form.
//
// Live numbers (points, unread counts, connection state) come from the headless
// Service.qml via `serviceFor`. The recent-activity list is this panel's own
// fetch, made when the popup opens and every couple of minutes while it stays
// open. Settings are written to the widget's shell.json entry with
// `omarchy-bar set`, which the shell hot-reloads.
Panel {
  id: root
  moduleName: "io.github.dreed47.makerworld"
  ipcTarget: "io.github.dreed47.makerworld"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false

  readonly property string pluginId: "io.github.dreed47.makerworld"
  readonly property var svc: root.bar && root.bar.shell ? root.bar.shell.serviceFor(pluginId) : null

  readonly property var cfg: (svc && svc.cfg) ? svc.cfg : Model.normalizedConfig(null)
  readonly property string region: svc ? String(svc.region || "global") : "global"
  readonly property string accessToken: svc ? String(svc.accessToken || "") : ""
  readonly property real points: svc ? svc.points : -1
  readonly property int followerCount: svc ? svc.followerCount : -1
  readonly property int boostTokens: svc ? svc.boostTokens : -1
  readonly property int totalDownloads: svc ? svc.totalDownloads : -1
  readonly property int totalLikes: svc ? svc.totalLikes : -1
  readonly property var unreadByType: svc ? svc.unreadByType : ({})
  readonly property int unreadTotal: svc ? svc.unreadTotal : 0
  readonly property string connState: svc ? String(svc.connState || "init") : "init"
  readonly property string profileName: svc ? String(svc.profileName || "") : ""

  readonly property string brandGlyph: String.fromCharCode(0xf1b2)  // nf-fa-cube
  readonly property string coinGlyph: Model.glyphFor("points")
  readonly property string bullet: String.fromCharCode(0x2022)

  // ---- Bar-pill text / tooltip (read by BarWidget.qml) ----------------
  //
  // Text only - the cube mark is drawn by the widget. Empty string = the pill
  // shows just the mark (fresh install, or points hidden with nothing unread).
  readonly property string pillText: {
    if (connState === "notoken") return ""
    var parts = []
    if (cfg.showPoints && points >= 0) parts.push(Model.groupNum(points))
    if (unreadTotal > 0) parts.push(bullet + unreadTotal)
    return parts.join("  ")
  }
  readonly property string label: pillText  // back-compat alias
  readonly property string tooltip: {
    if (connState === "notoken") return "MakerWorld — run makerworld-login to sign in"
    if (connState === "expired") return "MakerWorld — sign-in expired, run makerworld-login"
    var who = profileName !== "" ? profileName : "MakerWorld"
    return unreadTotal > 0 ? (who + " — " + unreadTotal + " unread") : who
  }

  // Right-click desktop notification (BarWidget.notify()).
  function statusLines() {
    if (connState === "notoken")
      return ["MakerWorld not signed in", "Run  makerworld-login  in a terminal."]
    var out = ["MakerWorld" + (profileName !== "" ? " — " + profileName : "")]
    if (points >= 0) {
      var pl = "Points: " + Model.groupNum(points)
      if (boostTokens > 0) pl += "   Boost tokens: " + boostTokens
      out.push(pl)
    }
    if (followerCount >= 0) out.push("Followers: " + Model.groupNum(followerCount))
    if (totalDownloads >= 0) {
      out.push("Downloads: " + Model.groupNum(totalDownloads)
        + (totalLikes >= 0 ? "   Likes: " + Model.groupNum(totalLikes) : ""))
    }
    var chips = Model.unreadChips(unreadByType)
    if (chips.length) {
      var bits = chips.map(function (c) { return c.count + " " + c.label })
      out.push("Unread: " + unreadTotal + "  (" + bits.join(", ") + ")")
    } else {
      out.push("No unread activity")
    }
    return out
  }
  readonly property string statusGlyph: coinGlyph

  // ---- Popup tabs --------------------------------------------------
  property string tab: "activity"   // "activity" | "models"
  property string designSort: "downloads"   // "downloads" | "likes" | "prints"

  // ---- Recent-activity list (this panel's own fetch) -----------------
  property var messages: []
  property bool loading: false
  property string listError: ""

  // ---- "My models" list -----------------------------------------
  property var myDesigns: []
  property int myDesignsTotal: 0
  property bool designsLoading: false
  property bool designsLoaded: false
  property string designsError: ""

  function fetchDesigns() {
    if (accessToken === "" || designsProc.running) return
    root.designsLoading = true
    designsProc.command = ["curl", "-sS", "--max-time", "25",
      "-H", "Authorization: Bearer " + accessToken,
      "-H", "User-Agent: bambu_network_agent/01.09.05.01",
      "-H", "Accept: application/json",
      "-w", "\n__HTTP__%{http_code}",
      Model.urlMyDesigns(region, 60, 0)]
    designsProc.running = true
  }

  Process {
    id: designsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.designsLoading = false
        var r = Model.splitHttp(text)
        if (r.status === 401 || r.status === 403) { root.designsError = "sign-in expired"; return }
        if (r.status < 200 || r.status >= 300) { root.designsError = "HTTP " + r.status; return }
        try {
          var parsed = Model.parseMyDesigns(JSON.parse(r.body), root.region)
          root.myDesigns = parsed.designs
          root.myDesignsTotal = parsed.total
          root.designsLoaded = true
          root.designsError = ""
        } catch (e) {
          root.designsError = "could not read the response"
        }
      }
    }
  }

  readonly property var sortedDesigns: Model.sortDesigns(root.myDesigns, root.designSort)

  // Recent activity is pulled one notification category at a time (comments,
  // model activity, system, community - not print jobs) and merged newest-first.
  property var catQueue: []
  property var catResults: []

  function refresh() {
    if (svc) { if (svc.pollCounts) svc.pollCounts(); if (svc.pollProfile) svc.pollProfile() }
    if (root.tab === "models" && !root.designsLoaded) root.fetchDesigns()
    if (accessToken === "" || listProc.running || root.catQueue.length > 0) return
    root.loading = true
    root.catResults = []
    var q = []
    for (var i = 0; i < Model.MESSAGE_CATEGORIES.length; i++) q.push(Model.MESSAGE_CATEGORIES[i].param)
    root.catQueue = q
    pumpList()
  }

  function pumpList() {
    if (listProc.running) return
    if (root.catQueue.length === 0) {
      root.messages = Model.mergeMessageLists(root.catResults, root.region, { dropPrint: true, limit: 30 })
      root.loading = false
      if (root.messages.length > 0) root.listError = ""
      return
    }
    var cat = root.catQueue.shift()
    listProc.command = ["curl", "-sS", "--max-time", "20",
      "-H", "Authorization: Bearer " + accessToken,
      "-H", "User-Agent: bambu_network_agent/01.09.05.01",
      "-H", "Accept: application/json",
      "-w", "\n__HTTP__%{http_code}",
      Model.urlMessages(region, 15, 0, cat)]
    listProc.running = true
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = Model.splitHttp(text)
        if (r.status === 401 || r.status === 403) {
          root.listError = "sign-in expired"; root.catQueue = []; root.loading = false; return
        }
        if (r.status >= 200 && r.status < 300) {
          try {
            var raw = Model.extractMessages(JSON.parse(r.body))
            var out = []
            for (var i = 0; i < raw.length; i++) out.push(Model.formatMessage(raw[i], root.region))
            root.catResults = root.catResults.concat([out])
          } catch (e) {
            root.listError = "could not read the response"
          }
        } else {
          root.listError = "HTTP " + r.status
        }
        Qt.callLater(root.pumpList)
      }
    }
  }

  Process { id: openProc }
  function openUrl(url) {
    if (url && url !== "") Quickshell.execDetached(["omarchy-launch-browser", String(url)])
  }
  function openMyModels() {
    // The notification centre - the thing this popup mirrors.
    openUrl(Model.messagesPageUrl(region))
  }
  function selectTab(t) {
    root.tab = t
    if (t === "models" && !root.designsLoaded) root.fetchDesigns()
  }
  function markAllRead() {
    if (svc && svc.markAllRead) svc.markAllRead()
    Qt.callLater(root.refresh)
  }

  // "Nm ago" ticker, only while the popup is open.
  property double nowMs: Date.now()
  Timer {
    interval: 60000
    repeat: true
    running: root.opened
    onRunningChanged: if (running) root.nowMs = Date.now()
    onTriggered: root.nowMs = Date.now()
  }
  Timer {
    id: listTimer
    interval: 120000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Lifecycle -----------------------------------------------------
  function open() {
    openedFromHotkey = false
    root.controller.show()
    root.refresh()
  }
  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
  }
  function close() {
    if (root.editingSettings) root.cancelEditingSettings()
    root.controller.hide()
  }
  function toggle() { root.opened ? root.close() : root.openFromHotkey() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- Settings form ----------------------------------------------
  property bool editingSettings: false
  property bool savingSettings: false
  property string draftRegion: "global"
  property string draftNotify: "on"
  property string draftShowPoints: "on"
  property string draftNotifyTypes: "comment,reply,like,follow,system,points"
  property string draftPollSeconds: "300"
  property var settingsSaveQueue: []

  function startEditingSettings() {
    draftRegion = String(cfg.region || "global")
    draftNotify = cfg.notify ? "on" : "off"
    draftShowPoints = cfg.showPoints ? "on" : "off"
    draftNotifyTypes = (cfg.notifyTypes || Model.KNOWN_TYPES).join(",")
    draftPollSeconds = String(cfg.pollSeconds || 300)
    editingSettings = true
  }
  function cancelEditingSettings() { editingSettings = false }

  function saveSettings() {
    if (savingSettings) return
    savingSettings = true
    var poll = parseInt(draftPollSeconds, 10)
    if (isNaN(poll) || poll < 120) poll = 120
    settingsSaveQueue = [
      ["region", Model.normalizedRegion(draftRegion)],
      ["notify", draftNotify === "off" ? "off" : "on"],
      ["showPoints", draftShowPoints === "off" ? "off" : "on"],
      ["notifyTypes", draftNotifyTypes.replace(/\s+/g, "")],
      ["pollSeconds", String(poll)]
    ]
    runNextSettingsSave()
  }
  function runNextSettingsSave() {
    if (settingsSaveQueue.length === 0) {
      savingSettings = false
      editingSettings = false
      Qt.callLater(root.refresh)
      return
    }
    var pair = settingsSaveQueue.shift()
    settingsSaveProc.command = ["omarchy-bar", "set", root.ipcTarget, pair[0], pair[1]]
    settingsSaveProc.running = true
  }
  Process {
    id: settingsSaveProc
    onExited: function (code) { root.runNextSettingsSave() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function settings(): void { root.openFromHotkey(); root.startEditingSettings() }
  }

  // ---- UI ---------------------------------------------------------
  readonly property color fg: root.bar ? root.bar.foreground : "#e0e0e0"
  readonly property color dim: root.bar ? Qt.darker(fg, 1.5) : "#909090"
  readonly property string mono: root.bar ? root.bar.fontFamily : "monospace"

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(col.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingSettings
      onReturnRequested: root.startEditingSettings()
      onCloseRequested: root.editingSettings ? root.cancelEditingSettings() : root.close()
      onTabRequested: function (direction) { if (!root.editingSettings) root.switchPanel(direction) }

      Column {
        id: col
        width: parent.width
        spacing: Style.space(12)

        // ---- Header: title + gear
        Item {
          width: parent.width
          height: Style.space(24)
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: root.brandGlyph + "  MakerWorld"
              + (root.profileName !== "" ? "  ·  " + root.profileName : "")
            color: root.fg
            font.family: root.mono
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Rectangle {
            id: gearBtn
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(24); height: Style.space(24)
            radius: Style.cornerRadius
            color: gearArea.containsMouse
              ? (root.bar ? Style.hoverFillFor(root.fg, Color.accent) : "#333") : "transparent"
            Text {
              anchors.centerIn: parent
              text: root.editingSettings ? String.fromCharCode(0x00d7) : String.fromCharCode(0xf013)
              color: root.dim
              font.family: root.mono
              font.pixelSize: root.editingSettings ? Style.font.title : Style.font.body
            }
            MouseArea {
              id: gearArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.editingSettings ? root.cancelEditingSettings() : root.startEditingSettings()
            }
          }
        }

        // ================= DATA VIEW =================
        Column {
          visible: !root.editingSettings
          width: parent.width
          spacing: Style.space(12)

          // ---- Setup / connection banner
          Rectangle {
            visible: root.connState === "notoken" || root.connState === "expired"
            width: parent.width
            height: visible ? bannerText.implicitHeight + Style.space(14) : 0
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.bar ? root.bar.urgent : "#cc4444"
            Text {
              id: bannerText
              x: Style.space(10); y: Style.space(7)
              width: parent.width - Style.space(20)
              wrapMode: Text.WordWrap
              text: (root.connState === "expired"
                ? "Your Bambu Cloud sign-in has expired.\n"
                : "Not signed in to Bambu Cloud.\n")
                + "Run  makerworld-login  in a terminal, then reopen this."
              color: root.fg
              font.family: root.mono
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Points hero
          Row {
            visible: root.points >= 0
            width: parent.width
            spacing: Style.space(10)
            Text {
              text: root.coinGlyph
              color: Color.accent
              font.family: root.mono
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: Model.groupNum(root.points)
                color: root.fg
                font.family: root.mono
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: "points"
                color: root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }
            Item { width: Style.space(4); height: 1 }
            // boost tokens, followers, lifetime downloads / likes
            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)
              visible: root.boostTokens > 0 || root.followerCount >= 0 || root.totalDownloads >= 0
              Text {
                visible: root.boostTokens > 0
                text: String.fromCharCode(0xf0e7) + "  " + root.boostTokens
                  + (root.boostTokens === 1 ? " boost token" : " boost tokens")
                color: root.fg
                font.family: root.mono
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: root.followerCount >= 0
                text: Model.glyphFor("follow") + "  " + Model.groupNum(root.followerCount) + " followers"
                color: root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: root.totalDownloads >= 0
                text: Model.STAT_GLYPH["downloads"] + "  " + Model.groupNum(root.totalDownloads) + " downloads"
                  + (root.totalLikes >= 0 ? "    " + Model.STAT_GLYPH["likes"] + "  " + Model.groupNum(root.totalLikes) : "")
                color: root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Unread chips
          Flow {
            visible: root.unreadTotal > 0
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: Model.unreadChips(root.unreadByType)
              Rectangle {
                required property var modelData
                height: Style.space(22)
                width: chipRow.implicitWidth + Style.space(14)
                radius: height / 2
                color: "transparent"
                border.width: 1
                border.color: root.dim
                Row {
                  id: chipRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)
                  Text {
                    text: modelData.glyph
                    color: Color.accent
                    font.family: root.mono
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: modelData.count + " " + modelData.label
                    color: root.fg
                    font.family: root.mono
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---- Tab strip: Activity | My models
          Row {
            width: parent.width
            spacing: Style.space(14)
            Repeater {
              model: [
                { key: "activity", label: "Activity" },
                { key: "models", label: "My models" }
              ]
              Text {
                required property var modelData
                text: modelData.label
                color: root.tab === modelData.key ? Color.accent : root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: root.tab === modelData.key
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectTab(modelData.key)
                }
              }
            }
          }

          // ================= ACTIVITY TAB =================
          Column {
          visible: root.tab === "activity"
          width: parent.width
          spacing: Style.space(12)

          // ---- Recent activity list
          Text {
            width: parent.width
            text: "RECENT ACTIVITY"
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Text {
            visible: root.messages.length === 0
            width: parent.width
            text: root.loading ? "loading…"
              : (root.listError !== "" ? "Couldn't load: " + root.listError
                : "Nothing recent.")
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            visible: root.messages.length > 0
            width: parent.width
            height: Math.min(Style.space(260), listCol.implicitHeight + Style.space(4))
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: Qt.darker(root.fg, 1.8)
            clip: true
            Flickable {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              contentWidth: width
              contentHeight: listCol.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              Column {
                id: listCol
                width: parent.width
                Repeater {
                  model: root.messages
                  Rectangle {
                    required property var modelData
                    width: listCol.width
                    height: rowCol.implicitHeight + Style.space(10)
                    color: rowArea.containsMouse
                      ? (root.bar ? Style.hoverFillFor(root.fg, Color.accent) : "#2a2a2a") : "transparent"
                    Column {
                      id: rowCol
                      x: Style.space(8)
                      y: Style.space(5)
                      width: parent.width - Style.space(16)
                      spacing: Style.space(2)
                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        Text {
                          text: modelData.glyph !== undefined ? modelData.glyph : Model.glyphFor(modelData.cls)
                          color: Color.accent
                          font.family: root.mono
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          text: modelData.title
                          color: root.fg
                          font.family: root.mono
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                        Item { width: 1; height: 1 }
                      }
                      Text {
                        width: parent.width
                        text: modelData.body
                        color: root.dim
                        font.family: root.mono
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WordWrap
                      }
                      Text {
                        text: Model.relTime(modelData.ts, root.nowMs)
                        color: Qt.darker(root.dim, 1.1)
                        font.family: root.mono
                        font.pixelSize: Style.font.caption - 1
                      }
                    }
                    MouseArea {
                      id: rowArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openUrl(modelData.url)
                    }
                  }
                }
              }
            }
          }

          // ---- Actions
          Row {
            width: parent.width
            spacing: Style.space(8)
            Rectangle {
              width: (parent.width - Style.space(8)) / 2
              height: Style.space(28)
              radius: Style.cornerRadius
              color: mrArea.containsMouse
                ? (root.bar ? Style.hoverFillFor(root.fg, Color.accent) : "#333") : "transparent"
              border.width: 1
              border.color: root.dim
              enabled: root.unreadTotal > 0
              opacity: enabled ? 1 : 0.4
              Text {
                anchors.centerIn: parent
                text: "Mark all read"
                color: root.fg
                font.family: root.mono
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: mrArea
                anchors.fill: parent
                enabled: root.unreadTotal > 0
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.markAllRead()
              }
            }
            Rectangle {
              width: (parent.width - Style.space(8)) / 2
              height: Style.space(28)
              radius: Style.cornerRadius
              color: omArea.containsMouse
                ? (root.bar ? Style.hoverFillFor(root.fg, Color.accent) : "#333") : "transparent"
              border.width: 1
              border.color: root.dim
              Text {
                anchors.centerIn: parent
                text: "Notifications " + String.fromCharCode(0x2197)
                color: root.fg
                font.family: root.mono
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: omArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openMyModels()
              }
            }
          }
          }
          // ================= MY MODELS TAB =================
          Column {
            visible: root.tab === "models"
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              height: sortRow.implicitHeight
              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "MY MODELS" + (root.myDesignsTotal > 0 ? "  ·  " + root.myDesignsTotal : "")
                color: root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Row {
                id: sortRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)
                Repeater {
                  model: [
                    { key: "downloads", label: "↓" },
                    { key: "likes", label: "♥" },
                    { key: "prints", label: "⎙" }
                  ]
                  Text {
                    required property var modelData
                    text: modelData.label
                    color: root.designSort === modelData.key ? Color.accent : root.dim
                    font.family: root.mono
                    font.pixelSize: Style.font.caption
                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(3)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.designSort = modelData.key
                    }
                  }
                }
              }
            }

            Text {
              visible: root.myDesigns.length === 0
              width: parent.width
              text: root.designsLoading ? "loading your models…"
                : (root.designsError !== "" ? "Couldn't load: " + root.designsError
                  : "No published models.")
              color: root.dim
              font.family: root.mono
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              visible: root.myDesigns.length > 0
              width: parent.width
              height: Math.min(Style.space(300), dCol.implicitHeight + Style.space(4))
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: Qt.darker(root.fg, 1.8)
              clip: true
              Flickable {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                contentWidth: width
                contentHeight: dCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                Column {
                  id: dCol
                  width: parent.width
                  Repeater {
                    model: root.sortedDesigns
                    Rectangle {
                      required property var modelData
                      width: dCol.width
                      height: dRow.implicitHeight + Style.space(10)
                      color: dArea.containsMouse
                        ? (root.bar ? Style.hoverFillFor(root.fg, Color.accent) : "#2a2a2a") : "transparent"
                      Column {
                        id: dRow
                        x: Style.space(8)
                        y: Style.space(5)
                        width: parent.width - Style.space(16)
                        spacing: Style.space(2)
                        Text {
                          width: parent.width
                          text: modelData.title
                          color: root.fg
                          font.family: root.mono
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          elide: Text.ElideRight
                        }
                        Text {
                          text: "↓ " + Model.groupNum(modelData.downloads)
                            + "    ♥ " + Model.groupNum(modelData.likes)
                            + "    ⎙ " + Model.groupNum(modelData.prints)
                            + (modelData.comments > 0 ? "    " + Model.glyphFor("comment") + " " + modelData.comments : "")
                          color: root.dim
                          font.family: root.mono
                          font.pixelSize: Style.font.caption - 1
                        }
                      }
                      MouseArea {
                        id: dArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openUrl(modelData.url)
                      }
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignRight
              text: "All models on MakerWorld " + String.fromCharCode(0x2197)
              color: Color.accent
              font.family: root.mono
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openUrl(Model.myModelsUrl(root.region))
              }
            }
          }
        }

        // ================= SETTINGS VIEW =================
        Column {
          visible: root.editingSettings
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "SETTINGS"
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          // region
          Column {
            width: parent.width
            spacing: Style.space(3)
            Text {
              text: "REGION  (global or china)"
              color: root.dim; font.family: root.mono; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            }
            TextField {
              width: parent.width
              enabled: !root.savingSettings
              text: root.draftRegion
              foreground: root.fg
              font.family: root.mono
              onTextChanged: root.draftRegion = text
            }
          }

          // notifyTypes
          Column {
            width: parent.width
            spacing: Style.space(3)
            Text {
              text: "NOTIFY FOR  (comma list, or 'all')"
              color: root.dim; font.family: root.mono; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            }
            TextField {
              width: parent.width
              enabled: !root.savingSettings
              text: root.draftNotifyTypes
              foreground: root.fg
              font.family: root.mono
              onTextChanged: root.draftNotifyTypes = text
            }
          }

          // pollSeconds
          Column {
            width: parent.width
            spacing: Style.space(3)
            Text {
              text: "CHECK EVERY  (seconds, minimum 120)"
              color: root.dim; font.family: root.mono; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            }
            TextField {
              width: parent.width
              enabled: !root.savingSettings
              text: root.draftPollSeconds
              foreground: root.fg
              font.family: root.mono
              inputMethodHints: Qt.ImhDigitsOnly
              onTextChanged: root.draftPollSeconds = text
            }
          }

          // on/off toggles
          Repeater {
            model: [
              { key: "notify", label: "Desktop notifications" },
              { key: "showPoints", label: "Show points in the bar pill" }
            ]
            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width - Style.space(70)
                text: modelData.label
                color: root.fg
                font.family: root.mono
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              Rectangle {
                width: Style.space(62); height: Style.space(24)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: root.dim
                property bool on: modelData.key === "notify"
                  ? (root.draftNotify !== "off") : (root.draftShowPoints !== "off")
                Text {
                  anchors.centerIn: parent
                  text: parent.on ? "on" : "off"
                  color: parent.on ? Color.accent : root.dim
                  font.family: root.mono
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  enabled: !root.savingSettings
                  onClicked: {
                    if (modelData.key === "notify")
                      root.draftNotify = (root.draftNotify === "off") ? "on" : "off"
                    else
                      root.draftShowPoints = (root.draftShowPoints === "off") ? "on" : "off"
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Token and less-common options live in "
              + "~/.config/omarchy/makerworld/config.json"
            color: Qt.darker(root.dim, 1.1)
            font.family: root.mono
            font.pixelSize: Style.font.caption - 1
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Rectangle {
              width: (parent.width - Style.space(8)) / 2
              height: Style.space(28)
              radius: Style.cornerRadius
              color: saveArea.containsMouse ? (root.bar ? Style.hoverFillFor(root.fg, Color.accent) : "#333") : "transparent"
              border.width: 1
              border.color: Color.accent
              Text {
                anchors.centerIn: parent
                text: root.savingSettings ? "saving…" : "Save"
                color: root.fg; font.family: root.mono; font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: saveArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                enabled: !root.savingSettings
                onClicked: root.saveSettings()
              }
            }
            Rectangle {
              width: (parent.width - Style.space(8)) / 2
              height: Style.space(28)
              radius: Style.cornerRadius
              color: cancelArea.containsMouse ? (root.bar ? Style.hoverFillFor(root.fg, Color.accent) : "#333") : "transparent"
              border.width: 1
              border.color: root.dim
              Text {
                anchors.centerIn: parent
                text: "Cancel"
                color: root.fg; font.family: root.mono; font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: cancelArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cancelEditingSettings()
              }
            }
          }
        }
      }
    }
  }
}
