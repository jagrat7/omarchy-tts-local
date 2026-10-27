# Architecture and review guide

The plugin has a five-tab settings panel: Providers (speech and screen
reading engines), Voice, Text, Languages, and Keys. Its command-line boundary
remains independently useful and testable.

## Ownership boundaries

- `bin/speak` is the public speech and settings API.
- `lib/config.sh` owns schema migration, validation and atomic config writes.
- `lib/health.sh` owns shared, atomic health-cache invalidation.
- `lib/sanitize.py` is the one sanitizer used for speech and live preview.
- provider executables declare small metadata headers consumed by `--info`.
- `bin/speak-voice` owns Piper catalogue/download lifecycle.
- `bin/speak-bindings` owns only the text between its markers in
  `~/.config/hypr/bindings.lua`; it backs up and validates every write. Its
  private JSON stores only chord choices—labels, commands, and installation
  paths are always derived from the current plugin.
- `components/TtsController.qml` is the async bridge from QML to those CLIs.
- `Panel.qml` owns presentation and transient interaction state shared across
  tabs; each tab's body is a component (`components/*Tab.qml`,
  `VoiceBrowser.qml`) that also owns the state only it uses.
- `components/utils.js` holds the pure helpers (key chords, voice names,
  catalogue sorting, provider checks, formatting). It reads no QML state, so
  `tests/test_utils.py` runs it directly under node.

QML uses argv arrays for user-controlled values. Shell interpretation is
limited to a fixed allowlist handled by the graphical setup backend.
Every provider and OCR engine runs locally; nothing in the plugin holds a
credential or sends selected text or captures off the machine.

## Configuration

`config.json` schema version 6 is additive and backwards compatible. Startup
fills missing defaults without replacing existing values. Schema 5 removes the
retired cloud providers' settings and moves a configuration that selected one
of them (or a cloud OCR engine) to Piper or Tesseract. Schema 6 maps a saved
`.ui.lastTab` from the old six tabs onto the five, so a panel last left on
Screen reopens on Providers. The panel now always opens on Overview, so
`.ui.lastTab` is still validated but no longer read. Invalid JSON, oversized
files, and unsafe nested shapes are preserved with an `.invalid.<timestamp>`
suffix before type-safe defaults are restored. Writes are limited to an
allowlist, serialized, and use an atomic rename with mode 0600. Existing config
symlinks keep pointing to the same target, while dangling symlinks are
rejected.

Runtime state is stored in a private, user-owned directory. Speech and
background jobs record both process ownership and identity; callers must only
clear state they still own, and the UI does not expose cancellation until that
identity is confirmed. Provider/OCR health entries carry fingerprints of the
adapter and its relevant configuration, so old proof becomes untested after
meaningful changes. QML settings writes are serialized, with
redundant pending writes to the same property coalesced.

Provider headers are the capability boundary consumed by `speak --info`.
Alongside descriptive fields, adapters can declare byte/character limits, rate
ranges, devices, install sizes, and deprecation. The panel acts on those
normalized fields instead of inferring behavior from a filename.

Speech preparation and playback have separate, identity-checked ownership
records. A new utterance atomically hands off under the speech lock; Stop can
cancel selection, capture, OCR, provider preparation, or playback without PID
reuse races. Public text and capture inputs, catalogue records, and downloads
all have explicit size ceilings.

Managed engine setup and Piper voice publication are transactions. Engine
activation records a private recovery journal before replacing a proven
generation; voice repair stages and verifies both the model and sidecar before
publishing the pair under the same lock Piper holds while reading them. A later
invocation repairs artifacts left by abrupt process death or power loss.

## Deliberate design changes

- Speech and OCR engines share the Providers tab as two groups, with one
  setup progress line; recognition languages keep their own focused browser.
- Keys use Omarchy's current Lua configuration, not the obsolete `.conf` file
  in the original mockup.
- Provider installs use reviewed Omarchy/uv commands and require confirmation.
- Direct engine packages are release-pinned; Kokoro deliberately uses an
  isolated Python 3.12 because its published metadata excludes newer Python.
- The cloud providers and OCR engines were removed when this fork went
  local-only, so the plugin keeps no credentials at all.
