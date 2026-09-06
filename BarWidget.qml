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

  visible: panelLoader.item && panelLoader.item.label !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: button.labelWidth

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

  // WidgetButton (not BarIconButton): the pill is a multi-char text label
  // ("<coins>  1,240  •3"), so it must size to its text.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // A warning triangle when the sign-in has lapsed, prefixed to whatever the
    // panel decided to show.
    readonly property string warn: (root.svc && (root.svc.connState === "expired"))
      ? String.fromCharCode(0xf071) + "  " : ""

    text: warn + (panelLoader.item ? panelLoader.item.label : "")
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : ""

    onPressed: function (b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.notify()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
