#!/usr/bin/env python3
"""Small integration checks for the public CLI/config boundary."""
import base64
import importlib.machinery
import importlib.util
import hashlib
import json
import uuid
import zipfile
import shutil
import os
import re
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
import io
import contextlib

ROOT = Path(__file__).resolve().parents[1]
SPEAK = ROOT / "bin" / "speak"
BINDINGS = ROOT / "bin" / "speak-bindings"
SETUP = ROOT / "bin" / "speak-setup"


def load_setup_module():
    """Load the extensionless setup helper without invoking its CLI."""
    name = f"_omarchy_tts_setup_test_{time.time_ns()}"
    loader = importlib.machinery.SourceFileLoader(name, str(SETUP))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    previous_umask = os.umask(0)
    os.umask(previous_umask)
    try:
        loader.exec_module(module)
    finally:
        os.umask(previous_umask)
    return module


class CliConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = {**os.environ, "XDG_CONFIG_HOME": self.temp.name,
                    "XDG_CACHE_HOME": self.temp.name,
                    "XDG_DATA_HOME": self.temp.name,
                    "XDG_RUNTIME_DIR": self.temp.name,
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent"}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        self.env.pop("OMARCHY_TTS_SETUP_LOCK_FD", None)
        self.env.pop("OMARCHY_TTS_DOWNLOAD_LOCK_FD", None)

    def tearDown(self):
        self.temp.cleanup()

    def run_speak(self, *args, input_text=None, check=True):
        return subprocess.run([SPEAK, *args], input=input_text, text=True,
                              capture_output=True, env=self.env, check=check)

