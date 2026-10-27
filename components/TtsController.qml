import QtQuick
import Quickshell.Io
import "utils.js" as Utils

Item {
  id: root
  visible: false

  readonly property string speakBin: Utils.localPath(Qt.resolvedUrl("../bin/speak"))
  readonly property string voiceBin: Utils.localPath(Qt.resolvedUrl("../bin/speak-voice"))
  readonly property string bindingsBin: Utils.localPath(Qt.resolvedUrl("../bin/speak-bindings"))
  readonly property string setupBin: Utils.localPath(Qt.resolvedUrl("../bin/speak-setup"))
  property var info: ({ providers: [], voices: [], ocr: {}, sanitizer: {}, ui: {} })
  // The OCR engine in use; tesseract until a config says otherwise.
  readonly property string ocrEngine: info.ocr?.engine || "tesseract"
  property var catalogue: []
  property bool catalogueLoading: false
  property var download: ({ status: "idle", voice: "", percent: 0 })
  property var bindings: ({ installed: false, bindings: {}, conflicts: [], canInstall: true })
  property var setup: ({ ready: false, engineReady: false, voiceReady: false })
  property bool setupLoaded: false
  property var setupJob: ({ status: "idle", step: "", progress: 0, message: "" })
  property string preview: ""
  property string error: ""
  property string verifying: ""
  property bool downloadStarting: false
  property string pendingDownloadVoice: ""
  property bool setupStarting: false
  property string pendingSpeech: ""
  property string pendingPreview: ""
  property string pendingConfigValue: ""
  property var statusSource: null
  property bool panelOpen: false
  property string watchedStatus: "idle"
  property string status: statusSource ? String(statusSource.status || (statusSource.speaking ? "speaking" : "idle")) : watchedStatus
  readonly property bool paused: status === "paused"
  readonly property bool speaking: status !== "idle"
  property var nowPlaying: Utils.idleNowPlaying()
  property bool nowPlayingQueued: false
  property var playbackQueue: []

  function refreshNowPlaying() {
    if (!panelOpen || !speaking) return
    if (nowPlayingProc.running) { nowPlayingQueued = true; return }
    nowPlayingQueued = false
    nowPlayingProc.running = true
  }
  onPanelOpenChanged: refreshNowPlaying()
  onStatusChanged: {
    if (speaking) refreshNowPlaying()
    else nowPlaying = Utils.idleNowPlaying()
  }
  function runNextPlayback() {
    if (playbackProc.running || playbackQueue.length === 0) return
    var queue = playbackQueue.slice()
    playbackProc.command = [speakBin].concat(queue.shift())
    playbackQueue = queue
    playbackProc.running = true
  }
  function playbackControl(args) {
    var queue = playbackQueue.slice()
    if (args[0] === "--live-rate") {
      writeEpoch++
      queue = queue.filter(function(item) { return item[0] !== "--live-rate" })
    }
    queue.push(args)
    playbackQueue = queue
    runNextPlayback()
  }
  function pause() { error = ""; playbackControl(["--pause"]) }
  function resume() { error = ""; playbackControl(["--resume"]) }
  function togglePause() { error = ""; playbackControl(["--toggle-pause"]) }
  function setLiveRate(rate) { error = ""; playbackControl(["--live-rate", String(rate)]) }
  // A setup or download job counts as running from "starting" on; busy also
  // covers the moment before the backend has answered the start request.
  readonly property bool setupRunning: setupJob.status === "starting" || setupJob.status === "running"
  readonly property bool setupBusy: setupStarting || setupRunning
  readonly property bool downloadRunning: download.status === "starting" || download.status === "downloading"
  readonly property bool setupCancellable:
    setupRunning
    && setupJob.cancellable !== false
    && Number(setupJob.pid || 0) > 1 && String(setupJob.processIdentity || "") !== ""
  readonly property bool downloadCancellable:
    downloadRunning
    && Number(download.pid || 0) > 1 && String(download.processIdentity || "") !== ""
  signal actionFinished

  function restart(process) { process.running = false; process.running = true }

  // `speak --info` takes about 200 ms. Restarting it while it is still
  // writing truncates its output, and half a JSON document does not parse -
  // which is how moving a slider twice in quick succession produced "Could
  // not read TTS settings". Reads are queued instead of killed.
  property bool infoQueued: false
  property bool infoLoaded: false
  property bool catalogueQueued: false
  property bool previewQueued: false

  // A read started before a write can finish after it, and would then report
  // the value we just replaced - which is how a slider ends up showing the
  // old number again a moment after being moved. Each read records the write
  // count it started under; if that count has moved on, the answer describes
  // a config that no longer exists and is thrown away.
  property int writeEpoch: 0
  property int readEpoch: 0

  function refresh() {
    // A read that starts while a queued write is still running can carry the
    // new epoch but the old bytes, so the epoch check alone cannot reject it.
    if (infoProc.running || configProc.running || configQueue.length > 0) {
      infoQueued = true
      return
    }
    infoQueued = false
    readEpoch = writeEpoch
    infoProc.running = true
  }
  function refreshBindings() { if (!bindingsProc.running) bindingsProc.running = true }
  function refreshSetup() {
    if (!setupStatusProc.running) setupStatusProc.running = true
    if (!setupJobProc.running) setupJobProc.running = true
  }
  function refreshDownload() { if (!downloadStatusProc.running) downloadStatusProc.running = true }
  function loadCatalogue() {
    error = ""
    catalogueLoading = true
    if (catalogueProc.running) {
      catalogueQueued = true
      return
    }
    catalogueProc.running = true
  }
  function action(argv) {
    if (actionProc.running) {
      error = "Another TTS action is still finishing. Please try again."
      return false
    }
    error = ""
    actionProc.command = argv
    actionProc.running = true
    return true
  }
  // Writing a setting cannot change keybindings or install state, so only the
  // settings themselves are re-read. Three processes per slider release was
  // most of what made the race easy to hit.
  property var configQueue: []
  function runNextConfig() {
    if (configProc.running || configQueue.length === 0) return
    var queue = configQueue.slice()
    var next = queue.shift()
    configQueue = queue
    pendingConfigValue = JSON.stringify(next.value)
    configProc.command = [speakBin, "--set-stdin-json", next.path]
    configProc.running = true
  }
  function setConfig(path, value) {
    error = ""
    writeEpoch++
    var queue = configQueue.slice()
    // Slider drags can enqueue the same property repeatedly. Keep the newest
    // pending value while preserving writes to unrelated settings.
    for (var i = queue.length - 1; i >= 0; --i) {
      if (queue[i].path === path) { queue.splice(i, 1); break }
    }
    queue.push({ path: path, value: String(value) })
    configQueue = queue
    runNextConfig()
  }
  function speak(text) { error = ""; pendingSpeech = String(text).slice(0, 4096); speechProc.command = [speakBin, "--stdin-json"]; restart(speechProc) }
  function stop() { error = ""; speechProc.command = [speakBin, "--stop"]; restart(speechProc) }
  // Choosing something not yet proven proves it, once the choice has landed.
  function selectProvider(name, verify) { if (verify) afterConfigVerify = name; setConfig(".provider", name) }
  // Only providers that declare `# devices:` offer this; the config layer
  // accepts cpu or gpu for exactly those paths. `then` runs once the write
  // has landed, so a test or install never reads the previous device.
  property string afterConfigVerify: ""
  property string afterConfigSetup: ""
  function setDevice(provider, device, then) {
    if (["kokoro", "kokoro_onnx"].indexOf(provider) < 0 || ["cpu", "gpu"].indexOf(device) < 0) return
    if (then === "verify") afterConfigVerify = provider
    else if (then === "install") afterConfigSetup = provider === "kokoro_onnx" ? "kokoro_onnx_" + device : provider
    setConfig("." + provider + ".device", device)
  }
  // Proving a backend takes seconds and makes no sound; `verifying` lets the
  // panel say so rather than appearing to have ignored the click.
  function verifyProvider(name) {
    error = ""
    if (verifyProc.running) { error = "Another backend test is still running."; return }
    verifying = name; verifyProc.command = [speakBin, "--verify", name]; verifyProc.running = true
  }
  function verifyOcrEngine(name) {
    error = ""
    if (verifyProc.running) { error = "Another backend test is still running."; return }
    verifying = "ocr:" + name; verifyProc.command = [speakBin, "--verify-ocr", name]; verifyProc.running = true
  }
  property string afterConfigVerifyOcr: ""
  function selectOcrEngine(name, verify) { if (verify) afterConfigVerifyOcr = name; setConfig(".ocr.engine", name) }
  property string refreshingLanguages: ""
  function refreshLanguages(engine) {
    error = ""
    if (languageRefreshProc.running) { error = "Languages are already being refreshed."; return }
    refreshingLanguages = engine
    languageRefreshProc.command = [speakBin, "--refresh-languages", engine]
    languageRefreshProc.running = true
  }
  function installLanguage(code) { startSetup("lang:" + code) }
  function previewText(text) {
    pendingPreview = String(text).slice(0, 32768)
    if (previewProc.running) {
      previewQueued = true
      return
    }
    previewProc.command = [speakBin, "--preview-stdin-json"]
    previewProc.running = true
  }
  function downloadVoice(key) {
    if (downloadStartProc.running || actionProc.running) {
      error = "Another TTS action is still finishing. Please try again."
      return
    }
    error = ""
    downloadStarting = true
    pendingDownloadVoice = key
    downloadStartProc.command = [voiceBin, "add", key, "--async"]
    downloadStartProc.running = true
  }
  function cancelDownload() {
    if (downloadCancellable) action([voiceBin, "cancel"])
  }
  function useVoice(key) { action([voiceBin, "use", key]) }
  function removeVoice(key) { action([voiceBin, "remove", key]) }
  function installBindings() { action([bindingsBin, "install"]) }
  function removeBindings() { action([bindingsBin, "remove"]) }
  function setBinding(actionName, chord) { action([bindingsBin, "set", actionName, chord]) }
  function startSetup(target) {
    if (setupStartProc.running || setupStarting) return
    error = ""
    setupStarting = true
    setupStartProc.command = [setupBin, "start", target]
    setupStartProc.running = true
  }
  function installProvider(provider) {
    var targets = ({ "piper": "piper", "kokoro": "kokoro", "kokoro_onnx": "kokoro_onnx", "easyocr": "easyocr" })
    if (targets[provider]) startSetup(targets[provider])
  }
  function uninstall(target) {
    var targets = ["piper", "kokoro", "kokoro_onnx_cpu", "kokoro_onnx_gpu", "easyocr"]
    if (targets.indexOf(target) >= 0) action([setupBin, "uninstall", target])
  }
  function cancelSetup() { if (setupCancellable) action([setupBin, "cancel"]) }

  Process {
    id: configProc; command: []; stdinEnabled: true
    onStarted: { write(root.pendingConfigValue + "\n"); root.pendingConfigValue = "" }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) {
      if (root.configQueue.length > 0) { Qt.callLater(root.runNextConfig); return }
      if (root.afterConfigSetup !== "") { var target = root.afterConfigSetup; root.afterConfigSetup = ""; root.startSetup(target) }
      if (root.afterConfigVerify !== "") { var name = root.afterConfigVerify; root.afterConfigVerify = ""; root.verifyProvider(name) }
      else if (root.afterConfigVerifyOcr !== "") { var engine = root.afterConfigVerifyOcr; root.afterConfigVerifyOcr = ""; root.verifyOcrEngine(engine) }
      root.refresh()
    }
  }
  Process {
    id: infoProc; command: [root.speakBin, "--info"]
    stdout: StdioCollector { id: infoStdout; waitForEnd: true }
    stderr: StdioCollector { id: infoStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var queued = root.infoQueued
      root.infoQueued = false
      if (root.readEpoch !== root.writeEpoch) {
        queued = true       // answered a question we have since changed
      } else if (exitCode !== 0) {
        root.error = String(infoStderr.text || "Could not read TTS settings.").trim()
      } else {
        try {
          var result = JSON.parse(String(infoStdout.text || ""))
          if (!result || typeof result !== "object" || !Array.isArray(result.providers))
            throw new Error("invalid settings response")
          root.info = result
          root.infoLoaded = true
        } catch (e) {
          root.error = "Could not read TTS settings."
        }
      }
      if (queued) Qt.callLater(root.refresh)
    }
  }
  Process {
    id: speechProc
    command: []
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify(root.pendingSpeech) + "\n")
      root.pendingSpeech = ""
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.error = text.trim()
    }
  }
  // The bar already owns a status stream. Reuse it when hosted there, while
  // retaining a fallback for standalone panel development.
  Process { id: speechWatch; running: root.statusSource === null; command: [root.speakBin, "--watch-status"]; stdout: SplitParser { splitMarker: "\n"; onRead: function(data) { root.watchedStatus = data.trim() } } }
  Process {
    id: nowPlayingProc; command: [root.speakBin, "--now-playing"]
    stdout: StdioCollector { id: nowPlayingStdout; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitStatus !== 0) return
      if (exitCode === 0 && root.panelOpen && root.speaking) {
        try { root.nowPlaying = JSON.parse(String(nowPlayingStdout.text || "")) } catch (e) {}
      }
      if (root.nowPlayingQueued) Qt.callLater(root.refreshNowPlaying)
    }
  }
  Process {
    id: playbackProc; command: []
    stderr: StdioCollector { id: playbackStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitStatus !== 0) return
      if (exitCode !== 0) root.error = String(playbackStderr.text || "Could not change playback.").trim()
      root.refreshNowPlaying()
      if (root.playbackQueue.length > 0) Qt.callLater(root.runNextPlayback)
      else root.refresh()
    }
  }
  Timer { interval: 450; repeat: true; running: root.panelOpen && root.speaking; onTriggered: root.refreshNowPlaying() }
  Process {
    id: verifyProc; command: []
    stdout: StdioCollector { id: verifyStdout; waitForEnd: true }
    stderr: StdioCollector { id: verifyStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      if (exitCode !== 0) root.error = String(verifyStderr.text || verifyStdout.text || "Test failed").trim()
      root.verifying = ""; root.refresh()
    }
  }
  Process {
    id: languageRefreshProc; command: []
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) { root.refreshingLanguages = ""; root.refresh() }
  }
  Process {
    id: actionProc; command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var stdout = String(actionStdout.text || "").trim()
      var stderr = String(actionStderr.text || "").trim()
      if (exitCode !== 0) root.error = stderr || stdout || "The TTS action failed."
      else if (stdout.charAt(0) === "{") {
        try {
          var result = JSON.parse(stdout)
          if (result.ok === false) root.error = result.message || "The TTS action failed."
        } catch (e) {}
      }
      root.refresh(); root.refreshBindings(); root.refreshSetup(); root.actionFinished()
    }
  }
  Process {
    id: previewProc
    command: []
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify(root.pendingPreview) + "\n")
      root.pendingPreview = ""
    }
    stdout: StdioCollector { id: previewStdout; waitForEnd: true }
    stderr: StdioCollector { id: previewStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      if (!root.previewQueued) {
        if (exitCode === 0) root.preview = String(previewStdout.text || "").trim()
        else if (exitCode === 1) root.preview = ""
        else root.error = String(previewStderr.text || "Could not prepare the spoken preview.").trim()
      }
      if (root.previewQueued) {
        root.previewQueued = false
        Qt.callLater(function() { root.previewText(root.pendingPreview) })
      }
    }
  }
  Process {
    id: catalogueProc; command: [root.voiceBin, "available", "--json"]
    stdout: StdioCollector { id: catalogueStdout; waitForEnd: true }
    stderr: StdioCollector { id: catalogueStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      if (root.catalogueQueued) {
        root.catalogueQueued = false
        Qt.callLater(root.loadCatalogue)
        return
      }
      root.catalogueLoading = false
      if (exitCode !== 0) {
        root.error = String(catalogueStderr.text || "Could not load the voice catalogue. Check your connection and try again.").trim()
        return
      }
      try { root.catalogue = JSON.parse(String(catalogueStdout.text || "[]")) }
      catch (e) { root.error = "The voice catalogue response was unreadable." }
    }
  }
  Process {
    id: downloadStatusProc; command: [root.voiceBin, "status"]
    stdout: StdioCollector { id: downloadStatusStdout; waitForEnd: true }
    stderr: StdioCollector { id: downloadStatusStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var result = null
      try { result = JSON.parse(String(downloadStatusStdout.text || "")) } catch (e) {}
      if (exitCode !== 0 || !result || typeof result.status !== "string") {
        downloadPoll.running = false
        root.downloadStarting = false
        root.pendingDownloadVoice = ""
        root.error = String(downloadStatusStderr.text || "Could not read voice-download status.").trim()
        return
      }
      var wasActive = root.downloadStarting || root.pendingDownloadVoice !== "" || root.downloadRunning
      root.download = result
      root.pendingDownloadVoice = ""
      if (["starting", "downloading"].indexOf(result.status) >= 0) {
        downloadPoll.running = true
      } else {
        downloadPoll.running = false
        if (wasActive && ["done", "error", "cancelled"].indexOf(result.status) >= 0) {
          root.loadCatalogue()
          root.refresh()
        }
      }
    }
  }
  Process {
    id: downloadStartProc; command: []
    stdout: StdioCollector { id: downloadStartStdout; waitForEnd: true }
    stderr: StdioCollector { id: downloadStartStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      root.downloadStarting = false
      var stdout = String(downloadStartStdout.text || "").trim()
      var stderr = String(downloadStartStderr.text || "").trim()
      if (exitCode !== 0 || stdout !== "started") {
        // The backend is authoritative. If another panel invocation already
        // owns the job, reconnect to it instead of presenting a false failure.
        if (stderr.indexOf("already running") >= 0) {
          root.pendingDownloadVoice = ""
          root.restart(downloadStatusProc)
          downloadPoll.running = true
          return
        }
        root.error = stderr || "Could not start the voice download."
        root.pendingDownloadVoice = ""
        return
      }
      root.restart(downloadStatusProc)
      downloadPoll.running = true
    }
  }
  Process {
    id: bindingsProc; command: [root.bindingsBin, "status"]
    stdout: StdioCollector { id: bindingsStdout; waitForEnd: true }
    stderr: StdioCollector { id: bindingsStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      try {
        if (exitCode !== 0) throw new Error("shortcut status failed")
        root.bindings = JSON.parse(String(bindingsStdout.text || ""))
      } catch (e) {
        root.bindings = { installed: false, bindings: {}, conflicts: [], canInstall: false }
        root.error = String(bindingsStderr.text || "Could not inspect current shortcuts.").trim()
      }
    }
  }
  Process {
    id: setupStatusProc; command: [root.setupBin, "status"]
    stdout: StdioCollector { id: setupStatusStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupStatusStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var result = null
      try { result = JSON.parse(String(setupStatusStdout.text || "")) } catch (e) {}
      if (exitCode === 0 && result && result.ok === true) {
        root.setup = result
        root.setupLoaded = true
      } else {
        root.error = (result && result.message)
                     || String(setupStatusStderr.text || "Could not read TTS setup status.").trim()
      }
    }
  }
  Process {
    id: setupStartProc; command: []
    stdout: StdioCollector { id: setupStartStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupStartStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      root.setupStarting = false
      var result = null
      try { result = JSON.parse(String(setupStartStdout.text || "")) } catch (e) {}
      if (exitCode !== 0 || !result || result.ok !== true) {
        if (result && result.code === "already_running") {
          root.restart(setupJobProc)
          setupJobPoll.running = true
          return
        }
        root.error = (result && result.message) || String(setupStartStderr.text || "Could not start setup.").trim()
        root.setupJob = { status: "error", step: "failed", progress: 0, message: root.error }
        return
      }
      root.setupJob = { status: "starting", step: "prepare", progress: 1,
                        message: "Preparing setup", pid: result.pid,
                        processIdentity: result.processIdentity || "" }
      root.restart(setupJobProc)
      setupJobPoll.running = true
    }
  }
  Process {
    id: setupJobProc; command: [root.setupBin, "job"]
    stdout: StdioCollector { id: setupJobStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupJobStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var result = null
      try { result = JSON.parse(String(setupJobStdout.text || "")) } catch (e) {}
      if (exitCode !== 0 || !result || typeof result.status !== "string") {
        setupJobPoll.running = false
        root.error = String(setupJobStderr.text || "Could not read setup progress.").trim()
        return
      }
      root.setupJob = result
      if (["starting", "running"].indexOf(result.status) >= 0) {
        setupJobPoll.running = true
      } else {
        setupJobPoll.running = false
        if (["done", "error", "cancelled"].indexOf(result.status) >= 0) {
          root.restart(setupStatusProc)
          root.refresh()
        }
      }
    }
  }
  Timer { id: downloadPoll; interval: 1000; repeat: true; running: false; onTriggered: if (!downloadStatusProc.running) downloadStatusProc.running = true }
  Timer { id: setupJobPoll; interval: 1200; repeat: true; running: false; onTriggered: if (!setupJobProc.running) setupJobProc.running = true }
}
