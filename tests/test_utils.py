#!/usr/bin/env python3
"""Unit tests for components/utils.js, the panel's pure helpers.

QML runs the file as a `.pragma library`; here node loads it in a vm context
with that line removed and a stub `Qt` holding the real key and modifier codes.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "components" / "utils.js"

# Values from Qt's qnamespace.h, so the stub matches what QML passes in.
QT = {
    "Key_Escape": 0x01000000, "Key_Tab": 0x01000001, "Key_Backspace": 0x01000003,
    "Key_Return": 0x01000004, "Key_Enter": 0x01000005, "Key_Delete": 0x01000007,
    "Key_Left": 0x01000012, "Key_Up": 0x01000013, "Key_Right": 0x01000014,
    "Key_Down": 0x01000015, "Key_Shift": 0x01000020, "Key_F1": 0x01000030,
    "Key_F35": 0x01000052, "Key_Space": 0x20, "Key_Apostrophe": 0x27,
    "Key_Comma": 0x2C, "Key_Minus": 0x2D, "Key_Period": 0x2E, "Key_Slash": 0x2F,
    "Key_Semicolon": 0x3B, "Key_Equal": 0x3D, "Key_A": 0x41, "Key_S": 0x53,
    "Key_BracketLeft": 0x5B, "Key_Backslash": 0x5C, "Key_BracketRight": 0x5D,
    "Key_QuoteLeft": 0x60,
    "ShiftModifier": 0x02000000, "ControlModifier": 0x04000000,
    "AltModifier": 0x08000000, "MetaModifier": 0x10000000,
}

RUNNER = r"""
const fs = require("fs"), vm = require("vm")
const [file, qt, expression] = process.argv.slice(1)
const Qt = JSON.parse(qt)
Qt.rgba = (r, g, b, a) => ({ r, g, b, a })
const context = vm.createContext({ Qt })
vm.runInContext(fs.readFileSync(file, "utf8").replace(/^\.pragma library\n/, ""), context)
process.stdout.write(JSON.stringify(vm.runInContext(expression, context)))
"""


@unittest.skipUnless(shutil.which("node"), "node is needed to run the QML helpers")
class UtilsTests(unittest.TestCase):
    def js(self, expression):
        result = subprocess.run(
            ["node", "-e", RUNNER, str(UTILS), json.dumps(QT), expression],
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def call(self, name, *args):
        return self.js("%s(%s)" % (name, ", ".join(json.dumps(a) for a in args)))

    def key(self, key, text="", *modifiers):
        mods = 0
        for m in modifiers:
            mods |= QT[m + "Modifier"]
        return {"key": QT["Key_" + key], "text": text, "modifiers": mods}

    def test_library_is_a_pragma_library_and_the_stub_covers_its_qt_names(self):
        source = UTILS.read_text()
        self.assertTrue(source.startswith(".pragma library\n"))
        used = set(re.findall(r"\bQt\.(Key_\w+|\w+Modifier)\b", source))
        self.assertIn("Key_Escape", used)
        self.assertEqual(used - set(QT), set())

    def test_key_name(self):
        self.assertEqual(self.call("keyName", self.key("A", "a")), "A")
        self.assertEqual(self.call("keyName", self.key("F1")), "F1")
        self.assertEqual(self.call("keyName", {"key": QT["Key_F1"] + 11, "text": ""}), "F12")
        self.assertEqual(self.call("keyName", self.key("F35")), "F35")
        self.assertEqual(self.call("keyName", self.key("BracketLeft", "[")), "BRACKETLEFT")
        self.assertEqual(self.call("keyName", self.key("QuoteLeft", "`")), "GRAVE")
        self.assertEqual(self.call("keyName", self.key("Space", " ")), "SPACE")
        self.assertEqual(self.call("keyName", self.key("Enter", "\r")), "RETURN")
        self.assertEqual(self.call("keyName", self.key("Escape", "\x1b")), "ESCAPE")
        self.assertEqual(self.call("keyName", self.key("Shift")), "")

    def test_chord_from_event(self):
        self.assertEqual(self.call("chordFromEvent", self.key("S", "s", "Meta", "Control")), "SUPER + CTRL + S")
        # Modifiers always come out in the same order, whatever was pressed.
        self.assertEqual(self.call("chordFromEvent", self.key("A", "A", "Shift", "Alt", "Control", "Meta")),
                         "SUPER + CTRL + ALT + SHIFT + A")
        self.assertEqual(self.call("chordFromEvent", self.key("F1", "", "Alt")), "ALT + F1")
        self.assertEqual(self.call("chordFromEvent", {"key": QT["Key_F1"] + 4, "text": "",
                                                      "modifiers": QT["ShiftModifier"]}), "SHIFT + F5")
        self.assertEqual(self.call("chordFromEvent", self.key("Slash", "/", "Control")), "CTRL + SLASH")
        # Escape cancels capture; a bare modifier is not a chord yet.
        self.assertEqual(self.call("chordFromEvent", self.key("Escape", "\x1b")), "")
        self.assertEqual(self.call("chordFromEvent", self.key("Escape", "\x1b", "Meta")), "")
        self.assertEqual(self.call("chordFromEvent", self.key("Shift", "", "Shift")), "")

    def test_real_conflicts_ignore_adoptable_chords(self):
        self.assertEqual(self.call("realConflicts", ["SUPER + S", "SUPER + R", "CTRL + X"],
                                   [{"chord": "super + s"}, "ctrl + x"]), ["SUPER + R"])
        self.assertEqual(self.call("realConflicts", ["SUPER + R"], []), ["SUPER + R"])

    def test_voice_name_and_label(self):
        self.assertEqual(self.call("voiceName", "en_US-amy-medium"), "Amy")
        self.assertEqual(self.call("voiceLabel", "en_US-amy-medium"), "Amy · en_US · medium")
        self.assertEqual(self.call("voiceName", "en_US-hfc_female-medium"), "Hfc female")
        self.assertEqual(self.call("voiceLabel", "zh_CN-huayan-x_low"), "Huayan · zh_CN · x_low")
        self.assertEqual(self.call("voiceLabel", "en_GB-a-b-c"), "A · en_GB · b-c")
        # Kokoro's keys are already names and stay exactly as they are.
        self.assertEqual(self.call("voiceName", "af_heart"), "af_heart")
        self.assertEqual(self.call("voiceLabel", "af_heart"), "af_heart")
        self.assertEqual(self.call("voiceLabel", "custom-voice"), "custom-voice")
        self.assertEqual(self.call("titleCase", ""), "")

    def test_voice_options(self):
        self.assertEqual(self.call("voiceOptions", ["en_US-amy-medium", "af_heart",
                                                     {"value": "v1", "label": "Nice"}, {"value": "v2"}]),
                         [{"label": "Amy · en_US · medium", "value": "en_US-amy-medium"},
                          {"label": "af_heart", "value": "af_heart"},
                          {"label": "Nice", "value": "v1"}, {"label": "v2", "value": "v2"}])

    def test_quality_rank(self):
        self.assertEqual([self.call("qualityRank", q) for q in ("x_low", "low", "medium", "high")], [0, 1, 2, 3])
        self.assertEqual(self.call("qualityRank", "studio"), 1)
        self.assertEqual(self.js("qualityRank(undefined)"), 1)

    def test_catalogue_rows_sort_filter_and_group(self):
        catalogue = [
            {"key": "en_US-amy-medium", "name": "amy", "lang": "en_US", "country": "United States", "quality": "medium", "sizeMB": 63, "installed": True},
            {"key": "de_DE-thorsten-high", "name": "thorsten", "lang": "de_DE", "country": "Germany", "quality": "high", "sizeMB": 114, "installed": False},
            {"key": "en_US-lessac-x_low", "name": "lessac", "lang": "en_US", "country": "United States", "quality": "x_low", "sizeMB": 20, "installed": False},
            {"key": "fr_FR-siwis-low", "name": "siwis", "lang": "fr_FR", "country": "France", "quality": "low", "sizeMB": 28, "installed": False},
        ]
        def keys(query, mode, active="en_US-amy-medium"):
            return [r["key"].split("-")[1] for r in self.call("catalogueRows", catalogue, query, mode, active)]
        self.assertEqual(keys("", "lang"), ["amy", "thorsten", "lessac", "siwis"])
        self.assertEqual(keys("", "name"), ["amy", "lessac", "siwis", "thorsten"])
        self.assertEqual(keys("", "size"), ["amy", "thorsten", "siwis", "lessac"])
        self.assertEqual(keys("", "quality"), ["amy", "thorsten", "siwis", "lessac"])
        self.assertEqual(keys("  GERMANY ", "lang"), ["thorsten"])
        # The active voice, when it is not installed, needs repair and leads
        # what can be downloaded.
        rows = self.call("catalogueRows", catalogue, "", "name", "fr_FR-siwis-low")
        self.assertEqual([(r["name"], r["group"]) for r in rows],
                         [("amy", "Installed"), ("siwis", "Needs repair"),
                          ("lessac", "Available"), ("thorsten", "Available")])

    def test_filter_by_query(self):
        langs = [{"value": "eng", "label": "English"}, {"value": "deu", "label": "German"}]
        self.assertEqual(self.call("filterByQuery", langs, "", ["value", "label"]), langs)
        self.assertEqual(self.call("filterByQuery", langs, "GER", ["value", "label"]), [langs[1]])
        self.assertEqual(self.call("filterByQuery", langs, "deu", ["label"]), [])

    def test_phrases_split_on_sentences_and_cut_long_runs(self):
        phrases = self.call("splitPhrases", "One. Two!  Three?\nFour")
        self.assertEqual(phrases, [{"text": "One.", "start": 0}, {"text": "Two!", "start": 5},
                                   {"text": "Three?", "start": 11}, {"text": "Four", "start": 18}])
        self.assertEqual(self.call("splitPhrases", 'He said "stop." Then left.'),
                         [{"text": 'He said "stop."', "start": 0}, {"text": "Then left.", "start": 16}])
        self.assertEqual(self.call("splitPhrases", "v1.2 is out"), [{"text": "v1.2 is out", "start": 0}])
        self.assertEqual(self.call("splitPhrases", ""), [])
        long = " ".join(["word"] * 80)    # 399 characters, no punctuation
        pieces = self.call("splitPhrases", long)
        self.assertTrue(all(len(p["text"]) <= 160 for p in pieces))
        self.assertEqual(" ".join(p["text"] for p in pieces), long)
        for p in pieces:
            self.assertEqual(long[p["start"]:p["start"] + len(p["text"])], p["text"])

    def test_phrase_at(self):
        phrases = [{"start": 0}, {"start": 10}, {"start": 30}]
        self.assertEqual([self.call("phraseAt", phrases, at) for at in (0, 9.9, 10, 29, 31, 999)], [0, 0, 1, 1, 2, 2])
        self.assertEqual(self.call("phraseAt", [], 5), 0)

    def test_idle_now_playing_is_a_fresh_object(self):
        self.assertEqual(self.js("idleNowPlaying() !== idleNowPlaying()"), True)
        self.assertEqual(self.call("idleNowPlaying")["status"], "idle")

    def test_provider_helpers(self):
        providers = [{"name": "piper", "status": "ready"}, {"name": "kokoro", "status": "missing"}]
        self.assertEqual(self.call("byName", providers, "kokoro"), providers[1])
        self.assertIsNone(self.call("byName", providers, "nope"))
        self.assertEqual([self.call("isUsable", {"status": s}) for s in ("ready", "untested", "failing", "missing")],
                         [True, True, False, False])
        self.assertTrue(self.call("canUninstall", {"install": "piper", "status": "ready"}))
        self.assertTrue(self.call("canUninstall", {"install": "x", "status": "missing", "installedDevices": ["gpu"]}))
        self.assertFalse(self.call("canUninstall", {"install": "x", "status": "missing"}))
        self.assertFalse(self.call("canUninstall", {"status": "ready"}))     # system package
        self.assertFalse(self.js("canUninstall(null)"))
        self.assertTrue(self.call("variantInstalled", {"status": "untested"}))
        self.assertTrue(self.call("variantInstalled", {"status": "missing", "installedDevices": ["cpu"]}))
        self.assertFalse(self.call("variantInstalled", {"status": "missing"}))

    def test_group_by_family_keeps_order_and_sorts_variants(self):
        entries = self.call("groupByFamily", [
            {"name": "piper"}, {"name": "kokoro_onnx", "family": "Kokoro", "variant": "ONNX"},
            {"name": "espeak"}, {"name": "kokoro", "family": "Kokoro", "variant": "B"}])
        self.assertEqual([(e["family"], [m["name"] for m in e["members"]]) for e in entries],
                         [("", ["piper"]), ("Kokoro", ["kokoro", "kokoro_onnx"]), ("", ["espeak"])])

    def test_variant_summary(self):
        self.assertEqual(self.call("variantSummary", {"installInfo": {"cpu": {"size": "about 480 MB"}, "gpu": {"size": "2 GB"}},
                                                      "variantNote": "Fast"}), "~480 MB · Fast")
        self.assertEqual(self.call("variantSummary", {"installInfo": {"default": {"size": "6 GB"}}}), "6 GB")
        self.assertEqual(self.call("variantSummary", {"variantNote": "Best quality"}), "Best quality")
        self.assertEqual(self.call("variantSummary", {}), "")

    def test_engine_status_and_action_text(self):
        self.assertEqual([self.call("engineStatusText", {"status": s}) for s in ("failing", "ready", "untested", "missing")],
                         ["Not working", "● Ready", "", ""])
        self.assertEqual(self.call("engineActionText", {"status": "failing", "install": "x"}), "Repair")
        self.assertEqual(self.call("engineActionText", {"status": "failing"}), "Retry")
        self.assertEqual(self.call("engineActionText", {"status": "missing", "install": "x"}), "Install")

    def test_lang_codes(self):
        self.assertEqual(self.call("langCodes", "eng+deu"), ["eng", "deu"])
        self.assertEqual(self.call("langCodes", "eng++fra+"), ["eng", "fra"])
        self.assertEqual(self.js("langCodes(undefined)"), ["eng"])
        self.assertEqual(self.call("langCodes", ""), ["eng"])

    def test_clock_text(self):
        self.assertEqual([self.call("clockText", s) for s in (0, 9.4, 59.6, 75, 600, 3600, -3)],
                         ["0:00", "0:09", "1:00", "1:15", "10:00", "60:00", "0:00"])

    def test_progress_fraction_is_never_empty_or_over_full(self):
        self.assertEqual([self.call("progressFraction", p) for p in (0, 1, 50, 100, 250, "37")],
                         [0.02, 0.02, 0.5, 1, 1, 0.37])
        self.assertEqual(self.js("progressFraction(undefined)"), 0.02)

    def test_with_alpha_and_local_path(self):
        self.assertEqual(self.call("withAlpha", {"r": 0.1, "g": 0.2, "b": 0.3, "a": 1}, 0.5),
                         {"r": 0.1, "g": 0.2, "b": 0.3, "a": 0.5})
        self.assertEqual(self.call("localPath", "file:///home/a%20b/bin/speak"), "/home/a b/bin/speak")
        self.assertEqual(self.call("localPath", "/already/a/path"), "/already/a/path")

    def test_item_helpers(self):
        self.assertEqual(self.js("""(() => {
          const root = { parent: null }, mid = { parent: root }, leaf = { parent: mid }, other = { parent: null }
          return [isInside(leaf, root), isInside(root, root), isInside(other, root), isInside(null, root)]
        })()"""), [True, True, False, False])
        self.assertEqual(self.js("""(() => {
          const popup = { closePolicy: 0, opened: false, tag: "popup" }
          const tree = { children: [{ children: [], data: [] }, { data: [{}], children: [{ data: [popup], children: [] }] }] }
          return [findPopup(tree), findPopup({ children: [] }), findPopup(null)]
        })()"""), [{"closePolicy": 0, "opened": False, "tag": "popup"}, None, None])


if __name__ == "__main__":
    unittest.main()
