#!/usr/bin/env python3
"""Static contracts for UI races that do not require a running compositor."""
import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class QmlContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.panel = (ROOT / "Panel.qml").read_text()
        cls.controller = (ROOT / "components" / "TtsController.qml").read_text()
        cls.wizard = (ROOT / "components" / "FirstRunWizard.qml").read_text()
        cls.inline_action = (ROOT / "components" / "InlineAction.qml").read_text()
        cls.key_row = (ROOT / "components" / "KeyRow.qml").read_text()
        cls.setting_toggle = (ROOT / "components" / "SettingToggle.qml").read_text()
        cls.segmented = (ROOT / "components" / "SegmentedControl.qml").read_text()

    def test_theme_colours_are_never_shadowed_by_qt_color(self):
        # Qt 6.12 added a QtQuick `Color` singleton that wins over an
        # unqualified qs.Commons Color, leaving every theme colour undefined.
        for path in [ROOT / "Panel.qml", *sorted((ROOT / "components").glob("*.qml"))]:
            with self.subTest(path.name):
                source = path.read_text()
                self.assertIsNone(re.search(r"(?<![\w.])Color\.", source))
                if "Commons.Color." in source:
                    self.assertIn("import qs.Commons as Commons\n", source)

    def test_every_local_install_confirmation_uses_the_shared_component(self):
        component = (ROOT / "components" / "EngineConfirm.qml").read_text()
        self.assertIn("target.installInfo", component)
        # Install and uninstall, for speech and for OCR, all use it.
        self.assertEqual(self.panel.count("EngineConfirm {"), 4)
        self.assertEqual(self.panel.count('mode: "uninstall"'), 2)
        # Sizes live in engine headers, not in the panel.
        self.assertNotIn("2.3 GB", self.panel)
        self.assertNotIn("About 6 GB", self.panel)

    def test_setup_cancel_requires_registered_worker_identity(self):
        self.assertIn("readonly property bool setupCancellable", self.controller)
        self.assertIn("Number(setupJob.pid || 0) > 1", self.controller)
        self.assertIn('String(setupJob.processIdentity || "") !== ""', self.controller)
        self.assertIn("visible: root.controller.setupCancellable", self.wizard)
        self.assertNotIn('setupJob = { status: "starting"',
                         next(line for line in self.controller.splitlines()
                              if "function startSetup" in line))

    def test_variant_slider_holds_only_installed_variants(self):
        # Variants share a row by `# family:`; the slider lists what is
        # installed, appears only with a choice to make, and + lists the rest.
        self.assertIn("Repeater { model: root.providerEntries; delegate: providerRow }", self.panel)
        start = self.panel.index("SegmentedControl {")
        slider = self.panel[start:self.panel.index("}", self.panel.index("onSelected", start))]
        self.assertIn("entry.installed.map", slider)
        self.assertIn("entry.selected && entry.installed.length > 1", slider)
        self.assertIn("model: entry.adding ? entry.available : []", self.panel)
        self.assertIn("readonly property bool showAdd: isFamily && available.length > 0", self.panel)

    def test_variant_install_is_offered_only_after_its_own_job_finishes(self):
        watcher = self.panel[self.panel.index("function onSetupJobChanged()"):]
        watcher = watcher[:watcher.index("\n    }\n")]
        self.assertIn("root.pendingSeen = true", watcher)
        self.assertIn('status === "done" && !root.pendingSeen', watcher)
        self.assertIn("root.provedVariant = root.pendingVariant", watcher)

    def test_panel_scrolls_and_yields_non_tab_keys_to_controls(self):
        self.assertIn("ScrollView {", self.panel)
        self.assertIn("readonly property bool descendantControlActive", self.panel)
        self.assertIn("if (root.descendantControlActive) return", self.panel)

    def test_provider_and_screen_engines_share_one_providers_tab(self):
        self.assertIn('readonly property var tabNames: ["Overview", "Providers", ', self.panel)
        self.assertNotIn('"Screen"', self.panel)
        # Sections and shortcuts follow the list, so a later tab change cannot
        # leave a stale index or a dead number key behind.
        self.assertIsNone(re.search(r"currentTab === \d", self.panel))
        self.assertEqual(self.panel.count('root.currentTabName === "Providers"'), 2)
        self.assertIn("event.key < Qt.Key_1 + tabCount", self.panel)
        # The two groups share one setup progress line.
        self.assertEqual(self.panel.count("controller.setupJob.message"), 1)

    def test_panel_tab_navigation_enters_real_controls(self):
        self.assertIn("function moveTabFocus(direction)", self.panel)
        self.assertIn("candidate.nextItemInFocusChain(forward)", self.panel)
        self.assertIn("candidate.forceActiveFocus", self.panel)
        self.assertIn("Keys.priority: Keys.BeforeItem", self.panel)
        self.assertIn("event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab", self.panel)

    def test_provider_actions_are_declared_by_backend_metadata(self):
        start = self.panel.index(
            "root.activeProvider && Number(root.activeProvider.maxBytes || 0) > 0"
        )
        caption = self.panel[start:self.panel.index("color: root.dim", start)]
        self.assertIn("text: root.activeProvider", caption)
        self.assertIn(': ""', caption)

    def test_retryable_controller_actions_clear_stale_errors(self):
        for signature in (
                "function speak(text)", "function stop()",
                "function verifyProvider(name)", "function verifyOcrEngine(name)",
                "function refreshLanguages(engine)"):
            start = self.controller.index(signature)
            following = self.controller.find("\n  function ", start + len(signature))
            body = self.controller[start:following if following >= 0 else None]
            self.assertIn('error = ""', body, signature)

    def test_playback_reads_are_queued_and_only_poll_an_open_active_panel(self):
        self.assertIn('property string status:', self.controller)
        self.assertIn('readonly property bool paused: status === "paused"', self.controller)
        self.assertIn('readonly property bool speaking: status !== "idle"', self.controller)
        self.assertIn('property var nowPlaying:', self.controller)
        self.assertIn('running: root.panelOpen && root.speaking', self.controller)
        self.assertIn('interval: 450', self.controller)
        self.assertIn('panelOpen: root.opened', self.panel)
        start = self.controller.index('function refreshNowPlaying()')
        body = self.controller[start:self.controller.index('onPanelOpenChanged:', start)]
        self.assertIn('if (!panelOpen || !speaking) return', body)
        self.assertIn('nowPlayingQueued = true', body)
        self.assertNotIn('restart(', body)
        for name in ('pause()', 'resume()', 'togglePause()', 'setLiveRate(rate)'):
            line = next(line for line in self.controller.splitlines() if 'function ' + name in line)
            self.assertIn('error = ""', line)
            self.assertIn('playbackControl(', line)
        self.assertIn('"pause", "snip"', self.panel)

    def test_duplicate_job_starts_reconnect_to_the_backend_owner(self):
        self.assertIn('result.code === "already_running"', self.controller)
        self.assertIn('stderr.indexOf("already running") >= 0', self.controller)
        self.assertIn("setupJobPoll.running = true", self.controller)
        self.assertIn("downloadPoll.running = true", self.controller)

    def test_user_text_uses_bounded_stdin_protocols_not_process_arguments(self):
        self.assertIn('speechProc.command = [speakBin, "--stdin-json"]', self.controller)
        self.assertIn('write(JSON.stringify(root.pendingSpeech) + "\\n")', self.controller)
        self.assertIn('[speakBin, "--preview-stdin-json"]', self.controller)
        self.assertIn('[speakBin, "--set-stdin-json", next.path]', self.controller)
        self.assertNotIn('[speakBin, "--preview-text",', self.controller)

    def test_opening_panel_does_not_fetch_download_catalogue(self):
        opened = self.panel[self.panel.index("onOpenedChanged:"):
                            self.panel.index("function restoreFromInfo")]
        self.assertNotIn("loadCatalogue", opened)
        # Only an explicit Browse/Download opens (and so fetches) the catalogue.
        self.assertIn("function openCatalogue() { root.browsing = true; root.voiceFilter = \"\"; controller.loadCatalogue() }",
                      self.panel)
        self.assertEqual(self.panel.count("controller.loadCatalogue()"), 1)

    def test_config_refresh_waits_for_all_pending_writes(self):
        refresh = self.controller[self.controller.index("function refresh()"):
                                  self.controller.index("function refreshBindings")]
        self.assertIn("configProc.running", refresh)
        self.assertIn("configQueue.length > 0", refresh)
        self.assertIn("infoQueued = true", refresh)

    def test_interactive_custom_controls_expose_keyboard_and_accessibility(self):
        for source in (self.inline_action, self.key_row, self.setting_toggle, self.segmented):
            self.assertIn("activeFocusOnTab", source)
            self.assertIn("Accessible.role", source)
            self.assertIn("Accessible.onPressAction", source)
            self.assertIn("Keys.onSpacePressed", source)

    def test_length_limit_is_bounded_in_the_panel(self):
        self.assertIn("IntValidator { bottom: 0; top: 1048576 }", self.panel)
        self.assertIn("Math.min(1048576", self.panel)

    def test_first_run_counts_only_usable_providers(self):
        self.assertIn("readonly property bool hasUsableProvider", self.panel)
        self.assertIn('all[i].status === "ready" || all[i].status === "untested"',
                      self.panel)
        self.assertIn("controller.setupLoaded", self.panel)
        self.assertIn("!hasUsableProvider", self.panel)

    def test_setup_status_requires_a_successful_backend_response(self):
        start = self.controller.index("id: setupStatusProc")
        block = self.controller[start:self.controller.index("id: setupStartProc", start)]
        self.assertIn("id: setupStatusStderr", block)
        self.assertIn("onExited: function(exitCode, exitStatus)", block)
        self.assertIn("exitCode === 0 && result && result.ok === true", block)
        self.assertNotIn("onStreamFinished", block)

    def test_preview_and_catalogue_reads_are_queued_not_killed(self):
        self.assertIn("property bool previewQueued", self.controller)
        self.assertIn("property bool catalogueQueued", self.controller)
        preview = self.controller[self.controller.index("function previewText"):
                                  self.controller.index("function downloadVoice")]
        catalogue = self.controller[self.controller.index("function loadCatalogue"):
                                    self.controller.index("function action")]
        self.assertNotIn("restart(", preview)
        self.assertNotIn("restart(", catalogue)
        self.assertIn("if (previewProc.running)", preview)
        self.assertIn("if (catalogueProc.running)", catalogue)

    def test_state_read_failures_stop_polling_and_surface_errors(self):
        self.assertIn("id: downloadStatusStderr", self.controller)
        self.assertIn("downloadPoll.running = false", self.controller)
        self.assertIn("id: setupJobStderr", self.controller)
        self.assertIn("setupJobPoll.running = false", self.controller)

    def test_info_failure_does_not_create_an_unbounded_retry_loop(self):
        start = self.controller.index("id: infoProc")
        block = self.controller[start:self.controller.index("id: speechProc", start)]
        self.assertIn("id: infoStderr", block)
        self.assertIn("onExited: function(exitCode, exitStatus)", block)
        self.assertNotIn("root.infoQueued = true", block)

    def test_slow_backend_operations_are_not_killed_and_restarted(self):
        start = self.controller.index("function verifyProvider")
        block = self.controller[start:self.controller.index("function previewText", start)]
        self.assertIn("if (verifyProc.running)", block)
        self.assertIn("if (languageRefreshProc.running)", block)
        self.assertNotIn("restart(", block)

    def test_executable_urls_support_encoded_install_paths(self):
        self.assertIn("decodeURIComponent(value.slice(7))", self.controller)

    def test_user_content_is_never_auto_detected_as_rich_text(self):
        self.assertIn("textFormat: Text.PlainText", self.inline_action)
        preview = self.panel[self.panel.index('text: controller.preview || "Spoken preview"') - 120:
                             self.panel.index('text: controller.preview || "Spoken preview"') + 80]
        self.assertIn("textFormat: Text.PlainText", preview)
        error = self.panel[self.panel.index('visible: controller.error !== ""'):]
        self.assertIn("textFormat: Text.PlainText", error[:180])
        self.assertIn("textFormat: TextEdit.PlainText", self.panel)



    def test_overview_is_the_first_tab_and_navigation_follows_the_tab_list(self):
        self.assertIn('readonly property var tabNames: ["Overview", "Providers", "Text", "Languages", "Keys"]',
                      self.panel)
        self.assertIn("var tabCount = root.tabNames.length", self.panel)
        self.assertNotRegex(self.panel, r"%\s*6\b")
        self.assertNotIn("Qt.Key_6", self.panel)
        opened = self.panel[self.panel.index("onOpenedChanged:"):self.panel.index("function restoreFromInfo")]
        self.assertIn("currentTab = 0", opened)

    def test_teleprompter_hosts_the_sample_and_shows_plain_text(self):
        self.assertNotIn("id: testButton", self.panel)
        self.assertEqual(self.panel.count("id: sampleField"), 1)
        overview = self.panel[self.panel.index("// Overview ----"):self.panel.index("// Providers: speech ----")]
        self.assertIn("id: sampleField", overview)
        self.assertIn("id: prompter", overview)
        phrase = overview[overview.index("delegate: Text {"):overview.index("Behavior on opacity")]
        self.assertIn("textFormat: Text.PlainText", phrase)
        # The sample cannot be played with no voice, whoever supplies voices.
        self.assertIn("readonly property bool voiceMissing: controller.infoLoaded && root.voiceOptions.length === 0",
                      self.panel)
        self.assertIn("if (!root.voiceMissing", self.panel)
        # With no voice the row stays one line and points at Providers (or the
        # catalogue when the engine downloads voices).
        self.assertIn('else root.currentTab = root.tabNames.indexOf("Providers")', self.panel)
        self.assertIn("visible: root.voiceMissing; color:", self.panel)
        self.assertNotIn("voiceOpen", self.panel)
        # The voice is picked inline; the length limit is a Text rule.
        overview = self.panel[self.panel.index("// Overview ----"):self.panel.index("// Providers: speech ----")]
        text_tab = self.panel[self.panel.index("// Text ----"):self.panel.index("// Languages ----")]
        self.assertIn("id: voiceDropdown", overview)
        self.assertNotIn("maxCharsField", overview)
        self.assertIn("id: maxCharsField", text_tab)
        self.assertIn('"Open Providers', self.panel)

    def test_speed_goes_live_while_speaking_and_keeps_the_override(self):
        apply = self.panel[self.panel.index("function applyRate"):self.panel.index("function clockText")]
        self.assertIn("root.rateOverride = s", apply)
        self.assertIn("controller.setLiveRate(s)", apply)
        self.assertIn("Math.max(root.rateMinimum, Math.min(root.rateMaximum", apply)
        self.assertIn('controller.nowPlaying.canLiveRate ? "applies now" : "next reading"', self.panel)

    def test_transport_controls_use_the_controller_playback_api(self):
        # The controller (and its tests) own the CLI flags and queueing; the
        # Overview only calls it, and only polls while the panel is open.
        self.assertIn("TtsController { id: controller; statusSource: root.hostWidget; panelOpen: root.opened }", self.panel)
        self.assertIn("controller.togglePause()", self.panel)
        self.assertIn("controller.setLiveRate(s)", self.panel)
        for name in ("function togglePause()", "function setLiveRate(rate)", 'readonly property bool paused: status === "paused"'):
            self.assertIn(name, self.controller)

class ProcessExitContractTests(unittest.TestCase):
    def test_every_controller_exit_handler_ignores_killed_runs(self):
        """restart() kills an in-flight process; its non-zero exit is not a
        failure of anything and must not surface as an error."""
        source = (ROOT / "components" / "TtsController.qml").read_text()
        handlers = re.findall(r"onExited: function\(([^)]*)\) \{\n((?:.*\n){1,5})", source)
        self.assertTrue(handlers, "no onExited handlers found")
        for params, body in handlers:
            self.assertIn("exitStatus", params)
            self.assertIn("if (exitStatus !== 0) return", body)


if __name__ == "__main__":
    unittest.main()
