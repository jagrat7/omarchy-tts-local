import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "utils.js" as Utils

// Confirmation for installing or removing any engine the plugin manages,
// speech or OCR. Sizes and notes come from the engine's own `# installsize:`
// and `# installnote:` headers (per device with a `-cpu`/`-gpu` suffix), as
// `speak --info` reports them under installInfo.
Rectangle {
  id: root
  // The provider or OCR engine object from `speak --info`, or null to hide.
  property var target: null
  // "install" or "uninstall".
  property string mode: "install"
  // Install: set when switching the target to this device; empty installs
  // (or repairs) the device it is configured with.
  property string device: ""
  // Uninstall: the engine in use, so removing it can say what will stop.
  property string activeName: ""
  property string inUseWarning: "This is the voice in use. Pick another provider afterwards or the shortcuts will stop speaking."
  property color foreground: Commons.Color.popups.text
  property string fontFamily: Style.font.family
  signal cancelled()
  // `engineTarget` is what `speak-setup uninstall` takes; installs ignore it.
  signal confirmed(string engineTarget)

  readonly property bool removing: mode === "uninstall"
  readonly property string name: target ? String(target.title || target.name || "") : ""
  readonly property bool switching: !removing && device !== ""
  readonly property bool repairing: !removing && !switching && !!target && target.status === "failing"
  readonly property string installDevice: switching ? device : String((target && target.device) || "")
  // Only an engine with a separate build per device (an installInfo entry per
  // device) is removed per device; Kokoro PyTorch runs either way from one
  // build and is removed whole.
  readonly property var removableDevices: target ? (target.installedDevices || []).filter(function(d) {
    return !!((target.installInfo || {})[d]) }) : []
  readonly property bool removesInUse: removing && !!target && target.name === activeName
    && (removableDevices.length === 0 || removableDevices.indexOf(String(target.device || "")) >= 0)
  function details(device) {
    var info = (target && target.installInfo) || {}
    return info[device] || info["default"] || {}
  }
  function engineTarget(device) { return device ? target.name + "_" + device : target.name }

  visible: target !== null
  width: parent ? parent.width : implicitWidth
  height: content.implicitHeight + 16
  radius: 6
  color: Utils.withAlpha(Commons.Color.accent, 0.08)
  border.width: 1
  border.color: Commons.Color.popups.border

  Column {
    id: content
    anchors.fill: parent; anchors.margins: 8; spacing: 6
    Text {
      width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
      text: root.removing ? "Uninstall " + root.name + "?"
          : root.switching ? "Run " + root.name + " on the " + root.device.toUpperCase() + "?"
          : (root.repairing ? "Repair " : "Install ") + root.name
            + (root.installDevice ? " for the " + root.installDevice.toUpperCase() : "") + "?"
      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
    }
    Text {
      readonly property var info: root.details(root.removing ? (root.removableDevices.length === 1 ? root.removableDevices[0] : "") : root.installDevice)
      visible: root.removing ? root.removableDevices.length < 2 && !!info.size : !!(info.size || info.note)
      width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
      text: root.removing ? "Frees " + info.size + "."
          : "󰀪  " + (info.size ? "Downloads " + info.size + (info.note ? ". " : "") : "") + (info.note || "")
      color: root.removing ? Commons.Color.muted : Commons.Color.accent
      font.family: root.fontFamily; font.pixelSize: Style.font.caption
    }
    Text {
      visible: root.removesInUse
      width: parent.width; wrapMode: Text.WordWrap
      text: "󰀪  " + root.inUseWarning
      color: Commons.Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    }
    Text {
      width: parent.width; wrapMode: Text.WordWrap
      text: !root.removing ? "Tested before it replaces anything; rolled back if it fails."
          : root.removableDevices.length > 1 ? "Choose which engine to remove; the other keeps working."
          : "You can install it again later."
      color: Commons.Color.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    }
    Flow {
      width: parent.width; spacing: 8
      Button { text: "Cancel"; bordered: true; focusable: true; onClicked: root.cancelled() }
      Repeater {
        model: root.removing && root.removableDevices.length > 1 ? root.removableDevices
             : [root.removing && root.removableDevices.length === 1 ? root.removableDevices[0] : ""]
        delegate: Button {
          required property string modelData
          text: !root.removing ? (root.switching ? "Download and switch" : root.repairing ? "Repair" : "Download and install")
              : root.removableDevices.length > 1
                ? "Remove " + modelData.toUpperCase() + " engine" + (root.details(modelData).size ? " (" + root.details(modelData).size + ")" : "")
                : "Uninstall"
          bordered: true; focusable: true; foreground: root.removing ? Commons.Color.urgent : Commons.Color.accent
          onClicked: root.confirmed(root.target ? root.engineTarget(modelData) : "")
        }
      }
    }
  }
}
