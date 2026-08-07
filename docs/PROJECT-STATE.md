# handyflash — Project State & Handover

**Authoritative snapshot. Last updated: 2026-08-07 (M3 close).**
Read this first if you are picking up the project with no prior context.
For executing the next milestone, then read `docs/M4-SPEC.md`.

---

## 0. What this is

A **Flash Player written from scratch in Zig 0.16**, AVM1 only (SWF v4–v8,
ActionScript 1/2). AVM2/AS3 files are detected and rejected by design.
Standalone git repo at `/Users/narekh/Projects/notconsole/handyflash`
(`main` branch, commit directly — user convention, no feature branches).

It is shaped like the user's other emulator cores in
`../handyplay-oss/` (exen/java/mophun/mre/mrp): `core/` is
frontend-agnostic, frontends are thin. The long-term goal is to become
their **6th core** (libretro + the libretro-web wasm player), which is why
the framebuffer is XRGB8888 and the milestone plan ends with a libretro
frontend. It is standalone (not inside handyplay-oss) because that
monorepo is pinned to zig **0.15.2** while this project uses **0.16**.

### Status

| Milestone | Deliverable | State |
|---|---|---|
| M0 | repo + specs + `swfinfo` | ✅ `5317018` |
| M1 | full tag parser + `swfdump` | ✅ `ef7ff0c` (56/56 corpus clean) |
| M2.0 | vendor simdra | ✅ |
| M2 | display list + timeline + renderer + SDL3 | ✅ **first pixels** |
| M3 | full AVM1 interpreter + conformance harness | ✅ `d12cb3a` (**76/697**) |
| M4 | objects/stage/buttons/text/bitmaps | 🔶 A1 done (**92/696**); B–F open |
| M5 | libretro core + save-states | ⬜ |
| M6 | audio | ⬜ |
| M7 | polish (morph/masks/EditText/filters) | ⬜ |

**Visually working today**: `squares.swf` and `homestuck-beta.swf` render
correctly (shapes, curves, strokes, gradients, layering, timeline).
**Scripting today**: every AVM1 opcode executes and the display-property
table is live (`_x`, `_alpha`, `_rotation`, … via both `getProperty` and
`mc._x`); 92 of Ruffle's 696 conformance tests pass.

---

## 1. Environment (READ THIS FIRST — costly to rediscover)

- **Zig 0.16 ONLY**: `~/.zvm/0.16.0/zig`. Plain `zig` on PATH is 0.15.2
  and will fail confusingly (std.Io/std.fs were rewritten in 0.16).
  - `zig build` (tools) · `zig build test` · `zig build sdl` ·
    `zig build run-sdl -- file.swf` · `-Doptimize=ReleaseFast`
  - The 0.16 build runner WORKS on this machine. (0.15.2's is broken —
    it can't link host libc — which is why handyplay-oss uses raw
    `zig build-obj`. That does **not** apply here.)
- **0.16 std idioms used** (differ from every pre-0.16 example):
  - CLI entry: `pub fn main(init: std.process.Init) !u8` →
    `init.gpa`, `init.io`, `init.arena`, `init.minimal.args.toSlice(arena)`
  - Files: `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))`
  - Stdout: `std.Io.File.stdout().writer(io, &buf)` → `.interface`, flush
  - Readers/writers: `std.Io.Reader.fixed(bytes)`,
    `std.Io.Writer.Allocating` (give it capacity before flate Compress —
    it asserts buffer > 8)
  - flate: `std.compress.flate.Decompress.init(&reader, .zlib, &window)`
    then `.reader.streamRemaining(&writer)`
  - `std.ArrayList` is unmanaged: `.empty`, `append(allocator, x)`
