import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for MakerWorld. Shows the point balance and an unread badge; the
// popup (Panel.qml, loaded lazily) holds the activity list and owns its own
// message fetch. The headless Service.qml owns polling and notifications and
// publishes the numbers this pill reads.
//
// Structure mirrors the Tempest Weather plugin's widget so the bar's popout
// coordinator, hotkey routing, and popout-switch handoff behave the same.
BarWidget {
  id: root
  moduleName: "io.github.dreed47.makerworld"

  readonly property string pluginId: "io.github.dreed47.makerworld"
  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(pluginId) : null

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }
  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }
  function notify() {
    if (!root.bar || !panelLoader.item) return
    var lines = panelLoader.item.statusLines()
    if (!lines || lines.length === 0) return
    var headline = lines.shift()
    var body = lines.join("\n")
    var cmd = "omarchy-notification-send --app-name MakerWorld " + root.bar.shellQuote(headline)
    if (body !== "") cmd += " " + root.bar.shellQuote(body)
    var g = panelLoader.item.statusGlyph
    if (g && g !== "") cmd += " -g " + root.bar.shellQuote(g)
    root.bar.run(cmd)
  }

  // Popout contract expected by Bar.findPanelWidget / requestPopout.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: panelLoader.item !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: pillRow.implicitWidth

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The MakerWorld cube mark, then the point balance / unread badge as text.
  // WidgetButton owns click routing, tooltip, and the bar's reveal wiring; its
  // own centred label is switched off and we lay out our own Row instead.
  readonly property bool expired: root.svc && root.svc.connState === "expired"
  readonly property string pillText: panelLoader.item ? String(panelLoader.item.pillText || "") : ""

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : ""
    fixedWidth: pillRow.implicitWidth + Style.spaceReal(17)

    onPressed: function (b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.notify()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.spaceReal(5)

      MakerWorldMark {
        id: mark
        anchors.verticalCenter: parent.verticalCenter
        readonly property int side: Math.max(12, Math.round((root.bar ? root.bar.barSize : 30) * 0.6))
        width: side
        height: side
        color: button.foreground
        opacity: root.expired ? 0.45 : 1
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.expired || root.pillText !== ""
        text: (root.expired ? String.fromCharCode(0xf071) + "  " : "") + root.pillText
        color: root.expired && root.bar ? root.bar.urgent : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }
  }
}