- Raw PCM uses mpv JSON IPC when available, with pw-cat/aplay fallback. Live
  rate is a pitch-preserving player speed ratio over the synthesis rate; the
  saved rate still drives the next synthesis natively.
- Now-playing elapsed and duration use the normal-rate content timeline:
  mpv audio PTS times the synthesis rate, excluding pauses. Duration uses an
  estimate of 15 characters/second (never less than elapsed); a pipe's
  reported duration covers only the bytes buffered so far.
  Fallback players expose no pause/live-rate capability and null progress.

## Suggested reviewer path

1. `lib/config.sh` and `bin/speak --info/--set`
2. `components/TtsController.qml`
3. the tab sections in `Panel.qml`
4. `bin/speak-setup` transaction and recovery behavior
5. `bin/speak-voice` catalogue, verification, publication, and recovery
6. `bin/speak-bindings` safety and coupled rollback behavior
7. provider/OCR engine invocation and input bounds

Run `python3 -m unittest discover -s tests -v` and the ShellCheck command from
the README. The suite includes static QML interaction contracts; a full visual
review still requires omarchy-shell.

## Releasing

`manifest.json`'s `version` is the release version. Bump it in a pull request;
when that merges to `main`, the Release workflow tags `v<version>` and
publishes a GitHub release whose notes list the merged pull requests. Pull
request descriptions are the changelog, so there is no CHANGELOG.md. The
marketplace lists a commit, not a release: after a release, submit the new
`main` SHA through its Plugin verification form.

## Re-pinning Piper voices

Voices download from one immutable revision of `rhasspy/piper-voices`, and
every model and sidecar is verified against `lib/piper-voices.sha256`. To move
to a newer upstream revision:

```bash
tools/pin-piper-voices <40-hex revision>
```

It rewrites `lib/piper-voices.json`, `lib/piper-voices.sha256`, and the
`PIPER_VOICES_REV` constant in `bin/speak-voice`. Review the diff like any
other dependency bump; the digests are the trust root for every download.

## Re-locking engine dependencies and models

```bash
tools/pin-engines lock      # rebuild lib/engines/*.lock from *.in (uv, hashed, wheel-only)
tools/pin-engines models    # re-fetch every pinned model artefact and confirm its digest
```

The locks are complete closures for Linux x86_64 / Python 3.12, compiled
against the index as it stood at `lib/engines/EXCLUDE_NEWER`; move that
instant forward to pick up newer releases, then re-run `lock`. CI fails if the
locks do not regenerate byte-for-byte or if any requirement lacks a wheel.

A dependency with no published wheel (today only `docopt`, via
kokoro → misaki → num2words) is served from the reviewed flat index
`lib/engines/wheels`. Its wheel is built reproducibly from the hash-verified
sdist so a reviewer can recreate it bit-for-bit:

```bash
curl -sSLO https://files.pythonhosted.org/packages/a2/55/8f8cab2afd404cf578136ef2cc5dfb50baa1761b68c9da1fb1e4eed343c9/docopt-0.6.2.tar.gz
echo '49b3a825280bd66b3aa83585ef59c4a8c82f2c8a522dbe754a8bc8d08c85c491  docopt-0.6.2.tar.gz' | sha256sum -c
tar xzf docopt-0.6.2.tar.gz && cd docopt-0.6.2
SOURCE_DATE_EPOCH=0 uv build --wheel --out-dir ../dist .
sha256sum ../dist/docopt-0.6.2-py2.py3-none-any.whl   # must match lib/engines/wheels/SHA256SUMS
```

The shipped wheel was produced by uv 0.12.8 with setuptools 84.0.0 as the
build backend (recorded in its `WHEEL` metadata) under `umask 022`. If a
later backend changes the metadata and the hash no longer matches, compare
the payload instead: `docopt.py` and `LICENSE-MIT` inside the wheel must be
byte-identical to the files in the verified sdist. Locks are maintained with
the uv release in `lib/engines/UV_VERSION`; `tools/pin-engines lock` refuses
any other.

To bump a model, edit `lib/engines/models.json` by hand with the new immutable
source and digest, then run `models` to prove it. A digest that no longer
matches is the event the manifest exists to catch, so the tool never rewrites
one.
