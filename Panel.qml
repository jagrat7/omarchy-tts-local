import QtQuick
import QtQuick.Controls
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "components"

Panel {
  id: root
  moduleName: "io.github.jagrat7.omarchy-tts-local"
  ipcTarget: moduleName
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Commons.Color.muted
  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  property int currentTab: 0
  readonly property var tabNames: ["Overview", "Providers", "Text", "Languages", "Keys"]
  // Sections test the name, not the index, so adding or reordering a tab
  // touches only the list above.
  readonly property string currentTabName: tabNames[currentTab] || ""
  property bool browsing: false
  property string voiceFilter: ""
  property string previewSource: "Visit https://omarchy.org in ~2s and run `speak --help`."
  property string sampleText: "Highlight any text and press the key. This is how it sounds right now."
  property string captureAction: ""
  property string capturedChord: ""
  property string confirmInstall: ""
  property string confirmProvider: ""
  // Set when the confirmation is for switching a provider to a device whose
  // engine is not installed yet; Continue then switches and installs.
  property string confirmDevice: ""
  property string confirmUninstall: ""
  property var autoVerified: ({})
  onActiveProviderChanged: {
    var p = activeProvider
    if (!p || p.status !== "untested" || autoVerified[p.name] || controller.verifying !== "") return
    autoVerified[p.name] = true
    controller.verifyProvider(p.name)
  }
  property string ocrConfirmUninstall: ""
  // Only engines this plugin installs (an `# install:` header) can be removed
  // here; system packages such as Tesseract belong to the package manager.
  function canUninstall(m) {
    return !!m && !!m.install
      && ((m.installedDevices || []).length > 0 || ["ready", "untested", "failing"].indexOf(m.status) >= 0)
  }
  readonly property var providers: controller.info.providers || []
  // Providers declaring the same `# family:` share one row as its variants:
  // a slider picks among the installed ones and + lists the rest to install.
  readonly property var providerEntries: {
    var out = [], families = {}
    for (var i = 0; i < providers.length; ++i) {
      var p = providers[i]
      if (!p.family) { out.push({ family: "", members: [p] }); continue }
      if (!families[p.family]) { families[p.family] = { family: p.family, members: [] }; out.push(families[p.family]) }
      families[p.family].members.push(p)
    }
    for (var j = 0; j < out.length; ++j)
      out[j].members.sort(function(a, b) { return String(a.variant).localeCompare(String(b.variant)) })
    return out
  }
  // A variant counts as installed if its engine for any device is present.
  function variantInstalled(m) { return m.status !== "missing" || (m.installedDevices || []).length > 0 }
  function variantSummary(m) {
    var info = m.installInfo || {}
    var size = String((info.cpu || info["default"] || {}).size || "").replace(/^about /, "~")
    return [size, m.variantNote || ""].filter(function(part) { return part !== "" }).join(" · ")
  }
  property string addingFamily: ""
  // A variant installed from the + list is followed until its job ends; one
  // that installs and passes its test is offered as the one to switch to.
  property string pendingVariant: ""
  property bool pendingSeen: false
  property string provedVariant: ""
  readonly property bool setupBusy: controller.setupStarting || controller.setupJob.status === "starting"
                                    || controller.setupJob.status === "running"
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
  property string confirmVoiceRemove: ""
  property string ocrConfirmInstall: ""
  property string ocrConfirmEngine: ""
  readonly property var activeOcrEngine: {
    var all = controller.info.ocr?.engines || []
    for (var i = 0; i < all.length; ++i) if (all[i].name === (controller.info.ocr?.engine || "tesseract")) return all[i]
    return null
  }
  property bool setupSkipped: false
  readonly property bool hasUsableProvider: {
    var all = controller.info.providers || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].status === "ready" || all[i].status === "untested") return true
    return false
  }
  readonly property bool needsSetup: controller.infoLoaded && controller.setupLoaded
                                     && !controller.setup.ready
                                     && !hasUsableProvider && !setupSkipped
  // PanelKeyCatcher's all-or-nothing `blocked` switch cannot both preserve
  // native control keys and contain Tab inside this popup. Track any focused
  // descendant instead: the handler below always owns Tab, then yields every
  // other key to the focused editor, button, toggle, row or dropdown.
  readonly property bool descendantControlActive: {
    var panelWindow = keyCatcher.Window.window
    var item = panelWindow ? panelWindow.activeFocusItem : null
    return !!item && item !== keyCatcher && root.isInsideKeyCatcher(item)
  }

  function tint(a) { return Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, a) }
  function keyName(event) {
    var key = event.text ? event.text.toUpperCase() : ""
    if (event.key === Qt.Key_BracketLeft) key = "BRACKETLEFT"
    else if (event.key === Qt.Key_BracketRight) key = "BRACKETRIGHT"
    else if (event.key === Qt.Key_Comma) key = "COMMA"
    else if (event.key === Qt.Key_Period) key = "PERIOD"
    else if (event.key === Qt.Key_Slash) key = "SLASH"
    else if (event.key === Qt.Key_Backslash) key = "BACKSLASH"
    else if (event.key === Qt.Key_Semicolon) key = "SEMICOLON"
    else if (event.key === Qt.Key_Apostrophe) key = "APOSTROPHE"
    else if (event.key === Qt.Key_Minus) key = "MINUS"
    else if (event.key === Qt.Key_Equal) key = "EQUAL"
    else if (event.key === Qt.Key_QuoteLeft) key = "GRAVE"
    else if (event.key === Qt.Key_Space) key = "SPACE"
    else if (event.key === Qt.Key_Tab) key = "TAB"
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) key = "RETURN"
    else if (event.key === Qt.Key_Backspace) key = "BACKSPACE"
    else if (event.key === Qt.Key_Delete) key = "DELETE"
    else if (event.key === Qt.Key_Left) key = "LEFT"
    else if (event.key === Qt.Key_Right) key = "RIGHT"
    else if (event.key === Qt.Key_Up) key = "UP"
    else if (event.key === Qt.Key_Down) key = "DOWN"
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35)
      key = "F" + String(event.key - Qt.Key_F1 + 1)
    else if (event.key === Qt.Key_Escape) key = "ESCAPE"
    return key
  }
  function chordFromEvent(event) {
    var parts = []
    if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (event.modifiers & Qt.AltModifier) parts.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    var key = keyName(event)
    if (!key || key === "ESCAPE") return ""
    parts.push(key)
    return parts.join(" + ")
  }
  function isInsideKeyCatcher(item) {
    var current = item
    while (current) {
      if (current === keyCatcher) return true
      current = current.parent
    }
    return false
  }
  function moveTabFocus(direction) {
    var forward = direction >= 0
    var panelWindow = keyCatcher.Window.window
    var current = panelWindow ? panelWindow.activeFocusItem : keyCatcher
    if (!current || typeof current.nextItemInFocusChain !== "function") current = keyCatcher
    var candidate = current
    // This key layer deliberately owns Tab before its descendants. Walk the
    // real Qt focus chain and keep focus inside this popup, including dynamic
    // repeater delegates, instead of maintaining a brittle manual list.
    for (var i = 0; i < 128; ++i) {
      candidate = candidate.nextItemInFocusChain(forward)
      if (!candidate || candidate === current) break
      if (candidate !== keyCatcher && root.isInsideKeyCatcher(candidate)) {
        candidate.forceActiveFocus(forward ? Qt.TabFocusReason : Qt.BacktabFocusReason)
        return
      }
    }
  }
  readonly property var activeProvider: {
    var all = controller.info.providers || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].name === controller.info.provider) return all[i]
    return null
  }
  property string voiceSort: "lang"

  readonly property var voiceSorts: [
    { key: "lang", label: "Language" },
    { key: "name", label: "Name" },
    { key: "size", label: "Size" },
    { key: "quality", label: "Quality" }
  ]

  // Voices are stored as filenames like "en_US-amy-medium". That is an
  // identifier, not a name, and it is what the dropdown and the status line
  // were showing. Providers whose voice names are already words - kokoro's
  // af_heart - are left exactly as they are.
  function titleCase(word) {
    var w = String(word)
    return w.length ? w.charAt(0).toUpperCase() + w.slice(1) : w
  }

  function voiceName(key) {
    var parts = String(key).split("-")
    if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
      return root.titleCase(parts[1].replace(/_/g, " "))
    return String(key)
  }

  function voiceLabel(key) {
    var parts = String(key).split("-")
    if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
      return root.voiceName(key) + " · " + parts[0] + " · " + parts.slice(2).join("-")
    return String(key)
  }

  // PanelSlider ends a drag with `liveValue = value`, assuming the owner has
  // already applied the new number. Ours is written to disk and read back,
  // which takes about 200 ms, so `value` still held the old number and the
  // knob snapped back to it before jumping forward again. These hold the
  // value the user just chose so `value` is already correct at that instant;
  // they are cleared as soon as a settings read confirms the write.
  property real rateOverride: -1
  property int confidenceOverride: -1

  readonly property real rateValue:
    Math.max(root.rateMinimum, Math.min(root.rateMaximum,
      rateOverride >= 0 ? rateOverride : Number(controller.info.rate || 1)))
  readonly property bool rateSupported: !!root.activeProvider
                                        && root.activeProvider.rateMin !== null
                                        && root.activeProvider.rateMax !== null
  readonly property real rateMinimum: root.rateSupported ? Number(root.activeProvider.rateMin) : 1
  readonly property real rateMaximum: root.rateSupported ? Number(root.activeProvider.rateMax) : 1
  // Overview -------------------------------------------------------------
  readonly property string playState: controller.status
  property bool voiceOpen: false
  readonly property bool voicesDownloadable: !root.activeProvider || root.activeProvider.voices === "downloadable"
  // Nothing to speak with, whoever supplies the voices; only the download
  // offer depends on whether this provider's voices can be fetched.
  readonly property bool voiceMissing: controller.infoLoaded && root.voiceOptions.length === 0
  readonly property int prompterPx: Style.fontPx(1.25)
  function playSample() { if (!root.voiceMissing && root.sampleText.trim() !== "") controller.speak(root.sampleText) }
  function openCatalogue() { root.browsing = true; root.voiceFilter = ""; controller.loadCatalogue() }
  // One speed control serves both cases: idle it is a setting, while reading
  // it also asks the backend to retune the utterance already playing.
  function applyRate(r) {
    var s = Math.max(root.rateMinimum, Math.min(root.rateMaximum, Math.round(r * 20) / 20))
    root.rateOverride = s
    if (controller.speaking) controller.setLiveRate(s)
    else controller.setConfig(".rate", s.toFixed(2))
  }
  function clockText(seconds) {
    var s = Math.max(0, Math.round(seconds))
    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
  }
  // The poll lands every half second; between answers the clock runs on
  // locally so the bar and the highlighted phrase move smoothly.
  property real nowPlayingStamp: Date.now()
  property real clock: Date.now()
  Connections { target: controller; function onNowPlayingChanged() { root.nowPlayingStamp = Date.now(); root.clock = root.nowPlayingStamp } }
  Timer { interval: 250; repeat: true; running: root.opened && root.playState === "speaking"; onTriggered: root.clock = Date.now() }
  readonly property real npDuration: Math.max(0, Number(controller.nowPlaying.duration) || 0)
  readonly property real npElapsed: {
    var base = Number(controller.nowPlaying.elapsed) || 0
    if (root.playState === "speaking") base += Math.max(0, root.clock - root.nowPlayingStamp) / 1000
    return root.npDuration > 0 ? Math.min(root.npDuration, base) : base
  }
  readonly property real npProgress: root.npDuration > 0 ? root.npElapsed / root.npDuration : 0
  // A string, so a poll that returns the same text does not rebuild the
  // prompter (an array would be a new value every time and reset the list).
  readonly property string promptText: String(controller.nowPlaying.text || "")
  // Sentences, with any too long to read at a glance (OCR often has no
  // punctuation at all) cut at a word boundary so each fits the screen.
  readonly property var phrases: {
    var text = root.promptText, out = [], start = 0
    function push(end) {
      var piece = text.slice(start, end), lead = piece.length - piece.replace(/^\s+/, "").length
      var at = start + lead
      piece = piece.trim()
      while (piece.length > 160) {
        var cut = piece.lastIndexOf(" ", 140)
        if (cut < 60) cut = 140
        out.push({ text: piece.slice(0, cut).trim(), start: at })
        at += cut; piece = piece.slice(cut).replace(/^\s+/, function(m) { at += m.length; return "" })
      }
      if (piece.length) out.push({ text: piece, start: at })
      start = end
    }
    for (var i = 0; i < text.length; ++i) {
      var c = text.charAt(i)
      if (c === "\n") { push(i + 1); continue }
      if (".!?…".indexOf(c) < 0) continue
      var j = i + 1
      while (j < text.length && ".!?…\"'”’)]".indexOf(text.charAt(j)) >= 0) j++
      if (j >= text.length || /\s/.test(text.charAt(j))) { push(j); i = j - 1 }
    }
    push(text.length)
    return out
  }
  // Speech runs at an even pace closely enough to place the reader by the
  // share of audio already played.
  readonly property int phraseIndex: {
    var list = root.phrases
    if (!list.length) return 0
    var at = root.promptText.length * root.npProgress, found = 0
    for (var i = 0; i < list.length; ++i) if (list[i].start <= at) found = i
    return found
  }
  readonly property int confidenceValue:
    confidenceOverride >= 0 ? confidenceOverride
                            : Number(controller.info.ocr?.minConfidence ?? 60)

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

  readonly property int removeSizeMB: {
    var all = controller.catalogue || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].key === root.confirmVoiceRemove) return Number(all[i].sizeMB || 0)
    return 0
  }

  // A provider addressed by filename (piper) sends plain keys and we make them
  // readable here; one that lists {value, label} pairs names its own voices.
  readonly property var voiceOptions: {
    var list = controller.info.voices || [], out = []
    for (var i = 0; i < list.length; ++i) {
      var v = list[i]
      if (v && typeof v === "object")
        out.push({ label: String(v.label || v.value), value: String(v.value) })
      else
        out.push({ label: root.voiceLabel(v), value: String(v) })
    }
    return out
  }

  // What to call the active voice: the provider's own name for it if we were
  // given one, otherwise the identifier tidied up.
  function activeVoiceLabel() {
    var opts = root.voiceOptions, current = String(controller.info.voice || "")
    for (var i = 0; i < opts.length; ++i)
      if (opts[i].value === current) return opts[i].label
    return root.voiceName(current)
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

  TtsController { id: controller; statusSource: root.hostWidget; panelOpen: root.opened }
  // The panel always opens on the Overview, the player for whatever is being
  // read. The sample text is still restored, but only once real settings
  // have arrived; a callLater fires long before the 200 ms read returns.
  property bool restorePending: false

  onOpenedChanged: {
    if (opened) {
      restorePending = true
      currentTab = 0
      controller.refresh(); controller.refreshBindings(); controller.refreshSetup(); controller.refreshDownload()
    }
  }

  function restoreFromInfo() {
    if (!restorePending || !controller.infoLoaded) return
    restorePending = false
    sampleText = String(controller.info.ui?.sampleText || sampleText)
    controller.previewText(previewSource)
  }
  Connections {
    target: controller
    function onInfoChanged() {
      // The controller discards reads older than the last write, so anything
      // arriving here already reflects it.
      root.rateOverride = -1
      root.confidenceOverride = -1
      root.restoreFromInfo()
      if (!sampleField.activeFocus) {
        root.sampleText = String(controller.info.ui?.sampleText || root.sampleText)
        Qt.callLater(function() { sampleField.cursorPosition = 0 })
      }
    }
  }
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

  KeyboardPanel {
    id: panelCard
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panelCard.fittedContentWidth(Style.space(420))
    contentHeight: panelCard.fittedContentHeight(body.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.moveTabFocus((event.modifiers & Qt.ShiftModifier)
                            || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (voiceDropdown.popupOpen) voiceDropdown.close()
          else if (root.captureAction !== "") {
            root.captureAction = ""
            root.capturedChord = ""
          } else root.close()
          event.accepted = true
          return
        }
        if (root.descendantControlActive) return
        if (root.captureAction !== "") {
          var chord = root.chordFromEvent(event)
          if (chord) root.capturedChord = chord
          event.accepted = true; return
        }
        var tabCount = root.tabNames.length
        if (event.key === Qt.Key_Left) root.currentTab = (root.currentTab + tabCount - 1) % tabCount
        else if (event.key === Qt.Key_Right) root.currentTab = (root.currentTab + 1) % tabCount
        else if (event.key >= Qt.Key_1 && event.key < Qt.Key_1 + tabCount) root.currentTab = event.key - Qt.Key_1
        // Space is play/pause on the Overview, as it is in any player.
        else if (event.key === Qt.Key_Space && root.currentTabName === "Overview" && controller.speaking) controller.togglePause()
        else return
        event.accepted = true
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: body.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: body.implicitHeight > scrollArea.height
        }

        Column {
          id: body
          width: scrollArea.availableWidth
          spacing: Style.space(12)

        Item {
          width: parent.width; height: Math.max(headerIcon.implicitHeight, headerTitle.implicitHeight)
          Text { id: headerIcon; text: "󰕾"; color: controller.speaking ? Commons.Color.accent : root.fg; font.family: root.ff; font.pixelSize: Style.fontPx(1.3); anchors.verticalCenter: parent.verticalCenter }
          Text { id: headerTitle; anchors.left: headerIcon.right; anchors.leftMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; text: "Text to speech"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle }
          Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; // The shortcut is the whole point of the tool; the panel is where
                 // someone finds out what it is.
                 text: { var b = controller.bindings.bindings
                         if (b && b.selection && b.selection.chord) return b.selection.chord
                         return "on-demand accessibility" }
                 color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }
        Row {
          width: parent.width; spacing: Style.space(14); visible: !root.needsSetup
          Repeater {
            model: root.tabNames
            delegate: Item {
              required property string modelData
              required property int index
              width: tabLabel.implicitWidth; height: tabLabel.implicitHeight + Style.space(6)
              activeFocusOnTab: true
              Accessible.role: Accessible.PageTab
              Accessible.name: modelData
              Accessible.selected: root.currentTab === index
              Accessible.onPressAction: root.currentTab = index
              Keys.onSpacePressed: root.currentTab = index
              Keys.onReturnPressed: root.currentTab = index
              Keys.onEnterPressed: root.currentTab = index
              Text { id: tabLabel; text: parent.modelData; color: root.currentTab === parent.index ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Commons.Color.accent; visible: root.currentTab === parent.index }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.currentTab = parent.index }
            }
          }
        }
        PanelSeparator { width: parent.width; foreground: root.fg }

        FirstRunWizard {
          width: parent.width; visible: root.needsSetup; controller: controller; foreground: root.fg
          onSkipped: root.setupSkipped = true
        }

        // Overview ---------------------------------------------------------
        // A teleprompter: the words being read are the largest thing on the
        // panel, with transport and speed under them. When nothing is being
        // read the same screen holds the sample text, so pressing Play turns
        // what you typed into what you are hearing without anything moving.
        Column {
          width: parent.width; spacing: Style.space(10); visible: !root.needsSetup && root.currentTabName === "Overview" && !root.browsing
          Rectangle {
            id: prompterScreen
            readonly property bool reading: root.playState !== "idle"
            width: parent.width; height: Style.space(172); radius: Style.space(6); clip: true
            color: Commons.Color.background; border.width: 1
            // Bordered like a text field, since at rest it is one.
            border.color: Style.controlBorder(sampleField.activeFocus, screenHover.hovered && !reading, root.fg, Commons.Color.accent)
            HoverHandler { id: screenHover }

            Flickable {
              id: sampleFlick
              anchors.fill: parent; anchors.margins: Style.space(10); anchors.bottomMargin: prompterFooter.height + Style.space(6)
              visible: !prompterScreen.reading; clip: true
              contentWidth: width; contentHeight: sampleField.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              TextArea.flickable: TextArea {
                id: sampleField
                textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap; selectByMouse: true
                padding: 0; background: null
                text: root.sampleText; color: root.fg; placeholderText: "Type something to hear it"; placeholderTextColor: root.dim
                font.family: root.ff; font.pixelSize: root.prompterPx
                Accessible.name: "Sample text"
                // Enter plays, as it would in a player; Shift+Enter is still a newline.
                Keys.onReturnPressed: function(event) { if (event.modifiers & Qt.ShiftModifier) event.accepted = false; else root.playSample() }
                Keys.onEnterPressed: function(event) { if (event.modifiers & Qt.ShiftModifier) event.accepted = false; else root.playSample() }
                onTextChanged: {
                  if (text.length > 4096) {
                    var oldCursor = cursorPosition
                    text = text.slice(0, 4096)
                    cursorPosition = Math.min(oldCursor, text.length)
                    return
                  }
                  root.sampleText = text
                }
                onEditingFinished: controller.setConfig(".ui.sampleText", text)
              }
            }

            // Preparation has no words yet when it is capturing or recognising
            // the screen; say what is happening rather than show an empty box.
            Column {
              anchors.centerIn: parent; anchors.verticalCenterOffset: -prompterFooter.height / 2
              spacing: Style.space(4); visible: prompterScreen.reading && root.phrases.length === 0
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰔟"; color: root.dim; font.family: root.ff; font.pixelSize: root.prompterPx }
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Getting the text ready…"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
            }

            ListView {
              id: prompter
              anchors.fill: parent; anchors.margins: Style.space(10); anchors.bottomMargin: prompterFooter.height + Style.space(12)
              visible: prompterScreen.reading && root.phrases.length > 0
              clip: true; interactive: false; spacing: Style.space(6)
              model: root.phrases
              currentIndex: root.phraseIndex
              // The spoken phrase is held in the middle, so the one just read
              // stays in view above it and the next one below.
              readonly property real currentHeight: currentItem ? currentItem.height : 0
              highlightRangeMode: ListView.StrictlyEnforceRange
              preferredHighlightBegin: Math.max(0, (height - currentHeight) / 2)
              preferredHighlightEnd: preferredHighlightBegin + currentHeight
              highlightMoveDuration: 420; highlightMoveVelocity: -1
              Accessible.role: Accessible.StaticText
              Accessible.name: root.phrases.length ? root.phrases[root.phraseIndex].text : ""
              delegate: Text {
                required property var modelData
                required property int index
                readonly property int distance: Math.abs(index - root.phraseIndex)
                width: ListView.view ? ListView.view.width : 0
                textFormat: Text.PlainText; wrapMode: Text.WordWrap; text: modelData.text
                color: distance === 0 ? root.fg : root.dim
                opacity: distance === 0 ? (root.playState === "paused" ? 0.7 : 1) : distance === 1 ? 0.75 : 0.35
                font.family: root.ff; font.pixelSize: distance === 0 ? root.prompterPx : Style.font.body
                Behavior on opacity { NumberAnimation { duration: 240 } }
              }
            }
            Rectangle {
              anchors.top: prompter.top; anchors.left: prompter.left; anchors.right: prompter.right
              height: Style.space(30); visible: prompter.visible
              gradient: Gradient {
                GradientStop { position: 0; color: prompterScreen.color }
                GradientStop { position: 1; color: Qt.rgba(prompterScreen.color.r, prompterScreen.color.g, prompterScreen.color.b, 0) }
              }
            }
            Rectangle {
              anchors.bottom: prompter.bottom; anchors.left: prompter.left; anchors.right: prompter.right
              height: Style.space(30); visible: prompter.visible
              gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(prompterScreen.color.r, prompterScreen.color.g, prompterScreen.color.b, 0) }
                GradientStop { position: 1; color: prompterScreen.color }
              }
            }

            Column {
              id: prompterFooter
              anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
              anchors.margins: Style.space(10); spacing: Style.space(5)
              // Progress, once there is audio to measure. Preparing slides an
              // unmeasured segment instead of claiming a percentage.
              Rectangle {
                id: progressTrack
                width: parent.width; height: 3; radius: 1.5; visible: prompterScreen.reading
                color: Style.selectedFillFor(root.fg, Commons.Color.accent); clip: true
                Rectangle {
                  visible: root.playState !== "preparing"
                  height: parent.height; radius: parent.radius
                  width: parent.width * root.npProgress
                  color: root.playState === "paused" ? root.dim : Commons.Color.accent
                  Behavior on width { NumberAnimation { duration: 260 } }
                }
                Rectangle {
                  id: preparingSweep
                  visible: root.playState === "preparing"
                  height: parent.height; radius: parent.radius; width: parent.width * 0.25
                  color: Commons.Color.accent
                  NumberAnimation on x {
                    running: preparingSweep.visible && root.opened
                    from: -progressTrack.width * 0.25; to: progressTrack.width
                    duration: 1300; loops: Animation.Infinite; easing.type: Easing.InOutQuad
                  }
                }
              }
              Item {
                width: parent.width; height: footerLeft.implicitHeight
                Text {
                  id: footerLeft
                  textFormat: Text.PlainText
                  text: !prompterScreen.reading ? (root.voiceMissing ? (root.voicesDownloadable ? "Download a voice to hear this" : "No voice to play this with") : "Sample · Enter to play")
                        : root.npDuration > 0 ? root.clockText(root.npElapsed) : ""
                  color: root.voiceMissing && !prompterScreen.reading ? Commons.Color.accent : root.dim
                  font.family: root.ff; font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: prompterScreen.reading
                  textFormat: Text.PlainText
                  text: root.playState === "paused" ? "Paused"
                        : root.playState === "preparing" ? "Preparing"
                        : root.phrases.length > 1 ? (root.phraseIndex + 1) + " of " + root.phrases.length : "Reading"
                  color: root.playState === "paused" ? Commons.Color.accent : root.dim
                  font.family: root.ff; font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: !prompterScreen.reading ? "Runs locally"
                        : root.npDuration > 0 ? "−" + root.clockText(root.npDuration - root.npElapsed) : ""
                  color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Transport on the left, speed on the right. The speed control is
          // the same one whether or not anything is playing: idle, it sets
          // the next reading; while reading it retunes the current one if
          // the provider can, and says when it cannot.
          Item {
            width: parent.width; height: Math.max(transport.implicitHeight, speedReadout.implicitHeight)
            Row {
              id: transport
              anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(6)
              Button {
                id: playButton
                width: root.playState === "idle" ? transport.deckWidth : height
                iconText: root.playState === "speaking" || root.playState === "preparing" ? "󰏤" : "󰐊"
                text: root.playState === "idle" ? "Play" : ""
                Accessible.name: root.playState === "idle" ? "Play sample" : controller.paused ? "Resume" : "Pause"
                tooltipText: root.playState === "idle" ? "" : !controller.nowPlaying.canPause ? "This provider cannot pause" : controller.paused ? "Resume" : "Pause"
                bordered: true; focusable: true
                foreground: root.playState === "idle" ? Commons.Color.accent : root.fg
                enabled: root.playState === "idle" ? !root.voiceMissing && root.sampleText.trim() !== ""
                         : root.playState !== "preparing" && controller.nowPlaying.canPause === true
                opacity: enabled ? 1 : 0.45
                onClicked: root.playState === "idle" ? root.playSample() : controller.togglePause()
              }
              Button {
                id: stopButton
                width: height; visible: root.playState !== "idle"
                iconText: "󰓛"; tooltipText: "Stop"; Accessible.name: "Stop"
                bordered: true; focusable: true; foreground: Commons.Color.urgent; accent: Commons.Color.urgent
                onClicked: controller.stop()
              }
              readonly property real deckWidth: playButton.height * 2 + spacing
            }
            Row {
              anchors.left: transport.right; anchors.leftMargin: Style.space(12)
              anchors.right: speedReadout.left; anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6); visible: root.rateSupported
              Button { id: slower; width: Style.space(28); text: "−"; bordered: true; focusable: true; Accessible.name: "Slower"; onClicked: root.applyRate(root.rateValue - .1) }
              // The knob tracks the raw pointer while the label shows the snapped
              // value, so on release it drifts to the step and eases there once
              // the config round-trip returns. Snapping liveValue as we go keeps
              // knob, label and stored value identical at every instant.
              PanelSlider {
                id: speedSlider
                width: parent.width - slower.width - faster.width - parent.spacing * 2; bar: root.bar
                anchors.verticalCenter: parent.verticalCenter
                minimum: root.rateMinimum; maximum: root.rateMaximum; step: .05
                value: root.rateValue
                function snap(v) { return Math.round(v * 20) / 20 }
                // Track the drag in the override too: the label reads it, and it
                // makes `value` already correct when the drag ends.
                onMoved: function(v) { var s = speedSlider.snap(v); root.rateOverride = s; speedSlider.liveValue = s }
                onReleased: function(v) { root.applyRate(v) }   // value is correct before liveValue resets to it
              }
              Button { id: faster; width: Style.space(28); text: "+"; bordered: true; focusable: true; Accessible.name: "Faster"; onClicked: root.applyRate(root.rateValue + .1) }
            }
            Column {
              id: speedReadout
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              width: root.rateSupported ? Style.space(70) : parent.width - transport.width - Style.space(12)
              Text {
                width: parent.width; horizontalAlignment: Text.AlignRight
                text: root.rateSupported ? root.rateValue.toFixed(2) + "×" : "Speed fixed by provider"
                color: root.rateSupported ? root.fg : root.dim; font.family: root.ff
                font.pixelSize: root.rateSupported ? Style.font.body : Style.font.caption
              }
              // Says whether the number above is what you are hearing.
              Text {
                width: parent.width; horizontalAlignment: Text.AlignRight
                visible: root.rateSupported && (root.playState === "speaking" || root.playState === "paused")
                text: controller.nowPlaying.canLiveRate ? "applies now" : "next reading"
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              }
            }
          }

          // Everything about the voice, folded into one line until asked for.
          Rectangle {
            id: voiceCard
            width: parent.width; height: voiceCardColumn.implicitHeight + Style.space(14); radius: Style.space(6)
            color: root.voiceOpen ? root.tint(0.06) : "transparent"
            border.width: 1; border.color: Style.controlBorder(voiceToggle.activeFocus, voiceHover.hovered, root.fg, Commons.Color.accent)
            HoverHandler { id: voiceHover }
            Column {
              id: voiceCardColumn
              anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
              anchors.margins: Style.space(10); anchors.topMargin: Style.space(7); spacing: Style.space(10)
              Item {
                id: voiceToggle
                width: parent.width; height: Math.max(voiceGlyph.implicitHeight, voiceChevron.implicitHeight)
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: "Voice settings, " + voiceSummary.text
                Accessible.expanded: root.voiceOpen
                Accessible.onPressAction: root.voiceOpen = !root.voiceOpen
                Keys.onSpacePressed: root.voiceOpen = !root.voiceOpen
                Keys.onReturnPressed: root.voiceOpen = !root.voiceOpen
                Keys.onEnterPressed: root.voiceOpen = !root.voiceOpen
                Text { id: voiceGlyph; anchors.verticalCenter: parent.verticalCenter; text: "󰗋"; color: root.voiceMissing ? Commons.Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                Text {
                  id: voiceSummary
                  anchors.left: voiceGlyph.right; anchors.leftMargin: Style.space(8)
                  anchors.right: voiceDownload.visible ? voiceDownload.left : voiceChevron.left; anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight; textFormat: Text.PlainText
                  // What you hear, how fast and how much, in one line.
                  text: root.voiceMissing ? "No voice installed"
                        : ["Voice", root.activeVoiceLabel(),
                           root.rateSupported ? root.rateValue.toFixed(2) + "×" : "",
                           controller.info.maxChars > 0 ? "≤" + controller.info.maxChars + " chars" : "unlimited"]
                          .filter(function(part) { return part !== "" }).join(" · ")
                  color: root.voiceMissing ? Commons.Color.accent : root.fg
                  font.family: root.ff; font.pixelSize: Style.font.body
                }
                InlineAction {
                  id: voiceDownload
                  anchors.right: voiceChevron.left; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  visible: root.voiceMissing && root.voicesDownloadable
                  text: "󰇚 Download"; color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption
                  onTriggered: root.openCatalogue()
                }
                Text { id: voiceChevron; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.voiceOpen ? "󰅃" : "󰅀"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                MouseArea { anchors.fill: parent; z: -1; cursorShape: Qt.PointingHandCursor; onClicked: root.voiceOpen = !root.voiceOpen }
              }
              Dropdown { id: voiceDropdown; visible: root.voiceOpen; width: parent.width; showLabel: false; foreground: root.fg; options: root.voiceOptions.length ? root.voiceOptions : [{ label: "No voice installed", value: "" }]; value: controller.info.voice || ""; onValueChanged: if (value && value !== controller.info.voice && value !== "No voice installed") controller.setConfig(controller.info.voicePath || ".piper.voice", value) }
              Button { width: parent.width; visible: root.voiceOpen && root.voicesDownloadable; text: controller.info.voices?.length ? "Browse all voices" : "Download a voice"; iconText: "󰇚"; bordered: true; focusable: true; foreground: controller.info.voices?.length ? root.fg : Commons.Color.accent; onClicked: root.openCatalogue() }
              Item {
                width: parent.width; height: limitHeader.implicitHeight; visible: root.voiceOpen
                PanelSectionHeader { id: limitHeader; text: "Length limit"; foreground: root.fg }
                Text { anchors.right: parent.right; text: controller.info.maxChars > 0 ? "~" + Math.max(1, Math.round(controller.info.maxChars / 900)) + " min" : "unlimited"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
              }
              Row { width: parent.width; spacing: 8; visible: root.voiceOpen
                Button { width: 48; text: "−500"; bordered: true; focusable: true; onClicked: controller.setConfig(".maxChars", Math.max(0, Number(controller.info.maxChars)-500)) }
                TextField {
                  id: maxCharsField; width: parent.width - 112
                  text: String(controller.info.maxChars || 0); foreground: root.fg
                  maximumLength: 7
                  inputMethodHints: Qt.ImhDigitsOnly
                  validator: IntValidator { bottom: 0; top: 1048576 }
                  onEditingFinished: controller.setConfig(".maxChars", Math.max(0, Math.min(1048576, Number(text) || 0)))
                }
                Button { width: 48; text: "+500"; bordered: true; focusable: true; onClicked: controller.setConfig(".maxChars", Math.min(1048576, Number(controller.info.maxChars||0)+500)) }
              }
              Text {
                width: parent.width
                visible: root.voiceOpen && root.activeProvider && Number(root.activeProvider.maxBytes || 0) > 0
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.activeProvider
                      ? (root.activeProvider.title || root.activeProvider.name) + " allows "
                        + root.activeProvider.maxBytes
                        + " UTF-8 bytes per request. Non-Latin characters can use more than one byte."
                      : ""
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Column {
          width: parent.width; spacing: 8; visible: !root.needsSetup && root.currentTabName === "Overview" && root.browsing
          Item {
            width: parent.width; height: browseHeader.implicitHeight
            PanelSectionHeader { id: browseHeader; text: root.installedCount + " installed · " + ((controller.catalogue || []).length - root.installedCount) + " available"; foreground: root.fg }
            InlineAction { anchors.right: parent.right; text: "Done"; color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption; onTriggered: root.browsing = false }
          }
          TextField { id: voiceFilterField; width: parent.width; placeholderText: "Search voices"; text: root.voiceFilter; foreground: root.fg; onTextChanged: root.voiceFilter = text }
          Text {
            width: parent.width; visible: controller.catalogueLoading
            text: "Loading and validating the voice catalogue…"
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width; spacing: Style.space(12)
            Text { text: "Sort"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                   anchors.verticalCenter: parent.verticalCenter }
            Repeater {
              model: root.voiceSorts
              delegate: InlineAction {
                required property var modelData
                text: modelData.label
                color: root.voiceSort === modelData.key ? Commons.Color.accent : root.dim
                font.family: root.ff; font.pixelSize: Style.font.caption
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
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              }
            }
            delegate: Rectangle {
              required property var modelData
              readonly property bool busy: (controller.downloadStarting && controller.pendingDownloadVoice === modelData.key)
                                            || ((controller.download.status === "starting" || controller.download.status === "downloading") && controller.download.voice === modelData.key)
              function activateRow() { if (modelData.installed && modelData.key !== controller.info.voice) controller.useVoice(modelData.key) }
              function activateAction() { if (busy) controller.cancelDownload(); else if (modelData.installed) root.confirmVoiceRemove = modelData.key; else controller.downloadVoice(modelData.key) }
              width: ListView.view.width; height: 42; radius: 5; color: modelData.installed ? root.tint(.07) : "transparent"
              activeFocusOnTab: modelData.installed && modelData.key !== controller.info.voice
              border.width: activeFocus ? 1 : 0; border.color: Commons.Color.accent
              Accessible.role: Accessible.Button
              Accessible.name: "Use " + root.voiceLabel(modelData.key)
              Accessible.onPressAction: activateRow()
              Keys.onSpacePressed: activateRow()
              Keys.onReturnPressed: activateRow()
              Keys.onEnterPressed: activateRow()
              Text { anchors.left: parent.left; anchors.right: parent.right; anchors.rightMargin: 112; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; textFormat: Text.PlainText; text: root.titleCase(String(parent.modelData.name).replace(/_/g, " ")) + " · " + parent.modelData.lang + " · " + parent.modelData.quality; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
              InlineAction {
                id: voiceAction; z: 2; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.installed ? (parent.modelData.key === controller.info.voice ? "󰄬 Active" : "Remove") : (parent.busy ? (controller.downloadCancellable ? controller.download.percent + "% · Cancel" : "Starting…") : (parent.modelData.key === controller.info.voice ? "Repair · " : "󰇚 ") + parent.modelData.sizeMB + " MB")
                color: parent.modelData.installed || parent.busy ? Commons.Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                enabled: (!parent.modelData.installed || parent.modelData.key !== controller.info.voice)
                         && (!parent.busy || controller.downloadCancellable)
                onTriggered: parent.activateAction()
              }
              MouseArea { anchors.fill: parent; z: 1; enabled: parent.modelData.installed && parent.modelData.key !== controller.info.voice; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: parent.activateRow() }
            }
          }
          Rectangle {
            width: parent.width; height: voiceRemoveRow.implicitHeight + 16; radius: 6
            visible: root.confirmVoiceRemove !== ""; color: root.tint(0.08); border.width: 1; border.color: Commons.Color.popups.border
            Row {
              id: voiceRemoveRow; anchors.fill: parent; anchors.margins: 8; spacing: 8
              Text { width: parent.width - cancelVoice.width - removeVoice.width - 24; elide: Text.ElideMiddle; textFormat: Text.PlainText; text: "Remove " + root.voiceLabel(root.confirmVoiceRemove) + "?" + (root.removeSizeMB > 0 ? "  Frees " + root.removeSizeMB + " MB." : ""); color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
              Button { id: cancelVoice; text: "Cancel"; bordered: true; focusable: true; onClicked: root.confirmVoiceRemove = "" }
              Button { id: removeVoice; text: "Remove"; bordered: true; focusable: true; foreground: Commons.Color.urgent; onClicked: { controller.removeVoice(root.confirmVoiceRemove); root.confirmVoiceRemove = "" } }
            }
          }
          Text { text: "Storage: ~/.local/share/omarchy-tts-local/voices/piper"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        // Providers: speech ------------------------------------------------
        // Speech and screen reading are both engines that run here, chosen once
        // and rarely revisited, so one tab holds them as two adjacent groups.
        Column {
          width: parent.width; spacing: Style.space(4); visible: !root.needsSetup && root.currentTabName === "Providers"
          Item {
            width: parent.width; height: providerHeader.implicitHeight
            PanelSectionHeader { id: providerHeader; text: "Speech"; foreground: root.fg }
          }
          Component {
            id: providerRow
            Rectangle {
              id: entry
              // One provider, or every variant of a family on one row.
              required property var modelData
              readonly property bool isFamily: modelData.family !== ""
              readonly property var installed: modelData.members.filter(root.variantInstalled)
              readonly property var available: modelData.members.filter(function(m) { return !root.variantInstalled(m) })
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
              readonly property bool showDevices: (p.devices || []).length > 0 && root.variantInstalled(p)
              readonly property bool showAdd: isFamily && available.length > 0
              readonly property bool showUninstall: root.canUninstall(p)
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
              color: selected ? root.tint(0.10) : "transparent"; border.width: selected || activeFocus ? 1 : 0; border.color: activeFocus ? Commons.Color.accent : root.tint(0.45)
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
                  Text { id: providerRadio; text: entry.selected ? "󰝥" : "󰝦"; color: entry.ready ? (entry.selected ? Commons.Color.accent : root.fg) : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  Text { id: providerName; anchors.left: providerRadio.right; anchors.leftMargin: 8; textFormat: Text.PlainText; text: entry.isFamily ? entry.modelData.family : (entry.p.title || entry.p.name); color: entry.usable ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  // With one variant there is no slider, so the name says which.
                  Text { anchors.left: providerName.right; anchors.leftMargin: 6; anchors.baseline: providerName.baseline; visible: entry.isFamily && entry.installed.length > 0 && !(entry.selected && entry.installed.length > 1); textFormat: Text.PlainText; text: entry.p.variant || ""; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                  Text { anchors.right: providerAction.visible ? providerAction.left : parent.right; anchors.rightMargin: providerAction.visible ? 8 : 0; anchors.verticalCenter: parent.verticalCenter
                    text: entry.failing ? "Not working" : entry.ready ? "● Ready" : ""
                    // urgent is otherwise reserved for Stop, but a backend that is
                    // present and cannot speak is a genuine fault, not an absence.
                    color: entry.failing ? Commons.Color.urgent : entry.ready ? Commons.Color.accent : root.dim
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                  }
                  InlineAction {
                    id: providerAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    visible: (!entry.ready && !entry.untested) || controller.verifying === entry.p.name
                    text: { if (controller.verifying === entry.p.name) return "Testing…"
                            if (entry.isFamily && entry.installed.length === 0) return entry.adding ? "Close" : "Install"
                            if (entry.failing && entry.p.install) return "Repair"
                            if (entry.failing) return "Retry"
                            return "Install" }
                    color: Commons.Color.accent
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                    onTriggered: entry.activateAction()
                  }
                }
                SegmentedControl {
                  width: parent.width
                  visible: entry.isFamily && entry.selected && entry.installed.length > 1
                  options: entry.installed.map(function(m) { return { value: m.name, label: m.variant || m.name } })
                  value: entry.p.name
                  foreground: root.fg; fontFamily: root.ff
                  onSelected: function(name) { root.chooseVariant(entry.installed.find(function(m) { return m.name === name })) }
                }
                Text { visible: entry.failing; width: parent.width; wrapMode: Text.WordWrap; text: "Installed, but it produced no audio when tested. Press Test to try again."; color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
                Text { visible: entry.p.deprecated === true; width: parent.width; wrapMode: Text.WordWrap; text: "Compatibility provider retained for upgrades. Choose Piper for continued support and better speech quality."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                // Where it runs, and adding or removing variants: only on the row in use.
                Item {
                  width: parent.width; height: Math.max(deviceRow.implicitHeight, lineActions.implicitHeight)
                  visible: entry.selected && (entry.showDevices || entry.showAdd || entry.showUninstall)
                  Row {
                    id: deviceRow
                    readonly property var devices: entry.p.devices || []
                    visible: entry.showDevices
                    spacing: 10
                    Text { text: deviceRow.devices.length > 1 ? "Run on" : "Runs on"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                    Text { visible: deviceRow.devices.length === 1; text: String(deviceRow.devices[0] || "").toUpperCase(); color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption }
                    Repeater {
                      model: deviceRow.devices.length > 1 ? deviceRow.devices : []
                      delegate: InlineAction {
                        required property string modelData
                        readonly property bool chosen: (entry.p.device || "cpu") === modelData
                        text: (chosen ? "󰝥 " : "󰝦 ") + modelData.toUpperCase()
                        color: chosen ? Commons.Color.accent : root.fg
                        font.family: root.ff; font.pixelSize: Style.font.caption
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
                      color: hovered || activeFocus ? Commons.Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                      onTriggered: root.addingFamily = entry.adding ? "" : entry.modelData.family
                    }
                    InlineAction {
                      id: providerUninstall
                      visible: entry.showUninstall
                      text: "󰆴"; Accessible.name: "Uninstall"; color: hovered || activeFocus ? Commons.Color.urgent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                      onTriggered: root.confirmUninstall = entry.p.name
                    }
                  }
                }
                // Variants not installed yet, with what each costs.
                Repeater {
                  model: entry.adding ? entry.available : []
                  delegate: Column {
                    required property var modelData
                    readonly property bool busy: root.pendingVariant === modelData.name && root.setupBusy
                    width: parent.width; spacing: 2
                    Item {
                      width: parent.width; height: Math.max(variantLabel.implicitHeight, variantAction.implicitHeight)
                      Text { id: variantLabel; anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: parent.parent.modelData.variant || parent.parent.modelData.name; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
                      Text {
                        anchors.left: variantLabel.right; anchors.leftMargin: 8; anchors.right: variantAction.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight; textFormat: Text.PlainText
                        text: parent.parent.busy ? "building · " + Number(controller.setupJob.progress || 0) + "%" : root.variantSummary(parent.parent.modelData)
                        color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                      }
                      InlineAction {
                        id: variantAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        text: parent.parent.busy ? "Cancel" : "Install"
                        color: parent.parent.busy ? root.dim : Commons.Color.accent
                        enabled: parent.parent.busy ? controller.setupCancellable : !root.setupBusy
                        font.family: root.ff; font.pixelSize: Style.font.caption
                        onTriggered: parent.parent.busy ? controller.cancelSetup() : root.installVariant(parent.parent.modelData)
                      }
                    }
                    Rectangle {
                      width: parent.width; height: 3; radius: 1.5; visible: parent.busy; color: Commons.Color.popups.border
                      Rectangle { height: parent.height; radius: parent.radius; color: Commons.Color.accent
                                  width: parent.width * Math.max(0.02, Math.min(1, Number(controller.setupJob.progress || 0) / 100)) }
                    }
                  }
                }
                Item {
                  width: parent.width; height: provedText.implicitHeight; visible: entry.proved !== null
                  Text { id: provedText; textFormat: Text.PlainText; text: "󰄬 " + (entry.proved ? (entry.proved.variant || entry.proved.name) : "") + " works"; color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption }
                  Row {
                    anchors.right: parent.right; spacing: 12
                    InlineAction { text: "Switch"; color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption
                                   onTriggered: { controller.selectProvider(entry.proved.name, false); root.provedVariant = "" } }
                    InlineAction { text: "Later"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
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
            target: root.confirmInstall !== "" ? (root.providers.find(function(p) { return p.name === root.confirmProvider }) || null) : null
            device: root.confirmDevice
            foreground: root.fg; fontFamily: root.ff
            onCancelled: { root.confirmInstall = ""; root.confirmProvider = ""; root.confirmDevice = "" }
            onConfirmed: {
              if (root.confirmDevice !== "") controller.setDevice(root.confirmProvider, root.confirmDevice, "install")
              else controller.installProvider(root.confirmProvider)
              root.confirmInstall = ""; root.confirmProvider = ""; root.confirmDevice = ""
            }
          }
          EngineConfirm {
            mode: "uninstall"
            width: parent.width
            target: root.confirmUninstall !== "" ? (root.providers.find(function(p) { return p.name === root.confirmUninstall }) || null) : null
            activeName: controller.info.provider || ""
            foreground: root.fg; fontFamily: root.ff
            onCancelled: root.confirmUninstall = ""
            onConfirmed: function(uninstallTarget) { controller.uninstall(uninstallTarget); root.confirmUninstall = "" }
          }
        }

        // Providers: screen reading ----------------------------------------
        Column {
          width: parent.width; spacing: Style.space(4); visible: !root.needsSetup && root.currentTabName === "Providers"
          Item {
            width: parent.width; height: engineHeader.implicitHeight
            PanelSectionHeader { id: engineHeader; text: "Screen reading"; foreground: root.fg }
            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Captures stay on this computer"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          }
          Component {
            id: ocrRow
            Rectangle {
              required property var modelData
              readonly property bool selected: modelData.name === (controller.info.ocr?.engine || "tesseract")
              readonly property bool ready: modelData.status === "ready"
              readonly property bool failing: modelData.status === "failing"
              readonly property bool untested: modelData.status === "untested"
              readonly property bool usable: ready || untested
              function activateRow() { if (usable) controller.selectOcrEngine(modelData.name, untested) }
              function activateAction() {
                var row = this
                if (row.failing && row.modelData.install) {
                  root.ocrConfirmEngine = row.modelData.name
                  root.ocrConfirmInstall = row.modelData.install
                } else if (row.failing || row.untested) {
                  controller.verifyOcrEngine(row.modelData.name)
                } else {
                  root.ocrConfirmEngine = row.modelData.name
                  root.ocrConfirmInstall = row.modelData.install
                }
              }
              width: parent ? parent.width : 0; height: engineCopy.implicitHeight + Style.space(12); radius: Style.space(6)
              color: selected ? root.tint(0.10) : "transparent"; border.width: selected || activeFocus ? 1 : 0; border.color: activeFocus ? Commons.Color.accent : root.tint(0.45)
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
                  Text { id: engineRadio; text: parent.parent.parent.selected ? "󰝥" : "󰝦"; color: parent.parent.parent.ready ? (parent.parent.parent.selected ? Commons.Color.accent : root.fg) : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  Text { id: engineName; anchors.left: engineRadio.right; anchors.leftMargin: 8; textFormat: Text.PlainText; text: parent.parent.parent.modelData.title || parent.parent.parent.modelData.name; color: parent.parent.parent.usable ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  Text { anchors.right: engineAction.visible ? engineAction.left : parent.right; anchors.rightMargin: engineAction.visible ? 8 : 0; anchors.verticalCenter: parent.verticalCenter
                    text: { var d = parent.parent.parent
                            if (d.failing) return "Not working"
                            return d.ready ? "● Ready" : "" }
                    color: { var d = parent.parent.parent; return d.failing ? Commons.Color.urgent : d.ready ? Commons.Color.accent : root.dim }
                    font.family: root.ff; font.pixelSize: Style.font.caption
                  }
                  InlineAction {
                    id: engineAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; visible: (!parent.parent.parent.ready && !parent.parent.parent.untested) || controller.verifying === "ocr:" + parent.parent.parent.modelData.name
                    text: { var d = parent.parent.parent
                            if (controller.verifying === "ocr:" + d.modelData.name) return "Testing…"
                            if (d.failing && d.modelData.install) return "Repair"
                            if (d.failing) return "Retry"
                            return "Install" }
                    color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption
                    onTriggered: parent.parent.parent.activateAction()
                  }
                }
                InlineAction {
                  anchors.right: parent.right
                  visible: root.canUninstall(parent.parent.modelData)
                  text: "󰆴"; Accessible.name: "Uninstall"; color: hovered || activeFocus ? Commons.Color.urgent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                  onTriggered: root.ocrConfirmUninstall = parent.parent.modelData.name
                }
                Text { width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: parent.parent.modelData.desc || ""; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                Text { visible: parent.parent.failing; width: parent.width; wrapMode: Text.WordWrap; text: "Installed, but it could not read the test image. Press Test to try again."; color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
              }
              MouseArea { anchors.fill: parent; enabled: parent.usable; z: 0; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: parent.activateRow() }
            }
          }
          Column {
            width: parent.width; spacing: Style.space(4)
            Repeater { model: controller.info.ocr?.engines || []; delegate: ocrRow }
          }
          EngineConfirm {
            width: parent.width
            target: root.ocrConfirmInstall !== "" ? ((controller.info.ocr?.engines || []).find(function(e) { return e.name === root.ocrConfirmEngine }) || null) : null
            foreground: root.fg; fontFamily: root.ff
            onCancelled: { root.ocrConfirmInstall = ""; root.ocrConfirmEngine = "" }
            onConfirmed: { controller.installProvider(root.ocrConfirmEngine); root.ocrConfirmInstall = ""; root.ocrConfirmEngine = "" }
          }
          EngineConfirm {
            mode: "uninstall"
            width: parent.width
            target: root.ocrConfirmUninstall !== "" ? ((controller.info.ocr?.engines || []).find(function(e) { return e.name === root.ocrConfirmUninstall }) || null) : null
            activeName: controller.info.ocr?.engine || ""
            inUseWarning: "This is the OCR engine in use. Pick another one afterwards or screen reading will stop."
            foreground: root.fg; fontFamily: root.ff
            onCancelled: root.ocrConfirmUninstall = ""
            onConfirmed: function(uninstallTarget) { controller.uninstall(uninstallTarget); root.ocrConfirmUninstall = "" }
          }
          Item {
            // A setting of the engine above, not a third group: caption-sized,
            // with a little air between it and the last engine row.
            width: parent.width; height: ocrHeader.implicitHeight + Style.space(6)
            visible: root.activeOcrEngine && root.activeOcrEngine.supportsConfidence === true
            Text { id: ocrHeader; anchors.bottom: parent.bottom; text: "Confidence floor"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
            Text { anchors.right: parent.right; anchors.bottom: parent.bottom; text: root.confidenceValue > 0 ? root.confidenceValue + "%" : "keep everything"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
          }
          Row {
            width: parent.width; spacing: 8
            visible: root.activeOcrEngine && root.activeOcrEngine.supportsConfidence === true
            Button { width: 32; text: "−"; bordered: true; focusable: true; onClicked: { var s = Math.max(0, root.confidenceValue - 5); root.confidenceOverride = s; controller.setConfig(".ocr.minConfidence", s) } }
            PanelSlider {
              id: confidenceSlider
              width: parent.width - 80; bar: root.bar
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
            Button { width: 32; text: "+"; bordered: true; focusable: true; onClicked: { var s = Math.min(95, root.confidenceValue + 5); root.confidenceOverride = s; controller.setConfig(".ocr.minConfidence", s) } }
          }
          // One progress line for the tab: setup runs one engine at a time, speech
          // or OCR, so the two groups never need a line each.
          Text {
            width: parent.width
            visible: controller.setupStarting || controller.setupJob.status === "running" || controller.setupJob.status === "starting" || controller.setupJob.status === "error"
            textFormat: Text.PlainText
            text: controller.setupStarting ? "Starting setup safely…" : controller.setupJob.message; wrapMode: Text.WordWrap
            color: controller.setupJob.status === "error" ? Commons.Color.urgent : root.dim
            font.family: root.ff; font.pixelSize: Style.font.caption
          }
        }

        // Text -------------------------------------------------------------
        Column {
          width: parent.width; spacing: 8; visible: !root.needsSetup && root.currentTabName === "Text"
          PanelSectionHeader { text: "What gets spoken"; foreground: root.fg }
          Row {
            width: parent.width; spacing: 8
            Rectangle {
              width: (parent.width - 8) / 2; height: 94; radius: 6; clip: true
              color: Commons.Color.background; border.width: 1; border.color: Commons.Color.popups.border
              TextArea {
                id: previewInput
                anchors.fill: parent; anchors.margins: 6
                textFormat: TextEdit.PlainText
                text: root.previewSource; color: root.dim
                wrapMode: TextEdit.Wrap; clip: true; background: null
                font.family: root.ff; font.pixelSize: Style.font.caption
                onTextChanged: {
                  if (text.length > 32768) {
                    var oldCursor = cursorPosition
                    text = text.slice(0, 32768)
                    cursorPosition = Math.min(oldCursor, text.length)
                    return
                  }
                  root.previewSource = text
                  previewDelay.restart()
                }
              }
            }
            Rectangle { width: (parent.width - 8) / 2; height: 94; radius: 6; clip: true; color: root.tint(.06); border.width: 1; border.color: Commons.Color.popups.border; Text { anchors.fill: parent; anchors.margins: 6; textFormat: Text.PlainText; text: controller.preview || "Spoken preview"; color: root.fg; wrapMode: Text.WordWrap; clip: true; elide: Text.ElideRight; maximumLineCount: 5; font.family: root.ff; font.pixelSize: Style.font.caption } }
          }
          SettingToggle { label: "Read URLs as ‘link’"; checked: controller.info.sanitizer?.urls === "link"; foreground: root.fg; onToggled: function(value) { controller.setConfig(".sanitizer.urls", value ? "link" : "domain") } }
          SettingToggle { label: "Read inline code"; checked: controller.info.sanitizer?.inlineCode !== false; foreground: root.fg; onToggled: function(value) { controller.setConfig(".sanitizer.inlineCode", value) } }
          SettingToggle { label: "Announce skipped code blocks"; checked: controller.info.sanitizer?.announceCodeBlocks !== false; foreground: root.fg; onToggled: function(value) { controller.setConfig(".sanitizer.announceCodeBlocks", value) } }
          SettingToggle { label: "Strip Markdown symbols"; checked: controller.info.sanitizer?.stripMarkdown !== false; foreground: root.fg; onToggled: function(value) { controller.setConfig(".sanitizer.stripMarkdown", value) } }
          SettingToggle { label: "Expand abbreviations and units"; checked: controller.info.sanitizer?.expandUnits !== false; foreground: root.fg; onToggled: function(value) { controller.setConfig(".sanitizer.expandUnits", value) } }
          Timer { id: previewDelay; interval: 180; onTriggered: controller.previewText(root.previewSource) }
        }

        // Languages --------------------------------------------------------
        // The engine is chosen once on Providers; languages are browsed, so
        // they keep a tab of their own.
        Column {
          width: parent.width; spacing: 10; visible: !root.needsSetup && root.currentTabName === "Languages"
          Item {
            width: parent.width; height: langHeader.implicitHeight
            PanelSectionHeader { id: langHeader; text: "Languages for " + (root.activeOcrEngine ? (root.activeOcrEngine.title || root.activeOcrEngine.name) : (controller.info.ocr?.engine || "tesseract")); foreground: root.fg }
            InlineAction {
              anchors.right: parent.right
              text: controller.refreshingLanguages !== "" ? "Checking…"
                    : root.installedLanguages.length + " installed · " + root.availableLanguages.length + " available"
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              enabled: controller.refreshingLanguages === ""
              onTriggered: controller.refreshLanguages(controller.info.ocr?.engine || "tesseract")
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            visible: root.ocrLanguages.length === 0
            text: "No language list yet. Click the count above to read what is installed and what can be added."
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
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
                color: active ? root.tint(0.16) : "transparent"
                border.width: 1; border.color: activeFocus ? Commons.Color.accent : (active ? root.tint(0.5) : Commons.Color.popups.border)
                activeFocusOnTab: true
                Accessible.role: Accessible.CheckBox
                Accessible.name: modelData.label || modelData.value
                Accessible.checked: active
                Accessible.onPressAction: root.toggleLanguage(modelData.value)
                Keys.onSpacePressed: root.toggleLanguage(modelData.value)
                Keys.onReturnPressed: root.toggleLanguage(modelData.value)
                Keys.onEnterPressed: root.toggleLanguage(modelData.value)
                Text { id: langChip; anchors.centerIn: parent; textFormat: Text.PlainText; text: parent.modelData.label || parent.modelData.value
                       color: parent.active ? Commons.Color.accent : root.dim
                       font.family: root.ff; font.pixelSize: Style.font.caption }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleLanguage(parent.modelData.value) }
              }
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            visible: root.installedLanguages.length > 0
            text: "Click a language to include or exclude it. Recognition uses every selected language at once, so leave out ones you do not need."
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          }
          TextField {
            id: languageFilterField
            width: parent.width; visible: root.ocrLanguages.length > 0
            placeholderText: "Search " + root.availableLanguages.length + " languages"
            text: root.languageFilter; foreground: root.fg
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
                     color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
              // Language packs are installed as tesseract-data packages, so
              // the action exists only for tesseract. Other engines list what
              // they have; adding to them is a follow-up, not a broken button.
              readonly property bool installable: (controller.info.ocr?.engine || "tesseract") === "tesseract"
              InlineAction { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                     text: !parent.installable ? "not downloaded" : parent.busy ? "Installing…" : "󰇚 Install"
                     color: parent.installable ? Commons.Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                     enabled: parent.installable && !parent.busy
                     onTriggered: controller.installLanguage(parent.modelData.value) }
            }
          }
        }

        // Keys -------------------------------------------------------------
        Column {
          width: parent.width; spacing: 6; visible: !root.needsSetup && root.currentTabName === "Keys"
          Item {
            width: parent.width; height: keysHeader.implicitHeight
            PanelSectionHeader { id: keysHeader; text: "Keybindings"; foreground: root.fg }
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
                     : (root.adoptableCount > 0 ? root.fg : root.dim)
              font.family: root.ff; font.pixelSize: Style.font.caption
            }
          }
          Repeater {
            model: ["selection", "clipboard", "stop", "pause", "snip", "window", "screen"]
            delegate: KeyRow {
              required property string modelData
              readonly property var binding: controller.bindings.bindings?.[modelData] || ({})
              actionName: modelData; label: binding.label || modelData; chord: binding.chord || ""; foreground: root.fg
              onChangeRequested: { root.captureAction = actionName; root.capturedChord = chord; keyCatcher.forceActiveFocus() }
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
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          }
          Text { width: parent.width; visible: controller.bindings.legacy === true; wrapMode: Text.WordWrap; text: "These shortcuts still point at the plugin's old location from before it was renamed. Apply changes to update them."; color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
          Text { width: parent.width; wrapMode: Text.WordWrap; text: "Only the marked omarchy-tts-local block in bindings.lua is managed. Every write is backed up and rolled back if Hyprland reports an error."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          Text { width: parent.width; visible: root.realConflicts.length > 0; wrapMode: Text.WordWrap; text: "Choose different shortcuts for: " + root.realConflicts.join(", "); color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        Rectangle {
          width: parent.width; height: captureColumn.implicitHeight + 16; radius: 7; visible: root.captureAction !== ""; color: Commons.Color.background; border.width: 1; border.color: Commons.Color.accent
          Column { id: captureColumn; anchors.fill: parent; anchors.margins: 8; spacing: 6
            Text { text: "Press the new shortcut for “" + root.captureAction + "”"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.body }
            Text { text: root.capturedChord || "Waiting for keys…"; color: Commons.Color.accent; font.family: root.ff; font.pixelSize: Style.font.subtitle }
            Row { spacing: 8
              Button { text: "Cancel"; bordered: true; focusable: true; onClicked: { root.captureAction = ""; root.capturedChord = "" } }
              Button { text: "Use shortcut"; bordered: true; focusable: true; enabled: root.capturedChord !== ""; foreground: Commons.Color.accent; onClicked: { controller.setBinding(root.captureAction, root.capturedChord); root.captureAction = ""; root.capturedChord = "" } }
            }
          }
        }

        // Elsewhere in the panel, a line keeps what is being read in reach:
        // the phrase, pause and stop, and a way back to the Overview.
        PanelSeparator { width: parent.width; foreground: root.fg; visible: nowPlayingStrip.visible || errorLine.visible }
        Item {
          id: nowPlayingStrip
          width: parent.width; height: Math.max(stripPause.implicitHeight, stripPhrase.implicitHeight)
          visible: !root.needsSetup && root.currentTab !== 0 && controller.speaking
          InlineAction {
            id: stripPause; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: controller.paused ? "󰐊" : "󰏤"; Accessible.name: controller.paused ? "Resume" : "Pause"
            enabled: root.playState !== "preparing" && controller.nowPlaying.canPause === true
            color: enabled ? Commons.Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.body
            onTriggered: controller.togglePause()
          }
          InlineAction {
            id: stripPhrase
            anchors.left: stripPause.right; anchors.leftMargin: Style.space(10)
            anchors.right: stripStop.left; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: root.playState === "preparing" || !root.phrases.length ? "Getting the text ready…"
                  : root.phrases[root.phraseIndex].text
            Accessible.name: "Show what is being read"
            color: hovered || activeFocus ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            onTriggered: root.currentTab = 0
          }
          InlineAction {
            id: stripStop; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: "󰓛"; Accessible.name: "Stop"
            color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.body
            onTriggered: controller.stop()
          }
        }
        Text { id: errorLine; width: parent.width; visible: controller.error !== ""; textFormat: Text.PlainText; text: controller.error; wrapMode: Text.WordWrap; color: Commons.Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
      }
      }
    }
  }
}
