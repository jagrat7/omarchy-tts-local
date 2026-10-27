import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "utils.js" as Utils

// Speech and screen reading are both engines that run here, chosen once
// and rarely revisited, so one tab holds them as two adjacent groups.
Column {
  id: root
  required property var panel
  required property var controller
  spacing: Style.space(12)

  property string confirmInstall: ""
  property string confirmProvider: ""
  // Set when the confirmation is for switching a provider to a device whose
  // engine is not installed yet; Continue then switches and installs.
  property string confirmDevice: ""
  property string confirmUninstall: ""
  property string ocrConfirmUninstall: ""
  function clearInstallConfirm() { confirmInstall = ""; confirmProvider = ""; confirmDevice = "" }
  readonly property var providers: controller.info.providers || []
  readonly property var ocrEngines: controller.info.ocr?.engines || []
  // Variants of one `# family:` share a row: a slider picks among the
  // installed ones and + lists the rest to install.
  readonly property var providerEntries: Utils.groupByFamily(providers)
  property string addingFamily: ""
  // A variant installed from the + list is followed until its job ends; one
  // that installs and passes its test is offered as the one to switch to.
  property string pendingVariant: ""
  property bool pendingSeen: false
  property string provedVariant: ""
  function installVariant(m) {
    if (setupBusy) return
    pendingVariant = m.name; pendingSeen = false; provedVariant = ""
    // An engine built per device starts with the CPU one.
    if ((m.installInfo || {}).cpu) controller.setDevice(m.name, "cpu", "install")
    else controller.installProvider(m.name)
  }
  function chooseVariant(m) {
    if (m.status === "failing") { confirmProvider = m.name; confirmInstall = m.install; return }
    // Only another device's engine is present: switch to it with the variant.
    if (m.status === "missing") controller.setDevice(m.name, m.installedDevices[0], "verify")
    controller.selectProvider(m.name, m.status !== "ready")
  }
  // Switching to a device whose engine is present is immediate (and retested);
  // one that needs a download asks first.
  function requestDevice(provider, device) {
    var present = (provider.installedDevices || []).indexOf(device) >= 0
    if (provider.name === "kokoro_onnx" && !present) {
      confirmProvider = provider.name; confirmDevice = device; confirmInstall = provider.install || "install"
      return
    }
    controller.setDevice(provider.name, device, present ? "verify" : "")
  }
  property string ocrConfirmInstall: ""
  property string ocrConfirmEngine: ""
  Connections {
    target: controller
    function onSetupJobChanged() {
      if (root.pendingVariant === "") return
      var status = controller.setupJob.status
      if (status === "starting" || status === "running") { root.pendingSeen = true; return }
      // A "done" left over from an earlier job is not this install finishing.
      if (status === "done" && !root.pendingSeen) return
      if (status === "done") { root.provedVariant = root.pendingVariant; root.addingFamily = "" }
      root.pendingVariant = ""; root.pendingSeen = false
    }
  }

  // Speech ------------------------------------------------------------
  Column {
    width: parent.width; spacing: Style.space(4)
    Item {
      width: parent.width; height: providerHeader.implicitHeight
      PanelSectionHeader { id: providerHeader; text: "Speech"; foreground: panel.fg }
    }
    Component {
      id: providerRow
      Rectangle {
        id: entry
        // One provider, or every variant of a family on one row.
        required property var modelData
        readonly property bool isFamily: modelData.family !== ""
        readonly property var installed: modelData.members.filter(Utils.variantInstalled)
        readonly property var available: modelData.members.filter(function(m) { return !Utils.variantInstalled(m) })
        readonly property var active: modelData.members.find(function(m) { return m.name === controller.info.provider }) || null
        readonly property bool selected: active !== null
        // The variant the row stands for: the one in use, else the best
        // installed one, else the first that could be installed.
        readonly property var p: active || installed.find(function(m) { return m.status === "ready" })
                                 || installed[0] || modelData.members[0]
        readonly property bool ready: p.status === "ready"
        readonly property bool failing: p.status === "failing"
        readonly property bool untested: p.status === "untested"
        // Installed means "present", which is not the same as usable.
        // Unproven is not unusable. A provider that is installed can be
        // selected; only one proven unable to speak is refused.
        readonly property bool usable: ready || untested
        readonly property bool adding: isFamily && root.addingFamily === modelData.family
        readonly property var proved: isFamily ? (modelData.members.find(function(m) {
          return m.name === root.provedVariant && m.status === "ready" && m.name !== controller.info.provider }) || null) : null
        readonly property bool showDevices: (p.devices || []).length > 0 && Utils.variantInstalled(p)
        readonly property bool showAdd: isFamily && available.length > 0
        readonly property bool showUninstall: Utils.canUninstall(p)
        function activateRow() { if (usable) controller.selectProvider(p.name, untested) }
        function activateAction() {
          if (isFamily && installed.length === 0) {
            root.addingFamily = adding ? "" : modelData.family
          } else if (failing && p.install) {
            root.confirmProvider = p.name
            root.confirmInstall = p.install
          } else if (failing || untested) {
            controller.verifyProvider(p.name)
          } else {
            root.confirmProvider = p.name
            root.confirmInstall = p.install
          }
        }
        width: parent ? parent.width : 0; height: providerCopy.implicitHeight + Style.space(12); radius: Style.space(6)
        color: selected ? panel.tint(0.10) : "transparent"; border.width: selected || activeFocus ? 1 : 0; border.color: activeFocus ? Commons.Color.accent : panel.tint(0.45)
        activeFocusOnTab: usable
        Accessible.role: Accessible.RadioButton
        Accessible.name: (isFamily ? modelData.family + " " + (p.variant || "") : (p.title || p.name)) + ", " + p.status
        Accessible.checked: selected
        Accessible.onPressAction: activateRow()
        Keys.onSpacePressed: activateRow()
        Keys.onReturnPressed: activateRow()
        Keys.onEnterPressed: activateRow()
        Column {
          id: providerCopy; z: 1; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8); spacing: Style.space(4)
          Item {
            width: parent.width; height: providerName.implicitHeight
            Text { id: providerRadio; text: entry.selected ? "󰝥" : "󰝦"; color: entry.ready ? (entry.selected ? Commons.Color.accent : panel.fg) : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body }
            Text { id: providerName; anchors.left: providerRadio.right; anchors.leftMargin: 8; textFormat: Text.PlainText; text: entry.isFamily ? entry.modelData.family : (entry.p.title || entry.p.name); color: entry.usable ? panel.fg : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body }
            // With one variant there is no slider, so the name says which.
            Text { anchors.left: providerName.right; anchors.leftMargin: 6; anchors.baseline: providerName.baseline; visible: entry.isFamily && entry.installed.length > 0 && !(entry.selected && entry.installed.length > 1); textFormat: Text.PlainText; text: entry.p.variant || ""; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
            Text { anchors.right: providerAction.visible ? providerAction.left : parent.right; anchors.rightMargin: providerAction.visible ? 8 : 0; anchors.verticalCenter: parent.verticalCenter
              text: Utils.engineStatusText(entry.p)
              // urgent is otherwise reserved for Stop, but a backend that is
              // present and cannot speak is a genuine fault, not an absence.
              color: entry.failing ? Commons.Color.urgent : entry.ready ? Commons.Color.accent : panel.dim
              font.family: panel.ff
              font.pixelSize: Style.font.caption
            }
            InlineAction {
              id: providerAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              visible: (!entry.ready && !entry.untested) || controller.verifying === entry.p.name
              text: { if (controller.verifying === entry.p.name) return "Testing…"
                      if (entry.isFamily && entry.installed.length === 0) return entry.adding ? "Close" : "Install"
                      return Utils.engineActionText(entry.p) }
              color: Commons.Color.accent
              font.family: panel.ff
              font.pixelSize: Style.font.caption
              onTriggered: entry.activateAction()
            }
          }
          SegmentedControl {
            width: parent.width
            visible: entry.isFamily && entry.selected && entry.installed.length > 1
            options: entry.installed.map(function(m) { return { value: m.name, label: m.variant || m.name } })
            value: entry.p.name
            foreground: panel.fg; fontFamily: panel.ff
            onSelected: function(name) { root.chooseVariant(entry.installed.find(function(m) { return m.name === name })) }
          }
          Text { visible: entry.failing; width: parent.width; wrapMode: Text.WordWrap; text: "Installed, but it produced no audio when tested. Press Test to try again."; color: Commons.Color.urgent; font.family: panel.ff; font.pixelSize: Style.font.caption }
          Text { visible: entry.p.deprecated === true; width: parent.width; wrapMode: Text.WordWrap; text: "Compatibility provider retained for upgrades. Choose Piper for continued support and better speech quality."; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
          // Where it runs, and adding or removing variants: only on the row in use.
          Item {
            width: parent.width; height: Math.max(deviceRow.implicitHeight, lineActions.implicitHeight)
            visible: entry.selected && (entry.showDevices || entry.showAdd || entry.showUninstall)
            Row {
              id: deviceRow
              readonly property var devices: entry.p.devices || []
              visible: entry.showDevices
              spacing: 10
              Text { text: deviceRow.devices.length > 1 ? "Run on" : "Runs on"; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
              Text { visible: deviceRow.devices.length === 1; text: String(deviceRow.devices[0] || "").toUpperCase(); color: Commons.Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption }
              Repeater {
                model: deviceRow.devices.length > 1 ? deviceRow.devices : []
                delegate: InlineAction {
                  required property string modelData
                  readonly property bool chosen: (entry.p.device || "cpu") === modelData
                  text: (chosen ? "󰝥 " : "󰝦 ") + modelData.toUpperCase()
                  color: chosen ? Commons.Color.accent : panel.fg
                  font.family: panel.ff; font.pixelSize: Style.font.caption
                  enabled: !chosen
                  Accessible.checked: chosen
                  onTriggered: root.requestDevice(entry.p, modelData)
                }
              }
            }
            Row {
              id: lineActions; anchors.right: parent.right; spacing: 12
              InlineAction {
                id: addVariant
                visible: entry.showAdd
                text: entry.adding ? "󰅖" : "󰐕"
                Accessible.name: entry.adding ? "Close" : "Add another " + entry.modelData.family + " engine"
                color: hovered || activeFocus ? Commons.Color.accent : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
                onTriggered: root.addingFamily = entry.adding ? "" : entry.modelData.family
              }
              InlineAction {
                id: providerUninstall
                visible: entry.showUninstall
                text: "󰆴"; Accessible.name: "Uninstall"; color: hovered || activeFocus ? Commons.Color.urgent : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
                onTriggered: root.confirmUninstall = entry.p.name
              }
            }
          }
          // Variants not installed yet, with what each costs.
          Repeater {
            model: entry.adding ? entry.available : []
            delegate: Column {
              id: variant
              required property var modelData
              readonly property bool busy: root.pendingVariant === modelData.name && controller.setupBusy
              width: parent.width; spacing: 2
              Item {
                width: parent.width; height: Math.max(variantLabel.implicitHeight, variantAction.implicitHeight)
                Text { id: variantLabel; anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: variant.modelData.variant || variant.modelData.name; color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption }
                Text {
                  anchors.left: variantLabel.right; anchors.leftMargin: 8; anchors.right: variantAction.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight; textFormat: Text.PlainText
                  text: variant.busy ? "building · " + Number(controller.setupJob.progress || 0) + "%" : Utils.variantSummary(variant.modelData)
                  color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
                }
                InlineAction {
                  id: variantAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  text: variant.busy ? "Cancel" : "Install"
                  color: variant.busy ? panel.dim : Commons.Color.accent
                  enabled: variant.busy ? controller.setupCancellable : !controller.setupBusy
                  font.family: panel.ff; font.pixelSize: Style.font.caption
                  onTriggered: variant.busy ? controller.cancelSetup() : root.installVariant(variant.modelData)
                }
              }
              ProgressLine { width: parent.width; height: 3; visible: variant.busy; percent: controller.setupJob.progress }
            }
          }
          Item {
            width: parent.width; height: provedText.implicitHeight; visible: entry.proved !== null
            Text { id: provedText; textFormat: Text.PlainText; text: "󰄬 " + (entry.proved ? (entry.proved.variant || entry.proved.name) : "") + " works"; color: Commons.Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption }
            Row {
              anchors.right: parent.right; spacing: 12
              InlineAction { text: "Switch"; color: Commons.Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption
                             onTriggered: { controller.selectProvider(entry.proved.name, false); root.provedVariant = "" } }
              InlineAction { text: "Later"; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
                             onTriggered: root.provedVariant = "" }
            }
          }
        }
        MouseArea { anchors.fill: parent; enabled: parent.usable; z: 0; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: parent.activateRow() }
      }
    }
    Repeater { model: root.providerEntries; delegate: providerRow }
    EngineConfirm {
      width: parent.width
      target: root.confirmInstall !== "" ? Utils.byName(root.providers, root.confirmProvider) : null
      device: root.confirmDevice
      foreground: panel.fg; fontFamily: panel.ff
      onCancelled: root.clearInstallConfirm()
      onConfirmed: {
        if (root.confirmDevice !== "") controller.setDevice(root.confirmProvider, root.confirmDevice, "install")
        else controller.installProvider(root.confirmProvider)
        root.clearInstallConfirm()
      }
    }
    EngineConfirm {
      mode: "uninstall"
      width: parent.width
      target: root.confirmUninstall !== "" ? Utils.byName(root.providers, root.confirmUninstall) : null
      activeName: controller.info.provider || ""
      foreground: panel.fg; fontFamily: panel.ff
      onCancelled: root.confirmUninstall = ""
      onConfirmed: function(uninstallTarget) { controller.uninstall(uninstallTarget); root.confirmUninstall = "" }
    }
  }

  // Screen reading ----------------------------------------------------
  Column {
    width: parent.width; spacing: Style.space(4)
    Item {
      width: parent.width; height: engineHeader.implicitHeight
      PanelSectionHeader { id: engineHeader; text: "Screen reading"; foreground: panel.fg }
    }
    Component {
      id: ocrRow
      Rectangle {
        id: engine
        required property var modelData
        readonly property bool selected: modelData.name === controller.ocrEngine
        readonly property bool ready: modelData.status === "ready"
        readonly property bool failing: modelData.status === "failing"
        readonly property bool untested: modelData.status === "untested"
        readonly property bool usable: ready || untested
        function activateRow() { if (usable) controller.selectOcrEngine(modelData.name, untested) }
        function activateAction() {
          if (failing && modelData.install) {
            root.ocrConfirmEngine = modelData.name
            root.ocrConfirmInstall = modelData.install
          } else if (failing || untested) {
            controller.verifyOcrEngine(modelData.name)
          } else {
            root.ocrConfirmEngine = modelData.name
            root.ocrConfirmInstall = modelData.install
          }
        }
        width: parent ? parent.width : 0; height: engineCopy.implicitHeight + Style.space(12); radius: Style.space(6)
        color: selected ? panel.tint(0.10) : "transparent"; border.width: selected || activeFocus ? 1 : 0; border.color: activeFocus ? Commons.Color.accent : panel.tint(0.45)
        activeFocusOnTab: usable
        Accessible.role: Accessible.RadioButton
        Accessible.name: (modelData.title || modelData.name) + ", " + modelData.status
        Accessible.checked: selected
        Accessible.onPressAction: activateRow()
        Keys.onSpacePressed: activateRow()
        Keys.onReturnPressed: activateRow()
        Keys.onEnterPressed: activateRow()
        Column {
          id: engineCopy; z: 1; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8); spacing: 2
          Item {
            width: parent.width; height: engineName.implicitHeight
            Text { id: engineRadio; text: engine.selected ? "󰝥" : "󰝦"; color: engine.ready ? (engine.selected ? Commons.Color.accent : panel.fg) : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body }
            Text { id: engineName; anchors.left: engineRadio.right; anchors.leftMargin: 8; textFormat: Text.PlainText; text: engine.modelData.title || engine.modelData.name; color: engine.usable ? panel.fg : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body }
            Text { anchors.right: engineAction.visible ? engineAction.left : parent.right; anchors.rightMargin: engineAction.visible ? 8 : 0; anchors.verticalCenter: parent.verticalCenter
              text: Utils.engineStatusText(engine.modelData)
              color: engine.failing ? Commons.Color.urgent : engine.ready ? Commons.Color.accent : panel.dim
              font.family: panel.ff; font.pixelSize: Style.font.caption
            }
            InlineAction {
              id: engineAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; visible: (!engine.ready && !engine.untested) || controller.verifying === "ocr:" + engine.modelData.name
              text: controller.verifying === "ocr:" + engine.modelData.name ? "Testing…" : Utils.engineActionText(engine.modelData)
              color: Commons.Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption
              onTriggered: engine.activateAction()
            }
          }
          InlineAction {
            anchors.right: parent.right
            visible: Utils.canUninstall(engine.modelData)
            text: "󰆴"; Accessible.name: "Uninstall"; color: hovered || activeFocus ? Commons.Color.urgent : panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
            onTriggered: root.ocrConfirmUninstall = engine.modelData.name
          }
          Text { width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: engine.modelData.desc || ""; color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption }
          Text { visible: engine.failing; width: parent.width; wrapMode: Text.WordWrap; text: "Installed, but it could not read the test image. Press Test to try again."; color: Commons.Color.urgent; font.family: panel.ff; font.pixelSize: Style.font.caption }
        }
        MouseArea { anchors.fill: parent; enabled: parent.usable; z: 0; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: parent.activateRow() }
      }
    }
    Column {
      width: parent.width; spacing: Style.space(4)
      Repeater { model: root.ocrEngines; delegate: ocrRow }
    }
    EngineConfirm {
      width: parent.width
      target: root.ocrConfirmInstall !== "" ? Utils.byName(root.ocrEngines, root.ocrConfirmEngine) : null
      foreground: panel.fg; fontFamily: panel.ff
      onCancelled: { root.ocrConfirmInstall = ""; root.ocrConfirmEngine = "" }
      onConfirmed: { controller.installProvider(root.ocrConfirmEngine); root.ocrConfirmInstall = ""; root.ocrConfirmEngine = "" }
    }
    EngineConfirm {
      mode: "uninstall"
      width: parent.width
      target: root.ocrConfirmUninstall !== "" ? Utils.byName(root.ocrEngines, root.ocrConfirmUninstall) : null
      activeName: controller.info.ocr?.engine || ""
      inUseWarning: "This is the OCR engine in use. Pick another one afterwards or screen reading will stop."
      foreground: panel.fg; fontFamily: panel.ff
      onCancelled: root.ocrConfirmUninstall = ""
      onConfirmed: function(uninstallTarget) { controller.uninstall(uninstallTarget); root.ocrConfirmUninstall = "" }
    }
    // One progress line for the tab: setup runs one engine at a time, speech
    // or OCR, so the two groups never need a line each.
    Text {
      width: parent.width
      visible: controller.setupBusy || controller.setupJob.status === "error"
      textFormat: Text.PlainText
      text: controller.setupStarting ? "Starting setup safely…" : controller.setupJob.message; wrapMode: Text.WordWrap
      color: controller.setupJob.status === "error" ? Commons.Color.urgent : panel.dim
      font.family: panel.ff; font.pixelSize: Style.font.caption
    }
  }
}
