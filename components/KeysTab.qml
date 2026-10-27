import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Shortcuts for every action, written into Hyprland's bindings.lua.
Column {
  id: root
  required property var panel
  required property var controller
  spacing: 6

  // Asks the panel to listen for a new chord for this action.
  signal captureRequested(string actionName, string chord)

  readonly property int adoptableCount: (controller.bindings.adoptable || []).length
  // A chord already bound to one of our own commands by hand is adoptable,
  // not a conflict; only a chord bound to something else needs attention.
  readonly property var realConflicts: {
    var adopt = controller.bindings.adoptable || [], out = []
    var chords = adopt.map(function (a) { return String(typeof a === "object" ? (a.chord || a.key || "") : a).toUpperCase() })
    var conflicts = controller.bindings.conflicts || []
    for (var i = 0; i < conflicts.length; ++i)
      if (chords.indexOf(String(conflicts[i]).toUpperCase()) < 0) out.push(conflicts[i])
    return out
  }

  Item {
    width: parent.width; height: keysHeader.implicitHeight
    PanelSectionHeader { id: keysHeader; text: "Keybindings"; foreground: panel.fg }
    Text {
      anchors.right: parent.right
      // "Not installed" beside six shortcuts that plainly work is a
      // contradiction. Unmanaged is a third state, not a broken one.
      text: controller.bindings.installed ? "● Managed"
            : root.realConflicts.length > 0 ? "Needs attention"
            : root.adoptableCount > 0 ? "Written by hand"
            : "Not set up"
      color: controller.bindings.installed ? Commons.Color.accent
             : root.realConflicts.length > 0 ? Commons.Color.urgent
             : (root.adoptableCount > 0 ? panel.fg : panel.dim)
      font.family: panel.ff; font.pixelSize: Style.font.caption
    }
  }
  Repeater {
    model: ["selection", "clipboard", "stop", "pause", "snip", "window", "screen"]
    delegate: KeyRow {
      required property string modelData
      readonly property var binding: controller.bindings.bindings?.[modelData] || ({})
      actionName: modelData; label: binding.label || modelData; chord: binding.chord || ""; foreground: panel.fg
      onChangeRequested: root.captureRequested(actionName, chord)
    }
  }
  Row { width: parent.width; spacing: 8
    Button {
      width: controller.bindings.installed ? (parent.width - 8)/2 : parent.width
      text: controller.bindings.installed ? "Apply changes"
            : (root.adoptableCount > 0 ? "Take over these shortcuts" : "Set up shortcuts")
      bordered: true; focusable: true; foreground: Commons.Color.accent
      enabled: controller.bindings.canInstall !== false
      onClicked: controller.installBindings()
    }
    Button {
      width: (parent.width - 8)/2
      visible: controller.bindings.installed
      text: "Remove shortcuts"; bordered: true; focusable: true; foreground: Commons.Color.urgent
      onClicked: controller.removeBindings()
    }
  }
  Text {
    width: parent.width; wrapMode: Text.WordWrap
    visible: !controller.bindings.installed && root.adoptableCount > 0
    text: "These shortcuts already work; they were written by hand rather than by this panel. Taking them over lets you change them here. Nothing is duplicated."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }
  Text { width: parent.width; wrapMode: Text.WordWrap; text: "Only the marked omarchy-tts-local block in bindings.lua is managed. Every write is backed up and rolled back if Hyprland reports an error."; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
  Text { width: parent.width; visible: root.realConflicts.length > 0; wrapMode: Text.WordWrap; text: "Choose different shortcuts for: " + root.realConflicts.join(", "); color: Commons.Color.urgent; font.family: panel.ff; font.pixelSize: Style.font.caption }
}
