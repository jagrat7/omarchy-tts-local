import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The engine is chosen once on Providers; languages are browsed, so
// they keep a tab of their own.
Column {
  id: root
  required property var panel
  required property var controller
  spacing: 10

  // Recognition languages, split the way voices are: what you have, then what
  // you could add. The free-text field invited a code and then silently read
  // nothing when its data was missing.
  property string languageFilter: ""
  readonly property var ocrLanguages: controller.info.ocr?.languages || []
  readonly property var installedLanguages: {
    var all = root.ocrLanguages, out = []
    for (var i = 0; i < all.length; ++i) if (all[i].installed) out.push(all[i])
    return out
  }
  readonly property var availableLanguages: {
    var q = String(root.languageFilter).toLowerCase().trim()
    var all = root.ocrLanguages, out = []
    for (var i = 0; i < all.length; ++i) {
      var l = all[i]
      if (l.installed) continue
      if (!q || String(l.value).toLowerCase().indexOf(q) >= 0
             || String(l.label).toLowerCase().indexOf(q) >= 0) out.push(l)
    }
    return out
  }
  function languageIsActive(code) {
    return String(controller.info.ocr?.langs || "eng").split("+").indexOf(String(code)) >= 0
  }
  function toggleLanguage(code) {
    var active = String(controller.info.ocr?.langs || "eng").split("+").filter(function (c) { return c.length })
    var at = active.indexOf(String(code))
    if (at >= 0) { if (active.length === 1) return; active.splice(at, 1) }
    else active.push(String(code))
    controller.setConfig(".ocr." + (controller.info.ocr?.engine || "tesseract") + ".langs", active.join("+"))
  }

  Item {
    width: parent.width; height: langHeader.implicitHeight
    PanelSectionHeader { id: langHeader; text: "Languages for " + (panel.activeOcrEngine ? (panel.activeOcrEngine.title || panel.activeOcrEngine.name) : (controller.info.ocr?.engine || "tesseract")); foreground: panel.fg }
    InlineAction {
      anchors.right: parent.right
      text: controller.refreshingLanguages !== "" ? "Checking…"
            : root.installedLanguages.length + " installed · " + root.availableLanguages.length + " available"
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      enabled: controller.refreshingLanguages === ""
      onTriggered: controller.refreshLanguages(controller.info.ocr?.engine || "tesseract")
    }
  }
  Text {
    width: parent.width; wrapMode: Text.WordWrap
    visible: root.ocrLanguages.length === 0
    text: "No language list yet. Click the count above to read what is installed and what can be added."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }
  Flow {
    width: parent.width; spacing: 6
    visible: root.installedLanguages.length > 0
    Repeater {
      model: root.installedLanguages
      delegate: Rectangle {
        required property var modelData
        readonly property bool active: root.languageIsActive(modelData.value)
        width: langChip.implicitWidth + 18; height: 24; radius: 4
        color: active ? panel.tint(0.16) : "transparent"
        border.width: 1; border.color: activeFocus ? Commons.Color.accent : (active ? panel.tint(0.5) : Commons.Color.popups.border)
        activeFocusOnTab: true
        Accessible.role: Accessible.CheckBox
        Accessible.name: modelData.label || modelData.value
        Accessible.checked: active
        Accessible.onPressAction: root.toggleLanguage(modelData.value)
        Keys.onSpacePressed: root.toggleLanguage(modelData.value)
        Keys.onReturnPressed: root.toggleLanguage(modelData.value)
        Keys.onEnterPressed: root.toggleLanguage(modelData.value)
        Text { id: langChip; anchors.centerIn: parent; textFormat: Text.PlainText; text: parent.modelData.label || parent.modelData.value
               color: parent.active ? Commons.Color.accent : panel.dim
               font.family: panel.ff; font.pixelSize: Style.font.caption }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleLanguage(parent.modelData.value) }
      }
    }
  }
  Text {
    width: parent.width; wrapMode: Text.WordWrap
    visible: root.installedLanguages.length > 0
    text: "Click a language to include or exclude it. Recognition uses every selected language at once, so leave out ones you do not need."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }
  TextField {
    id: languageFilterField
    width: parent.width; visible: root.ocrLanguages.length > 0
    placeholderText: "Search " + root.availableLanguages.length + " languages"
    text: root.languageFilter; foreground: panel.fg
    onTextChanged: root.languageFilter = text
  }
  ListView {
    width: parent.width; height: Style.space(150); clip: true; spacing: 2
    visible: root.availableLanguages.length > 0
    model: root.availableLanguages
    delegate: Rectangle {
      required property var modelData
      readonly property bool busy: controller.setupJob.target === "lang:" + modelData.value
                                   && (controller.setupJob.status === "running" || controller.setupJob.status === "starting")
      width: ListView.view.width; height: 28; radius: 4; color: "transparent"
      Text { anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
             textFormat: Text.PlainText
             text: (parent.modelData.label || parent.modelData.value)
                   + (parent.modelData.label && parent.modelData.label !== parent.modelData.value ? "  (" + parent.modelData.value + ")" : "")
             color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption }
      // Language packs are installed as tesseract-data packages, so
      // the action exists only for tesseract. Other engines list what
      // they have; adding to them is a follow-up, not a broken button.
      readonly property bool installable: (controller.info.ocr?.engine || "tesseract") === "tesseract"
      InlineAction { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
             text: !parent.installable ? "not downloaded" : parent.busy ? "Installing…" : "󰇚 Install"
             color: parent.installable ? Commons.Color.accent : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
             enabled: parent.installable && !parent.busy
             onTriggered: controller.installLanguage(parent.modelData.value) }
    }
  }
}
