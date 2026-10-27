import QtQuick
import QtQuick.Controls
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "components"

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
  readonly property var activeOcrEngine: {
    var all = controller.info.ocr?.engines || []
    for (var i = 0; i < all.length; ++i) if (all[i].name === (controller.info.ocr?.engine || "tesseract")) return all[i]
    return null
  }
  property bool setupSkipped: false
  readonly property bool hasUsableProvider: {
    var all = controller.info.providers || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].status === "ready" || all[i].status === "untested") return true
    return false
  }
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
    return !!item && item !== keyCatcher && root.isInsideKeyCatcher(item)
  }

  function tint(a) { return Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, a) }
  function keyName(event) {
    var key = event.text ? event.text.toUpperCase() : ""
    if (event.key === Qt.Key_BracketLeft) key = "BRACKETLEFT"
    else if (event.key === Qt.Key_BracketRight) key = "BRACKETRIGHT"
    else if (event.key === Qt.Key_Comma) key = "COMMA"
    else if (event.key === Qt.Key_Period) key = "PERIOD"
    else if (event.key === Qt.Key_Slash) key = "SLASH"
    else if (event.key === Qt.Key_Backslash) key = "BACKSLASH"
    else if (event.key === Qt.Key_Semicolon) key = "SEMICOLON"
    else if (event.key === Qt.Key_Apostrophe) key = "APOSTROPHE"
    else if (event.key === Qt.Key_Minus) key = "MINUS"
    else if (event.key === Qt.Key_Equal) key = "EQUAL"
    else if (event.key === Qt.Key_QuoteLeft) key = "GRAVE"
    else if (event.key === Qt.Key_Space) key = "SPACE"
    else if (event.key === Qt.Key_Tab) key = "TAB"
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) key = "RETURN"
    else if (event.key === Qt.Key_Backspace) key = "BACKSPACE"
    else if (event.key === Qt.Key_Delete) key = "DELETE"
    else if (event.key === Qt.Key_Left) key = "LEFT"
    else if (event.key === Qt.Key_Right) key = "RIGHT"
    else if (event.key === Qt.Key_Up) key = "UP"
    else if (event.key === Qt.Key_Down) key = "DOWN"
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35)
      key = "F" + String(event.key - Qt.Key_F1 + 1)
    else if (event.key === Qt.Key_Escape) key = "ESCAPE"
    return key
  }
  function chordFromEvent(event) {
    var parts = []
    if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (event.modifiers & Qt.AltModifier) parts.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    var key = keyName(event)
    if (!key || key === "ESCAPE") return ""
    parts.push(key)
    return parts.join(" + ")
  }
  function isInsideKeyCatcher(item) {
    var current = item
    while (current) {
      if (current === keyCatcher) return true
      current = current.parent
    }
    return false
  }
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
      if (candidate !== keyCatcher && root.isInsideKeyCatcher(candidate)) {
        candidate.forceActiveFocus(forward ? Qt.TabFocusReason : Qt.BacktabFocusReason)
        return
      }
    }
  }
  readonly property var activeProvider: {
    var all = controller.info.providers || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].name === controller.info.provider) return all[i]
    return null
  }

  // Voices are stored as filenames like "en_US-amy-medium". That is an
  // identifier, not a name, and it is what the dropdown and the status line
  // were showing. Providers whose voice names are already words - kokoro's
  // af_heart - are left exactly as they are.
  function titleCase(word) {
    var w = String(word)
    return w.length ? w.charAt(0).toUpperCase() + w.slice(1) : w
  }

  function voiceName(key) {
    var parts = String(key).split("-")
    if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
      return root.titleCase(parts[1].replace(/_/g, " "))
    return String(key)
  }

  function voiceLabel(key) {
    var parts = String(key).split("-")
    if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
      return root.voiceName(key) + " · " + parts[0] + " · " + parts.slice(2).join("-")
    return String(key)
  }

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
  // Sentences, with any too long to read at a glance (OCR often has no
  // punctuation at all) cut at a word boundary so each fits the screen.
  readonly property var phrases: {
    var text = root.promptText, out = [], start = 0
    function push(end) {
      var piece = text.slice(start, end), lead = piece.length - piece.replace(/^\s+/, "").length
      var at = start + lead
      piece = piece.trim()
      while (piece.length > 160) {
        var cut = piece.lastIndexOf(" ", 140)
        if (cut < 60) cut = 140
        out.push({ text: piece.slice(0, cut).trim(), start: at })
        at += cut; piece = piece.slice(cut).replace(/^\s+/, function(m) { at += m.length; return "" })
      }
      if (piece.length) out.push({ text: piece, start: at })
      start = end
    }
    for (var i = 0; i < text.length; ++i) {
      var c = text.charAt(i)
      if (c === "\n") { push(i + 1); continue }
      if (".!?…".indexOf(c) < 0) continue
      var j = i + 1
      while (j < text.length && ".!?…\"'”’)]".indexOf(text.charAt(j)) >= 0) j++
      if (j >= text.length || /\s/.test(text.charAt(j))) { push(j); i = j - 1 }
    }
    push(text.length)
    return out
  }
  // Speech runs at an even pace closely enough to place the reader by the
  // share of audio already played.
  readonly property int phraseIndex: {
    var list = root.phrases
    if (!list.length) return 0
    var at = root.promptText.length * root.npProgress, found = 0
    for (var i = 0; i < list.length; ++i) if (list[i].start <= at) found = i
    return found
  }
  // A provider addressed by filename (piper) sends plain keys and we make them
  // readable here; one that lists {value, label} pairs names its own voices.
  readonly property var voiceOptions: {
    var list = controller.info.voices || [], out = []
    for (var i = 0; i < list.length; ++i) {
      var v = list[i]
      if (v && typeof v === "object")
        out.push({ label: String(v.label || v.value), value: String(v.value) })
      else
        out.push({ label: root.voiceLabel(v), value: String(v) })
    }
    return out
  }

  // What to call the active voice: the provider's own name for it if we were
  // given one, otherwise the identifier tidied up.
  function activeVoiceLabel() {
    var opts = root.voiceOptions, current = String(controller.info.voice || "")
    for (var i = 0; i < opts.length; ++i)
      if (opts[i].value === current) return opts[i].label
    return root.voiceName(current)
  }

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
          else if (root.captureAction !== "") {
            root.captureAction = ""
            root.capturedChord = ""
          } else root.close()
          event.accepted = true
          return
        }
        if (root.descendantControlActive) return
        if (root.captureAction !== "") {
          var chord = root.chordFromEvent(event)
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
              Button { text: "Cancel"; bordered: true; focusable: true; onClicked: { root.captureAction = ""; root.capturedChord = "" } }
              Button { text: "Use shortcut"; bordered: true; focusable: true; enabled: root.capturedChord !== ""; foreground: Commons.Color.accent; onClicked: { controller.setBinding(root.captureAction, root.capturedChord); root.captureAction = ""; root.capturedChord = "" } }
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