- **SDL3** from Homebrew (`/opt/homebrew/{include,lib}`). Do **not**
  call `SDL_SetMainReady` (we don't include SDL_main.h).
- **Reference clones** (git-ignored, must exist at `reference/`):
  - `reference/ruffle/` — the behavior authority for everything
  - `reference/openflash/` — open-flash spec site + sample SWFs
  - If missing: clone ruffle-rs/ruffle and the open-flash repos there.

### ⚠️ The zig test-collection trap (cost 6 silent test failures)

Zig only compiles `test` blocks from files reached by a **test-context**
import. `core/flash.zig`'s root `test` block therefore **explicitly
imports every test-bearing file**. `refAllDecls` alone is NOT enough —
it silently dropped all display/render/avm1 tests from the binary, and
they had been "passing" by never running. **Add new test-bearing files
to that list.**

### Test-fixture gotchas (hit repeatedly)

- SWF **signed** bit-fields need the sign bit: +200 needs 9 bits, not 8.
- `comptime` float math folds in f128 — use runtime vars when a test
  depends on f64 rounding (`var x: f64 = 0.1; x += 0.2;`).
- simdra AA coverage rounds ±1 LSB — pixel assertions need tolerance ≥2.

---

## 2. Repository map

```
handyflash/
├── build.zig                 modules: flash (core) + simdra (vendored); steps: tools/test/sdl
├── core/
│   ├── flash.zig             UMBRELLA + Player (host seam) + the root test-import list
│   ├── swf/                  PARSER (M1) — pure decoding, zero interpretation
│   │   ├── decompress.zig    FWS/CWS (ZWS/LZMA deferred, ADR D4)
│   │   ├── header.zig        stage rect / frame rate / frame count
│   │   ├── reader.zig        bit+byte reader (UB/SB/FB, RECT, MATRIX, CXFORM, LE32_FLOAT64)
│   │   ├── tags.zig          TagCode enum + tolerant scanner
│   │   ├── shape.zig         DefineShape1-4 (styles + edge records)
│   │   ├── font_text.zig     DefineFont1-3, FontInfo, DefineText1-2, DefineEditText
│   │   ├── button.zig        DefineButton1-2 + ButtonCondActions
│   │   ├── bitmap_tags.zig   raw payload capture (decode is M4)
│   │   ├── sound_tags.zig    DefineSound/StartSound/SoundStreamHead (playback M6)
│   │   ├── place.zig         PlaceObject1-3 + ClipActions, RemoveObject1-2
│   │   ├── filters.zig       FILTERLIST exact skipping
│   │   └── movie.zig         two-pass preload → Movie{lib, frames[]}
│   ├── display/
│   │   ├── library.zig       character dict + per-frame Control lists
│   │   ├── display_object.zig placed instance state
│   │   └── movie_clip.zig    timeline: runFrame / goto rewind+replay / action QUEUEING
│   ├── avm1/                 THE INTERPRETER (M3)
│   │   ├── opcodes.zig       full 0x00-0x9F decoder (allocation-free)
│   │   ├── string.zig        UCS-2 AvmString + ascii() + case folding
│   │   ├── value.zig         Value + exact ES3 coercions + JS number formatting
│   │   ├── object.zig        handle-table ScriptObject, accessors, version-gate attrs
│   │   ├── runtime.zig       Vm: stack/registers/pools/protos/Host hooks/calls
│   │   ├── activation.zig    linear dispatch (the big one, ~1000 lines)
│   │   └── globals/globals.zig  Object/Function/Array/String/Number/Boolean/Math/Error/…
│   └── render/
│       ├── shape_utils.zig   SWF dual-edge records → DrawPath IR (port of ruffle)
│       ├── renderer.zig      display-tree walk → simdra
│       └── canvas.zig        BGRA surface; pixels() IS the libretro framebuffer
├── frontends/sdl/main.zig    windowed playback + --headless-frames N PNG dump
├── tools/                    swfinfo · swfdump · trace_runner
├── tests/
│   ├── parse_corpus.sh       swfdump over ruffle's 56 tag SWFs (M1 gate)
│   └── conformance/          run_avm1.sh + pass_list.txt (ratchet) + known_skip.txt
├── vendor/simdra/            vendored rasterizer (MIT, the user's own lib)
└── docs/
    ├── PROJECT-STATE.md      ← you are here
    ├── M4-SPEC.md            next milestone, fully specified for handover
    ├── ARCHITECTURE.md       module map, frame lifecycle, memory model
    ├── SPEC.md               the spec stack (what to read for what)
    ├── AVM1.md               per-opcode status + the 11 stubs
    ├── TAGS.md               per-tag status
    ├── TESTING.md            harness design
    └── DECISIONS.md          ADRs D0–D7 + risks
```

---

## 3. How it works (the 60-second version)

**Load** (`swf/movie.zig`): decompress → parse header → walk the tag
stream ONCE. Definition tags decode eagerly into a character `Library`;
control tags are indexed per frame. `DefineSprite` recurses. Everything
is allocated from one arena owned by the `Movie`, and every parsed struct
holds **slices into the decompressed buffer** (no copies). AVM2 (DoABC or
`FileAttributes.AS3`) → `error.Avm2Unsupported`.

**Per frame** (`Player.runOneFrame` in `core/flash.zig`):
1. `root.runFrame(ctx)` — timeline advances (implicit stop on 1-frame
   clips, loop past end), control tags execute; `DoAction` bodies are
   **queued**, never run inline.
2. `root.applyPendingGoto(ctx)` — deferred gotos rewind/replay.
3. Drain the queue: each entry runs an `Activation` with `this` = the
   clip's AVM object and `scope` = that same handle (**clip objects
   double as timeline variable scopes**; `scope_parent = 0` so lookup
   falls through to `_global`). Gotos re-apply between entries.
4. Render (dirty-flagged): walk the display tree back-to-front,
   concatenating twips matrices and 8.8-fixed cxforms straight into
   simdra paints.

