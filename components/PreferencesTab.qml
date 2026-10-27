import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The rules that shape what is spoken, then how screen captures are read.
Column {
  id: root
  required property var panel
  required property var controller
  spacing: 8

  // Holds the confidence just chosen until a settings read confirms it, as
  // the Overview does for speed (see rateOverride there).
  property int confidenceOverride: -1

  readonly property int confidenceValue:
    confidenceOverride >= 0 ? confidenceOverride
                            : Number(controller.info.ocr?.minConfidence ?? 60)
  Connections { target: controller; function onInfoChanged() { root.confidenceOverride = -1 } }

  PanelSectionHeader { text: "Text"; foreground: panel.fg }
  Row {
    width: parent.width; spacing: 8
    Rectangle {
      width: (parent.width - 8) / 2; height: 94; radius: 6; clip: true
      color: Commons.Color.background; border.width: 1; border.color: Commons.Color.popups.border
      TextArea {
        id: previewInput
        anchors.fill: parent; anchors.margins: 6
        textFormat: TextEdit.PlainText
        text: panel.previewSource; color: panel.dim
        wrapMode: TextEdit.Wrap; clip: true; background: null
        font.family: panel.ff; font.pixelSize: Style.font.caption
        onTextChanged: {
          if (text.length > 32768) {
            var oldCursor = cursorPosition
            text = text.slice(0, 32768)
            cursorPosition = Math.min(oldCursor, text.length)
            return
          }
          panel.previewSource = text
          previewDelay.restart()
        }
      }
    }
    Rectangle { width: (parent.width - 8) / 2; height: 94; radius: 6; clip: true; color: panel.tint(.06); border.width: 1; border.color: Commons.Color.popups.border; Text { anchors.fill: parent; anchors.margins: 6; textFormat: Text.PlainText; text: controller.preview || "Spoken preview"; color: panel.fg; wrapMode: Text.WordWrap; clip: true; elide: Text.ElideRight; maximumLineCount: 5; font.family: panel.ff; font.pixelSize: Style.font.caption } }
  }
  SettingToggle { label: "Read URLs as ‘link’"; checked: controller.info.sanitizer?.urls === "link"; foreground: panel.fg; onToggled: function(value) { controller.setConfig(".sanitizer.urls", value ? "link" : "domain") } }
  SettingToggle { label: "Read inline code"; checked: controller.info.sanitizer?.inlineCode !== false; foreground: panel.fg; onToggled: function(value) { controller.setConfig(".sanitizer.inlineCode", value) } }
  SettingToggle { label: "Announce skipped code blocks"; checked: controller.info.sanitizer?.announceCodeBlocks !== false; foreground: panel.fg; onToggled: function(value) { controller.setConfig(".sanitizer.announceCodeBlocks", value) } }
  SettingToggle { label: "Strip Markdown symbols"; checked: controller.info.sanitizer?.stripMarkdown !== false; foreground: panel.fg; onToggled: function(value) { controller.setConfig(".sanitizer.stripMarkdown", value) } }
  SettingToggle { label: "Expand abbreviations and units"; checked: controller.info.sanitizer?.expandUnits !== false; foreground: panel.fg; onToggled: function(value) { controller.setConfig(".sanitizer.expandUnits", value) } }
  // How much of a selection is read. It shapes what gets spoken, so it
  // sits with the text rules, as one row like the toggles above.
  Item {
    width: parent.width; height: Math.max(limitLabel.implicitHeight, limitStepper.height)
    Column {
      id: limitLabel
      anchors.left: parent.left; anchors.right: limitStepper.left; anchors.rightMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      Text { textFormat: Text.PlainText; text: "Length limit"; color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.body }
      Text {
        width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText
        text: controller.info.maxChars > 0 ? "Characters per read · ~" + Math.max(1, Math.round(controller.info.maxChars / 900)) + " min" : "0 reads the whole selection"
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      }
    }
    Row {
      id: limitStepper
      anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(4)
      Button { width: Style.space(28); height: maxCharsField.height; text: "−"; bordered: true; focusable: true; Accessible.name: "500 fewer characters"; onClicked: controller.setConfig(".maxChars", Math.max(0, Number(controller.info.maxChars)-500)) }
      TextField {
        id: maxCharsField; width: Style.space(72)
        text: String(controller.info.maxChars || 0); foreground: panel.fg
        maximumLength: 7
        inputMethodHints: Qt.ImhDigitsOnly
        validator: IntValidator { bottom: 0; top: 1048576 }
        Accessible.name: "Length limit in characters"
        onEditingFinished: controller.setConfig(".maxChars", Math.max(0, Math.min(1048576, Number(text) || 0)))
      }
      Button { width: Style.space(28); height: maxCharsField.height; text: "+"; bordered: true; focusable: true; Accessible.name: "500 more characters"; onClicked: controller.setConfig(".maxChars", Math.min(1048576, Number(controller.info.maxChars||0)+500)) }
    }
  }
  Text {
    width: parent.width
    visible: !!panel.activeProvider && Number(panel.activeProvider.maxBytes || 0) > 0
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: panel.activeProvider
          ? (panel.activeProvider.title || panel.activeProvider.name) + " allows "
            + panel.activeProvider.maxBytes
            + " UTF-8 bytes per request. Non-Latin characters can use more than one byte."
          : ""
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }
  // Screen -------------------------------------------------------------
  // How screen captures are read, once an engine is chosen on Providers.
  // Only engines that report confidence have anything to set here.
  Item { width: parent.width; height: Style.space(4); visible: confidenceRow.visible }
  PanelSectionHeader { text: "Screen"; foreground: panel.fg; visible: confidenceRow.visible }
  Item {
    id: confidenceRow
    width: parent.width; height: Math.max(confidenceLabel.implicitHeight, confidenceSlider.implicitHeight)
    visible: !!panel.activeOcrEngine && panel.activeOcrEngine.supportsConfidence === true
    Column {
      id: confidenceLabel
      anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      Text { textFormat: Text.PlainText; text: "Confidence floor"; color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.body }
      Text { textFormat: Text.PlainText; text: "Skip words read below it"; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
    }
    PanelSlider {
      id: confidenceSlider
      anchors.left: confidenceLabel.right; anchors.leftMargin: Style.space(12)
      anchors.right: confidenceReadout.left; anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter; bar: panel.bar
      minimum: 0; maximum: 95; step: 5; integer: true
      value: root.confidenceValue
      function snap(v) { return Math.round(v / 5) * 5 }
      onMoved: function(v) { var s = confidenceSlider.snap(v); root.confidenceOverride = s; confidenceSlider.liveValue = s }
      onReleased: function(v) {
        var s = confidenceSlider.snap(v)
        root.confidenceOverride = s
        controller.setConfig(".ocr.minConfidence", s)
      }
    }
    Text {
      id: confidenceReadout
      anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      width: Style.space(36); horizontalAlignment: Text.AlignRight
      text: root.confidenceValue > 0 ? root.confidenceValue + "%" : "off"
      color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
  }
  Timer { id: previewDelay; interval: 180; onTriggered: controller.previewText(panel.previewSource) }
}
