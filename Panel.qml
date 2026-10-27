import QtQuick
import QtQuick.Controls
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "components"
import "components/utils.js" as Utils

Panel {
  id: root
  moduleName: "io.github.jagrat7.omarchy-tts-local"
  ipcTarget: moduleName
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Commons.Color.muted
  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  property int currentTab: 0
  readonly property var tabNames: ["Overview", "Providers", "Preferences", "Languages", "Keys"]
  // Sections test the name, not the index, so adding or reordering a tab
  // touches only the list above.
  readonly property string currentTabName: tabNames[currentTab] || ""
  property bool browsing: false
  property string voiceFilter: ""
  property string previewSource: "Visit https://omarchy.org in ~2s and run `speak --help`."
  property string sampleText: "Highlight any text and press the key. This is how it sounds right now."
  property string captureAction: ""
  property string capturedChord: ""
  property var autoVerified: ({})
  onActiveProviderChanged: {
    var p = activeProvider
    if (!p || p.status !== "untested" || autoVerified[p.name] || controller.verifying !== "") return
    autoVerified[p.name] = true
    controller.verifyProvider(p.name)
  }
  readonly property var activeOcrEngine: Utils.byName(controller.info.ocr?.engines || [], controller.ocrEngine)
  property bool setupSkipped: false
  readonly property bool hasUsableProvider: (controller.info.providers || []).some(Utils.isUsable)
  readonly property bool needsSetup: controller.infoLoaded && controller.setupLoaded
                                     && !controller.setup.ready
                                     && !hasUsableProvider && !setupSkipped
  // PanelKeyCatcher's all-or-nothing `blocked` switch cannot both preserve
  // native control keys and contain Tab inside this popup. Track any focused
  // descendant instead: the handler below always owns Tab, then yields every
  // other key to the focused editor, button, toggle, row or dropdown.
  readonly property bool descendantControlActive: {
    var panelWindow = keyCatcher.Window.window
    var item = panelWindow ? panelWindow.activeFocusItem : null
    return !!item && item !== keyCatcher && Utils.isInside(item, keyCatcher)
  }

  function tint(a) { return Utils.withAlpha(Commons.Color.accent, a) }
  function cancelCapture() { root.captureAction = ""; root.capturedChord = "" }
  function moveTabFocus(direction) {
    var forward = direction >= 0
    var panelWindow = keyCatcher.Window.window
    var current = panelWindow ? panelWindow.activeFocusItem : keyCatcher
    if (!current || typeof current.nextItemInFocusChain !== "function") current = keyCatcher
    var candidate = current
    // This key layer deliberately owns Tab before its descendants. Walk the
    // real Qt focus chain and keep focus inside this popup, including dynamic
    // repeater delegates, instead of maintaining a brittle manual list.
    for (var i = 0; i < 128; ++i) {
      candidate = candidate.nextItemInFocusChain(forward)
      if (!candidate || candidate === current) break
      if (candidate !== keyCatcher && Utils.isInside(candidate, keyCatcher)) {
        candidate.forceActiveFocus(forward ? Qt.TabFocusReason : Qt.BacktabFocusReason)
        return
      }
    }
  }
  readonly property var activeProvider: Utils.byName(controller.info.providers || [], controller.info.provider)

  // Playback --------------------------------------------------------------
  readonly property string playState: controller.status
  // Nothing to speak with, whoever supplies the voices; only the download
  // offer depends on whether this provider's voices can be fetched.
  readonly property bool voiceMissing: controller.infoLoaded && root.voiceOptions.length === 0
  function openCatalogue() { root.browsing = true; root.voiceFilter = ""; controller.loadCatalogue() }
  // The poll lands every half second; between answers the clock runs on
  // locally so the bar and the highlighted phrase move smoothly.
  property real nowPlayingStamp: Date.now()
  property real clock: Date.now()
  Connections { target: controller; function onNowPlayingChanged() { root.nowPlayingStamp = Date.now(); root.clock = root.nowPlayingStamp } }
  Timer { interval: 250; repeat: true; running: root.opened && root.playState === "speaking"; onTriggered: root.clock = Date.now() }
  readonly property real npDuration: Math.max(0, Number(controller.nowPlaying.duration) || 0)
  readonly property real npElapsed: {
    var base = Number(controller.nowPlaying.elapsed) || 0
    if (root.playState === "speaking") base += Math.max(0, root.clock - root.nowPlayingStamp) / 1000
    return root.npDuration > 0 ? Math.min(root.npDuration, base) : base
  }
  readonly property real npProgress: root.npDuration > 0 ? root.npElapsed / root.npDuration : 0
  // A string, so a poll that returns the same text does not rebuild the
  // prompter (an array would be a new value every time and reset the list).
  readonly property string promptText: String(controller.nowPlaying.text || "")
  readonly property var phrases: Utils.splitPhrases(root.promptText)
  readonly property int phraseIndex: Utils.phraseAt(root.phrases, root.promptText.length * root.npProgress)
  readonly property var voiceOptions: Utils.voiceOptions(controller.info.voices || [])

  TtsController { id: controller; statusSource: root.hostWidget; panelOpen: root.opened }
  // The panel always opens on the Overview, the player for whatever is being
  // read. The sample text is still restored, but only once real settings
  // have arrived; a callLater fires long before the 200 ms read returns.
  property bool restorePending: false

  onOpenedChanged: {
    if (opened) {
      restorePending = true
      currentTab = 0
      controller.refresh(); controller.refreshBindings(); controller.refreshSetup(); controller.refreshDownload()
    }
  }

  function restoreFromInfo() {
    if (!restorePending || !controller.infoLoaded) return
    restorePending = false
    sampleText = String(controller.info.ui?.sampleText || sampleText)
    controller.previewText(previewSource)
  }
  Connections { target: controller; function onInfoChanged() { root.restoreFromInfo() } }

  KeyboardPanel {
    id: panelCard
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panelCard.fittedContentWidth(Style.space(420))
    contentHeight: panelCard.fittedContentHeight(body.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.moveTabFocus((event.modifiers & Qt.ShiftModifier)
                            || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (overviewTab.voiceDropdown.popupOpen) overviewTab.voiceDropdown.close()
          else if (root.captureAction !== "") root.cancelCapture()
          else root.close()
          event.accepted = true
          return
        }
        if (root.descendantControlActive) return
        if (root.captureAction !== "") {
          var chord = Utils.chordFromEvent(event)
          if (chord) root.capturedChord = chord
          event.accepted = true; return
        }
        var tabCount = root.tabNames.length
        if (event.key === Qt.Key_Left) root.currentTab = (root.currentTab + tabCount - 1) % tabCount
        else if (event.key === Qt.Key_Right) root.currentTab = (root.currentTab + 1) % tabCount
        else if (event.key >= Qt.Key_1 && event.key < Qt.Key_1 + tabCount) root.currentTab = event.key - Qt.Key_1
        // Space is play/pause on the Overview, as it is in any player.
        else if (event.key === Qt.Key_Space && root.currentTabName === "Overview" && controller.speaking) controller.togglePause()
        else return
        event.accepted = true
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: body.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: body.implicitHeight > scrollArea.height
        }

        Column {
          id: body
          width: scrollArea.availableWidth
          spacing: Style.space(12)

        Item {
          width: parent.width; height: Math.max(headerIcon.implicitHeight, headerTitle.implicitHeight)
          Text { id: headerIcon; text: "󰕾"; color: controller.speaking ? Commons.Color.accent : root.fg; font.family: root.ff; font.pixelSize: Style.fontPx(1.3); anchors.verticalCenter: parent.verticalCenter }
          Text { id: headerTitle; anchors.left: headerIcon.right; anchors.leftMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; text: "Text to speech"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle }
          Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; // The shortcut is the whole point of the tool; the panel is where
                 // someone finds out what it is.
                 text: { var b = controller.bindings.bindings
                         if (b && b.selection && b.selection.chord) return b.selection.chord
                         return "on-demand accessibility" }
                 color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }
        Row {
          width: parent.width; spacing: Style.space(14); visible: !root.needsSetup
          Repeater {
            model: root.tabNames
            delegate: Item {
              required property string modelData
              required property int index
              width: tabLabel.implicitWidth; height: tabLabel.implicitHeight + Style.space(6)
              activeFocusOnTab: true
              Accessible.role: Accessible.PageTab
              Accessible.name: modelData
              Accessible.selected: root.currentTab === index
              Accessible.onPressAction: root.currentTab = index
              Keys.onSpacePressed: root.currentTab = index
              Keys.onReturnPressed: root.currentTab = index
              Keys.onEnterPressed: root.currentTab = index
              Text { id: tabLabel; text: parent.modelData; color: root.currentTab === parent.index ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Commons.Color.accent; visible: root.currentTab === parent.index }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.currentTab = parent.index }
            }
          }
        }
        PanelSeparator { width: parent.width; foreground: root.fg }

        FirstRunWizard {
          width: parent.width; visible: root.needsSetup; controller: controller; foreground: root.fg
          onSkipped: root.setupSkipped = true
        }

        // Each tab is a component; the panel decides which one shows.
        OverviewTab {
          id: overviewTab
          width: parent.width; visible: !root.needsSetup && root.currentTabName === "Overview" && !root.browsing
          panel: root; controller: controller
        }
        VoiceBrowser {
          width: parent.width; visible: !root.needsSetup && root.currentTabName === "Overview" && root.browsing
          panel: root; controller: controller
        }
        ProvidersTab {
          width: parent.width; visible: !root.needsSetup && root.currentTabName === "Providers"
          panel: root; controller: controller
        }
        PreferencesTab {
          width: parent.width; visible: !root.needsSetup && root.currentTabName === "Preferences"
          panel: root; controller: controller
        }
        LanguagesTab {
          width: parent.width; visible: !root.needsSetup && root.currentTabName === "Languages"
          panel: root; controller: controller
        }
        KeysTab {
          width: parent.width; visible: !root.needsSetup && root.currentTabName === "Keys"
          panel: root; controller: controller
          onCaptureRequested: function(actionName, chord) { root.captureAction = actionName; root.capturedChord = chord; keyCatcher.forceActiveFocus() }
        }

        Rectangle {
          width: parent.width; height: captureColumn.implicitHeight + 16; radius: 7; visible: root.captureAction !== ""; color: Commons.Color.background; border.width: 1; border.color: Commons.Color.accent
          Column { id: captureColumn; anchors.fill: parent; anchors.margins: 8; spacing: 6
            Text { text: "Press the new shortcut for “" + root.captureAction + "”"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.body }
            Text { text: root.capturedChord || "Waiting for keys…"; color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.subtitle }
            Row { spacing: 8
              Button { text: "Cancel"; bordered: true; focusable: true; onClicked: root.cancelCapture() }
              Button { text: "Use shortcut"; bordered: true; focusable: true; enabled: root.capturedChord !== ""; foreground: Commons.Color.accent; onClicked: { controller.setBinding(root.captureAction, root.capturedChord); root.cancelCapture() } }
            }
          }
        }

        // Elsewhere in the panel, a line keeps what is being read in reach:
        // the phrase, pause and stop, and a way back to the Overview.
        PanelSeparator { width: parent.width; foreground: root.fg; visible: nowPlayingStrip.visible || errorLine.visible }
        Item {
          id: nowPlayingStrip
          width: parent.width; height: Math.max(stripPause.implicitHeight, stripPhrase.implicitHeight)
          visible: !root.needsSetup && root.currentTab !== 0 && controller.speaking
          InlineAction {
            id: stripPause; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: controller.paused ? "󰐊" : "󰏤"; Accessible.name: controller.paused ? "Resume" : "Pause"
            enabled: root.playState !== "preparing" && controller.nowPlaying.canPause === true
            color: enabled ? Commons.Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.body
            onTriggered: controller.togglePause()
          }
          InlineAction {
            id: stripPhrase
            anchors.left: stripPause.right; anchors.leftMargin: Style.space(10)
            anchors.right: stripStop.left; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: root.playState === "preparing" || !root.phrases.length ? "Getting the text ready…"
                  : root.phrases[root.phraseIndex].text
            Accessible.name: "Show what is being read"
            color: hovered || activeFocus ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            onTriggered: root.currentTab = 0
          }
          InlineAction {
            id: stripStop; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: "󰓛"; Accessible.name: "Stop"
            color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.body
            onTriggered: controller.stop()
          }
        }
        Text { id: errorLine; width: parent.width; visible: controller.error !== ""; textFormat: Text.PlainText; text: controller.error; wrapMode: Text.WordWrap; color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
      }
      }
    }
  }
}
