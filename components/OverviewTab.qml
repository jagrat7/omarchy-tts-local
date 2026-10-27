import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "utils.js" as Utils

// A teleprompter: the words being read are the largest thing on the
// panel, with transport and speed under them. When nothing is being
// read the same screen holds the sample text, so pressing Play turns
// what you typed into what you are hearing without anything moving.
Column {
  id: root
  required property var panel
  required property var controller
  spacing: Style.space(10)

  // PanelSlider ends a drag with `liveValue = value`, assuming the owner has
  // already applied the new number. Ours is written to disk and read back,
  // which takes about 200 ms, so `value` still held the old number and the
  // knob snapped back to it before jumping forward again. This holds the
  // value the user just chose so `value` is already correct at that instant;
  // it is cleared as soon as a settings read confirms the write. The
  // confidence slider on Preferences does the same.
  property real rateOverride: -1
  // The panel closes the list with Escape.
  readonly property alias voiceDropdown: voiceDropdown
  Connections {
    target: controller
    function onInfoChanged() {
      // The controller discards reads older than the last write, so anything
      // arriving here already reflects it.
      root.rateOverride = -1
      if (!sampleField.activeFocus) {
        panel.sampleText = String(controller.info.ui?.sampleText || panel.sampleText)
        Qt.callLater(function() { sampleField.cursorPosition = 0 })
      }
    }
  }

  readonly property real rateValue:
    Math.max(root.rateMinimum, Math.min(root.rateMaximum,
      rateOverride >= 0 ? rateOverride : Number(controller.info.rate || 1)))
  readonly property bool rateSupported: !!panel.activeProvider
                                        && panel.activeProvider.rateMin !== null
                                        && panel.activeProvider.rateMax !== null
  readonly property real rateMinimum: root.rateSupported ? Number(panel.activeProvider.rateMin) : 1
  readonly property real rateMaximum: root.rateSupported ? Number(panel.activeProvider.rateMax) : 1
  readonly property bool voicesDownloadable: !panel.activeProvider || panel.activeProvider.voices === "downloadable"
  // With no voice the row stays one line and points at where to get one:
  // the catalogue when this engine downloads voices, otherwise Providers.
  readonly property bool voiceFetchable: panel.voiceMissing && !!panel.activeProvider && panel.activeProvider.voices === "downloadable"
  function voiceRowActivate() {
    if (root.voiceFetchable) panel.openCatalogue()
    else panel.currentTab = panel.tabNames.indexOf("Providers")
  }
  readonly property int prompterPx: Style.fontPx(1.25)
  function playSample() { if (!panel.voiceMissing && panel.sampleText.trim() !== "") controller.speak(panel.sampleText) }
  // The shell's Dropdown always drops its list below the field. The voice
  // picker is the last thing on the Overview, and the panel can rest on the
  // bar, so the list ran past the panel's edge. Find the dropdown's popup and
  // open it upward when there is more room above; if the shell's dropdown
  // ever stops exposing a popup this way, it simply keeps opening downward.
  property var voicePopup: null
  function openUpwardWhenCramped(dropdown) {
    var popup = Utils.findPopup(dropdown)
    if (!popup || !popup.parent) return
    // A press on the field itself used to close the list on press-outside
    // and then reopen it on click. Only presses outside the field close it
    // now, so a second click on the field toggles it shut.
    popup.closePolicy = Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
    var anchor = popup.parent, gap = Style.spacing.xxs
    popup.y = Qt.binding(function() {
      var top = anchor.mapToItem(panel, 0, 0).y
      var below = panel.height - top - anchor.height
      var needed = popup.height + gap
      return below < needed && top > below ? -needed : anchor.height + gap
    })
    root.voicePopup = popup
  }
  // One speed control serves both cases: idle it is a setting, while reading
  // it also asks the backend to retune the utterance already playing.
  function applyRate(r) {
    var s = Math.max(root.rateMinimum, Math.min(root.rateMaximum, Math.round(r * 20) / 20))
    root.rateOverride = s
    if (controller.speaking) controller.setLiveRate(s)
    else controller.setConfig(".rate", s.toFixed(2))
  }

  Rectangle {
    id: prompterScreen
    readonly property bool reading: panel.playState !== "idle"
    width: parent.width; height: Style.space(172); radius: Style.space(6); clip: true
    color: Commons.Color.background; border.width: 1
    // Bordered like a text field, since at rest it is one.
    border.color: Style.controlBorder(sampleField.activeFocus, screenHover.hovered && !reading, panel.fg, Commons.Color.accent)
    HoverHandler { id: screenHover }

    Flickable {
      id: sampleFlick
      anchors.fill: parent; anchors.margins: Style.space(10); anchors.bottomMargin: prompterFooter.height + Style.space(6)
      visible: !prompterScreen.reading; clip: true
      contentWidth: width; contentHeight: sampleField.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      TextArea.flickable: TextArea {
        id: sampleField
        textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap; selectByMouse: true
        padding: 0; background: null
        text: panel.sampleText; color: panel.fg; placeholderText: "Type something to hear it"; placeholderTextColor: panel.dim
        font.family: panel.ff; font.pixelSize: root.prompterPx
        Accessible.name: "Sample text"
        // Enter plays, as it would in a player; Shift+Enter is still a newline.
        Keys.onReturnPressed: function(event) { if (event.modifiers & Qt.ShiftModifier) event.accepted = false; else root.playSample() }
        Keys.onEnterPressed: function(event) { if (event.modifiers & Qt.ShiftModifier) event.accepted = false; else root.playSample() }
        onTextChanged: {
          if (text.length > 4096) {
            var oldCursor = cursorPosition
            text = text.slice(0, 4096)
            cursorPosition = Math.min(oldCursor, text.length)
            return
          }
          panel.sampleText = text
        }
        onEditingFinished: controller.setConfig(".ui.sampleText", text)
      }
    }

    // Preparation has no words yet when it is capturing or recognising
    // the screen; say what is happening rather than show an empty box.
    Column {
      anchors.centerIn: parent; anchors.verticalCenterOffset: -prompterFooter.height / 2
      spacing: Style.space(4); visible: prompterScreen.reading && panel.phrases.length === 0
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰔟"; color: panel.dim; font.family: panel.ff; font.pixelSize: root.prompterPx }
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Getting the text ready…"; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body }
    }

    ListView {
      id: prompter
      anchors.fill: parent; anchors.margins: Style.space(10); anchors.bottomMargin: prompterFooter.height + Style.space(12)
      visible: prompterScreen.reading && panel.phrases.length > 0
      clip: true; interactive: false; spacing: Style.space(6)
      model: panel.phrases
      currentIndex: panel.phraseIndex
      // The spoken phrase is held in the middle, so the one just read
      // stays in view above it and the next one below.
      readonly property real currentHeight: currentItem ? currentItem.height : 0
      highlightRangeMode: ListView.StrictlyEnforceRange
      preferredHighlightBegin: Math.max(0, (height - currentHeight) / 2)
      preferredHighlightEnd: preferredHighlightBegin + currentHeight
      highlightMoveDuration: 420; highlightMoveVelocity: -1
      Accessible.role: Accessible.StaticText
      Accessible.name: panel.phrases.length ? panel.phrases[panel.phraseIndex].text : ""
      delegate: Text {
        required property var modelData
        required property int index
        readonly property int distance: Math.abs(index - panel.phraseIndex)
        width: ListView.view ? ListView.view.width : 0
        textFormat: Text.PlainText; wrapMode: Text.WordWrap; text: modelData.text
        color: distance === 0 ? panel.fg : panel.dim
        opacity: distance === 0 ? (panel.playState === "paused" ? 0.7 : 1) : distance === 1 ? 0.75 : 0.35
        font.family: panel.ff; font.pixelSize: distance === 0 ? root.prompterPx : Style.font.body
        Behavior on opacity { NumberAnimation { duration: 240 } }
      }
    }
    Rectangle {
      anchors.top: prompter.top; anchors.left: prompter.left; anchors.right: prompter.right
      height: Style.space(30); visible: prompter.visible
      gradient: Gradient {
        GradientStop { position: 0; color: prompterScreen.color }
        GradientStop { position: 1; color: Utils.withAlpha(prompterScreen.color, 0) }
      }
    }
    Rectangle {
      anchors.bottom: prompter.bottom; anchors.left: prompter.left; anchors.right: prompter.right
      height: Style.space(30); visible: prompter.visible
      gradient: Gradient {
        GradientStop { position: 0; color: Utils.withAlpha(prompterScreen.color, 0) }
        GradientStop { position: 1; color: prompterScreen.color }
      }
    }

    Column {
      id: prompterFooter
      anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
      anchors.margins: Style.space(10); spacing: Style.space(5)
      // Progress, once there is audio to measure. Preparing slides an
      // unmeasured segment instead of claiming a percentage.
      Rectangle {
        id: progressTrack
        width: parent.width; height: 3; radius: 1.5; visible: prompterScreen.reading
        color: Style.selectedFillFor(panel.fg, Commons.Color.accent); clip: true
        Rectangle {
          visible: panel.playState !== "preparing"
          height: parent.height; radius: parent.radius
          width: parent.width * panel.npProgress
          color: panel.playState === "paused" ? panel.dim : Commons.Color.accent
          Behavior on width { NumberAnimation { duration: 260 } }
        }
        Rectangle {
          id: preparingSweep
          visible: panel.playState === "preparing"
          height: parent.height; radius: parent.radius; width: parent.width * 0.25
          color: Commons.Color.accent
          NumberAnimation on x {
            running: preparingSweep.visible && panel.opened
            from: -progressTrack.width * 0.25; to: progressTrack.width
            duration: 1300; loops: Animation.Infinite; easing.type: Easing.InOutQuad
          }
        }
      }
      Item {
        width: parent.width; height: footerLeft.implicitHeight
        Text {
          id: footerLeft
          textFormat: Text.PlainText
          text: !prompterScreen.reading ? (panel.voiceMissing ? (root.voiceFetchable ? "Download a voice to hear this" : "Install a voice in Providers to hear this") : "Sample · Enter to play")
                : panel.npDuration > 0 ? Utils.clockText(panel.npElapsed) : ""
          color: panel.voiceMissing && !prompterScreen.reading ? Commons.Color.accent : panel.dim
          font.family: panel.ff; font.pixelSize: Style.font.caption
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: prompterScreen.reading
          textFormat: Text.PlainText
          text: panel.playState === "paused" ? "Paused"
                : panel.playState === "preparing" ? "Preparing"
                : panel.phrases.length > 1 ? (panel.phraseIndex + 1) + " of " + panel.phrases.length : "Reading"
          color: panel.playState === "paused" ? Commons.Color.accent : panel.dim
          font.family: panel.ff; font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: !prompterScreen.reading ? "Runs locally"
                : panel.npDuration > 0 ? "−" + Utils.clockText(panel.npDuration - panel.npElapsed) : ""
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Transport on the left, speed on the right. The speed control is
  // the same one whether or not anything is playing: idle, it sets
  // the next reading; while reading it retunes the current one if
  // the provider can, and says when it cannot.
  Item {
    width: parent.width; height: Math.max(transport.implicitHeight, speedReadout.implicitHeight)
    Row {
      id: transport
      anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(6)
      Button {
        id: playButton
        width: panel.playState === "idle" ? transport.deckWidth : height
        iconText: panel.playState === "speaking" || panel.playState === "preparing" ? "󰏤" : "󰐊"
        text: panel.playState === "idle" ? "Play" : ""
        Accessible.name: panel.playState === "idle" ? "Play sample" : controller.paused ? "Resume" : "Pause"
        tooltipText: panel.playState === "idle" ? "" : !controller.nowPlaying.canPause ? "This provider cannot pause" : controller.paused ? "Resume" : "Pause"
        bordered: true; focusable: true
        foreground: panel.playState === "idle" ? Commons.Color.accent : panel.fg
        enabled: panel.playState === "idle" ? !panel.voiceMissing && panel.sampleText.trim() !== ""
                 : panel.playState !== "preparing" && controller.nowPlaying.canPause === true
        opacity: enabled ? 1 : 0.45
        onClicked: panel.playState === "idle" ? root.playSample() : controller.togglePause()
      }
      Button {
        id: stopButton
        width: height; visible: panel.playState !== "idle"
        iconText: "󰓛"; tooltipText: "Stop"; Accessible.name: "Stop"
        bordered: true; focusable: true; foreground: Commons.Color.urgent; accent: Commons.Color.urgent
        onClicked: controller.stop()
      }
      readonly property real deckWidth: playButton.height * 2 + spacing
    }
    Row {
      anchors.left: transport.right; anchors.leftMargin: Style.space(12)
      anchors.right: speedReadout.left; anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6); visible: root.rateSupported
      Button { id: slower; width: Style.space(28); text: "−"; bordered: true; focusable: true; Accessible.name: "Slower"; onClicked: root.applyRate(root.rateValue - .1) }
      // The knob tracks the raw pointer while the label shows the snapped
      // value, so on release it drifts to the step and eases there once
      // the config round-trip returns. Snapping liveValue as we go keeps
      // knob, label and stored value identical at every instant.
      PanelSlider {
        id: speedSlider
        width: parent.width - slower.width - faster.width - parent.spacing * 2; bar: panel.bar
        anchors.verticalCenter: parent.verticalCenter
        minimum: root.rateMinimum; maximum: root.rateMaximum; step: .05
        value: root.rateValue
        function snap(v) { return Math.round(v * 20) / 20 }
        // Track the drag in the override too: the label reads it, and it
        // makes `value` already correct when the drag ends.
        onMoved: function(v) { var s = speedSlider.snap(v); root.rateOverride = s; speedSlider.liveValue = s }
        onReleased: function(v) { root.applyRate(v) }   // value is correct before liveValue resets to it
      }
      Button { id: faster; width: Style.space(28); text: "+"; bordered: true; focusable: true; Accessible.name: "Faster"; onClicked: root.applyRate(root.rateValue + .1) }
    }
    Column {
      id: speedReadout
      anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      width: root.rateSupported ? Style.space(70) : parent.width - transport.width - Style.space(12)
      Text {
        width: parent.width; horizontalAlignment: Text.AlignRight
        text: root.rateSupported ? root.rateValue.toFixed(2) + "×" : "Speed fixed by provider"
        color: root.rateSupported ? panel.fg : panel.dim; font.family: panel.ff
        font.pixelSize: root.rateSupported ? Style.font.body : Style.font.caption
      }
      // Says whether the number above is what you are hearing.
      Text {
        width: parent.width; horizontalAlignment: Text.AlignRight
        visible: root.rateSupported && (panel.playState === "speaking" || panel.playState === "paused")
        text: controller.nowPlaying.canLiveRate ? "applies now" : "next reading"
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      }
    }
  }

  // The voice is picked right here. With none installed the same line
  // says so and points at where to get one.
  Rectangle {
    id: voiceMissingRow
    width: parent.width; height: voiceMissingLine.implicitHeight + Style.space(14); radius: Style.space(6)
    visible: panel.voiceMissing; color: "transparent"
    border.width: 1; border.color: Style.controlBorder(voiceMissingRow.activeFocus, voiceHover.hovered, panel.fg, Commons.Color.accent)
    activeFocusOnTab: visible
    Accessible.role: Accessible.Button
    Accessible.name: "No voice installed, " + voiceAction.text
    Accessible.onPressAction: root.voiceRowActivate()
    Keys.onSpacePressed: root.voiceRowActivate()
    Keys.onReturnPressed: root.voiceRowActivate()
    Keys.onEnterPressed: root.voiceRowActivate()
    HoverHandler { id: voiceHover }
    Item {
      id: voiceMissingLine
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(voiceGlyph.implicitHeight, voiceAction.implicitHeight)
      Text { id: voiceGlyph; anchors.verticalCenter: parent.verticalCenter; text: "󰗋"; color: Commons.Color.accent; font.family: panel.ff; font.pixelSize: Style.font.body }
      Text {
        anchors.left: voiceGlyph.right; anchors.leftMargin: Style.space(8)
        anchors.right: voiceAction.left; anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight; textFormat: Text.PlainText
        text: "No voice installed"; color: Commons.Color.accent
        font.family: panel.ff; font.pixelSize: Style.font.body
      }
      InlineAction {
        id: voiceAction
        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
        text: root.voiceFetchable ? "󰇚 Download" : "Open Providers 󰅂"; color: Commons.Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption
        onTriggered: root.voiceRowActivate()
      }
    }
    MouseArea { anchors.fill: parent; z: -1; cursorShape: Qt.PointingHandCursor; onClicked: root.voiceRowActivate() }
  }
  Row {
    width: parent.width; spacing: Style.space(6); visible: !panel.voiceMissing
    Dropdown {
      id: voiceDropdown
      width: parent.width - (browseVoices.visible ? browseVoices.width + parent.spacing : 0)
      showLabel: false; foreground: panel.fg
      options: panel.voiceOptions; value: controller.info.voice || ""
      onValueChanged: if (value && value !== controller.info.voice) controller.setConfig(controller.info.voicePath || ".piper.voice", value)
      Component.onCompleted: root.openUpwardWhenCramped(voiceDropdown)
    }
    Button {
      id: browseVoices
      visible: root.voicesDownloadable; width: height; height: voiceDropdown.height
      iconText: "󰇚"; tooltipText: "Browse all voices"; Accessible.name: "Browse all voices"
      bordered: true; focusable: true; foreground: panel.fg
      onClicked: panel.openCatalogue()
    }
  }
}
