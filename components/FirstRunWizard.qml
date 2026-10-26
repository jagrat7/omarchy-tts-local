import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Rectangle {
  id: root
  required property var controller
  property color foreground: Commons.Color.popups.text
  signal skipped
  width: parent ? parent.width : implicitWidth
  height: content.implicitHeight + Style.space(24)
  radius: Style.space(8)
  color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.08)
  border.width: 1
  border.color: Commons.Color.popups.border

  readonly property bool failed: controller.setupJob.status === "error"
  readonly property bool cpuUnsupported: failed && controller.setupJob.code === "cpu_unsupported"
  readonly property bool kokoroFailed: failed && ["recommended", "kokoro_onnx", "kokoro_onnx_cpu"].indexOf(controller.setupJob.target || "") >= 0
  readonly property bool busy: controller.setupStarting
                               || controller.setupJob.status === "starting"
                               || controller.setupJob.status === "running"

  Column {
    id: content
    anchors.fill: parent
    anchors.margins: Style.space(12)
    spacing: Style.space(10)

    Text {
      text: root.controller.setup.ready ? "Setup complete" : "Welcome to Text to Speech"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      text: root.controller.setup.ready
        ? "The local voice is ready. Text stays on this computer."
        : "Set up Kokoro, a natural local voice that runs on the CPU (about 480 MB). The engine and voices are kept inside the plugin’s data folder, and highlighted text never leaves this computer."
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Rectangle {
      width: parent.width
      height: 6
      radius: 3
      visible: root.busy
      color: Commons.Color.popups.border
      Rectangle {
        height: parent.height
        width: parent.width * Math.max(0.02, Math.min(1, root.controller.setupJob.progress / 100))
        radius: parent.radius
        color: Commons.Color.accent
      }
    }
    Text {
      width: parent.width
      visible: root.busy || root.controller.setupJob.status === "error"
      textFormat: Text.PlainText
      text: root.controller.setupStarting
            ? "Starting setup safely…"
            : (root.controller.setupJob.message || "Preparing setup")
      color: root.controller.setupJob.status === "error" ? Commons.Color.urgent : Commons.Color.muted
      wrapMode: Text.WordWrap
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    // When Kokoro could not be set up for a reason Piper might not share
    // (a failed download, a voice that would not speak), offer the lighter
    // engine. A processor that cannot run the engines at all gets no offer:
    // Piper needs the same processor features.
    Text {
      width: parent.width
      visible: root.kokoroFailed && !root.cpuUnsupported
      wrapMode: Text.WordWrap
      text: "Piper is lighter and works on more computers, with simpler voices."
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    // Wraps rather than clipping when a failure adds a third button.
    Flow {
      width: parent.width
      spacing: Style.space(8)
      Button {
        visible: !root.cpuUnsupported
        text: root.controller.setup.ready ? "Continue" : (root.controller.setupJob.status === "error" ? "Try again" : "Set up Kokoro")
        iconText: root.controller.setup.ready ? "󰄬" : "󰐊"
        bordered: true; focusable: true
        foreground: Commons.Color.accent
        enabled: !root.busy
        onClicked: root.controller.setup.ready ? root.skipped() : root.controller.startSetup("recommended")
      }
      Button {
        visible: root.kokoroFailed && !root.cpuUnsupported && !root.busy
        text: "Use Piper instead"
        bordered: true; focusable: true
        onClicked: { root.controller.selectProvider("piper", false); root.controller.startSetup("piper") }
      }
      Button {
        visible: root.controller.setupCancellable
        text: "Cancel"
        bordered: true; focusable: true
        onClicked: root.controller.cancelSetup()
      }
      Button {
        visible: !root.busy && !root.controller.setup.ready
        text: "Choose another provider"
        bordered: true; focusable: true
        onClicked: root.skipped()
      }
    }
  }
}
