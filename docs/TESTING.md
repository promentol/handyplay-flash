# Testing

Four harness layers + unit tests. Three read corpora that live under
git-ignored `reference/` (see SPEC.md); the fourth is ours, and it is
the only one that can test something ruffle's corpus does not cover.

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

## 5. The libretro core — `zig build libretro-test`

    ./zig-out/bin/libretro_test_host zig-out/libretro/flash_libretro.dylib \
        game.swf --frames 210 --hold a        # or --point 0.5,0.8

`frontends/libretro/test_host.zig` dlopens the core and drives it through
the real C ABI, so a wrong `callconv`, a missing export or a crash in
`retro_run` is caught without installing RetroArch. It runs the movie
twice — untouched, then pressed — and reports how many pixels differ.
`--hold` PULSES rather than holds, because a movie sees key events and a
button held from frame 1 gives exactly one edge (docs/LIBRETRO.md).
`--point x,y` drives the absolute pointer, `--reset-at N` exercises
RetroArch's Restart, and `--shell` keeps the intro and controls legend.

## 6. Audio

Two flags make silence testable without listening:

    trace_runner test.swf --frames N --audio        # pull the mixed samples
    handyplay-flash-sdl game.swf --headless-frames 300   # prints energy + sounds started

`--audio` on the trace runner must not change a single traced line — the
mixer's clock rule (docs/AUDIO.md) under test rather than asserted, and
it holds across all 694 corpus dirs. The headless SDL line reports the
sum of |sample| and how many `StartSound` tags were reached versus
played, which is what tells "never got there" from "decoded to nothing".

## 7. Save-states — three gates

    sh tests/conformance/savestate.sh  /tmp/ss.txt 8      # 195 of 195 dirs
    sh tests/conformance/games.sh      /tmp/games.txt 60  # 36 of 36 games
    sh tests/conformance/statebytes.sh /tmp/bytes.txt 8   # 655 of 659 dirs

`savestate.sh` runs every scorable multi-frame corpus dir twice —
straight through, and with a serialize/restore spliced in at the halfway
frame — and demands the traces match. `trace_runner --save-at N` is the
mechanism; it restores into a FRESH player, so anything the state forgot
shows up as diverging script output.

Build BOTH halves first — `zig build libretro` makes the core, and
`zig build libretro-test` makes the host that dlopens it. They are
separate steps, so building only the first leaves a stale host behind and
its measurements silently describe an older build.

`games.sh` and `statebytes.sh` both run `libretro_test_host --state N`,
which adds the four container gates: two saves byte-identical, the size
stable across a run, a re-save after a restore reproducing the blob, and
the one-frame delta a rewind layer would store. The re-save is the
strictest of the four and found nearly every bug in that work — it
catches a payload the state dropped even when the movie never reads it
back. The two differ only in what they run over: `games.sh` takes
`games/*.swf` (and prints each state's size and per-frame delta),
`statebytes.sh` takes the whole AVM1 corpus.

Four `statebytes` dirs fail for host reasons, not state reasons — see
docs/SAVESTATE.md.

## Static analysis helpers

`tools/avm1dis.py <file.swf>` disassembles every action blob, including
button condition actions and clip events. `tools/keymap.py <file.swf>`
answers "which keys does this movie handle?" without running it — the
same four sources `core/key_survey.zig` walks at load, so the two are
each other's check. `--sites` prints where each binding was found.

## Progress reporting

Every milestone ends by updating `docs/TAGS.md` + `docs/AVM1.md` statuses and
`tests/conformance/pass_list.txt`. The matrices + pass count are the public
progress report (linked from README).


## 4. Our own AS2 corpus — `tools/as2/as2.sh`

**What it is for.** Ruffle's corpus is large but it is not OURS: nothing in
it places an object with a blend mode, so workstream F shipped with no
test able to see it. This layer closes that hole — we write the
ActionScript, compile it, and run the result in BOTH players.

    sh tools/as2/as2.sh build              # the two images, once
    sh tools/as2/as2.sh record [case...]   # run RUFFLE, save expectations
    sh tools/as2/as2.sh check  [case...]   # run ours against them
    sh tools/as2/as2.sh run    [case...]   # record then check

A case is `tests/as2/<name>/` holding `Test.as` and `test.toml`. The
recorded `expected.png` / `expected.txt` are CHECKED IN, so `check` needs
neither Docker nor a network; `record` is the deliberate step.

**A case with no ActionScript.** Some things no compiler here can emit —
Flash Lite's opcode `0x2D` is the first. Such a case names a
`generator = "tools/…py"` in its `test.toml` instead of shipping a
`Test.as`, and the script writes `test.swf` directly. It also sets
`ruffle = false`, because ruffle has no 0x2D either: `record` skips it and
keeps the checked-in expectation, which is OURS and says so in the case's
own comments. `tests/as2/fscommand2` is the example.

**Two images, on purpose.** `tools/as2/compiler` is mtasc — the AS2
compiler ruffle's own CONTRIBUTING recommends — built from source,
because there is no Debian package and the 2007 binaries are 32-bit x86.
141 MB, offline. `tools/as2/runner` is ruffle's PREBUILT web bundle in
headless Chromium; building ruffle's native exporter would mean the whole
Rust workspace, and the wasm is a 10 MB download running the same core.

**Two things about the runner that are not obvious:**

- **Ruffle loads PAUSED.** Its own selfhosted tests call `resume()` after
  attaching the trace observer. Without it the movie never runs a frame.
- **The renderer must be WEBGPU.** Ruffle's plain WebGL backend implements
  Normal, Add and Subtract and silently falls back to Normal for
  everything else (`render/webgl/src/lib.rs`, "TODO: Unsupported blend
  mode"). A comparison run on it agrees about nothing while appearing to
  agree about everything.

Traces come from the console rather than `traceObserver`, which never
fires here; `trace()` also goes through `tracing` from
`web/src/log_adapter.rs`, and that channel works.

**Writing a case.** mtasc type-checks, so mixed-type arithmetic — half
the point of a coercion test — has to be laundered through an untyped
helper (`dyn()` in `avm1_core`). `on` is a keyword and cannot be a
variable. Ruffle is driven on a WALL CLOCK, so a case should settle on
its first frame and hold still.

**What the thresholds mean.** `tolerance` is per channel and
`max_outliers` counts channel differences over it. They are set from
MEASUREMENT, not taste, and each case says what was measured — total ink
per shape, which cells agree, what the worst pixel is. Two cases are
KNOWN DIVERGENCES and say so in their own source: `erase` inside a layer
(the reference drops the whole box where we knock a hole) and a stroke
under a non-uniform scale (Flash carries an elliptical pen through the
transform; we stroke in device space with a round one and lay down ~30%
more ink on a diagonal).