**Interpreter** (Ruffle model, ADR D0): a byte reader over the action
slice; `If`/`Jump` seek the reader; running off the end is an implicit
return; a shared budget (200k actions/frame) guards runaway scripts.

**Clip ⇄ VM linkage**: `MovieClip.avm_object: u32` (lazily created in
`Player.clipObject`); the ScriptObject's `native = .{ .clip = *MovieClip }`.
Movie control (play/stop/goto) flows through `Vm.Host` function pointers
installed by `Player.installHost`.

---

## 4. Key decisions and why (full ADRs in docs/DECISIONS.md)

| # | Decision | Rationale |
|---|---|---|
| D0 | **Ruffle-style linear interpreter**, not open-flash's CFG | battle-tested, far simpler; open-flash's per-action docs still drive semantics |
| D1 | Runtime strings are **[]u16 UCS-2** | `String.length`/`charCodeAt` are code-unit based; corpus has non-ASCII |
| D2 | Objects in a **handle table** (u32), arena-allocated, no GC yet | save-states become a table walk; no pointer invalidation |
| D3 | JPEG via **simdra's stb** (amended from pure-Zig) | also gets PNG/GIF (legal in DefineBitsJPEG2 v8+); we still own SWF stream surgery |
| D4 | **LZMA/ZWS deferred** | SWF ≥13 only, outside AVM1-era scope; std has lzma when wanted |
| D5 | Save-states: own **HFS0 TLV**, LSO excluded | rewind must not un-write persistence |
| D6 | **AGPL-3.0** (+ commercial dual) | matches handyplay-oss — ⚠️ **user must confirm before public release** |
| D7 | **Rasterizer = vendored simdra**, not neonGL | simdra had 90% of what SWF needs; neonGL is fixed-function GL ES 1.1 (wrong abstraction for winding-rule vector fills) |

---

## 5. simdra (the rasterizer) — a sibling project that was extended FOR this

`vendor/simdra/` is a vendored copy of the user's own MIT-licensed npm
package **simdra** (`github.com/promentol/simdra`, source of truth at
`../handyplay-oss/vendor/simdra`). During this project it was extended
with everything Flash needs and **published as 0.2.0** (commits
`8134b50..256b243`, pushed).

Flash-driven features added upstream:
- **Per-paint ColorTransform** (SWF CXFORM: 8.8-fixed mult + add incl.
  alpha) — layout is byte-identical to our parsed CXFORM, so it passes
  through untouched
- **Gradient spread modes** pad/repeat/reflect (+ JS `setSpread`)
- **Bilinear pattern sampling** (`SmPattern.setFilter`)
- **SkColorType surfaces**: `bgra8888` = little-endian XRGB8888 =
  **zero-copy libretro present**
- **Flash blend modes** `flash_{subtract,invert,alpha,erase}`
- **`colorMatrixU32`** (ColorMatrixFilter primitive)
- **Opt-in gradient ramp LUT** + gradient/pattern benchmarks

Invariants when touching it: JS API compatibility is a hard constraint
(543/543 JS tests must stay green); add defaulted fields and new setters,
never new positional params on existing factories. Run its tests with
`PATH="$HOME/.zvm/sdk-shim:$PATH" npm test` (it builds with zig 0.15.x
via node-zigar; the core also compiles clean under 0.16).

**Open item for the user: `npm publish` of 0.2.0 has NOT been done.**

