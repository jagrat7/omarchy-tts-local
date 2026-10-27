import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "utils.js" as Utils

// Every Piper voice in the catalogue: what is installed first, then what
// can be downloaded, searchable and sortable.
Column {
  id: root
  required property var panel
  required property var controller
  spacing: 8

  property string confirmVoiceRemove: ""

  property string voiceSort: "lang"

  readonly property var voiceSorts: [
    { key: "lang", label: "Language" },
    { key: "name", label: "Name" },
    { key: "size", label: "Size" },
    { key: "quality", label: "Quality" }
  ]

  readonly property int removeSizeMB: {
    var all = controller.catalogue || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].key === root.confirmVoiceRemove) return Number(all[i].sizeMB || 0)
    return 0
  }

  readonly property int installedCount: {
    var all = controller.catalogue || [], n = 0
    for (var i = 0; i < all.length; ++i) if (all[i].installed) n++
    return n
  }

  readonly property var filteredVoices: Utils.catalogueRows(controller.catalogue || [], panel.voiceFilter,
                                                            root.voiceSort, controller.info.voice)

  Item {
    width: parent.width; height: browseHeader.implicitHeight
    PanelSectionHeader { id: browseHeader; text: root.installedCount + " installed · " + ((controller.catalogue || []).length - root.installedCount) + " available"; foreground: panel.fg }
    InlineAction { anchors.right: parent.right; text: "Done"; color: Commons.Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption; onTriggered: panel.browsing = false }
  }
  TextField { id: voiceFilterField; width: parent.width; placeholderText: "Search voices"; text: panel.voiceFilter; foreground: panel.fg; onTextChanged: panel.voiceFilter = text }
  Text {
    width: parent.width; visible: controller.catalogueLoading
    text: "Loading and validating the voice catalogue…"
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }

  Row {
    width: parent.width; spacing: Style.space(12)
    Text { text: "Sort"; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
           anchors.verticalCenter: parent.verticalCenter }
    Repeater {
      model: root.voiceSorts
      delegate: InlineAction {
        required property var modelData
        text: modelData.label
        color: root.voiceSort === modelData.key ? Commons.Color.accent : panel.dim
        font.family: panel.ff; font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        Accessible.role: Accessible.RadioButton
        Accessible.checked: root.voiceSort === modelData.key
        onTriggered: root.voiceSort = modelData.key
      }
    }
  }

  ListView {
    width: parent.width; height: Style.space(240); clip: true; model: root.filteredVoices; spacing: 2
    section.property: "group"
    section.criteria: ViewSection.FullString
    section.delegate: Item {
      required property string section
      width: ListView.view ? ListView.view.width : 0
      height: sectionLabel.implicitHeight + Style.space(10)
      Text {
        id: sectionLabel
        anchors.left: parent.left; anchors.leftMargin: Style.space(8)
        anchors.bottom: parent.bottom
        text: parent.section === "Installed"
              ? "Installed — click to use, Remove to delete"
              : parent.section === "Needs repair"
                ? "Active voice is incomplete — repair to use it"
                : "Available to download"
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      }
    }
    delegate: Rectangle {
      required property var modelData
      readonly property bool busy: (controller.downloadStarting && controller.pendingDownloadVoice === modelData.key)
                                    || (controller.downloadRunning && controller.download.voice === modelData.key)
      function activateRow() { if (modelData.installed && modelData.key !== controller.info.voice) controller.useVoice(modelData.key) }
      function activateAction() { if (busy) controller.cancelDownload(); else if (modelData.installed) root.confirmVoiceRemove = modelData.key; else controller.downloadVoice(modelData.key) }
      width: ListView.view.width; height: 42; radius: 5; color: modelData.installed ? panel.tint(.07) : "transparent"
      activeFocusOnTab: modelData.installed && modelData.key !== controller.info.voice
      border.width: activeFocus ? 1 : 0; border.color: Commons.Color.accent
      Accessible.role: Accessible.Button
      Accessible.name: "Use " + Utils.voiceLabel(modelData.key)
      Accessible.onPressAction: activateRow()
      Keys.onSpacePressed: activateRow()
      Keys.onReturnPressed: activateRow()
      Keys.onEnterPressed: activateRow()
      Text { anchors.left: parent.left; anchors.right: parent.right; anchors.rightMargin: 112; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; textFormat: Text.PlainText; text: Utils.titleCase(String(parent.modelData.name).replace(/_/g, " ")) + " · " + parent.modelData.lang + " · " + parent.modelData.quality; color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption }
      InlineAction {
        id: voiceAction; z: 2; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
        text: parent.modelData.installed ? (parent.modelData.key === controller.info.voice ? "󰄬 Active" : "Remove") : (parent.busy ? (controller.downloadCancellable ? controller.download.percent + "% · Cancel" : "Starting…") : (parent.modelData.key === controller.info.voice ? "Repair · " : "󰇚 ") + parent.modelData.sizeMB + " MB")
        color: parent.modelData.installed || parent.busy ? Commons.Color.accent : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        enabled: (!parent.modelData.installed || parent.modelData.key !== controller.info.voice)
                 && (!parent.busy || controller.downloadCancellable)
        onTriggered: parent.activateAction()
      }
      MouseArea { anchors.fill: parent; z: 1; enabled: parent.modelData.installed && parent.modelData.key !== controller.info.voice; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: parent.activateRow() }
    }
  }
  Rectangle {
    width: parent.width; height: voiceRemoveRow.implicitHeight + 16; radius: 6
    visible: root.confirmVoiceRemove !== ""; color: panel.tint(0.08); border.width: 1; border.color: Commons.Color.popups.border
    Row {
      id: voiceRemoveRow; anchors.fill: parent; anchors.margins: 8; spacing: 8
      Text { width: parent.width - cancelVoice.width - removeVoice.width - 24; elide: Text.ElideMiddle; textFormat: Text.PlainText; text: "Remove " + Utils.voiceLabel(root.confirmVoiceRemove) + "?" + (root.removeSizeMB > 0 ? "  Frees " + root.removeSizeMB + " MB." : ""); color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption }
      Button { id: cancelVoice; text: "Cancel"; bordered: true; focusable: true; onClicked: root.confirmVoiceRemove = "" }
      Button { id: removeVoice; text: "Remove"; bordered: true; focusable: true; foreground: Commons.Color.urgent; onClicked: { controller.removeVoice(root.confirmVoiceRemove); root.confirmVoiceRemove = "" } }
    }
  }
  Text { text: "Storage: ~/.local/share/omarchy-tts-local/voices/piper"; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
}
