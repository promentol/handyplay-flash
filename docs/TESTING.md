# Testing

Three harness layers + unit tests. All corpora live under git-ignored
`reference/` (see SPEC.md); nothing is vendored.

## 1. Parser corpus (M1) — `tests/parse_corpus.sh`

Runs `swfdump` over `reference/ruffle/swf/tests/swfs/*.swf` (56 files, one
minimal SWF per tag, `.fla` sources checked in upstream). Exit criteria: zero
fatal parse errors — unknown/out-of-scope tags are *reported*, not fatal.
Spot-check correctness by diffing `swfdump` output against the expected
structs in `reference/ruffle/swf/src/test_data.rs`.

## 2. AVM1 conformance (M3+) — `tests/conformance/run_avm1.sh`

The acceptance suite: `reference/ruffle/tests/tests/swfs/avm1/` — 697 dirs of
`test.swf` + `output.txt` (expected `trace()` output, line-exact) + `test.as`
(recompilable source). ~90% are pure trace tests; no renderer needed.

- `tools/trace_runner` loads test.swf headless, runs N frames (default: the
  movie's frame count, overridable), prints trace() lines to stdout.
- The script diffs stdout against `output.txt` exactly.
- **`pass_list.txt` is a committed ratchet**: every dir that passes gets a
  line; CI (and every milestone) re-runs the list and **a passing entry may
  never be removed** — regressions fail loudly. New passes are appended.
- `known_skip.txt` lists dirs requiring out-of-scope features (AVM2, video,
  network, filters) with a reason column.
- Determinism requirements this imposes: fixed timestep, seeded rng
  (RandomNumber), fake clock (GetTime), stable trace formatting of numbers
  (ES3 ToString(Number) — implement exactly).

Targets: M3 ≥ 80, M4 ≥ 300, M7 ≥ 450 passing dirs.

## 3. Visual + frontend checks

- SDL: launch in background with **no timeout** for user visual confirmation
  (squares.swf in M2, homestuck-beta.swf in M4, morph.swf in M7).
- `--headless-frames N` renders N frames without a window and dumps the
  framebuffer (PNG/raw) for automated before/after comparisons.
- libretro (M5): `test_host` dlopens the core, runs frames, serializes,
  restores, re-runs — framebuffers must be **byte-identical** (the same
  determinism gate the other handyplay cores use). Then a manual RetroArch
  load to check geometry/fps/input.

## 4. Unit tests — `zig build test`

Per-module `test` blocks: reader bit-level roundtrips, LE32_FLOAT64 encoding,
ES3 coercion tables (value.zig), matrix/cxform math, rasterizer scanline
fixtures (known polygon → known coverage), ADPCM known-vectors (M6). Model:
ruffle's `swf/src/test_data.rs` (raw bytes ↔ expected struct pairs).

## Progress reporting

Every milestone ends by updating `docs/TAGS.md` + `docs/AVM1.md` statuses and
`tests/conformance/pass_list.txt`. The matrices + pass count are the public
progress report (linked from README).
