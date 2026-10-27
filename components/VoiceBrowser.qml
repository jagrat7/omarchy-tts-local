import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

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

  function qualityRank(q) {
    return ({ "x_low": 0, "low": 1, "medium": 2, "high": 3 })[String(q)] ?? 1
  }

  readonly property int installedCount: {
    var all = controller.catalogue || [], n = 0
    for (var i = 0; i < all.length; ++i) if (all[i].installed) n++
    return n
  }

  readonly property var filteredVoices: {
    var q = voiceFilter.toLowerCase().trim(), all = controller.catalogue || [], out = []
    for (var i = 0; i < all.length; ++i) {
      var value = all[i]
      if (!q || String(value.key).toLowerCase().indexOf(q) >= 0
             || String(value.lang).toLowerCase().indexOf(q) >= 0
             || String(value.country).toLowerCase().indexOf(q) >= 0) out.push(value)
    }
    var mode = root.voiceSort
    out.sort(function (a, b) {
      // Installed always leads, so the list you can act on is never buried
      // under a hundred you have not downloaded.
      var aState = a.installed ? 0 : (a.key === controller.info.voice ? 1 : 2)
      var bState = b.installed ? 0 : (b.key === controller.info.voice ? 1 : 2)
      if (aState !== bState) return aState - bState
      if (mode === "name") return String(a.name).localeCompare(String(b.name))
      if (mode === "size") return (b.sizeMB - a.sizeMB) || String(a.name).localeCompare(String(b.name))
      if (mode === "quality") return (root.qualityRank(b.quality) - root.qualityRank(a.quality))
                                     || String(a.name).localeCompare(String(b.name))
      return String(a.lang).localeCompare(String(b.lang))
             || String(a.name).localeCompare(String(b.name))
    })
    // ListView sections need the group on the item itself.
    var grouped = []
    for (var j = 0; j < out.length; ++j) {
      var v = out[j]
      grouped.push({ key: v.key, name: v.name, lang: v.lang, country: v.country,
                     quality: v.quality, sizeMB: v.sizeMB, installed: v.installed,
                     group: v.installed ? "Installed"
                       : (v.key === controller.info.voice ? "Needs repair" : "Available") })
    }
    return grouped
  }

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
                                    || ((controller.download.status === "starting" || controller.download.status === "downloading") && controller.download.voice === modelData.key)
      function activateRow() { if (modelData.installed && modelData.key !== controller.info.voice) controller.useVoice(modelData.key) }
      function activateAction() { if (busy) controller.cancelDownload(); else if (modelData.installed) root.confirmVoiceRemove = modelData.key; else controller.downloadVoice(modelData.key) }
      width: ListView.view.width; height: 42; radius: 5; color: modelData.installed ? panel.tint(.07) : "transparent"
      activeFocusOnTab: modelData.installed && modelData.key !== controller.info.voice
      border.width: activeFocus ? 1 : 0; border.color: Commons.Color.accent
      Accessible.role: Accessible.Button
      Accessible.name: "Use " + panel.voiceLabel(modelData.key)
      Accessible.onPressAction: activateRow()
      Keys.onSpacePressed: activateRow()
      Keys.onReturnPressed: activateRow()
      Keys.onEnterPressed: activateRow()
      Text { anchors.left: parent.left; anchors.right: parent.right; anchors.rightMargin: 112; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; textFormat: Text.PlainText; text: panel.titleCase(String(parent.modelData.name).replace(/_/g, " ")) + " · " + parent.modelData.lang + " · " + parent.modelData.quality; color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption }
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
      Text { width: parent.width - cancelVoice.width - removeVoice.width - 24; elide: Text.ElideMiddle; textFormat: Text.PlainText; text: "Remove " + panel.voiceLabel(root.confirmVoiceRemove) + "?" + (root.removeSizeMB > 0 ? "  Frees " + root.removeSizeMB + " MB." : ""); color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption }
      Button { id: cancelVoice; text: "Cancel"; bordered: true; focusable: true; onClicked: root.confirmVoiceRemove = "" }
      Button { id: removeVoice; text: "Remove"; bordered: true; focusable: true; foreground: Commons.Color.urgent; onClicked: { controller.removeVoice(root.confirmVoiceRemove); root.confirmVoiceRemove = "" } }
    }
  }
  Text { text: "Storage: ~/.local/share/omarchy-tts-local/voices/piper"; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
}
