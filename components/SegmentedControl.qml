import QtQuick
import qs.Commons
import qs.Commons as Commons
import "utils.js" as Utils

// A row of equal pills with a highlight that slides to the chosen one, for
// picking one of a few options (a provider's installed variants).
Rectangle {
  id: root
  // [{ value, label }]
  property var options: []
  property string value: ""
  property color foreground: Commons.Color.popups.text
  property string fontFamily: Style.font.family
  signal selected(string value)

  readonly property int currentIndex: {
    for (var i = 0; i < options.length; ++i) if (options[i].value === value) return i
    return -1
  }
  readonly property real pillWidth: (width - 4) / Math.max(1, options.length)

  width: parent ? parent.width : implicitWidth
  implicitHeight: pills.implicitHeight + 4
  radius: Style.space(6)
  color: Utils.withAlpha(foreground, 0.06)

  Rectangle {
    visible: root.currentIndex >= 0
    x: 2 + Math.max(0, root.currentIndex) * root.pillWidth; y: 2
    width: root.pillWidth; height: root.height - 4
    radius: Style.space(5)
    color: Utils.withAlpha(Commons.Color.accent, 0.18); border.width: 1; border.color: Utils.withAlpha(Commons.Color.accent, 0.5)
    Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  }

  Row {
    id: pills
    x: 2; y: 2
    Repeater {
      model: root.options
      delegate: Item {
        required property var modelData
        required property int index
        readonly property bool chosen: index === root.currentIndex
        width: root.pillWidth; height: label.implicitHeight + Style.space(6)
        activeFocusOnTab: !chosen
        Accessible.role: Accessible.RadioButton
        Accessible.name: modelData.label
        Accessible.checked: chosen
        Accessible.onPressAction: if (!chosen) root.selected(modelData.value)
        Keys.onSpacePressed: if (!chosen) root.selected(modelData.value)
        Keys.onReturnPressed: if (!chosen) root.selected(modelData.value)
        Keys.onEnterPressed: if (!chosen) root.selected(modelData.value)
        Text {
          id: label; anchors.centerIn: parent
          textFormat: Text.PlainText; text: parent.modelData.label
          color: parent.chosen ? Commons.Color.accent : root.foreground
          font.family: root.fontFamily; font.pixelSize: Style.font.caption
          font.bold: parent.chosen; font.underline: parent.activeFocus
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: parent.chosen ? Qt.ArrowCursor : Qt.PointingHandCursor
          onClicked: if (!parent.chosen) root.selected(parent.modelData.value)
        }
      }
    }
  }
}