    def test_fresh_info_creates_complete_private_config(self):
        info = json.loads(self.run_speak("--info").stdout)
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        settings = json.loads(config.read_text())
        self.assertEqual(info["provider"], "piper")
        self.assertTrue(info["sanitizer"]["stripMarkdown"])
        self.assertEqual(settings["schemaVersion"], 6)
        for retired in ("openai", "elevenlabs", "gemini", "google"):
            self.assertNotIn(retired, settings)
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_partial_provider_objects_receive_missing_defaults(self):
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"kokoro_onnx": {"voice": "af_sky"},
                                      "kokoro": {}}))
        self.run_speak("--info")
        settings = json.loads(config.read_text())
        self.assertEqual(settings["kokoro_onnx"]["voice"], "af_sky")
        self.assertEqual(settings["kokoro_onnx"]["device"], "cpu")
        self.assertEqual(settings["kokoro_onnx"]["keepWarm"], 10)
        self.assertEqual(settings["kokoro"]["voice"], "af_heart")

    def test_retired_cloud_settings_migrate_to_local_defaults(self):
        """The cloud providers and OCR engines were removed. A config that
        still selects one lands on the local default, and its settings and
        the collapsed Local/Cloud groups are dropped."""
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({
            "schemaVersion": 4, "provider": "elevenlabs",
            "openai": {"voice": "nova"}, "elevenlabs": {"voiceId": "abc"},
            "gemini": {"api": "vertex"}, "google": {"voice": ""},
            "ocr": {"engine": "google", "openai": {"model": "gpt-4.1-mini"}},
            "ui": {"collapsed": "cloud,ocr-cloud", "lastTab": 2},
        }))
        info = json.loads(self.run_speak("--info").stdout)
        settings = json.loads(config.read_text())
        self.assertEqual(info["provider"], "piper")
        self.assertEqual(info["ocr"]["engine"], "tesseract")
        self.assertEqual(settings["schemaVersion"], 6)
        for retired in ("openai", "elevenlabs", "gemini", "google"):
            self.assertNotIn(retired, settings)
            self.assertNotIn(retired, settings["ocr"])
        self.assertNotIn("collapsed", settings["ui"])
        self.assertEqual(settings["ui"]["lastTab"], 2)

    def test_last_tab_follows_the_merged_providers_tab(self):
        """Schema 6 merged Provider and Screen into one Providers tab. An index
        saved under the old six tabs lands on the same content; one saved
        under the new five is kept, and only those five can be written."""
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.parent.mkdir(parents=True)
        for schema, saved, expected in ((5, 0, 0), (5, 1, 1), (5, 2, 2), (5, 3, 0),
                                        (5, 4, 3), (5, 5, 4), (6, 3, 3), (6, 5, 0)):
            with self.subTest(schema=schema, saved=saved):
                config.write_text(json.dumps({"schemaVersion": schema, "ui": {"lastTab": saved}}))
                info = json.loads(self.run_speak("--info").stdout)
                self.assertEqual(info["ui"]["lastTab"], expected)
                self.assertEqual(json.loads(config.read_text())["schemaVersion"], 6)
        self.run_speak("--set", ".ui.lastTab", "4")
        self.assertNotEqual(self.run_speak("--set", ".ui.lastTab", "5", check=False).returncode, 0)
        self.assertEqual(json.loads(config.read_text())["ui"]["lastTab"], 4)

    def test_help_does_not_require_or_create_writable_state(self):
        blocked = Path(self.temp.name, "blocked")
        blocked.write_text("not a directory")
        env = {**self.env, "XDG_CONFIG_HOME": str(blocked),
               "XDG_CACHE_HOME": str(blocked), "XDG_RUNTIME_DIR": str(blocked)}
        result = subprocess.run([SPEAK, "--help"], env=env, check=True,
                                text=True, capture_output=True)
        self.assertIn("Usage: speak", result.stdout)

    def test_combined_state_watch_emits_initial_and_config_changes(self):
        watcher = subprocess.Popen(
            [SPEAK, "--watch-state"], env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.assertTrue(select.select([watcher.stdout], [], [], 3)[0])
            initial = json.loads(watcher.stdout.readline())
            self.assertEqual(initial, {"status": "idle", "provider": "piper"})

            self.run_speak("--set", ".provider", "kokoro")
            self.assertTrue(select.select([watcher.stdout], [], [], 3)[0])
            changed = json.loads(watcher.stdout.readline())
            self.assertEqual(changed["provider"], "kokoro")
        finally:
            watcher.terminate()
            watcher.wait(timeout=3)
            watcher.stdout.close()
            watcher.stderr.close()

    def test_info_makes_no_network_request(self):
        marker = Path(self.temp.name, "curl-was-run")
        tools = Path(self.temp.name, "tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(f"#!/usr/bin/env bash\nprintf touched > {marker}\nexit 99\n")
        curl.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"
        self.run_speak("--info")
        self.assertFalse(marker.exists(), "a read-only state query made a network request")

    def test_image_only_clipboard_is_ocrd_before_speech(self):
        tools = Path(self.temp.name, "tools")
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        ocr = Path(self.temp.name, "omarchy-tts-local", "ocr")
        tools.mkdir()
        providers.mkdir(parents=True)
        ocr.mkdir(parents=True)
        captured = Path(self.temp.name, "spoken-text")

        wl_paste = tools / "wl-paste"
        wl_paste.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == --list-types ]]; then\n"
            "  [[ ${MIXED_CLIPBOARD:-0} == 1 ]] && printf 'text/plain;charset=utf-8\\n'\n"
            "  printf 'image/png\\n'\n"
            "elif [[ $* == *text/plain* ]]; then printf 'Preferred clipboard text.'\n"
            "else printf 'fake-png-bytes'; fi\n"
        )
        wl_paste.chmod(0o755)
        ocr_bin = ocr / "testocr"
        ocr_bin.write_text(
            "#!/usr/bin/env bash\n# desc: test OCR\ncat >/dev/null\n"
            "printf 'Words recovered from the image.\\n'\n"
        )
        ocr_bin.chmod(0o755)
        provider = providers / "capturetest"
        provider.write_text(
            "#!/usr/bin/env bash\n# desc: capture speech input\n# kind: local\n"
            "cat > \"$CAPTURED_TEXT\"\n"
        )
        provider.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"
        self.env["CAPTURED_TEXT"] = str(captured)
        self.run_speak("--set", ".ocr.engine", "testocr")

        self.run_speak("--clipboard", "--provider", "capturetest")
        self.assertEqual(captured.read_text().strip(),
                         "Words recovered from the image.")

        self.env["MIXED_CLIPBOARD"] = "1"
        self.run_speak("--clipboard", "--provider", "capturetest")
        self.assertEqual(captured.read_text().strip(),
                         "Preferred clipboard text.")

    def test_screen_capture_never_falls_back_to_all_monitors(self):
        tools = Path(self.temp.name, "screen-tools")
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        tools.mkdir()
        providers.mkdir(parents=True)
        grim_marker = Path(self.temp.name, "grim-ran")
        hyprctl = tools / "hyprctl"
        hyprctl.write_text("#!/usr/bin/env bash\nprintf '[]\\n'\n")
        hyprctl.chmod(0o755)
        grim = tools / "grim"
        grim.write_text(
            "#!/usr/bin/env bash\nprintf ran > \"$GRIM_MARKER\"\nprintf fake-image\n"
        )
        grim.chmod(0o755)
        provider = providers / "capturetest"
        provider.write_text(
            "#!/usr/bin/env bash\n# desc: capture speech input\n# kind: local\n"
            "cat >/dev/null\n"
        )
        provider.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "GRIM_MARKER": str(grim_marker)}
        result = subprocess.run(
            [SPEAK, "--screen", "--provider", "capturetest"], env=env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("focused monitor", result.stderr)
        self.assertFalse(grim_marker.exists())

    def test_invalid_config_is_preserved_before_recovery(self):
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.parent.mkdir(parents=True)
        config.write_text('{"provider":')
        result = self.run_speak("--info")
        self.assertEqual(json.loads(result.stdout)["provider"], "piper")
        preserved = list(config.parent.glob("config.json.invalid.*"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_text(), '{"provider":')
        self.assertEqual(preserved[0].stat().st_mode & 0o777, 0o600)

    def test_structurally_invalid_nested_config_is_preserved_and_repaired(self):
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.parent.mkdir(parents=True)
        original = {"provider": "piper", "piper": [],
                    "ocr": {"engine": "custom", "custom": "broken"}}
        config.write_text(json.dumps(original))
        result = self.run_speak("--info")
        self.assertEqual(result.returncode, 0, result.stderr)
        repaired = json.loads(config.read_text())
        self.assertIsInstance(repaired["piper"], dict)
        self.assertIsInstance(repaired["ocr"]["custom"], dict)
        preserved = list(config.parent.glob("config.json.invalid.*"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(json.loads(preserved[0].read_text()), original)

    def test_config_updates_preserve_a_dotfile_symlink(self):
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        target = Path(self.temp.name, "dotfiles", "tts.json")
        config.parent.mkdir(parents=True)
        target.parent.mkdir()
        target.write_text("{}\n")
        config.symlink_to(target)

        self.run_speak("--set", ".rate", ".25")
        self.assertTrue(config.is_symlink())
        self.assertEqual(json.loads(target.read_text())["rate"], 0.25)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_dangling_config_symlink_is_refused_without_replacement(self):
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.parent.mkdir(parents=True)
        target = Path(self.temp.name, "missing", "tts.json")
        config.symlink_to(target)
        result = self.run_speak("--info", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(config.is_symlink())
        self.assertFalse(target.exists())

    def test_non_file_config_paths_are_refused_without_moving_them(self):
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.mkdir(parents=True)
        marker = config / "keep"
        marker.write_text("unchanged")
        result = self.run_speak("--info", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(config.is_dir())
        self.assertEqual(marker.read_text(), "unchanged")

    def test_config_symlink_to_a_directory_is_refused_without_moving_target(self):
        base = Path(self.temp.name, "omarchy-tts-local")
        base.mkdir(parents=True)
        target = Path(self.temp.name, "managed-config-directory")
        target.mkdir()
        marker = target / "keep"
        marker.write_text("unchanged")
        config = base / "config.json"
        config.symlink_to(target, target_is_directory=True)
        result = self.run_speak("--info", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(config.is_symlink())
        self.assertEqual(marker.read_text(), "unchanged")

    def test_noop_config_write_preserves_inode_and_mtime(self):
        self.run_speak("--info")
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        before = config.stat()
        self.run_speak("--set", ".rate", "1.0")
        after = config.stat()
        self.assertEqual(after.st_ino, before.st_ino)
        self.assertEqual(after.st_mtime_ns, before.st_mtime_ns)

    def test_control_commands_work_without_parsing_damaged_config(self):
        config = Path(self.temp.name, "omarchy-tts-local", "config.json")
        config.parent.mkdir(parents=True)
        config.write_text('{"provider":')
        self.assertEqual(self.run_speak("--status").stdout.strip(), "idle")
        self.run_speak("--stop")
        self.assertEqual(config.read_text(), '{"provider":')
        self.assertEqual(list(config.parent.glob("config.json.invalid.*")), [])

    def test_info_reports_sanitizer_toggles_turned_off(self):
        keys = ("inlineCode", "announceCodeBlocks", "stripMarkdown", "expandUnits")
        for key in keys:
            self.run_speak("--set-stdin-json", f".sanitizer.{key}",
                           input_text=json.dumps("false") + "\n")
        sanitizer = json.loads(self.run_speak("--info").stdout)["sanitizer"]
        for key in keys:
            self.assertIs(sanitizer[key], False, key)

    def test_stdin_json_protocol_preserves_strings_and_rejects_other_json(self):
        sample = '  true, "$HOME", backslash \\ and café  '
        saved = self.run_speak("--set-stdin-json", ".ui.sampleText",
                               input_text=json.dumps(sample) + "\n")
        self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertEqual(json.loads(self.run_speak("--info").stdout)["ui"]["sampleText"],
                         sample)
        preview = self.run_speak("--preview-stdin-json",
                                 input_text=json.dumps("true") + "\n")
        self.assertEqual(preview.stdout, "true")
        for encoded in ('{"not":"a string"}\n', '"nul\\u0000byte"\n'):
            with self.subTest(encoded=encoded):
                self.assertNotEqual(
                    self.run_speak("--set-stdin-json", ".ui.sampleText",
                                   input_text=encoded, check=False).returncode,
                    0,
                )

    def test_input_and_length_limits_are_enforced_before_a_provider_runs(self):
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True)
        marker = Path(self.temp.name, "limit-provider-ran")
        provider = providers / "limitcheck"
        provider.write_text(
            "#!/usr/bin/env bash\n# kind: local\n# probe: true\n"
            "printf ran > \"$LIMIT_MARKER\"\ncat >/dev/null\n"
        )
        provider.chmod(0o755)
        self.env["LIMIT_MARKER"] = str(marker)
        result = self.run_speak("--raw", "--provider", "limitcheck",
                                input_text="x" * 1_048_577, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 MiB", result.stderr)
        self.assertFalse(marker.exists())
        self.assertNotEqual(
            self.run_speak("--max-chars", "1048577", "hello", check=False).returncode,
            0,
        )

    def test_sanitizer_failure_is_not_misreported_as_empty_input(self):
        tools = Path(self.temp.name, "broken-sanitizer-tools")
        tools.mkdir()
        python = tools / "python3"
        python.write_text("#!/usr/bin/env bash\nexit 70\n")
        python.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}"}
        result = subprocess.run([SPEAK, "hello"], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("text preparation failed", result.stderr)

    def test_persisted_rate_is_clamped_but_explicit_unsupported_rate_fails(self):
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True)
        marker = Path(self.temp.name, "effective-rate")
        provider = providers / "narrowrate"
        provider.write_text(
            "#!/usr/bin/env bash\n# kind: local\n# probe: true\n"
            "# ratemin: 0.7\n# ratemax: 1.2\n"
            "cat >/dev/null\nprintf '%s' \"$TTS_RATE\" > \"$RATE_MARKER\"\n"
        )
        provider.chmod(0o755)
        self.env["RATE_MARKER"] = str(marker)
        self.run_speak("--set", ".rate", "4")
        self.run_speak("--raw", "--provider", "narrowrate", "hello")
        self.assertEqual(marker.read_text(), "1.2")
        marker.unlink()
        result = self.run_speak("--raw", "--provider", "narrowrate",
                                "--rate", "4", "hello", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0.7 to 1.2", result.stderr)
        self.assertFalse(marker.exists())

    def test_command_line_overrides_are_validated(self):
        for args in (("--rate", "fast", "hello"),
                     ("--rate", "3", "hello"),
                     ("--max-chars", "-1", "hello"),
                     ("--provider", "../bad", "hello")):
            self.assertNotEqual(self.run_speak(*args, check=False).returncode, 0)

    def test_byte_limit_is_measured_in_utf8_bytes(self):
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True)
        marker = Path(self.temp.name, "provider-ran")
        provider = providers / "bytetest"
        provider.write_text(
            "#!/usr/bin/env bash\n# desc: byte limit test\n# kind: local\n"
            "# probe: true\n# maxbytes: 5\ncat >/dev/null\nprintf ran > \"$BYTE_MARKER\"\n"
        )
        provider.chmod(0o755)
        self.env["BYTE_MARKER"] = str(marker)
        result = self.run_speak("--raw", "--provider", "bytetest", "你好", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("5 UTF-8 bytes", result.stderr)
        self.assertFalse(marker.exists())

    def test_provider_limits_are_compared_as_decimal_metadata(self):
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True)
        marker = Path(self.temp.name, "provider-ran")
        provider = providers / "decimaltest"
        provider.write_text(
            "#!/usr/bin/env bash\n# desc: decimal limit test\n# kind: local\n"
            "# probe: true\n# maxchars: 08\ncat >/dev/null\n"
            "printf ran > \"$DECIMAL_MARKER\"\n"
        )
        provider.chmod(0o755)
        self.env["DECIMAL_MARKER"] = str(marker)
        result = self.run_speak("--raw", "--provider", "decimaltest",
                                "123456789", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at most 08 characters", result.stderr)
        self.assertFalse(marker.exists())

    def test_removed_system_providers_migrate_to_piper(self):
        """espeak-ng and Speech Dispatcher were dropped in 1.3.0. A config that
        still names one lands on the default instead of an absent provider."""
        for old in ("espeak-ng", "spd", "openai", "elevenlabs", "gemini", "google"):
            config = Path(self.temp.name, "omarchy-tts-local", "config.json")
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text(json.dumps({"schemaVersion": 2, "provider": old}))
            info = json.loads(self.run_speak("--info").stdout)
            self.assertEqual(info["provider"], "piper", old)
            self.assertNotIn(old, {item["name"] for item in info["providers"]})

    def test_invalid_optional_provider_metadata_cannot_break_info(self):
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True)
        provider = providers / "custommeta"
        provider.write_text(
            "#!/usr/bin/env bash\n# maxchars: many\n# maxbytes: lots\n"
            "# ratemin: slow\ncat >/dev/null\n"
        )
        provider.chmod(0o755)
        info = json.loads(self.run_speak("--info").stdout)
        custom = next(item for item in info["providers"]
                      if item["name"] == "custommeta")
        self.assertIsNone(custom["rateMin"])
        self.assertIsNone(custom["maxChars"])
        self.assertIsNone(custom["maxBytes"])

    def test_state_watch_reports_the_provider_actually_speaking(self):
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True)
        provider = providers / "override"
        provider.write_text("#!/usr/bin/env bash\n# kind: local\n# probe: true\ncat >/dev/null\nsleep 30\n")
        provider.chmod(0o755)
        watcher = subprocess.Popen(
            [SPEAK, "--watch-state"], env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        speaking = None
        speech = None
        try:
            self.assertTrue(select.select([watcher.stdout], [], [], 3)[0])
            watcher.stdout.readline()
            speech = subprocess.Popen(
                [SPEAK, "--provider", "override", "hello"], env=self.env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                if select.select([watcher.stdout], [], [], 0.25)[0]:
                    candidate = json.loads(watcher.stdout.readline())
                    if candidate["status"] == "speaking":
                        speaking = candidate
                        break
            self.assertEqual(speaking, {"status": "speaking", "provider": "override"})
            self.run_speak("--stop")
            speech.wait(timeout=3)
        finally:
            if speech is not None and speech.poll() is None:
                self.run_speak("--stop", check=False)
                speech.wait(timeout=3)
            watcher.terminate()
            watcher.wait(timeout=3)
            watcher.stdout.close()
            watcher.stderr.close()

    def test_stop_cancels_selection_preparation_before_provider_start(self):
        tools = Path(self.temp.name, "preparation-tools")
        tools.mkdir()
        started = Path(self.temp.name, "selection-started")
        provider_marker = Path(self.temp.name, "provider-started")
        wl_paste = tools / "wl-paste"
        wl_paste.write_text(
            "#!/usr/bin/env bash\n"
            "printf started > \"$SELECTION_MARKER\"\n"
            "sleep 30\nprintf 'too late'\n"
        )
        wl_paste.chmod(0o755)
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True)
        provider = providers / "neverstart"
        provider.write_text(
            "#!/usr/bin/env bash\n# kind: local\n# probe: true\n"
            "printf started > \"$PROVIDER_MARKER\"\ncat >/dev/null\n"
        )
        provider.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "SELECTION_MARKER": str(started),
               "PROVIDER_MARKER": str(provider_marker)}
        speech = subprocess.Popen(
            [SPEAK, "--selection", "--provider", "neverstart"], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not started.exists():
                time.sleep(0.01)
            self.assertTrue(started.exists(), "selection capture never entered preparation")
            stopped = subprocess.run([SPEAK, "--stop"], env=env,
                                     capture_output=True, text=True, timeout=3)
            self.assertEqual(stopped.returncode, 0, stopped.stderr)
            speech.wait(timeout=3)
            self.assertFalse(provider_marker.exists())
            status = subprocess.run([SPEAK, "--status"], env=env,
                                    capture_output=True, text=True, timeout=3)
            self.assertEqual(status.stdout.strip(), "idle")
        finally:
            if speech.poll() is None:
                subprocess.run([SPEAK, "--stop"], env=env, capture_output=True)
                speech.wait(timeout=3)

    def test_concurrent_config_updates_do_not_overwrite_each_other(self):
        self.run_speak("--info")
        for _ in range(5):
            first = subprocess.Popen([SPEAK, "--set", ".rate", "1.25"],
                                     env=self.env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
            second = subprocess.Popen([SPEAK, "--set", ".maxChars", "321"],
                                      env=self.env, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
            self.assertEqual(first.wait(timeout=3), 0)
            self.assertEqual(second.wait(timeout=3), 0)
            info = json.loads(self.run_speak("--info").stdout)
            self.assertEqual((info["rate"], info["maxChars"]), (1.25, 321))

    def test_set_accepts_known_path_and_rejects_unknown_path(self):
        self.run_speak("--set", ".rate", "1.25")
        self.assertEqual(json.loads(self.run_speak("--info").stdout)["rate"], 1.25)
        result = self.run_speak("--set", ".apiKeys.openai", "secret", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_preview_uses_persisted_sanitizer_options(self):
        self.run_speak("--set", ".sanitizer.urls", "link")
        result = self.run_speak("--preview-text", "See https://example.com in 2s")
        self.assertEqual(result.stdout, "See link in 2 seconds")

    def test_binding_manager_owns_only_its_marked_block(self):
        hypr = Path(self.temp.name, "hypr")
        hypr.mkdir()
        target = hypr / "bindings.lua"
        target.write_text('o.bind("SUPER + B", "Browser", "browser")\n')
        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        installed = target.read_text()
        self.assertIn("-- >>> omarchy-tts-local bindings", installed)
        self.assertIn('"Browser"', installed)
        subprocess.run([BINDINGS, "remove"], env=self.env, check=True,
                       capture_output=True, text=True)
        self.assertEqual(target.read_text().strip(),
                         'o.bind("SUPER + B", "Browser", "browser")')

    def test_managed_bindings_follow_the_stable_plugin_symlink(self):
        plugin = Path(self.temp.name, "omarchy", "plugins",
                      "io.github.jagrat7.omarchy-tts-local")
        first = Path(self.temp.name, "checkout-a")
        second = Path(self.temp.name, "checkout-b")
        for checkout in (first, second):
            (checkout / "bin").mkdir(parents=True)
            (checkout / "bin" / "speak").write_text("#!/bin/sh\n")
        plugin.parent.mkdir(parents=True)
        plugin.symlink_to(first, target_is_directory=True)

        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        target = Path(self.temp.name, "hypr", "bindings.lua")
        rendered = target.read_text()
        self.assertIn(str(plugin / "bin" / "speak"), rendered)
        self.assertNotIn(str(first / "bin" / "speak"), rendered)

        plugin.unlink()
        plugin.symlink_to(second, target_is_directory=True)
        self.assertEqual((plugin / "bin" / "speak").resolve(),
                         (second / "bin" / "speak").resolve())
        self.assertIn(str(plugin / "bin" / "speak"), target.read_text())

    def test_binding_backups_are_bounded(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        target.parent.mkdir()
        target.write_text("-- Personal keybindings\n")
        for _ in range(6):
            subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                           capture_output=True, text=True)
        self.assertEqual(len(list(target.parent.glob("bindings.lua.tts.bak.*"))), 3)

    def test_binding_remove_is_idempotent_and_does_not_create_a_file(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        subprocess.run([BINDINGS, "remove"], env=self.env, check=True,
                       capture_output=True, text=True)
        self.assertFalse(target.exists())

    def test_binding_manager_adopts_legacy_documented_bindings(self):
        hypr = Path(self.temp.name, "hypr")
        hypr.mkdir()
        target = hypr / "bindings.lua"
        target.write_text('o.bind("SUPER + ALT + E", "Speak selection", "speak --toggle")\n')
        status = subprocess.run([BINDINGS, "status"], env=self.env, check=True,
                                capture_output=True, text=True)
        self.assertTrue(json.loads(status.stdout)["canInstall"])
        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        installed = target.read_text()
        self.assertEqual(installed.count("Speak selection"), 1)
        self.assertIn("-- >>> omarchy-tts-local bindings", installed)

    def test_binding_manager_rejects_non_chord_input(self):
        for chord in ('SUPER + E\n")\nos.execute("bad")',
                      "SUPER + A + B", "SUPER + SUPER + E", "SUPER"):
            result = subprocess.run(
                [BINDINGS, "set", "selection", chord],
                env=self.env, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_binding_config_persists_choices_not_derived_commands(self):
        config = Path(self.temp.name, "omarchy-tts-local", "bindings.json")
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({
            "selection": {"chord": "SUPER + ALT + Q",
                          "label": "stale", "command": "/old/plugin/speak --toggle"}
        }))
        status = subprocess.run([BINDINGS, "status"], env=self.env, check=True,
                                capture_output=True, text=True)
        binding = json.loads(status.stdout)["bindings"]["selection"]
        self.assertEqual(binding["chord"], "SUPER + ALT + Q")
        self.assertNotEqual(binding["command"], "/old/plugin/speak --toggle")
        subprocess.run([BINDINGS, "set", "selection", "SUPER + ALT + Z"],
                       env=self.env, check=True, capture_output=True, text=True)
        stored = json.loads(config.read_text())
        self.assertEqual(stored["selection"], {"chord": "SUPER + ALT + Z"})

    def test_concurrent_binding_edits_preserve_both_choices(self):
        first = subprocess.Popen(
            [BINDINGS, "set", "selection", "SUPER + ALT + Z"],
            env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            text=True,
        )
        second = subprocess.Popen(
            [BINDINGS, "set", "clipboard", "SUPER + ALT + V"],
            env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            text=True,
        )
        first_rc = first.wait(timeout=3)
        second_rc = second.wait(timeout=3)
        first_error = first.stderr.read()
        second_error = second.stderr.read()
        first.stderr.close()
        second.stderr.close()
        self.assertEqual(first_rc, 0, first_error)
        self.assertEqual(second_rc, 0, second_error)
        config = Path(self.temp.name, "omarchy-tts-local", "bindings.json")
        stored = json.loads(config.read_text())
        self.assertEqual(stored["selection"]["chord"], "SUPER + ALT + Z")
        self.assertEqual(stored["clipboard"]["chord"], "SUPER + ALT + V")

    def test_binding_manager_detects_active_default_conflicts(self):
        tools = Path(self.temp.name, "tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == binds ]]; then\n"
            "  printf '%s\\n' '[{\"modmask\":72,\"key\":\"E\",\"dispatcher\":\"exec\",\"arg\":\"editor\"}]'\n"
            "else exit 0; fi\n"
        )
        hyprctl.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"
        self.env["HYPRLAND_INSTANCE_SIGNATURE"] = "test"
        status = subprocess.run([BINDINGS, "status"], env=self.env,
                                capture_output=True, text=True, check=True)
        self.assertIn("SUPER + ALT + E", json.loads(status.stdout)["conflicts"])

    def test_lua_reported_managed_bindings_are_not_conflicts(self):
        # Lua-configured Hyprland reports o.bind() shortcuts as dispatcher
        # "__lua" with an opaque id, so only the label identifies our block.
        tools = Path(self.temp.name, "lua-tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == binds ]]; then\n"
            "  printf '%s\\n' '[{\"modmask\":72,\"key\":\"E\",\"dispatcher\":\"__lua\",\"arg\":\"192\",\"description\":\"Speak selection\"},"
            "{\"modmask\":72,\"key\":\"A\",\"dispatcher\":\"__lua\",\"arg\":\"193\",\"description\":\"ChatGPT\"}]'\n"
            "else exit 0; fi\n"
        )
        hyprctl.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "HYPRLAND_INSTANCE_SIGNATURE": "test"}
        status = subprocess.run([BINDINGS, "status"], env=env,
                                capture_output=True, text=True, check=True)
        conflicts = json.loads(status.stdout)["conflicts"]
        self.assertNotIn("SUPER + ALT + E", conflicts)
        self.assertIn("SUPER + ALT + A", conflicts)

    def test_binding_manager_fails_closed_when_active_bindings_are_unreadable(self):
        tools = Path(self.temp.name, "broken-hypr-tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text("#!/usr/bin/env bash\nexit 1\n")
        hyprctl.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "HYPRLAND_INSTANCE_SIGNATURE": "test"}
        result = subprocess.run([BINDINGS, "install"], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inspect active Hyprland shortcuts", result.stderr)
        self.assertFalse(Path(self.temp.name, "hypr", "bindings.lua").exists())

    def test_binding_manager_never_reads_non_regular_configuration_nodes(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        choices = Path(self.temp.name, "omarchy-tts-local", "bindings.json")
        for path in (target, choices):
            with self.subTest(path=path):
                path.parent.mkdir(parents=True, exist_ok=True)
                os.mkfifo(path)
                result = subprocess.run(
                    [BINDINGS, "status"], env=self.env,
                    capture_output=True, text=True, timeout=2,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("non-regular", result.stderr)
                self.assertTrue(path.is_fifo())
                path.unlink()

    def test_binding_lock_never_follows_a_symlink(self):
        directory = Path(self.temp.name, "omarchy-tts-local")
        directory.mkdir(parents=True)
        victim = Path(self.temp.name, "binding-lock-victim")
        victim.write_text("keep me")
        (directory / "bindings.lock").symlink_to(victim)
        result = subprocess.run(
            [BINDINGS, "status"], env=self.env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private lock", result.stderr)
        self.assertEqual(victim.read_text(), "keep me")

    def test_binding_conflicts_ignore_spacing_and_modifier_order(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        target.parent.mkdir()
        target.write_text('o.bind("ALT+SUPER+E", "Editor", "code")\n')
        status = subprocess.run([BINDINGS, "status"], env=self.env,
                                capture_output=True, text=True, check=True)
        payload = json.loads(status.stdout)
        self.assertEqual(payload["conflicts"], ["SUPER + ALT + E"])
        self.assertFalse(payload["canInstall"])

    def test_commented_bindings_do_not_create_false_conflicts(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        target.parent.mkdir()
        target.write_text('-- o.bind("SUPER + ALT + E", "Old", "editor")\n')
        result = subprocess.run([BINDINGS, "install"], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-- o.bind", target.read_text())
        self.assertIn("omarchy-tts-local bindings", target.read_text())

    def test_active_documented_bindings_are_adoptable(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        target.parent.mkdir()
        target.write_text(
            'o.bind("SUPER + ALT + E", "Speak selection", "speak --toggle")\n'
        )
        tools = Path(self.temp.name, "legacy-binding-tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == binds ]]; then\n"
            "  printf '%s\\n' '[{\"modmask\":72,\"key\":\"E\","
            "\"dispatcher\":\"exec\",\"arg\":\"speak --toggle\"}]'\n"
            "else exit 0; fi\n"
        )
        hyprctl.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "HYPRLAND_INSTANCE_SIGNATURE": "test"}
        result = subprocess.run([BINDINGS, "install"], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_text().count("SUPER + ALT + E"), 1)

    def test_unrelated_exact_speak_command_is_never_adopted(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        target.parent.mkdir()
        original = 'o.bind("SUPER + ALT + E", "Other", "/usr/bin/speak --toggle")\n'
        target.write_text(original)
        result = subprocess.run([BINDINGS, "install"], env=self.env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), original)

    def test_binding_manager_rejects_duplicate_managed_shortcuts(self):
        result = subprocess.run(
            [BINDINGS, "set", "selection", "SUPER + ALT + A"], env=self.env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("shortcut already used", result.stderr)
        self.assertFalse(Path(self.temp.name, "omarchy-tts-local", "bindings.json").exists())

    def test_custom_program_named_speak_is_preserved_as_a_conflict(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        target.parent.mkdir()
        line = 'o.bind("SUPER + ALT + E", "Custom", "/usr/bin/speak --toggle --custom")\n'
        target.write_text(line)
        result = subprocess.run([BINDINGS, "install"], env=self.env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), line)

    def test_binding_writes_preserve_dotfile_symlinks(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        actual = Path(self.temp.name, "dotfiles", "bindings.lua")
        target.parent.mkdir()
        actual.parent.mkdir()
        actual.write_text("-- dotfile\n")
        target.symlink_to(actual)
        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        self.assertTrue(target.is_symlink())
        self.assertIn("omarchy-tts-local bindings", actual.read_text())

    def test_hyprland_rejection_removes_a_new_bindings_file(self):
        tools = Path(self.temp.name, "reject-tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == binds ]]; then printf '[]\\n'; exit 0; fi\n"
            "if [[ $1 == configerrors ]]; then printf 'invalid generated binding\\n'; exit 0; fi\n"
            "exit 0\n"
        )
        hyprctl.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "HYPRLAND_INSTANCE_SIGNATURE": "test"}
        target = Path(self.temp.name, "hypr", "bindings.lua")
        result = subprocess.run([BINDINGS, "install"], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid generated binding", result.stderr)
        self.assertFalse(target.exists())

    def test_hyprland_rejection_rolls_back_binding_and_choice_together(self):
        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        target = Path(self.temp.name, "hypr", "bindings.lua")
        choices = Path(self.temp.name, "omarchy-tts-local", "bindings.json")
        before_target = target.read_text()
        before_choices = choices.read_text() if choices.exists() else None

        tools = Path(self.temp.name, "rollback-tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == binds ]]; then printf '[]\\n'; exit 0; fi\n"
            "if [[ $1 == configerrors ]]; then printf 'rejected\\n'; exit 0; fi\n"
            "exit 0\n"
        )
        hyprctl.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "HYPRLAND_INSTANCE_SIGNATURE": "test"}
        result = subprocess.run(
            [BINDINGS, "set", "selection", "SUPER + ALT + Z"], env=env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), before_target)
        if before_choices is None:
            self.assertFalse(choices.exists())
        else:
            self.assertEqual(choices.read_text(), before_choices)

    def test_hyprland_launch_failure_rolls_back_both_files(self):
        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        target = Path(self.temp.name, "hypr", "bindings.lua")
        choices = Path(self.temp.name, "omarchy-tts-local", "bindings.json")
        before_target = target.read_text()

        tools = Path(self.temp.name, "missing-hypr-tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text("#!/definitely/missing/interpreter\n")
        hyprctl.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "HYPRLAND_INSTANCE_SIGNATURE": "test"}
        result = subprocess.run(
            [BINDINGS, "set", "selection", "SUPER + ALT + Z"], env=env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), before_target)
        self.assertFalse(choices.exists())

    def piper_plugin(self, catalogue, files=None):
        """A plugin tree whose shipped catalogue and digest manifest are the
        test's own. The trust root is repository-owned, so a test cannot inject
        it through the cache; it ships it the way a release does."""
        plugin = Path(self.temp.name, "plugin-" + uuid.uuid4().hex[:8])
        (plugin / "bin").mkdir(parents=True)
        (plugin / "lib").mkdir()
        shutil.copy(ROOT / "bin" / "speak-voice", plugin / "bin" / "speak-voice")
        for item in (ROOT / "lib").iterdir():
            if item.name not in ("piper-voices.json", "piper-voices.sha256"):
                (plugin / "lib" / item.name).symlink_to(item)
        (plugin / "lib" / "piper-voices.json").write_text(json.dumps(catalogue))
        lines = ["# test manifest", "0" * 64 + "  placeholder/none.onnx"]
        for path, content in (files or {}).items():
            lines.append(f"{hashlib.sha256(content).hexdigest()}  {path}")
        (plugin / "lib" / "piper-voices.sha256").write_text("\n".join(lines) + "\n")
        return plugin / "bin" / "speak-voice"

    def test_voice_catalogue_is_shipped_pinned_and_refresh_is_offline(self):
        """Every model and sidecar the plugin can install has a SHA-256 in the
        reviewed tree, the catalogue ships alongside, and refresh never
        contacts the network. A mutable upstream branch cannot change what
        is downloaded or what it must hash to."""
        catalogue = json.loads((ROOT / "lib" / "piper-voices.json").read_text())
        manifest = {}
        header = None
        for line in (ROOT / "lib" / "piper-voices.sha256").read_text().splitlines():
            if line.startswith("#"):
                header = header or line
                continue
            digest, path = line.split("  ", 1)
            self.assertRegex(digest, r"^[0-9a-f]{64}$", path)
            manifest[path] = digest
        revision = re.search(r"@([0-9a-f]{40})$", header).group(1)
        self.assertIn(f"PIPER_VOICES_REV={revision}",
                      (ROOT / "bin" / "speak-voice").read_text(),
                      "the download revision and the digest manifest must move together")
        for voice, entry in catalogue.items():
            for path in entry["files"]:
                if path.endswith(".onnx") or path.endswith(".onnx.json"):
                    self.assertIn(path, manifest, f"{voice}: {path} has no shipped digest")
        tools = Path(self.temp.name, "catalogue-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "refresh-curl-ran")
        curl = tools / "curl"
        curl.write_text("#!/usr/bin/env bash\nprintf ran > \"$REFRESH_MARKER\"\nexit 22\n")
        curl.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}", "REFRESH_MARKER": str(marker)}
        result = subprocess.run([ROOT / "bin" / "speak-voice", "refresh"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pinned", result.stdout)
        self.assertFalse(marker.exists(), "refresh must not touch the network")

    def test_download_is_refused_when_the_shipped_digest_does_not_match(self):
        voice = "en_US-tampered-medium"
        model_path = "en/en_US/tampered/medium/en_US-tampered-medium.onnx"
        catalogue = {voice: {"files": {
            model_path: {"size_bytes": 4},
            model_path + ".json": {"size_bytes": 2}}}}
        speak_voice = self.piper_plugin(catalogue, files={
            model_path: b"good", model_path + ".json": b"{}"})
        tools = Path(self.temp.name, "tamper-voice-tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(
            "#!/usr/bin/env bash\n"
            "out=\nurl=\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == -o ]]; then out=$2; shift; elif [[ $1 == https:* ]]; then url=$1; fi\n"
            "  shift\n"
            "done\n"
            "if [[ $url == *.onnx.json* ]]; then printf '{}' > \"$out\"; else printf evil > \"$out\"; fi\n"
        )
        curl.chmod(0o755)
        env = {**self.env, "HOME": self.temp.name, "PATH": f"{tools}:{self.env['PATH']}"}
        result = subprocess.run([speak_voice, "add", voice], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verification failed", result.stderr)
        voices = Path(self.temp.name, "omarchy-tts-local", "voices", "piper")
        self.assertFalse((voices / f"{voice}.onnx").exists())
        self.assertEqual(list(voices.glob("*.part")) if voices.exists() else [], [])

    def test_download_is_refused_for_a_file_without_a_shipped_digest(self):
        voice = "en_US-unlisted-medium"
        model_path = "en/en_US/unlisted/medium/en_US-unlisted-medium.onnx"
        speak_voice = self.piper_plugin({voice: {"files": {
            model_path: {"size_bytes": 4}, model_path + ".json": {"size_bytes": 2}}}})
        tools = Path(self.temp.name, "unlisted-voice-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "unlisted-curl-ran")
        curl = tools / "curl"
        curl.write_text("#!/usr/bin/env bash\nprintf ran > \"$VOICE_CURL_MARKER\"\nexit 1\n")
        curl.chmod(0o755)
        env = {**self.env, "HOME": self.temp.name, "PATH": f"{tools}:{self.env['PATH']}",
               "VOICE_CURL_MARKER": str(marker)}
        result = subprocess.run([speak_voice, "add", voice], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verified manifest", result.stderr)
        self.assertFalse(marker.exists(), "an unlisted file must never be requested")

    def test_voice_metadata_limits_are_rejected_before_download(self):
        base = Path(self.temp.name, "omarchy-tts-local")
        base.mkdir(parents=True, exist_ok=True)
        voice = "en_US-too-large-medium"
        speak_voice = self.piper_plugin({voice: {"files": {
            "voices/large.onnx": {"size_bytes": 1_073_741_825},
            "voices/large.onnx.json": {"size_bytes": 2},
        }}}, files={})
        tools = Path(self.temp.name, "limit-voice-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "voice-curl-ran")
        curl = tools / "curl"
        curl.write_text("#!/usr/bin/env bash\nprintf ran > \"$VOICE_CURL_MARKER\"\nexit 1\n")
        curl.chmod(0o755)
        env = {**self.env, "HOME": self.temp.name,
               "PATH": f"{tools}:{self.env['PATH']}",
               "VOICE_CURL_MARKER": str(marker)}
        available = subprocess.run(
            [speak_voice, "available", "--json"], env=env,
            capture_output=True, text=True, check=True,
        )
        self.assertNotIn(voice, {item["key"] for item in json.loads(available.stdout)})
        result = subprocess.run(
            [speak_voice, "add", voice], env=env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_real_piper_catalogue_paths_download_without_a_fake_prefix(self):
        base = Path(self.temp.name, "omarchy-tts-local")
        base.mkdir(parents=True, exist_ok=True)
        voice = "en_US-layout-medium"
        model_path = "en/en_US/layout/medium/en_US-layout-medium.onnx"
        sidecar_path = model_path + ".json"
        speak_voice = self.piper_plugin({voice: {"files": {
            model_path: {"size_bytes": 4},
            sidecar_path: {"size_bytes": 2},
        }}}, files={model_path: b"data", sidecar_path: b"{}"})
        tools = Path(self.temp.name, "layout-voice-tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(
            "#!/usr/bin/env bash\n"
            "out=\nurl=\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == -o ]]; then out=$2; shift; elif [[ $1 == https:* ]]; then url=$1; fi\n"
            "  shift\n"
            "done\n"
            "printf '%s\\n' \"$url\" >> \"$VOICE_URLS\"\n"
            "if [[ $url == *.onnx.json* ]]; then printf '{}' > \"$out\"; else printf data > \"$out\"; fi\n"
        )
        curl.chmod(0o755)
        urls = Path(self.temp.name, "voice-urls")
        env = {**self.env, "HOME": self.temp.name,
               "PATH": f"{tools}:{self.env['PATH']}", "VOICE_URLS": str(urls)}
        result = subprocess.run(
            [speak_voice, "add", voice], env=env,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(model_path, urls.read_text())
        self.assertIn("/resolve/1162a9173d0ce503555aed757976b7a9912eae4c/", urls.read_text())
        self.assertNotIn("/resolve/main/", urls.read_text())
        voices = base / "voices" / "piper"
        self.assertEqual((voices / f"{voice}.onnx").read_bytes(), b"data")
        self.assertEqual((voices / f"{voice}.onnx.json").read_text(), "{}")

    def test_ambiguous_voice_metadata_is_rejected_before_download(self):
        base = Path(self.temp.name, "omarchy-tts-local")
        base.mkdir(parents=True, exist_ok=True)
        voice = "en_US-ambiguous-medium"
        speak_voice = self.piper_plugin({voice: {"files": {
            "voices/first.onnx": {"size_bytes": 2},
            "voices/second.onnx": {"size_bytes": 2},
            "voices/first.onnx.json": {"size_bytes": 2},
        }}}, files={})
        tools = Path(self.temp.name, "ambiguous-voice-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "voice-curl-ran")
        curl = tools / "curl"
        curl.write_text("#!/usr/bin/env bash\nprintf ran > \"$VOICE_CURL_MARKER\"\nexit 1\n")
        curl.chmod(0o755)
        env = {**self.env, "HOME": self.temp.name,
               "PATH": f"{tools}:{self.env['PATH']}",
               "VOICE_CURL_MARKER": str(marker)}
        result = subprocess.run(
            [speak_voice, "add", voice], env=env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid model metadata", result.stderr)
        self.assertFalse(marker.exists())

    def test_interrupted_voice_publication_is_recovered_before_reuse(self):
        base = Path(self.temp.name, "omarchy-tts-local")
        voices = base / "voices" / "piper"
        voices.mkdir(parents=True)
        voice = "en_US-recover-medium"
        speak_voice = self.piper_plugin({voice: {"files": {
            "voices/recover.onnx": {"size_bytes": 3},
            "voices/recover.onnx.json": {"size_bytes": 2},
        }}}, files={"voices/recover.onnx": b"old", "voices/recover.onnx.json": b"{}"})
        (voices / f"{voice}.onnx").write_bytes(b"x")
        (voices / f"{voice}.onnx.json").write_text("partial")
        (voices / f".{voice}.onnx.previous.4242").write_bytes(b"old")
        (voices / f".{voice}.onnx.json.previous.4242").write_text("{}")
        (voices / f".{voice}.onnx.stage.4242").write_bytes(b"new")

        result = subprocess.run(
            [speak_voice, "add", voice],
            env={**self.env, "HOME": self.temp.name},
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((voices / f"{voice}.onnx").read_bytes(), b"old")
        self.assertEqual((voices / f"{voice}.onnx.json").read_text(), "{}")
        self.assertEqual(list(voices.glob(f".{voice}.*")), [])

    def test_active_voice_cannot_be_removed(self):
        base = Path(self.temp.name, "omarchy-tts-local")
        voices = base / "voices" / "piper"
        voices.mkdir(parents=True)
        voice = "en_US-active-medium"
        model = voices / f"{voice}.onnx"
        sidecar = voices / f"{voice}.onnx.json"
        model.write_bytes(b"model")
        sidecar.write_text("{}")
        (base / "config.json").write_text(json.dumps({"piper": {"voice": voice}}))
        result = subprocess.run(
            [ROOT / "bin" / "speak-voice", "remove", voice],
            env={**self.env, "HOME": self.temp.name},
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("choose another active voice", result.stderr)
        self.assertTrue(model.exists())
        self.assertTrue(sidecar.exists())

    def test_installed_voice_can_be_selected_offline_without_a_catalogue(self):
        base = Path(self.temp.name, "omarchy-tts-local")
        voices = base / "voices" / "piper"
        voices.mkdir(parents=True)
        voice = "en_US-offline-medium"
        (voices / f"{voice}.onnx").write_bytes(b"model")
        (voices / f"{voice}.onnx.json").write_text("{}")

        tools = Path(self.temp.name, "offline-voice-tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text("#!/usr/bin/env bash\nexit 99\n")
        curl.chmod(0o755)
        env = {**self.env, "HOME": self.temp.name,
               "PATH": f"{tools}:{self.env['PATH']}"}
        result = subprocess.run(
            [ROOT / "bin" / "speak-voice", "use", voice], env=env,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads((base / "config.json").read_text())
        self.assertEqual(config["piper"]["voice"], voice)

    def test_voice_status_does_not_initialize_config_or_data(self):
        root = Path(self.temp.name, "isolated-voice-status")
        env = {**self.env,
               "XDG_CONFIG_HOME": str(root / "config"),
               "XDG_CACHE_HOME": str(root / "cache"),
               "XDG_DATA_HOME": str(root / "data"),
               "XDG_RUNTIME_DIR": str(root / "runtime"),
               "HOME": str(root / "home")}
        result = subprocess.run([ROOT / "bin" / "speak-voice", "status"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "idle")
        self.assertFalse((root / "config" / "omarchy-tts-local").exists())
        self.assertFalse((root / "data" / "omarchy-tts-local").exists())
        self.assertFalse((root / "cache" / "omarchy-tts-local").exists())

    def test_async_voice_download_registers_identity_before_acknowledging_start(self):
        env = {**self.env, "HOME": self.temp.name}
        base = Path(self.temp.name, "omarchy-tts-local")
        voices = base / "voices" / "piper"
        voices.mkdir(parents=True)
        voice = "en_US-test-medium"
        (voices / f"{voice}.onnx").write_bytes(b"model")
        (voices / f"{voice}.onnx.json").write_text("{}")
        speak_voice = self.piper_plugin({voice: {"files": {
            "voices/test.onnx": {"size_bytes": 5},
            "voices/test.onnx.json": {"size_bytes": 2},
        }}}, files={"voices/test.onnx": b"model", "voices/test.onnx.json": b"{}"})

        result = subprocess.run(
            [speak_voice, "add", voice, "--async"],
            env=env, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "started")
        state_path = base / "download.json"
        for _ in range(100):
            state = json.loads(state_path.read_text())
            if state["status"] == "done":
                break
            time.sleep(0.01)
        self.assertEqual(state["status"], "done", state)
        self.assertGreater(state["pid"], 1)
        self.assertTrue(state["processIdentity"])

    def test_async_voice_worker_holds_the_download_lock(self):
        env = {**self.env, "HOME": self.temp.name}
        base = Path(self.temp.name, "omarchy-tts-local")
        base.mkdir(parents=True, exist_ok=True)
        voice = "en_US-lock-medium"
        speak_voice = self.piper_plugin({
            voice: {
                "name": "lock", "quality": "medium",
                "language": {"name_english": "English",
                             "country_english": "United States", "code": "en_US"},
                "files": {
                    "voices/test.onnx": {"size_bytes": 4},
                    "voices/test.onnx.json": {"size_bytes": 2},
                },
            }
        }, files={"voices/test.onnx": b"data", "voices/test.onnx.json": b"{}"})
        tools = Path(self.temp.name, "voice-tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(
            "#!/usr/bin/env bash\n"
            "out=\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == -o || $1 == --output ]]; then out=$2; shift; fi\n"
            "  shift\n"
            "done\n"
            "sleep 10\n"
            "printf data > \"$out\"\n"
        )
        curl.chmod(0o755)
        env["PATH"] = f"{tools}:{env['PATH']}"

        first = subprocess.run(
            [speak_voice, "add", voice, "--async"],
            env=env, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        state = json.loads((base / "download.json").read_text())
        self.assertIn(state["status"], ("starting", "downloading"))
        self.assertGreater(state["pid"], 1)
        self.assertTrue(state["processIdentity"])
        self.assertEqual(os.getpgid(state["pid"]), state["pid"], state)
        second = subprocess.run(
            [speak_voice, "add", voice, "--async"],
            env=env, capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("already running", second.stderr)
        cancelled = subprocess.run(
            [speak_voice, "cancel"], env=env,
            capture_output=True, text=True,
        )
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)

    def test_cancelling_new_voice_rolls_back_model_and_sidecar_together(self):
        env = {**self.env, "HOME": self.temp.name}
        base = Path(self.temp.name, "omarchy-tts-local")
        base.mkdir(parents=True, exist_ok=True)
        voice = "en_US-atomic-medium"
        speak_voice = self.piper_plugin({
            voice: {
                "files": {
                    "voices/test.onnx": {"size_bytes": 4},
                    "voices/test.onnx.json": {"size_bytes": 2},
                },
            },
        }, files={"voices/test.onnx": b"data", "voices/test.onnx.json": b"{}"})
        marker = Path(self.temp.name, "metadata-started")
        tools = Path(self.temp.name, "atomic-voice-tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(
            "#!/usr/bin/env bash\n"
            "out=\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == -o || $1 == --output ]]; then out=$2; shift; fi\n"
            "  shift\n"
            "done\n"
            "if [[ $out == *.onnx.part ]]; then printf data > \"$out\"; exit 0; fi\n"
            "printf started > \"$VOICE_METADATA_MARKER\"\n"
            "sleep 30\n"
            "printf '{}' > \"$out\"\n"
        )
        curl.chmod(0o755)
        env["PATH"] = f"{tools}:{env['PATH']}"
        env["VOICE_METADATA_MARKER"] = str(marker)

        started = subprocess.run(
            [speak_voice, "add", voice, "--async"],
            env=env, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(started.returncode, 0, started.stderr)
        for _ in range(300):
            if marker.exists():
                break
            time.sleep(0.01)
        self.assertTrue(marker.exists(), "metadata download never started")
        cancelled = subprocess.run(
            [speak_voice, "cancel"], env=env,
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        voices = base / "voices" / "piper"
        self.assertFalse((voices / f"{voice}.onnx").exists())
        self.assertFalse((voices / f"{voice}.onnx.json").exists())

    def test_voice_cancel_refuses_when_no_registered_job_exists(self):
        env = {**self.env, "HOME": self.temp.name}
        result = subprocess.run(
            [ROOT / "bin" / "speak-voice", "cancel"],
            env=env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no active voice download", result.stderr)

    def test_voice_cancel_never_signals_a_completed_job_identity(self):
        env = {**self.env, "HOME": self.temp.name}
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            stat = Path(f"/proc/{sleeper.pid}/stat").read_text()
            identity = stat.rsplit(")", 1)[1].split()[19]
            state = Path(self.temp.name, "omarchy-tts-local", "download.json")
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text(json.dumps({
                "status": "done", "voice": "test", "pid": sleeper.pid,
                "processIdentity": identity,
            }))
            result = subprocess.run(
                [ROOT / "bin" / "speak-voice", "cancel"], env=env,
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=3)

    def test_voice_status_repairs_corrupt_or_unowned_active_state(self):
        state = Path(self.temp.name, "omarchy-tts-local", "download.json")
        state.parent.mkdir(parents=True, exist_ok=True)
        for value, message in (
                ('{"status":', "unreadable"),
                (json.dumps({"status": "downloading", "voice": "test",
                             "pid": 0, "processIdentity": ""}),
                 "stopped unexpectedly")):
            state.write_text(value)
            result = subprocess.run(
                [ROOT / "bin" / "speak-voice", "status"],
                env={**self.env, "HOME": self.temp.name},
                check=True, capture_output=True, text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["status"], "error")
            self.assertIn(message, payload["message"])
            self.assertEqual(json.loads(state.read_text()), payload)

    def test_voice_status_replaces_oversized_state_without_parsing_it(self):
        state = Path(self.temp.name, "omarchy-tts-local", "download.json")
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_bytes(b" " * 65537)
        result = subprocess.run(
            [ROOT / "bin" / "speak-voice", "status"],
            env={**self.env, "HOME": self.temp.name}, check=True,
            capture_output=True, text=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "error")
        self.assertLess(state.stat().st_size, 65537)

    def test_voice_status_never_enters_or_reads_non_regular_state_nodes(self):
        state = Path(self.temp.name, "omarchy-tts-local", "download.json")
        state.mkdir(parents=True)
        result = subprocess.run(
            [ROOT / "bin" / "speak-voice", "status"],
            env={**self.env, "HOME": self.temp.name}, check=True,
            capture_output=True, text=True, timeout=2,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "error")
        self.assertIn("unsafe", payload["message"])
        self.assertTrue(state.is_dir())
        self.assertEqual(list(state.iterdir()), [])

        state.rmdir()
        os.mkfifo(state)
        result = subprocess.run(
            [ROOT / "bin" / "speak-voice", "status"],
            env={**self.env, "HOME": self.temp.name}, check=True,
            capture_output=True, text=True, timeout=2,
        )
        self.assertEqual(json.loads(result.stdout)["status"], "error")
        self.assertTrue(state.is_fifo())

    def test_setup_backend_status_and_allowlist(self):
        self.env["XDG_DATA_HOME"] = str(Path(self.temp.name, "data"))
        status = subprocess.run([SETUP, "status"], env=self.env, check=True,
                                capture_output=True, text=True)
        payload = json.loads(status.stdout)
        self.assertFalse(payload["ready"])
        self.assertEqual(payload["defaultVoice"], "en_US-amy-medium")
        rejected = subprocess.run([SETUP, "start", "anything-else"], env=self.env,
                                  check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(rejected.stdout)["code"], "unknown_target")

    def test_setup_job_tolerates_corrupt_json_shapes(self):
        state = Path(self.temp.name, "omarchy-tts-local", "setup.json")
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text("[]")
        result = subprocess.run([SETUP, "job"], env=self.env, check=True,
                                capture_output=True, text=True)
        self.assertEqual(json.loads(result.stdout)["status"], "idle")

    def test_setup_job_rejects_oversized_control_state(self):
        state = Path(self.temp.name, "omarchy-tts-local", "setup.json")
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_bytes(b" " * 65537)
        result = subprocess.run([SETUP, "job"], env=self.env, check=True,
                                capture_output=True, text=True)
        self.assertEqual(json.loads(result.stdout)["status"], "idle")

    def test_setup_job_never_reads_a_non_regular_control_node(self):
        state = Path(self.temp.name, "omarchy-tts-local", "setup.json")
        state.parent.mkdir(parents=True, exist_ok=True)
        os.mkfifo(state)
        result = subprocess.run([SETUP, "job"], env=self.env, check=True,
                                capture_output=True, text=True, timeout=2)
        self.assertEqual(json.loads(result.stdout)["status"], "idle")

    def test_setup_cancel_refuses_a_completed_or_unowned_job(self):
        state = Path(self.temp.name, "omarchy-tts-local", "setup.json")
        state.parent.mkdir(parents=True, exist_ok=True)
        original = {"status": "done", "pid": os.getpid(),
                    "processIdentity": "not-the-owner"}
        state.write_text(json.dumps(original))
        result = subprocess.run([SETUP, "cancel"], env=self.env, check=True,
                                capture_output=True, text=True)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertEqual(json.loads(state.read_text()), original)

    def test_setup_cleanup_requires_explicit_confirmation(self):
        result = subprocess.run([SETUP, "cleanup"], env=self.env, text=True,
                                capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["code"],
                         "confirmation_required")

    def test_engine_setup_installs_only_hash_locked_closures(self):
        """Every managed engine installs from a complete lock shipped in the
        plugin, hash-enforced and wheel-only, and the installer never lets a
        library fetch code or models on its own."""
        source = SETUP.read_text()
        self.assertIn('"--require-hashes",', source)
        self.assertIn('"--only-binary", ":all:"', source)
        self.assertIn('"--find-links", str(ENGINE_SPECS / "wheels")', source)
        self.assertIn('"pip", "sync"', source)
        self.assertNotIn('"pip", "install"', source)
        self.assertNotIn("download_enabled=True", source)
        self.assertIn('"venv", "--relocatable"', source)
        for engine, top in (("piper", "piper-tts==1.7.0"), ("kokoro", "kokoro==0.9.4"),
                            ("easyocr", "easyocr==1.7.2")):
            spec = (ROOT / "lib" / "engines" / f"{engine}.in").read_text()
            self.assertIn(top, spec, engine)
            blocks = self.lock_blocks((ROOT / "lib" / "engines" / f"{engine}.lock").read_text())
            self.assertTrue(blocks, engine)
            for requirement, hashes in blocks:
                self.assertRegex(requirement, r"(==|@ https://)", f"{engine}: {requirement} is not pinned")
                self.assertTrue(hashes, f"{engine}: {requirement} has no hash")
                for digest in hashes:
                    self.assertRegex(digest, r"^[0-9a-f]{64}$")
            self.assertNotIn("./", "".join(r for r, _ in blocks), f"{engine}: path requirements are not allowed in a lock")
        kokoro = dict(self.lock_blocks((ROOT / "lib" / "engines" / "kokoro.lock").read_text()))
        spacy = next(r for r in kokoro if r.startswith("en-core-web-sm @"))
        self.assertIn("1932429db727d4bff3deed6b34cfc05df17794f4a52eeb26cf8928f7c1a0fb85", kokoro[spacy])
        # The one dependency without a published wheel is served from the
        # reviewed flat index, and the lock admits exactly that wheel.
        wheels = ROOT / "lib" / "engines" / "wheels"
        sums = dict(line.split("  ", 1)[::-1] for line in (wheels / "SHA256SUMS").read_text().splitlines())
        self.assertEqual(set(sums), {p.name for p in wheels.iterdir() if p.name != "SHA256SUMS"})
        for name, digest in sums.items():
            self.assertEqual(hashlib.sha256((wheels / name).read_bytes()).hexdigest(), digest, name)
        self.assertEqual(kokoro["docopt==0.6.2"], [sums["docopt-0.6.2-py2.py3-none-any.whl"]])
        self.assertRegex((ROOT / "lib" / "engines" / "EXCLUDE_NEWER").read_text().strip(),
                         r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    @staticmethod
    def lock_blocks(lock):
        """[(requirement, [hashes])] from a uv requirements lock."""
        blocks, current = [], None
        for line in lock.splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith(" "):
                for digest in re.findall(r"--hash=sha256:([0-9a-f]+)", line):
                    current[1].append(digest)
            else:
                current = [line.rstrip(" \\").strip(), []]
                blocks.append(current)
        return [(r, h) for r, h in blocks]

    def test_engine_builders_run_exactly_the_locked_wheel_only_install(self):
        setup = load_setup_module()
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            if argv[2] == "venv":
                Path(argv[-1], "bin").mkdir(parents=True)
        setup.run_checked = run
        setup.ensure_uv = lambda: "/usr/bin/uv"
        setup.install_kokoro_models = lambda models: calls.append(["models", str(models)])
        setup.install_easyocr_models = lambda models: calls.append(["models", str(models)])
        setup.write_state = lambda *a, **k: None
        for engine, build in (("piper", setup.build_piper), ("kokoro", setup.build_kokoro), ("easyocr", setup.build_easyocr)):
            calls.clear()
            target = Path(self.temp.name, f"stage-{engine}")
            build(target)
            self.assertEqual(calls[0], ["/usr/bin/uv", "--no-config", "venv", "--relocatable", "--python", "3.12", str(target)], engine)
            self.assertEqual(calls[1], ["/usr/bin/uv", "--no-config", "pip", "sync", "--python", str(target / "bin/python"),
                                        "--require-hashes", "--only-binary", ":all:",
                                        "--find-links", str(setup.ENGINE_SPECS / "wheels"),
                                        str(setup.ENGINE_LOCKS[engine])], engine)
            self.assertEqual((target / ".lock-sha256").read_text().strip(),
                             hashlib.sha256(setup.ENGINE_LOCKS[engine].read_bytes()).hexdigest(), engine)
            if engine != "piper":
                self.assertEqual(calls[2], ["models", str(target / "models")], engine)

    def test_uv_is_only_the_distribution_binary_and_runs_without_overrides(self):
        source = SETUP.read_text()
        self.assertNotIn('which("uv")', source)
        setup = load_setup_module()
        setup.SYSTEM_UV = Path(self.temp.name, "not-there")
        installed = []
        setup.privileged_pacman = lambda *pkgs: installed.append(pkgs)
        setup.write_state = lambda *a, **k: None
        setup.PKEXEC = Path("/usr/bin/env")
        setup.PACMAN = Path("/usr/bin/env")
        with self.assertRaisesRegex(RuntimeError, "could not be found"):
            setup.ensure_uv()
        self.assertEqual(installed, [("uv",)], "a missing uv is installed through the privileged path, never taken from PATH")
        with unittest.mock.patch.dict(os.environ, {"UV_INDEX_URL": "https://evil.invalid/simple",
                                                   "UV_FIND_LINKS": "/tmp/evil", "PIP_INDEX_URL": "x",
                                                   "UV_CACHE_DIR": "/tmp/cache", "HOME": self.temp.name}):
            env = setup.uv_environment()
        self.assertNotIn("UV_INDEX_URL", env)
        self.assertNotIn("UV_FIND_LINKS", env)
        self.assertNotIn("PIP_INDEX_URL", env)
        self.assertEqual(env["UV_CACHE_DIR"], "/tmp/cache")
        self.assertEqual(env["HOME"], self.temp.name)

    def test_engines_from_other_releases_are_not_installed(self):
        setup = load_setup_module()
        setup.ENGINE = Path(self.temp.name, "engines")
        (setup.ENGINE / "piper" / "bin").mkdir(parents=True)
        self.assertFalse(setup.engine_built_from_lock("piper"), "no stamp: built by something else")
        (setup.ENGINE / "piper" / ".lock-sha256").write_text("0" * 64 + "\n")
        self.assertFalse(setup.engine_built_from_lock("piper"), "another lock's digest")
        (setup.ENGINE / "piper" / ".lock-sha256").write_text(
            hashlib.sha256(setup.ENGINE_LOCKS["piper"].read_bytes()).hexdigest() + "\n")
        self.assertTrue(setup.engine_built_from_lock("piper"))
        # and the engines themselves refuse such an environment before running anything
        tools = Path(self.temp.name, "stale-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "stale-ran")
        (tools / "python").write_text("#!/usr/bin/env bash\nprintf ran > \"$ENGINE_MARKER\"\nexit 0\n")
        (tools / "python").chmod(0o755)
        data = Path(self.temp.name, "stale-data")
        for engine in ("kokoro", "easyocr"):
            (data / "engines" / engine / "bin").mkdir(parents=True)
            shutil.copy(tools / "python", data / "engines" / engine / "bin" / "python")
            (data / "engines" / engine / "models").mkdir()
        (data / "engines" / "kokoro" / "models" / "kokoro-v1_0.pth").write_bytes(b"x")
        (data / "engines" / "easyocr" / "models" / "craft_mlt_25k.pth").write_bytes(b"x")
        env = {**os.environ, "TTS_PLUGIN_DIR": str(ROOT), "TTS_DATA_DIR": str(data),
               "TTS_CONFIG": str(Path(self.temp.name, "c.json")), "TTS_SILENT": "1", "ENGINE_MARKER": str(marker)}
        Path(self.temp.name, "c.json").write_text("{}")
        for script in (ROOT / "providers" / "kokoro", ROOT / "ocr" / "easyocr"):
            result = subprocess.run([script], input=b"Probe.", capture_output=True, env=env)
            self.assertEqual(result.returncode, 127, (script.name, result.stderr))
            self.assertIn(b"installed by an earlier release", result.stderr, script.name)
            self.assertFalse(marker.exists(), script.name)

    def test_language_install_goes_through_the_privileged_path_only(self):
        setup = load_setup_module()
        calls = []
        setup.PKEXEC = Path("/usr/bin/env")
        setup.language_package = lambda code: f"tesseract-data-{code}"
        setup.privileged_pacman = lambda *pkgs: calls.append(pkgs)
        setup.write_state = lambda *a, **k: None
        setup.subprocess = unittest.mock.MagicMock()
        setup.subprocess.run.return_value = unittest.mock.Mock(returncode=0, stdout="", stderr="")
        setup.install_language("deu")
        self.assertEqual(calls, [("tesseract-data-deu",)])
        setup.PKEXEC = Path(self.temp.name, "pkexec")
        with self.assertRaisesRegex(RuntimeError, "unavailable"):
            setup.install_language("deu")
        self.assertEqual(len(calls), 1)

    def test_reviewed_wheel_index_is_verified_before_uv_runs(self):
        setup = load_setup_module()
        specs = Path(self.temp.name, "engines")
        shutil.copytree(ROOT / "lib" / "engines", specs)
        setup.ENGINE_SPECS = specs
        setup.ENGINE_LOCKS = {name: specs / f"{name}.lock" for name in ("piper", "kokoro", "easyocr")}
        setup.verify_reviewed_wheels()
        stray = specs / "wheels" / "extra-1.0-py3-none-any.whl"
        stray.write_bytes(b"not reviewed")
        with self.assertRaisesRegex(RuntimeError, "does not match its digest list"):
            setup.verify_reviewed_wheels()
        stray.unlink()
        wheel = next(specs.glob("wheels/*.whl"))
        wheel.write_bytes(wheel.read_bytes() + b"x")
        with self.assertRaisesRegex(RuntimeError, "failed verification"):
            setup.verify_reviewed_wheels()

    def test_easyocr_model_extraction_takes_only_the_named_verified_member(self):
        setup = load_setup_module()
        model = b"model-bytes"
        entry = {"url": "https://example.invalid/m.zip", "archive_sha256": "", "archive_size": 0,
                 "sha256": hashlib.sha256(model).hexdigest(), "size": len(model)}
        def archive_with(members):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as bundle:
                for name, data in members.items():
                    bundle.writestr(name, data)
            return buffer.getvalue()
        def install(members):
            data = archive_with(members)
            entry["archive_sha256"] = hashlib.sha256(data).hexdigest()
            entry["archive_size"] = len(data)
            setup.model_manifest = lambda: {"easyocr": {"models": {"english_g2.pth": entry}}}
            setup.fetch_verified = lambda url, dest, sha, size: dest.write_bytes(data)
            target = Path(self.temp.name, "models-" + uuid.uuid4().hex[:6])
            setup.install_easyocr_models(target)
            return target
        # the named member is extracted, a sibling with a traversal name is ignored
        target = install({"english_g2.pth": model, "../evil.pth": b"x", "other.pth": b"y"})
        self.assertEqual((target / "english_g2.pth").read_bytes(), model)
        self.assertEqual(sorted(p.name for p in target.iterdir()), ["english_g2.pth"])
        # a member whose bytes differ from the shipped digest is refused (same
        # length, so it is the digest and not the size check that catches it)
        with self.assertRaisesRegex(RuntimeError, "does not match its shipped digest"):
            install({"english_g2.pth": b"model-BYTES"})
        # and a member of the wrong length never even reaches the digest
        with self.assertRaisesRegex(RuntimeError, "size does not match"):
            install({"english_g2.pth": b"tampered-bytes"})
        # an archive without the member is refused
        with self.assertRaisesRegex(RuntimeError, "does not contain the expected model"):
            install({"something-else.pth": model})

    def test_piper_verifies_catalogue_voices_before_loading(self):
        tools = Path(self.temp.name, "piper-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "piper-ran")
        fake_piper = tools / "piper"
        fake_piper.write_text("#!/usr/bin/env bash\nprintf ran > \"$PIPER_MARKER\"\ncat >/dev/null\n")
        fake_piper.chmod(0o755)
        voices = Path(self.temp.name, "voices")
        voices.mkdir()
        (voices / "en_US-amy-medium.onnx").write_bytes(b"not the real model")
        (voices / "en_US-amy-medium.onnx.json").write_text('{"audio": {"sample_rate": 22050}}')
        (voices / "custom-voice.onnx").write_bytes(b"my own model")
        (voices / "custom-voice.onnx.json").write_text('{"audio": {"sample_rate": 22050}}')
        data = Path(self.temp.name, "piper-data")
        (data / "engines" / "piper" / "bin").mkdir(parents=True)
        shutil.copy(fake_piper, data / "engines" / "piper" / "bin" / "piper")
        (data / "engines" / "piper" / ".lock-sha256").write_text(
            hashlib.sha256((ROOT / "lib" / "engines" / "piper.lock").read_bytes()).hexdigest() + "\n")
        env = {**os.environ, "TTS_PLUGIN_DIR": str(ROOT), "TTS_CONFIG": str(Path(self.temp.name, "c.json")),
               "TTS_DATA_DIR": str(data), "PIPER_VOICES_DIR": str(voices), "TTS_SILENT": "1",
               "PIPER_MARKER": str(marker), "XDG_RUNTIME_DIR": str(Path(self.temp.name, "run"))}
        Path(self.temp.name, "run").mkdir(exist_ok=True)
        Path(self.temp.name, "c.json").write_text("{}")
        result = subprocess.run([ROOT / "providers" / "piper"], input=b"Probe.", capture_output=True,
                                env={**env, "TTS_VOICE": "en_US-amy-medium"})
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn(b"failed verification", result.stderr)
        self.assertFalse(marker.exists(), "a catalogue voice with the wrong bytes must never reach Piper")
        result = subprocess.run([ROOT / "providers" / "piper"], input=b"Probe.", capture_output=True,
                                env={**env, "TTS_VOICE": "custom-voice"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists(), "a voice outside the catalogue is the user's own")

    def test_device_settings_accept_only_cpu_or_gpu_for_device_providers(self):
        self.run_speak("--set", ".kokoro_onnx.device", "gpu")
        self.run_speak("--set", ".kokoro.device", "gpu")
        config = json.loads(Path(self.temp.name, "omarchy-tts-local", "config.json").read_text())
        self.assertEqual(config["kokoro_onnx"]["device"], "gpu")
        self.assertEqual(config["kokoro"]["device"], "gpu")
        for path, value in ((".kokoro_onnx.device", "tpu"), (".piper.device", "gpu"),
                            (".kokoro_onnx.voice", "../af_heart")):
            with self.subTest(path=path, value=value):
                result = subprocess.run([SPEAK, "--set", path, value], env=self.env,
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
        info = json.loads(self.run_speak("--info").stdout)
        onnx = next(p for p in info["providers"] if p["name"] == "kokoro_onnx")
        self.assertEqual(onnx["devices"], ["cpu", "gpu"])
        self.assertEqual(onnx["device"], "gpu")
        piper = next(p for p in info["providers"] if p["name"] == "piper")
        self.assertEqual(piper["devices"], [])
        self.assertIsNone(piper["device"])

    def test_uninstall_removes_one_device_engine_and_keeps_shared_models(self):
        engines = Path(self.temp.name, "omarchy-tts-local", "engines")
        cpu_models = engines / "kokoro_onnx" / "models"
        gpu_models = engines / "kokoro_onnx_gpu" / "models"
        cpu_models.mkdir(parents=True)
        gpu_models.mkdir(parents=True)
        (cpu_models / "kokoro-v1.0.onnx").write_bytes(b"model")
        os.link(cpu_models / "kokoro-v1.0.onnx", gpu_models / "kokoro-v1.0.onnx")
        (engines / "kokoro_onnx_gpu.previous.1").mkdir()
        result = subprocess.run([SETUP, "uninstall", "kokoro_onnx_gpu"], env=self.env,
                                capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(result.stdout)["ok"])
        self.assertFalse((engines / "kokoro_onnx_gpu").exists())
        self.assertFalse((engines / "kokoro_onnx_gpu.previous.1").exists())
        self.assertEqual((cpu_models / "kokoro-v1.0.onnx").read_bytes(), b"model")
        refused = subprocess.run([SETUP, "uninstall", "../kokoro_onnx"], env=self.env,
                                 capture_output=True, text=True)
        self.assertFalse(json.loads(refused.stdout)["ok"])
        self.assertTrue((engines / "kokoro_onnx").exists())

    def test_uninstalling_piper_removes_its_voices(self):
        data = Path(self.temp.name, "omarchy-tts-local")
        (data / "engines" / "piper" / "bin").mkdir(parents=True)
        (data / "voices" / "piper").mkdir(parents=True)
        (data / "voices" / "piper" / "en_US-amy-medium.onnx").write_bytes(b"voice")
        subprocess.run([SETUP, "uninstall", "piper"], env=self.env,
                       capture_output=True, text=True, check=True)
        self.assertFalse((data / "engines" / "piper").exists())
        self.assertFalse((data / "voices" / "piper").exists())

    def test_family_variants_are_reported_for_one_shared_row(self):
        providers = Path(self.temp.name, "omarchy-tts-local", "providers")
        providers.mkdir(parents=True, exist_ok=True)
        custom = providers / "kokoro_custom"
        custom.write_text("#!/usr/bin/env bash\n# family: Kokoro\n# variant: Custom\n"
                          "# variantnote: my build\ncat >/dev/null\n")
        custom.chmod(0o755)
        info = json.loads(self.run_speak("--info").stdout)
        providers = {p["name"]: p for p in info["providers"]}
        self.assertEqual((providers["kokoro_onnx"]["family"], providers["kokoro_onnx"]["variant"]),
                         ("Kokoro", "ONNX"))
        self.assertEqual((providers["kokoro"]["family"], providers["kokoro"]["variant"]),
                         ("Kokoro", "PyTorch"))
        self.assertEqual(providers["kokoro_custom"]["variantNote"], "my build")
        self.assertIsNone(providers["piper"]["family"])

    def test_install_info_comes_from_engine_headers_per_device(self):
        info = json.loads(self.run_speak("--info").stdout)
        providers = {p["name"]: p for p in info["providers"]}
        self.assertEqual(set(providers["kokoro_onnx"]["installInfo"]), {"cpu", "gpu"})
        self.assertIn("GB", providers["kokoro_onnx"]["installInfo"]["gpu"]["size"])
        self.assertIn("default", providers["kokoro"]["installInfo"])
        self.assertIn("default", providers["piper"]["installInfo"])
        engines = {e["name"]: e for e in info["ocr"]["engines"]}
        self.assertIn("default", engines["easyocr"]["installInfo"])

    def test_model_artefacts_are_pinned_to_immutable_sources_with_digests(self):
        manifest = json.loads((ROOT / "lib" / "engines" / "models.json").read_text())
        for name, entry in manifest["easyocr"]["models"].items():
            self.assertRegex(entry["url"], r"^https://github\.com/JaidedAI/EasyOCR/releases/download/[^/]+/[^/]+\.zip$", name)
            self.assertRegex(entry["archive_sha256"], r"^[0-9a-f]{64}$", name)
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$", name)
            self.assertGreater(entry["size"], 0)
        kokoro = manifest["kokoro"]
        self.assertRegex(kokoro["revision"], r"^[0-9a-f]{40}$")
        for path in ("config.json", "kokoro-v1_0.pth", "voices/af_heart.pt"):
            self.assertRegex(kokoro["files"][path]["sha256"], r"^[0-9a-f]{64}$", path)
        provider = (ROOT / "providers" / "kokoro").read_text()
        speak = (ROOT / "bin" / "speak").read_text()
        torch_voices = re.search(r"voice_path=\.kokoro\.voice\n\s*vs='([^']*)'", speak).group(1)
        for voice in re.findall(r'"(a[fm]_[a-z]+|b[fm]_[a-z]+)"', torch_voices):
            self.assertIn(f"voices/{voice}.pt", kokoro["files"], f"bundled voice {voice} has no digest")
        # The ONNX engine's voices all live in one pinned voice pack.
        onnx = manifest["kokoro_onnx"]["files"]
        self.assertEqual(set(onnx), {"kokoro-v1.0.onnx", "voices-v1.0.bin"})
        for name, entry in onnx.items():
            self.assertRegex(entry["url"], r"^https://github\.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1\.0/", name)
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$", name)
            self.assertGreater(entry["size"], 0)
        self.assertIn("HF_HUB_OFFLINE=1", provider)
        self.assertIn("weights_only=True", provider)
        self.assertNotIn("download_enabled=True", (ROOT / "ocr" / "easyocr").read_text())

    def test_privileged_helpers_are_fixed_paths_verified_at_use(self):
        source = SETUP.read_text()
        self.assertNotIn('which("pkexec")', source)
        self.assertNotIn('which("pacman")', source)
        self.assertIn('PKEXEC = Path("/usr/bin/pkexec")', source)
        self.assertIn('PACMAN = Path("/usr/bin/pacman")', source)
        setup = load_setup_module()
        # A distribution-installed executable passes.
        self.assertEqual(setup.trusted_system_executable(Path("/usr/bin/env")), "/usr/bin/env")
        # Anything under a user-writable tree is refused, however it is named.
        mine = Path(self.temp.name, "pacman")
        mine.write_text("#!/usr/bin/env bash\nexit 0\n")
        mine.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "not owned by root|writable by other users"):
            setup.trusted_system_executable(mine)
        # Symlink components are refused before ownership is even considered.
        link = Path(self.temp.name, "usr-bin-link")
        link.symlink_to("/usr/bin")
        with self.assertRaisesRegex(RuntimeError, "symbolic link"):
            setup.trusted_system_executable(link / "env")
        # Relative and non-canonical spellings never reach the privilege helper.
        for bad in (Path("usr/bin/env"), Path("/usr/bin/../bin/env")):
            with self.assertRaisesRegex(RuntimeError, "non-canonical"):
                setup.trusted_system_executable(bad)
        # And the privileged call composes only from those checks.
        calls = []
        setup.run_checked = lambda argv, **kw: calls.append(argv)
        setup.PKEXEC = Path("/usr/bin/env")
        setup.PACMAN = Path("/usr/bin/env")
        setup.privileged_pacman("uv")
        self.assertEqual(calls, [["/usr/bin/env", "/usr/bin/env", "-S", "--noconfirm", "--needed", "uv"]])
        setup.PACMAN = mine
        with self.assertRaises(RuntimeError):
            setup.privileged_pacman("uv")
        self.assertEqual(len(calls), 1, "a refused package manager must never be executed")

    def test_fetch_verified_rejects_a_digest_mismatch_and_keeps_nothing(self):
        setup = load_setup_module()
        served = Path(self.temp.name, "served.bin")
        served.write_bytes(b"evil")
        setup.run_checked = lambda argv, **kw: shutil.copy(served, argv[-1])
        dest = Path(self.temp.name, "model.pth")
        good = hashlib.sha256(b"good").hexdigest()
        with self.assertRaisesRegex(RuntimeError, "does not match its shipped digest"):
            setup.fetch_verified("https://example.invalid/model", dest, good, 4)
        self.assertFalse(dest.exists())
        self.assertEqual(list(Path(self.temp.name).glob("model.pth*")), [])
        with self.assertRaisesRegex(RuntimeError, "unpinned source"):
            setup.fetch_verified("http://example.invalid/model", dest, good, 4)
        served.write_bytes(b"good")
        setup.fetch_verified("https://example.invalid/model", dest, good, 4)
        self.assertEqual(dest.read_bytes(), b"good")

    def test_engine_transaction_rolls_back_when_proof_fails(self):
        setup = load_setup_module()
        setup.ENGINE = Path(self.temp.name, "transaction-engines")
        target = setup.ENGINE / "piper"
        target.mkdir(parents=True)
        (target / "generation").write_text("old")

        def build(staging):
            staging.mkdir()
            (staging / "generation").write_text("new")

        def fail_proof(_name):
            raise RuntimeError("proof failed")

        setup.prove = fail_proof
        with self.assertRaisesRegex(RuntimeError, "proof failed"):
            setup.install_engine_transaction("piper", build)
        self.assertEqual((target / "generation").read_text(), "old")
        self.assertEqual(list(setup.ENGINE.glob(".piper.staging.*")), [])
        self.assertEqual(list(setup.ENGINE.glob("piper.previous.*")), [])
        self.assertFalse((setup.ENGINE / ".piper.transaction.json").exists())

    def test_engine_transaction_commits_and_prunes_old_generations(self):
        setup = load_setup_module()
        setup.ENGINE = Path(self.temp.name, "commit-engines")
        target = setup.ENGINE / "kokoro"
        target.mkdir(parents=True)
        (target / "generation").write_text("old")
        stale = setup.ENGINE / "kokoro.previous.1"
        stale.mkdir()
        (stale / "generation").write_text("older")

        def build(staging):
            staging.mkdir()
            (staging / "generation").write_text("new")

        setup.prove = lambda _name: None
        setup.install_engine_transaction("kokoro", build)
        self.assertEqual((target / "generation").read_text(), "new")
        self.assertEqual(list(setup.ENGINE.glob("kokoro.previous.*")), [])
        self.assertFalse((setup.ENGINE / ".kokoro.transaction.json").exists())

    def test_engine_transaction_journal_recovers_a_hard_interruption(self):
        setup = load_setup_module()
        setup.ENGINE = Path(self.temp.name, "recovery-engines")
        setup.ENGINE.mkdir()
        target = setup.ENGINE / "easyocr"
        backup = setup.ENGINE / "easyocr.previous.42"
        staging = setup.ENGINE / ".easyocr.staging.42"
        target.mkdir()
        backup.mkdir()
        staging.mkdir()
        (target / "generation").write_text("unproved")
        (backup / "generation").write_text("known-good")
        setup.replace_json(setup.ENGINE / ".easyocr.transaction.json", {
            "name": "easyocr", "staging": str(staging),
            "backup": str(backup), "hadPrevious": True,
        })

        setup.recover_engine_transaction("easyocr")
        self.assertEqual((target / "generation").read_text(), "known-good")
        self.assertFalse(staging.exists())
        self.assertFalse((setup.ENGINE / ".easyocr.transaction.json").exists())

    def test_engine_transaction_finishes_a_durably_proved_commit(self):
        setup = load_setup_module()
        setup.ENGINE = Path(self.temp.name, "proved-recovery-engines")
        setup.ENGINE.mkdir()
        target = setup.ENGINE / "kokoro"
        backup = setup.ENGINE / "kokoro.previous.42"
        staging = setup.ENGINE / ".kokoro.staging.42"
        target.mkdir()
        backup.mkdir()
        (target / "generation").write_text("proved")
        (backup / "generation").write_text("old")
        setup.replace_json(setup.ENGINE / ".kokoro.transaction.json", {
            "name": "kokoro", "staging": str(staging),
            "backup": str(backup), "hadPrevious": True, "phase": "proved",
        })

        setup.recover_engine_transaction("kokoro")
        self.assertEqual((target / "generation").read_text(), "proved")
        self.assertFalse(backup.exists())
        self.assertFalse((setup.ENGINE / ".kokoro.transaction.json").exists())

    def test_runtime_directory_symlinks_are_rejected(self):
        runtime = Path(self.temp.name, "omarchy-tts-local")
        destination = Path(self.temp.name, "runtime-destination")
        destination.mkdir()
        runtime.symlink_to(destination, target_is_directory=True)
        commands = ([SPEAK, "--status"], [ROOT / "bin" / "speak-voice", "list"],
                    [SETUP, "status"])
        for command in commands:
            result = subprocess.run(command, env=self.env, text=True,
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0, command)
            self.assertIn("symlink", result.stderr.lower(), command)

    def test_speech_state_publication_refuses_non_regular_destination(self):
        status = Path(self.temp.name, "omarchy-tts-local", "status")
        status.mkdir(parents=True)
        result = self.run_speak("hello", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("register speech preparation", result.stderr)
        self.assertTrue(status.is_dir())
        self.assertEqual(list(status.iterdir()), [])

    def test_every_bundled_provider_has_a_silent_verification_path(self):
        for provider in (ROOT / "providers").iterdir():
            if not provider.is_file():
                continue
            source = provider.read_text()
            self.assertTrue(
                "TTS_SILENT" in source or "play_raw" in source or "play_file" in source,
                f"{provider.name} bypasses the non-audible verification contract",
            )

    def test_test_dock_uses_the_same_sanitizer_as_normal_speech(self):
        controller = (ROOT / "components" / "TtsController.qml").read_text()
        speak_line = next(line for line in controller.splitlines()
                          if "function speak(text)" in line)
        self.assertNotIn("--raw", speak_line)

    def test_setup_registers_worker_identity_before_reporting_started(self):
        """start() must not acknowledge until the worker has published its
        PID and start-time identity. The launcher seam stands in for the real
        worker so no install target - and no privilege prompt - is needed."""
        fake_worker = Path(self.temp.name, "fake-worker.py")
        fake_worker.write_text(
            "import json, os, sys, time\n"
            "from pathlib import Path\n"
            "state = Path(os.environ['FAKE_WORKER_STATE'])\n"
            "identity = Path(f'/proc/{os.getpid()}/stat').read_text().rsplit(')', 1)[1].split()[19]\n"
            "base = {'pid': os.getpid(), 'processIdentity': identity, 'target': sys.argv[1], 'cancellable': True}\n"
            "state.write_text(json.dumps({'status': 'running', 'step': 'prepare', 'progress': 2, 'message': 'Preparing', **base}))\n"
            "time.sleep(0.2)\n"
            "state.write_text(json.dumps({'status': 'done', 'step': 'complete', 'progress': 100, 'message': 'Ready', **base}))\n")
        with unittest.mock.patch.dict(os.environ, self.env):
            setup = load_setup_module()
            setup.ensure_private_runtime()
            os.environ["FAKE_WORKER_STATE"] = str(setup.STATE)
            setup.worker_command = lambda target: [sys.executable, str(fake_worker), target]
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                setup.start("piper")
        payload = json.loads(output.getvalue())
        self.assertTrue(payload["ok"], payload)
        registered = json.loads(setup.STATE.read_text())
        self.assertEqual(registered["pid"], payload["pid"])
        self.assertTrue(registered["processIdentity"])
        for _ in range(100):
            current = json.loads(setup.STATE.read_text())
            if current["status"] in {"done", "error"}:
                break
            time.sleep(0.02)
        self.assertEqual(current["status"], "done", current)

    def test_engines_refuse_unverified_model_files_before_loading(self):
        """A model file the manifest does not vouch for, or one that no longer
        matches its digest, stops the engine before any Python starts."""
        tools = Path(self.temp.name, "engine-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "python-ran")
        fake_python = tools / "python"
        fake_python.write_text("#!/usr/bin/env bash\nprintf ran > \"$ENGINE_MARKER\"\nexit 0\n")
        fake_python.chmod(0o755)
        env = {**os.environ, "TTS_PLUGIN_DIR": str(ROOT), "TTS_CONFIG": str(Path(self.temp.name, "c.json")),
               "TTS_SILENT": "1", "ENGINE_MARKER": str(marker)}
        Path(self.temp.name, "c.json").write_text("{}")
        # EasyOCR: an unknown .pth in the model directory.
        models = Path(self.temp.name, "easyocr-models")
        models.mkdir()
        (models / "surprise.pth").write_bytes(b"x")
        result = subprocess.run([ROOT / "ocr" / "easyocr"], input=(ROOT / "lib" / "ocr-probe.png").read_bytes(),
                                capture_output=True, env={**env, "EASYOCR_PYTHON": str(fake_python),
                                                          "EASYOCR_MODELS": str(models), "TTS_OCR_LANGS": "eng"})
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn(b"not a verified model file", result.stderr)
        self.assertFalse(marker.exists())
        # EasyOCR: a known name whose bytes changed.
        (models / "surprise.pth").unlink()
        (models / "english_g2.pth").write_bytes(b"tampered")
        result = subprocess.run([ROOT / "ocr" / "easyocr"], input=(ROOT / "lib" / "ocr-probe.png").read_bytes(),
                                capture_output=True, env={**env, "EASYOCR_PYTHON": str(fake_python),
                                                          "EASYOCR_MODELS": str(models), "TTS_OCR_LANGS": "eng"})
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn(b"failed verification", result.stderr)
        self.assertFalse(marker.exists())
        # Kokoro: the model directory has the right names with the wrong bytes.
        kmodels = Path(self.temp.name, "kokoro-models")
        (kmodels / "voices").mkdir(parents=True)
        for name in ("config.json", "kokoro-v1_0.pth", "voices/af_heart.pt"):
            (kmodels / name).write_bytes(b"tampered")
        result = subprocess.run([ROOT / "providers" / "kokoro"], input=b"Probe.",
                                capture_output=True, env={**env, "KOKORO_PYTHON": str(fake_python),
                                                          "KOKORO_MODELS": str(kmodels), "TTS_VOICE": "af_heart"})
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn(b"failed verification", result.stderr)
        self.assertFalse(marker.exists())

    def test_internal_background_workers_require_a_supervised_lock(self):
        setup = subprocess.run(
            [SETUP, "_worker", "piper"], env=self.env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(setup.returncode, 0)
        self.assertIn("inherited lock", setup.stderr)

        voice = subprocess.run(
            [ROOT / "bin" / "speak-voice", "_download",
             "en_US-test-medium", "no"],
            env={**self.env, "HOME": self.temp.name},
            capture_output=True, text=True,
        )
        self.assertNotEqual(voice.returncode, 0)
        self.assertIn("inherited lock", voice.stderr)

    def test_setup_and_download_locks_never_follow_symlinks(self):
        runtime = Path(self.temp.name, "omarchy-tts-local")
        runtime.mkdir(parents=True, exist_ok=True)
        victim = Path(self.temp.name, "lock-victim")
        victim.write_text("keep me")

        setup_lock = runtime / "setup.lock"
        setup_lock.symlink_to(victim)
        result = subprocess.run(
            [SETUP, "start", "piper"], env=self.env,
            capture_output=True, text=True,
        )
        self.assertEqual(json.loads(result.stdout)["code"], "lock_error")
        self.assertEqual(victim.read_text(), "keep me")

        setup_lock.unlink()
        download_lock = runtime / "download.lock"
        download_lock.symlink_to(victim)
        result = subprocess.run(
            [ROOT / "bin" / "speak-voice", "add",
             "en_US-test-medium", "--async"],
            env={**self.env, "HOME": self.temp.name},
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lock symlink", result.stderr)
        self.assertEqual(victim.read_text(), "keep me")


class LegacyKeyCleanupTests(unittest.TestCase):
    """Cleanup still clears API keys that versions with cloud providers kept
    in the keyring under the old service name."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.tools = self.home / "tools"
        self.tools.mkdir()
        self.env = {**os.environ,
                    "PATH": f"{self.tools}:{os.environ['PATH']}",
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "XDG_CACHE_HOME": str(self.home / "cache"),
                    "XDG_DATA_HOME": str(self.home / "data"),
                    "XDG_RUNTIME_DIR": str(self.home / "run"),
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent"}
        (self.home / "run").mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def write_secret_tool(self, source):
        tool = self.tools / "secret-tool"
        tool.write_text("#!/usr/bin/env bash\n" + source)
        tool.chmod(0o755)

    def test_cleanup_reports_keyring_failures_and_returns_nonzero(self):
        self.write_secret_tool(
            "case ${1:-} in\n"
            "  lookup) exit 0 ;;\n"
            "  clear) exit 7 ;;\n"
            "  store) cat >/dev/null; exit 0 ;;\n"
            "esac\n"
        )
        result = subprocess.run(
            [SETUP, "cleanup", "--yes"], env=self.env,
            text=True, capture_output=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(payload["ok"])
        self.assertTrue(any("API key" in failure for failure in payload["failures"]))

    def test_cleanup_clears_legacy_keys_under_the_old_service_name(self):
        calls = self.home / "secret-tool-calls"
        self.write_secret_tool(
            f'printf "%s\\n" "$*" >> {calls}\n'
            "case ${1:-} in\n"
            "  lookup) [[ $5 == openai ]] && exit 0; exit 1 ;;\n"
            "  clear) exit 0 ;;\n"
            "esac\n"
        )
        result = subprocess.run(
            [SETUP, "cleanup", "--yes"], env=self.env,
            text=True, capture_output=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stored API keys (openai)", payload["removed"])
        self.assertIn("clear service omarchy-tts key openai", calls.read_text())

    def test_cleanup_without_a_keyring_helper_still_succeeds(self):
        env = {**self.env, "PATH": "/usr/bin:/bin"}
        if shutil.which("secret-tool", path=env["PATH"]):
            self.skipTest("a system secret-tool is installed")
        result = subprocess.run(
            [SETUP, "cleanup", "--yes"], env=env, text=True, capture_output=True,
        )
        self.assertEqual(json.loads(result.stdout)["failures"], [])

    def test_cleanup_does_not_claim_absent_keys_were_removed(self):
        self.write_secret_tool(
            "case ${1:-} in\n"
            "  lookup) exit 1 ;;\n"
            "  clear) exit 0 ;;\n"
            "esac\n"
        )
        result = subprocess.run(
            [SETUP, "cleanup", "--yes"], env=self.env,
            text=True, capture_output=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["ok"])
        self.assertFalse(any("API key" in item for item in payload["removed"]))


class ProviderHealthTests(unittest.TestCase):
    """A provider that is installed but cannot speak must never read "ready".

    This is the regression that silently disabled every keybinding: kokoro
    passed its probe, was reported ready, was selected as default, and could
    not synthesise a single sample.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "XDG_CACHE_HOME": str(self.home / "cache"),
                    "XDG_RUNTIME_DIR": str(self.home / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        self.providers = self.home / "config" / "omarchy-tts-local" / "providers"
        self.providers.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def write_provider(self, name, body, probe="true"):
        path = self.providers / name
        path.write_text("#!/usr/bin/env bash\n"
                        f"# desc: test provider {name}\n"
                        "# kind: local\n"
                        f"# probe: {probe}\n"
                        f"{body}\n")
        path.chmod(0o755)
        return path

    def speak(self, *args):
        return subprocess.run([SPEAK, *args], text=True, capture_output=True,
                              env=self.env, check=False)

    def status_of(self, name):
        info = json.loads(self.speak("--info").stdout)
        for entry in info["providers"]:
            if entry["name"] == name:
                return entry["status"]
        return None

    def test_installed_but_broken_provider_is_not_ready(self):
        self.write_provider("brokentest", "exit 3")
        self.assertEqual(self.status_of("brokentest"), "untested",
                         "an unproven provider must not claim to be ready")
        result = self.speak("--verify", "brokentest")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status_of("brokentest"), "failing")

    def test_working_provider_becomes_ready_only_after_proof(self):
        self.write_provider("worktest", "cat > /dev/null")
        self.assertEqual(self.status_of("worktest"), "untested")
        result = self.speak("--verify", "worktest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status_of("worktest"), "ready")

    def test_health_proof_expires_when_the_adapter_changes(self):
        provider = self.write_provider("changing", "cat > /dev/null")
        self.assertEqual(self.speak("--verify", "changing").returncode, 0)
        self.assertEqual(self.status_of("changing"), "ready")
        provider.write_text(provider.read_text() + "# release changed\n")
        self.assertEqual(self.status_of("changing"), "untested")

    def test_proof_cannot_bless_config_changed_while_provider_runs(self):
        self.write_provider(
            "movingconfig",
            "cat >/dev/null\n"
            "tmp=${TTS_CONFIG}.provider-test\n"
            "jq '.movingconfig = {changed: true}' \"$TTS_CONFIG\" > \"$tmp\"\n"
            "mv \"$tmp\" \"$TTS_CONFIG\"",
        )
        result = self.speak("--verify", "movingconfig")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status_of("movingconfig"), "untested")

    def test_legacy_health_without_a_fingerprint_is_untrusted(self):
        self.write_provider("legacy", "cat > /dev/null")
        health = self.home / "cache" / "omarchy-tts-local" / "health.json"
        health.parent.mkdir(parents=True)
        health.write_text(json.dumps({"legacy": {"status": "ok"}}))
        self.assertEqual(self.status_of("legacy"), "untested")

    def test_provider_probe_has_a_deadline(self):
        self.write_provider("hangingprobe", "cat > /dev/null", probe="sleep 30")
        started = time.monotonic()
        self.assertEqual(self.status_of("hangingprobe"), "missing")
        self.assertLess(time.monotonic() - started, 5)

    def test_health_writer_recovers_a_truncated_cache_atomically(self):
        health = self.home / "cache" / "omarchy-tts-local" / "health.json"
        health.parent.mkdir(parents=True)
        health.write_text('{"worktest":')
        self.write_provider("worktest", "cat > /dev/null")
        result = self.speak("--verify", "worktest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(health.read_text())["worktest"]["status"], "ok")
        self.assertEqual(health.stat().st_mode & 0o777, 0o600)

    def test_provider_setting_change_invalidates_cached_proof(self):
        health = self.home / "cache" / "omarchy-tts-local" / "health.json"
        health.parent.mkdir(parents=True)
        health.write_text(json.dumps({
            "piper": {"status": "ok", "fingerprint": "old"},
            "unrelated": {"status": "ok", "fingerprint": "keep"},
        }))
        result = self.speak("--set", ".piper.voice", "en_US-test-medium")
        self.assertEqual(result.returncode, 0, result.stderr)
        updated = json.loads(health.read_text())
        self.assertNotIn("piper", updated)
        self.assertIn("unrelated", updated)

    def test_absent_provider_reports_missing_not_failing(self):
        # Absence and breakage are different problems with different fixes.
        self.write_provider("absenttest", "cat > /dev/null", probe="false")
        self.assertEqual(self.status_of("absenttest"), "missing")
        result = self.speak("--verify", "absenttest")
        self.assertIn("not installed", result.stdout)

    def test_failure_during_real_speech_is_recorded(self):
        self.write_provider("livetest", "exit 4")
        self.speak("--set", ".provider", "livetest")
        self.speak("Hello there.")
        self.assertEqual(self.status_of("livetest"), "failing",
                         "a real failure should mark the provider without a separate test")

    def test_superseded_speech_cannot_erase_the_new_owner(self):
        self.write_provider(
            "slowtest",
            "trap 'exit 143' TERM INT\ncat > /dev/null\nsleep 30",
        )
        self.speak("--set", ".provider", "slowtest")
        first = subprocess.Popen([SPEAK, "first"], text=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 env=self.env)
        pid_file = self.home / "run" / "omarchy-tts-local" / "pgid"
        for _ in range(100):
            if pid_file.exists():
                break
            time.sleep(0.02)
        status_file = self.home / "run" / "omarchy-tts-local" / "status"
        self.assertEqual(pid_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(status_file.stat().st_mode & 0o777, 0o600)
        second = subprocess.Popen([SPEAK, "second"], text=True,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  env=self.env)
        for _ in range(100):
            if pid_file.exists() and first.poll() is not None:
                break
            time.sleep(0.02)
        self.assertEqual(self.speak("--status").stdout.strip(), "speaking")
        self.assertTrue(pid_file.exists())
        self.speak("--stop")
        first.wait(timeout=3)
        second.wait(timeout=3)

    def test_registered_playback_owner_is_the_provider_session(self):
        marker = self.home / "provider-pid"
        self.write_provider(
            "ownedgroup",
            'printf "%s\\n" "$$" > "$PROVIDER_PID_MARKER"\n'
            "cat > /dev/null\n"
            "sleep 30",
        )
        env = {**self.env, "PROVIDER_PID_MARKER": str(marker)}
        speaking = subprocess.Popen(
            [SPEAK, "--provider", "ownedgroup", "hello"], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        pid_file = self.home / "run" / "omarchy-tts-local" / "pgid"
        try:
            for _ in range(200):
                if marker.exists() and pid_file.exists():
                    break
                time.sleep(0.01)
            provider_pid = int(marker.read_text().strip())
            registered_pid = int(pid_file.read_text().split()[0])
            self.assertEqual(registered_pid, provider_pid)
            self.assertEqual(os.getpgid(provider_pid), provider_pid)
        finally:
            self.speak("--stop")
            speaking.wait(timeout=3)

    def test_stale_speech_identity_cannot_signal_a_reused_pid(self):
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            state = self.home / "run" / "omarchy-tts-local"
            state.mkdir(parents=True, exist_ok=True)
            (state / "pgid").write_text(f"{sleeper.pid} definitely-wrong\n")
            (state / "status").write_text("speaking\n")
            self.assertEqual(self.speak("--status").stdout.strip(), "idle")
            self.speak("--stop")
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=3)

    def test_speech_control_never_follows_runtime_state_symlinks(self):
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            state = self.home / "run" / "omarchy-tts-local"
            state.mkdir(parents=True, exist_ok=True)
            identity = Path(f"/proc/{sleeper.pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
            external_owner = self.home / "external-owner"
            external_owner.write_text(f"{sleeper.pid} {identity}\n")
            owner = state / "pgid"
            owner.symlink_to(external_owner)
            self.speak("--stop")
            self.assertIsNone(sleeper.poll())

            owner.write_text(f"{sleeper.pid} {identity}\n")
            external_status = self.home / "external-status"
            external_status.write_text("private text that must not be displayed\n")
            status_path = state / "status"
            status_path.unlink(missing_ok=True)
            status_path.symlink_to(external_status)
            status = self.speak("--status").stdout.strip()
            self.assertEqual(status, "preparing")
            self.assertNotIn("private text", status)
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
            sleeper.wait(timeout=3)


class LegacyRenameTests(unittest.TestCase):
    """The plugin was renamed from omarchy-tts. Its old config, data and cache
    directories move to the new names on first use, and the shortcut block
    written under the old name is still recognised as ours."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.bases = {name: self.home / name for name in ("config", "data", "cache")}
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(self.bases["config"]),
                    "XDG_DATA_HOME": str(self.bases["data"]),
                    "XDG_CACHE_HOME": str(self.bases["cache"]),
                    "XDG_RUNTIME_DIR": str(self.home / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        (self.home / "run").mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def write_legacy(self):
        old = {name: base / "omarchy-tts" for name, base in self.bases.items()}
        old["config"].mkdir(parents=True)
        (old["config"] / "config.json").write_text(json.dumps({"provider": "kokoro"}))
        (old["data"] / "voices" / "piper").mkdir(parents=True)
        (old["data"] / "voices" / "piper" / "kept.onnx").write_text("voice")
        old["cache"].mkdir(parents=True)
        (old["cache"] / "health.json").write_text("{}")
        return old

    def assert_moved(self, old):
        for name, base in self.bases.items():
            self.assertFalse(old[name].exists(), name)
        new = {name: base / "omarchy-tts-local" for name, base in self.bases.items()}
        self.assertEqual(json.loads((new["config"] / "config.json").read_text())["provider"],
                         "kokoro")
        self.assertEqual((new["data"] / "voices" / "piper" / "kept.onnx").read_text(), "voice")
        self.assertTrue((new["cache"] / "health.json").exists())

    def test_speak_moves_old_directories_before_creating_new_ones(self):
        old = self.write_legacy()
        result = subprocess.run([SPEAK, "--info"], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["provider"], "kokoro")
        self.assert_moved(old)

    def test_every_other_tool_moves_old_directories_too(self):
        for tool in ((SETUP, "status"), (BINDINGS, "status"),
                     (ROOT / "bin" / "speak-voice", "list")):
            with self.subTest(tool=tool[0].name):
                old = self.write_legacy()
                subprocess.run(list(tool), env=self.env, capture_output=True, check=True)
                self.assert_moved(old)
                for base in self.bases.values():
                    shutil.rmtree(base / "omarchy-tts-local")

    def test_an_existing_new_directory_is_never_merged_or_replaced(self):
        old = self.write_legacy()
        current = self.bases["config"] / "omarchy-tts-local"
        current.mkdir(parents=True)
        (current / "config.json").write_text(json.dumps({"provider": "piper"}))
        subprocess.run([SPEAK, "--info"], env=self.env, capture_output=True, check=True)
        self.assertEqual(json.loads((current / "config.json").read_text())["provider"], "piper")
        self.assertTrue((old["config"] / "config.json").exists(),
                        "the old directory was discarded instead of left alone")

    def test_pre_rename_shortcut_block_is_recognised_and_rewritten(self):
        hypr = self.bases["config"] / "hypr"
        hypr.mkdir(parents=True)
        lua = hypr / "bindings.lua"
        lua.write_text(
            'o.bind("SUPER + B", "Browser", "browser")\n\n'
            "-- >>> omarchy-tts bindings\n"
            'o.bind("SUPER + ALT + E", "Speak selection", '
            '"/old/plugins/io.github.hikari112.tts/bin/speak --toggle")\n'
            "-- <<< omarchy-tts bindings\n"
        )
        status = json.loads(subprocess.run([BINDINGS, "status"], env=self.env, text=True,
                                           capture_output=True, check=True).stdout)
        self.assertTrue(status["installed"])
        self.assertTrue(status["legacy"])
        self.assertEqual(status["conflicts"], [], "our own old block was read as a conflict")

        subprocess.run([BINDINGS, "install"], env=self.env, capture_output=True, check=True)
        text = lua.read_text()
        self.assertNotIn("-- >>> omarchy-tts bindings", text)
        self.assertNotIn("hikari112", text)
        self.assertIn("-- >>> omarchy-tts-local bindings", text)
        self.assertEqual(text.count("SUPER + ALT + E"), 1)
        self.assertIn('"Browser"', text)
        status = json.loads(subprocess.run([BINDINGS, "status"], env=self.env, text=True,
                                           capture_output=True, check=True).stdout)
        self.assertFalse(status["legacy"])

        subprocess.run([BINDINGS, "remove"], env=self.env, capture_output=True, check=True)
        self.assertEqual(lua.read_text().strip(), 'o.bind("SUPER + B", "Browser", "browser")')


class BindingAdoptionTests(unittest.TestCase):
    """Shortcuts a user set up by hand are ours to adopt, not to duplicate."""

    LUA = """-- Personal keybindings
o.bind("SUPER + SHIFT + S", "Screenshot", "omarchy-capture-screenshot")
o.bind("SUPER + ALT + P", "Unrelated", "/usr/bin/speaker-test --nonsense")
o.bind("SUPER + ALT + E", "Speak selection", "/home/someone/.local/bin/speak --toggle")
o.bind("SUPER + ALT + X", "Stop speaking", "speak --stop")
"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        (self.home / "hypr").mkdir(parents=True)
        (self.home / "omarchy-tts-local").mkdir(parents=True)
        self.lua = self.home / "hypr" / "bindings.lua"
        self.lua.write_text(self.LUA)
        self.env = {**os.environ, "XDG_CONFIG_HOME": str(self.home)}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)

    def tearDown(self):
        self.temp.cleanup()

    def run_bindings(self, *args):
        return subprocess.run([BINDINGS, *args], text=True, capture_output=True,
                              env=self.env, check=False)

    def test_hand_written_bindings_are_adoptable_not_conflicts(self):
        state = json.loads(self.run_bindings("status").stdout)
        self.assertFalse(state["installed"])
        self.assertEqual(state["conflicts"], [])
        self.assertIn("SUPER + ALT + E", state["adoptable"])
        self.assertTrue(state["canInstall"], "adoption must not be a dead end")

    def test_install_adopts_without_duplicating(self):
        self.run_bindings("install")
        text = self.lua.read_text()
        self.assertEqual(text.count("SUPER + ALT + E"), 1, "chord bound twice")
        self.assertIn("Screenshot", text, "unrelated binding was removed")

    def test_similarly_named_program_is_left_alone(self):
        # speaker-test is not speak; adopting it would break the user's setup.
        self.run_bindings("install")
        self.assertIn("speaker-test", self.lua.read_text())

    def test_genuine_conflict_still_refuses_and_changes_nothing(self):
        self.lua.write_text('o.bind("SUPER + ALT + E", "Open editor", "code")\n')
        before = self.lua.read_text()
        state = json.loads(self.run_bindings("status").stdout)
        self.assertEqual(state["conflicts"], ["SUPER + ALT + E"])
        self.assertFalse(state["canInstall"])
        result = self.run_bindings("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.lua.read_text(), before)


class CancelledSpeechTests(unittest.TestCase):
    """Stopping speech must never be recorded as a broken provider.

    A provider that execs a player does not necessarily die by the signal sent
    to it. mpv catches SIGTERM and exits 4, so stopping cloud speech marked the
    backend failing, the panel then offered only "Replace key", and the
    provider could not be selected again.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "XDG_CACHE_HOME": str(self.home / "cache"),
                    "XDG_RUNTIME_DIR": str(self.home / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        (self.home / "run").mkdir(parents=True)
        self.providers = self.home / "config" / "omarchy-tts-local" / "providers"
        self.providers.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def write_provider(self, name, body):
        path = self.providers / name
        path.write_text("#!/usr/bin/env bash\n"
                        f"# desc: test provider {name}\n"
                        "# kind: local\n"
                        "# probe: true\n"
                        f"{body}\n")
        path.chmod(0o755)

    def status_of(self, name):
        info = json.loads(subprocess.run([SPEAK, "--info"], text=True,
                                         capture_output=True, env=self.env).stdout)
        return next(p["status"] for p in info["providers"] if p["name"] == name)

    def test_stopping_a_signal_translating_provider_is_not_a_failure(self):
        # Exits 4 on SIGTERM instead of dying by signal, exactly as mpv does.
        self.write_provider("mpvlike",
                            'trap "exit 4" TERM\ncat > /dev/null\nsleep 30 &\nwait $!')
        speaking = subprocess.Popen([SPEAK, "--provider", "mpvlike"],
                                    stdin=subprocess.PIPE, text=True, env=self.env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        speaking.stdin.write("Interrupt me.\n")
        speaking.stdin.close()
        time.sleep(1.5)
        subprocess.run([SPEAK, "--stop"], env=self.env, capture_output=True)
        speaking.wait(timeout=30)
        self.assertNotEqual(self.status_of("mpvlike"), "failing",
                            "a stopped provider was recorded as broken")

    def test_stopping_speech_writes_nothing_to_stderr(self):
        # setsid --wait reports a child killed by a signal ("did not exit
        # normally"), and the panel shows any stderr as an error.
        self.write_provider("killable", "cat > /dev/null\nsleep 30 &\nwait $!")
        speaking = subprocess.Popen([SPEAK, "--provider", "killable"],
                                    stdin=subprocess.PIPE, text=True, env=self.env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        speaking.stdin.write("Interrupt me.\n")
        speaking.stdin.close()
        time.sleep(1.5)
        subprocess.run([SPEAK, "--stop"], env=self.env, capture_output=True)
        # Not communicate(): Python 3.11 flushes the already-closed stdin.
        speaking.wait(timeout=30)
        self.assertEqual(speaking.stderr.read(), "")
        speaking.stderr.close()

    def test_a_genuine_failure_is_still_recorded(self):
        self.write_provider("brokenlike", "cat > /dev/null; exit 4")
        subprocess.run([SPEAK, "--provider", "brokenlike"], input="Hello.",
                       text=True, env=self.env, capture_output=True)
        self.assertEqual(self.status_of("brokenlike"), "failing",
                         "an uncancelled failure must still mark the provider")
        self.write_provider("noisy", "cat > /dev/null; echo 'model missing' >&2; exit 4")
        result = subprocess.run([SPEAK, "--provider", "noisy"], input="Hello.",
                                text=True, env=self.env, capture_output=True)
        self.assertIn("model missing", result.stderr,
                      "a provider's own error must still reach the panel")


class OcrEngineTests(unittest.TestCase):
    """Engines are chosen the way voices are: listed, proven, then selected.

    Health for an engine lives under its own key so a reading engine and a
    speaking provider that share a name never overwrite each other.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "XDG_CACHE_HOME": str(self.home / "cache"),
                    "XDG_RUNTIME_DIR": str(self.home / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        (self.home / "run").mkdir(parents=True)
        self.engines = self.home / "config" / "omarchy-tts-local" / "ocr"
        self.engines.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def write_engine(self, name, body, probe="true"):
        path = self.engines / name
        path.write_text("#!/usr/bin/env bash\n"
                        f"# desc: test engine {name}\n"
                        f"# probe: {probe}\n"
                        "cat > /dev/null\n" + body)
        path.chmod(0o755)

    def speak(self, *args):
        return subprocess.run([SPEAK, *args], text=True, capture_output=True, env=self.env)

    def engine(self, name):
        info = json.loads(self.speak("--info").stdout)
        return next(e for e in info["ocr"]["engines"] if e["name"] == name)

    def test_engine_is_untested_until_it_reads_the_probe(self):
        self.write_engine("reads", "printf 'Probe 123\\n'\n")
        self.write_engine("blind", "exit 1\n")
        self.write_engine("absent", "exit 0\n", probe="false")
        self.assertEqual(self.engine("reads")["status"], "untested")
        self.assertEqual(self.engine("absent")["status"], "missing")
        self.assertEqual(self.speak("--verify-ocr", "reads").returncode, 0)
        self.assertEqual(self.engine("reads")["status"], "ready")
        self.assertNotEqual(self.speak("--verify-ocr", "blind").returncode, 0)
        self.assertEqual(self.engine("blind")["status"], "failing")
        health = json.loads((self.home / "cache" / "omarchy-tts-local" / "health.json").read_text())
        self.assertIn("ocr:reads", health)
        self.assertNotIn("reads", health, "engine health must not be filed as a voice provider")

    def test_languages_are_kept_per_engine(self):
        self.write_engine("one", "exit 0\n")
        self.speak("--set", ".ocr.tesseract.langs", "eng+jpn")
        self.speak("--set", ".ocr.easyocr.langs", "eng+deu")
        self.speak("--set", ".ocr.engine", "tesseract")
        self.assertEqual(json.loads(self.speak("--info").stdout)["ocr"]["langs"], "eng+jpn")
        self.speak("--set", ".ocr.engine", "easyocr")
        self.assertEqual(json.loads(self.speak("--info").stdout)["ocr"]["langs"], "eng+deu")
        self.assertNotEqual(self.speak("--set", ".ocr.easyocr.langs", "eng;rm").returncode, 0)
        self.assertEqual(json.loads(self.speak("--info").stdout)["ocr"]["langs"], "eng+deu")

    def test_custom_engine_languages_are_persisted_without_jq_injection(self):
        self.write_engine("custom-engine", "printf 'text\\n'\n")
        self.assertEqual(
            self.speak("--set", ".ocr.custom-engine.langs", "eng+jpn").returncode, 0
        )
        self.speak("--set", ".ocr.engine", "custom-engine")
        info = json.loads(self.speak("--info").stdout)
        self.assertEqual(info["ocr"]["langs"], "eng+jpn")
        self.assertNotEqual(
            self.speak("--set", ".ocr.bad] | .provider.langs", "eng").returncode, 0
        )

    def test_legacy_shared_languages_migrate_to_tesseract_only(self):
        config = self.home / "config" / "omarchy-tts-local" / "config.json"
        config.write_text('{"schemaVersion": 2, "ocr": {"engine": "tesseract", "langs": "eng+jpn+deu"}}')
        self.speak("--info")
        data = json.loads(config.read_text())
        self.assertEqual(data["ocr"]["tesseract"]["langs"], "eng+jpn+deu")
        self.assertEqual(data["ocr"]["easyocr"]["langs"], "eng",
                         "a language set tesseract accepts is not one EasyOCR can combine")


class OcrLanguageTests(unittest.TestCase):
    """Recognition languages are discovered, not typed into a free-text box.

    A configured language whose data was missing produced an empty result and
    exit 0: reading nothing, forever, without ever saying why.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "XDG_CACHE_HOME": str(self.home / "cache"),
                    "XDG_RUNTIME_DIR": str(self.home / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        (self.home / "run").mkdir(parents=True)
        self.engines = self.home / "config" / "omarchy-tts-local" / "ocr"
        self.engines.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def write_engine(self, name, languages_json):
        path = self.engines / name
        path.write_text("#!/usr/bin/env bash\n"
                        f"# desc: test engine {name}\n"
                        "# kind: local\n"
                        "# probe: true\n"
                        'if [[ "${1:-}" == "--languages" ]]; then\n'
                        f"  printf '%s' '{languages_json}'\n"
                        "  exit 0\n"
                        "fi\n"
                        "cat > /dev/null\n")
        path.chmod(0o755)

    def speak(self, *args):
        return subprocess.run([SPEAK, *args], text=True, capture_output=True, env=self.env)

    def test_languages_are_absent_until_explicitly_refreshed(self):
        self.write_engine("faketess", '[{"value":"eng","label":"eng","installed":true}]')
        self.speak("--set", ".ocr.engine", "faketess")
        info = json.loads(self.speak("--info").stdout)
        self.assertEqual(info["ocr"]["languages"], [],
                         "opening settings should not shell out to a package database")
        result = self.speak("--refresh-languages", "faketess")
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(self.speak("--info").stdout)
        self.assertEqual([l["value"] for l in info["ocr"]["languages"]], ["eng"])
        self.assertTrue(info["ocr"]["languages"][0]["installed"])

    def test_available_and_installed_are_distinguished(self):
        self.write_engine("faketess",
                          '[{"value":"eng","label":"eng","installed":true},'
                          '{"value":"jpn","label":"jpn","installed":false}]')
        self.speak("--set", ".ocr.engine", "faketess")
        self.speak("--refresh-languages", "faketess")
        langs = json.loads(self.speak("--info").stdout)["ocr"]["languages"]
        installed = [l["value"] for l in langs if l["installed"]]
        available = [l["value"] for l in langs if not l["installed"]]
        self.assertEqual(installed, ["eng"])
        self.assertEqual(available, ["jpn"])

    def test_unknown_engine_is_refused(self):
        self.assertNotEqual(self.speak("--refresh-languages", "nope").returncode, 0)


class LanguageInstallTargetTests(unittest.TestCase):
    """QML may name a language; it may never name a command or a package."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(Path(self.temp.name) / "config"),
                    "XDG_RUNTIME_DIR": str(Path(self.temp.name) / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)

    def tearDown(self):
        self.temp.cleanup()

    def start(self, target):
        result = subprocess.run([SETUP, "start", target], text=True,
                                capture_output=True, env=self.env)
        try:
            return json.loads(result.stdout)
        except ValueError:
            return {"ok": False, "message": result.stdout + result.stderr}

    def test_malformed_language_codes_are_refused_by_shape(self):
        for target in ("lang:../../etc/passwd", "lang:jpn; rm -rf /", "lang:JPN",
                       "lang:", "lang:toolongcode"):
            with self.subTest(target=target):
                answer = self.start(target)
                self.assertFalse(answer.get("ok", False),
                                 f"{target} was accepted as an install target")
                self.assertNotIn("started", answer)


class LanguageNameTableTests(unittest.TestCase):
    """Language data files are identifiers; the panel must show names.

    The engine joins its codes against lib/tesseract-languages.tsv. The fake
    engines above never touch that table, so its shape is checked directly.
    """

    TABLE = Path(__file__).resolve().parents[1] / "lib" / "tesseract-languages.tsv"

    def rows(self):
        return [line.split("\t") for line in self.TABLE.read_text().splitlines() if line]

    def test_every_row_is_code_and_distinct_name(self):
        for row in self.rows():
            with self.subTest(row=row):
                self.assertEqual(len(row), 2)
                code, name = row
                self.assertRegex(code, r"^[a-z]{3,4}(_[a-z]+)*$")
                self.assertTrue(name.strip())
                self.assertNotEqual(code, name, "a code standing in for its own name")

    def test_script_variants_say_which_script(self):
        names = dict(self.rows())
        self.assertEqual(names["jpn"], "Japanese")
        self.assertIn("Cyrillic", names["aze_cyrl"])
        self.assertIn("Simplified", names["chi_sim"])
        self.assertIn("vertical", names["jpn_vert"])

    def test_no_duplicate_codes(self):
        codes = [r[0] for r in self.rows()]
        self.assertEqual(len(codes), len(set(codes)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