Known perf note: gradient/pattern fills are the slowest path
(7.1ms/800×600 linear gradient native vs Skia's 1.4ms) — tracked, with
SIMD row samplers as the recorded follow-up. Pattern fills already beat
Skia.

---

## 6. Workflows

```sh
# build & test
~/.zvm/0.16.0/zig build test          # unit tests (50/50)
~/.zvm/0.16.0/zig build               # tools → zig-out/bin/
~/.zvm/0.16.0/zig build sdl           # SDL3 frontend

# look at a SWF
./zig-out/bin/swfinfo file.swf
./zig-out/bin/swfdump file.swf        # stable, diffable tag dump
sh tests/parse_corpus.sh              # M1 gate: 56/56 clean

# render
zig build run-sdl -- file.swf                          # windowed
./zig-out/bin/handyflash-sdl file.swf --headless-frames 30 --out x.png

# AVM1 conformance
sh tests/conformance/run_avm1.sh              # full run (SLOW serially)
sh tests/conformance/run_avm1.sh <dir>        # one test + diff
sh tests/conformance/run_avm1.sh --ratchet    # regression check vs pass_list
sh tests/conformance/run_avm1.sh --update     # rewrite pass_list.txt
```

### ⚠️ Fast corpus runs (10 min → 40 s)

Build ReleaseFast and parallelize; the serial shell loop is unusably
slow. Recipe (recreate in a scratch dir):

```sh
# conf.sh <results-file> <test-dir-name>
CORPUS=reference/ruffle/tests/tests/swfs/avm1; BIN=./zig-out/bin/trace_runner
n=$(sed -n 's/^num_frames *= *\([0-9]*\).*/\1/p; s/^num_ticks *= *\([0-9]*\).*/\1/p' \
    "$CORPUS/$2/test.toml" | head -1); [ -n "$n" ] || n=1
got=$(timeout 10 "$BIN" "$CORPUS/$2/test.swf" --frames "$n" 2>/dev/null)
[ "$got" = "$(cat "$CORPUS/$2/output.txt")" ] && echo "PASS $2" >>"$1" || echo "FAIL $2" >>"$1"
```
```sh
~/.zvm/0.16.0/zig build -Doptimize=ReleaseFast
ls $CORPUS | grep -v __framework__ | xargs -P 8 -I{} sh conf.sh results.txt {}
grep -c PASS results.txt
```

**Method that works**: full run → bucket failures by their first diff
line (`sort | uniq -c | sort -rn`) → fix the biggest bucket → repeat.
Also rank by diff size to find near-misses. When a diff is confusing,
**read the test's `test.as`** — the corpus ships each test's source.

---

## 7. What's done, precisely

**Parser (M1)** — every in-scope tag decodes; ruffle's 56-SWF tag corpus
scans with zero errors; spot-verified against `swf/src/test_data.rs`.

**Renderer (M2)** — shapes with solid/linear/radial/focal-gradient fills
and strokes (caps/joins/miter, 1px hairline minimum), cxform, sprite
nesting. Masks/bitmaps/text are M4/M7.

**Interpreter (M3)** — all ~100 opcodes decode and execute. Notable
correctness work verified against Ruffle: SWF-version coercion rules
(undefined→"" below v7, bool→"1"/"0" below v5, with `trace` as the
documented exception), NaN==NaN true, constructor-vs-function duality,
array holes/own-only element reads, `__proto__` accessor, `addProperty`
getters/setters, ASSetPropFlags **version-gate bits**, SetTarget
retargeting, DoInitAction at Initialize priority, proto-chain `for..in`,
goto rewind survival, no double-tick of newly placed clips.

**Documented stubs (10)** — listed with rationale in `docs/AVM1.md`.
Chief among them: TargetPath, CloneSprite, StartDrag, `Call`. Some are
also no-ops in Ruffle (StrictMode, FsCommand2, and WaitForFrame which is
behaviorally identical for local files).

**M4 workstream A1 (display properties)** — the 22-entry table lives in
`core/avm1/stage_object.zig`, the one file under `core/avm1/` that imports
`core/display/`. Three things there are load-bearing and easy to undo by
accident:
- the table's ORDER is the SWF4 property index;
- scale/rotation are a CACHED decomposition on `DisplayObject`, stored in
  percent/degrees exactly as ActionScript set them (re-deriving from the
  matrix drifts, and `stage_property_representation` checks 300 exact
  round-trips);
- `DisplayObject.transformed_by_script` makes the timeline stop
  re-applying PlaceObject to script-moved objects.

---

## 8. What's next

**M4 is fully specified in `docs/M4-SPEC.md`** — six workstreams
(interpreter stubs → MovieClip methods/globals → events+buttons → text →
bitmaps → blend modes), each with exact semantics and the authoritative
Ruffle reference file, plus the M3 failure clusters and a near-miss hit
list. Gate: **≥300/697**.

Then: **M5** libretro core + HFS0 save-states (byte-identical
serialize→restore→re-run gate; copy the ABI from
`../handyplay-oss/java-core/frontends/libretro/libretro.zig`) ·
**M6** audio (ADPCM/PCM → minimp3 → SoundStreamBlock sync) ·
**M7** polish (morph shapes, EditText, clipDepth masks — simdra's
`clipPath` is ready — PlaceObject3 filters/blend modes).

Afterwards, adoption into handyplay-oss: a `build-cores.sh` entry, the
libretro-web 6th-core registration, and optionally migrating save-states
to their `common/statefmt.zig` (`flash_core = 7` is reserved there).

### Open items for the user
1. **`npm publish` simdra 0.2.0** (code is pushed; publish is not done)
2. **Confirm AGPL-3.0** (ADR D6) before any public release
3. The 4-test gap between M3's 76 and its 80 target — folded into M4

---

## 9. Working preferences observed

- Commit directly on `main`, no feature branches.
- When showing visual output, launch the SDL player **in the background
  with no timeout** and leave it open for inspection.
- Prefers Zig + stdlib over dependencies; vendored C (stb, minimp3) is
  the sanctioned exception.
- Wants real implementations, not host-side fakes or hardcoded shortcuts.
- Replace cleanly when changing approach — don't keep both paths.
