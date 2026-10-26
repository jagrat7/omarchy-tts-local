# mpv playback experiment

Worktree: `/home/jagrat/.t3/worktrees/omarchy-tts/t3-5002f5f0`  
Branch: `exp/playback-mpv-sol`

The CLI implements pause/resume/toggle, persisted live rate, and bounded
now-playing state. The controller polls only while its panel is open and
speech is active, queues reads and controls, and keeps speaking true while
paused. The bar exposes status; Keys includes an unbound Pause / resume row.

Playback uses one private socket per utterance. IPC validates both the
speech owner and player PID/start time/group, then checks Unix peer
credentials. The speech lock serializes commands against Stop/replacement.
Text is limited to 4096 characters in an atomic mode 0600 runtime file;
completion and Stop remove it. Fallback pw-cat/aplay speech remains usable,
with unsupported controls reported as false and live rate applied next time.

mpv ignores user config/scripts, uses lavf's s16le demuxer, a 40 ms audio
buffer, and scaletempo2 with a 10 ms search interval. The default 40 ms
search distorted repeated test tones even in a fully buffered file-only
experiment; 10 ms preserved their periods. The filter retains pitch as
specified in the [mpv manual](https://mpv.io/manual/stable/#audio-filters).

## Measurements

The unchanged benchmark from `exp/playback-bench` ran three trials against
this checkout. All sound went to a dedicated null sink, with exclusive-link
proofs, isolated XDG state, no default-sink changes, and verified sink/stream
removal. Numbers are rough: the recording timebase error estimate is about
38 ms. The pw-cat comparison reuses the benchmark agent's three-trial base
result at `/tmp/tts-bench-base-final.json`.

| Measurement | Result |
| --- | ---: |
| First audio, mpv median (range) | 228 ms (227–236) |
| First audio, base pw-cat median | 144 ms |
| Startup difference | +84 ms |
| Pause median | 30 ms |
| Resume median | 68 ms |
| Pause/resume tone-time difference | 0 ms; all 48 beeps retained in every trial |
| Live 2×, fast producer, one trial | 136 ms; subsequent periods passed |
| Stop speaking / paused median, all processes gone | 228 / 242 ms |
| Playback CPU median / paused median | 1.2% / 0.0% |

The unchanged benchmark's producer supplies only about 1.25× real time.
It accepts the 2× command (`applied: live`) and initially reaches 2×, then
underruns; its sustained-rate correctness check fails, so that run has no
valid live-rate latency. The separate fast-producer run changed only its
chunk sleep multiplier from 0.8 to 0.1 in a private copy under `/tmp`, and
passed the same detection logic. This result does not replace the unchanged
benchmark result.

Reproduction artifacts on this machine:

- `/tmp/tts-mpv-sol-optimized-bench.json` — unchanged benchmark, three trials.
- `/tmp/tts-mpv-sol-optimized-fast-bench.json` — faster producer, one trial.
- `/tmp/tts-mpv-sol-fast-bench` — private copy with the producer adjustment.
- `/tmp/tts-mpv-sol-keys.png` — inspected offscreen Keys screenshot.

## Verification and limitations

`python3 -m unittest discover -s tests` passed 228 tests with one existing
skip. ShellCheck 0.11.0 passed the full documented command. The suite emits
an existing subprocess ResourceWarning; that process had already exited
when inspected. Tests include actual mpv with file-only PCM output: the
1.5 s fixture produced exactly 36,000 samples and its final 458 ms were all
zero, confirming the raw-demuxer EOF garbage is absent. No real audio sink
is used by this test. A final `pgrep -a` filtered to all isolated benchmark
runtimes found no remaining players, generators, or engines.

Duration is estimated at 15 characters/second, never below elapsed; mpv's
pipe duration is only a partially buffered length and cannot provide a
reliable total. Elapsed uses mpv audio PTS times the original synthesis
rate, a normal-rate content timeline suitable for approximate text progress.
The estimate varies with language, voice, punctuation, and the provider.

Live speed cannot outrun synthesis indefinitely, and aggressive changes
may underrun a slow provider. Fallback players deliberately offer neither
pause nor live speed: pausing an entire process group would complicate
Stop and provider ownership. Older mpv/FFmpeg versions and the installed
Kokoro voice were not independently benchmarked. A process killed with
SIGKILL cannot run cleanup; a subsequent Stop or utterance clears its
remaining runtime metadata. The full Overview redesign is outside this
backend experiment.
