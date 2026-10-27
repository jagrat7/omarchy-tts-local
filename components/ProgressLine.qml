import QtQuick
import qs.Commons as Commons
import "utils.js" as Utils

// A setup job's progress as a thin bar; set its height, the ends round off.
Rectangle {
  id: root
  // Any number-ish value; a job that has not reported one yet reads as 0.
  property var percent: 0
  radius: height / 2
  color: Commons.Color.popups.border
  Rectangle {
    height: parent.height; radius: parent.radius; color: Commons.Color.accent
    width: parent.width * Utils.progressFraction(root.percent)
  }
}
