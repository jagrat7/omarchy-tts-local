# Security policy

Please [report vulnerabilities privately](https://github.com/jagrat7/omarchy-tts-local/security/advisories/new)
through GitHub Security Advisories. Do not include selected text, clipboard
contents, or screenshots in a report. Only the latest release is supported.

## What the plugin touches

- **Your text and screen**: selections, the clipboard and captures are read
  and processed on this computer only. Text input is capped at 1 MiB and
  images at 50 MiB. The current utterance (at most 4096 characters) is kept
  in a mode 0600 file in the private runtime directory and removed on Stop or
  completion. Diagnostic output never includes spoken or selected text.
- **The network**: only for installs and downloads you start (engines,
  models, Piper voices), each pinned and verified as described below.
- **Root**: `pkexec` runs `pacman` only to install `uv` or
  `tesseract-data-*` packages, and only after an explicit click.

## Supply chain

Everything the plugin installs after the initial `omarchy plugin add` is fixed
by the reviewed commit:

- **Engine code**: `lib/engines/<engine>.lock` is the complete dependency
  closure for Linux x86_64 / Python 3.12 with a SHA-256 for every wheel,
  compiled reproducibly (`lib/engines/EXCLUDE_NEWER`); the installer applies it
  with `uv pip sync --require-hashes --only-binary :all:`, so nothing outside
  the lock can be installed and no source build can run. A dependency that
  publishes no wheel is shipped as a reviewed, reproducibly built wheel in
  `lib/engines/wheels` (digests in `SHA256SUMS`, checked before `uv` runs).
- **Model artefacts**: `lib/engines/models.json` (EasyOCR, Kokoro) and
  `lib/piper-voices.sha256` (Piper voices) name fixed sources and digests:
  Kokoro and Piper files come from one immutable repository revision; EasyOCR
  archives come from fixed GitHub release-asset URLs, whose content is bound
  by the shipped digest (a re-uploaded asset fails closed). Downloads that do
  not match are discarded; library downloaders are never enabled and the
  Hugging Face hub client runs offline.
- **Engines from earlier releases**: each environment records the digest of
  the lock that built it; an environment without this release's digest is
  treated as not installed.
- **Privilege boundary**: `pkexec` and `pacman` are used at fixed canonical
  paths, verified root-owned and unwritable by others up to `/`, immediately
  before each call.

Residual trust roots: `uv` is used only at `/usr/bin/uv` from the
distribution's repository, runs with `--no-config` and without `UV_*`/`PIP_*`
overrides, and provides the Python 3.12 interpreter (the system's, or a
python-build-standalone build verified against checksums compiled into `uv`).
A distribution-installed `piper` on `PATH` is accepted when no managed engine
exists. PyPI, GitHub and Hugging Face can withhold a file but never substitute
one, since every artefact is bound by a digest in this repository.

`tools/pin-engines` and `tools/pin-piper-voices` regenerate these files so a
bump is a reviewable diff, and CI proves the locks apply and reproduce.
