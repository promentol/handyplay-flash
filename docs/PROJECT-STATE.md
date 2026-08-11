# handyplay-flash — Project State & Handover

**Authoritative snapshot. Last updated: 2026-08-10 (workstream L close, then a long semantics sweep — closures, coercions, SWF4 rules, the ASnative tables and the missing global classes — and then the last 54 dirs, one at a time: 679/679, the whole scorable corpus. Then the AS2 authoring pipeline, and Flash Lite: `fscommand`, `fscommand2`, the player profile and the soft-key strip.)**
Read this first if you are picking up the project with no prior context.
For executing the next milestone, then read `docs/M4-SPEC.md`.

---

## 0. What this is

A **Flash Player written from scratch in Zig 0.16**, AVM1 only (SWF v4–v8,
ActionScript 1/2). AVM2/AS3 files are detected and rejected by design.
Standalone git repo at `/Users/narekh/Projects/notconsole/handyplay-flash`
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
| M4 | objects/stage/buttons/text/bitmaps | ✅ every workstream closed — A, B, C, D, E, F, L (**679/679** traces, images **21/26**) |
| M5 | libretro core + save-states | ✅ **core PLAYING in RetroArch** (universal macOS dylib, pad bound by the key survey, per-movie bindings as core options) and **save-states + rewind ON by default**: 36/36 games, 195/195 multi-frame corpus dirs, 655/659 byte gates (docs/SAVESTATE.md) |
| M6 | audio | 🔶 **event sounds, streams, PCM/ADPCM/MP3 and FLV audio play**; Nellymoser/Speex deliberately silent |
| M7 | polish (morph/masks/EditText/filters) | ⬜ |

**Visually working today**: `squares.swf`, `homestuck-beta.swf`,
`homestuck-beta2.swf` and `shumway-3.swf` render correctly — shapes,
curves, strokes, gradients, layering, timeline, and now the embedded
bitmaps (every `DefineBits*` family) that used to paint as gray boxes.
**Scripting today**: every AVM1 opcode executes and the whole
`MovieClip` class surface is live — timeline control, hit tests
(shape-exact), bounds, coordinate conversion, drag. `Date`, `flash.geom`,
`Object.registerClass`, `watch`, `setInterval`, `AsBroadcaster` and the
Key/Mouse/Stage/System/Color singletons all exist, and the frontend feeds
real mouse and keyboard input.
**Interactive today**: buttons draw, hit-test and react — rollOver,
press, release, releaseOutside, drag in and out, keyPress, and the state
changes that go with them; clips with mouse handlers behave the same way.
Focus, `Selection`, and Tab ordering work.
**Text today**: static text and text fields both render glyphs; a field
is a real instance with formatting spans, HTML in and out, wrapping and
alignment, autosize, scrolling, a two-way `variable` binding, a
selection, and typing through the full editing-command set.
**Bitmaps today**: `flash.display.BitmapData` is complete apart from
Perlin noise and filters — build, fill, flood, scroll, noise, colour
transform, channel copy, merge, threshold, compare, hit-test, colour
bounds, pixel dissolve, both forms of `copyPixels`, `paletteMap`, plus
`attachBitmap`, `beginBitmapFill`, `loadBitmap` and `draw` — including
Perlin noise, a ColorMatrixFilter through `applyFilter`, and blend modes.
Every one of Ruffle's 679 scorable conformance dirs passes, and 12 of
its 26 runnable image comparisons; EVERY bitmap dir passes both.
**XML today**: `XML` and `XMLNode` in full — parse, build, walk, clone,
reparent, serialise, namespaces, `idMap`, the lot — over a hand-written
UTF-16 parser. Everything but `load`/`sendAndLoad`, which need I/O.
**Filters today**: every class, every property coercion, and
PlaceObject3's filter list decoded and readable — but only
`ColorMatrixFilter` is actually APPLIED (M7 owns the kernels).
**Loading today**: a movie can fetch. `loadVariables`, `LoadVars`,
`XML.load`/`sendAndLoad`, `loadMovie`/`loadMovieNum`, `unloadMovie`,
`MovieClipLoader` with its full event sequence, `XMLSocket`, and
`flash.net.FileReference`/`FileReferenceList`. A loaded SWF brings its
OWN library, version and timeline; `_level1` and up are real, ticking
and rendering above the root; a GIF/JPEG/PNG loaded into a clip becomes
its only child. `core/` still does no I/O — every one of those goes
through `Player.Options.load_file` and completes at the END of the tick,
which is exactly why `LoadVars.loaded` reads false right after `load()`
returns.
**ExternalInterface today**: the whole marshalling surface (`_toXML`,
`_toAS`, `_escapeXML`, `_jsQuoteString` and friends). The bridge itself
needs a browser and is not here.

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
handyplay-flash/
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
│   │   ├── sound_tags.zig    DefineSound/StartSound/SoundStreamHead (played, M6)
│   │   ├── place.zig         PlaceObject1-3 + ClipActions, RemoveObject1-2
│   │   ├── filters.zig       FILTERLIST exact skipping
│   │   └── movie.zig         two-pass preload → Movie{lib, frames[]}
│   ├── display/
│   │   ├── library.zig       character dict + per-frame Control lists
│   │   ├── display_object.zig placed instance state
│   │   ├── bounds.zig        self/world bounds, shape-exact hit tests
│   │   ├── drawing.zig       the script drawing API's geometry
│   │   ├── button.zig        a button as a CONTAINER: states + hit area + cond actions
│   │   ├── mouse.zig         picking + the roll/press/release state machine
│   │   ├── tab.zig           tab order: custom by tabIndex, automatic by 6y+x
│   │   ├── text.zig          static DefineText: the sticky-state glyph walk
│   │   ├── font.zig          face metrics, kerning, `evaluate` (the layout primitive)
│   │   ├── text_layout.zig   spans → lines and boxes: wrap, align, tabs, autosize
│   │   ├── edit_text.zig     a TEXT FIELD instance: spans, selection, input, layout cache
│   │   ├── device_font.zig   a host TTF as a face, in EM units (via simdra)
│   │   └── movie_clip.zig    timeline: runFrame / goto rewind+replay / action QUEUEING
│   ├── avm1/                 THE INTERPRETER (M3)
│   │   ├── opcodes.zig       full 0x00-0x9F decoder (allocation-free)
│   │   ├── string.zig        UCS-2 AvmString + ascii() + case folding
│   │   ├── value.zig         Value + exact ES3 coercions + JS number formatting
│   │   ├── object.zig        handle-table ScriptObject, accessors, version-gate attrs
│   │   ├── runtime.zig       Vm: stack/registers/pools/protos/Host hooks/calls
│   │   ├── activation.zig    linear dispatch (the big one, ~1000 lines)
│   │   ├── stage_object.zig  display properties, paths, focus — the only
│   │   │                     file under avm1/ that imports display/
│   │   ├── timers.zig        setInterval / setTimeout
│   │   ├── text_binding.zig  TextField.variable, both ways, stored on the TARGET
│   │   └── globals/          globals.zig · decl.zig · movie_clip.zig · geom.zig
│   │                         date.zig · singletons.zig · selection.zig
│   │                         text_field.zig · text_format.zig · text_snapshot.zig
│   │                         style_sheet.zig · filters.zig · bitmap_data.zig
│   │                         loader.zig (LoadVars + the form codec +
│   │                         MovieClipLoader) · socket.zig (XMLSocket) ·
│   │                         file_reference.zig · external.zig
│   ├── bitmap/               PIXELS — no display, no interpreter
│   │   ├── pixels.zig        Color, the premultiply pair (a LOOKUP TABLE
│   │   │                     going back), Lehmer RNG, version size limits
│   │   ├── data.zig          BitmapData: the buffer and the two flags
│   │   ├── operations.zig    every pixel op, and PixelRegion — the one
│   │   │                     place source→destination clipping lives
│   │   └── decode.zig        DefineBits* → RGBA (stb for JPEG/PNG/GIF,
│   │                         inflate + de-swizzle for lossless)
│   ├── text/                 THE TEXT MODEL — no display, no interpreter
│   │   ├── format.zig        TextFormat: 19 tri-state properties
│   │   ├── spans.zig         FormatSpans: resolved runs over the text
│   │   └── html.zig          Flash's HTML in and out
│   └── render/
│       ├── shape_utils.zig   SWF dual-edge records → DrawPath IR (port of ruffle)
│       ├── renderer.zig      display-tree walk → simdra
│       └── canvas.zig        BGRA surface; pixels() IS the libretro framebuffer
├── frontends/sdl/main.zig    windowed playback + --headless-frames N PNG dump
├── tools/                    swfinfo · swfdump · trace_runner
│   ├── avm1dis.py            AVM1 disassembler, RECURSES into fn bodies
│   ├── swfstruct.py          timeline structure (frames/places/sprites)
│   ├── dumptext.zig          fonts and text tags in a movie, for diagnosis
│   └── pngdiff.py            visual gate: pixel diff + bounding box, and
│                             ruffle's per-channel outlier rule for images.sh
├── tests/
│   ├── parse_corpus.sh       swfdump over ruffle's 56 tag SWFs (M1 gate)
│   └── conformance/          run_avm1.sh + sweep.sh (parallel) +
│                             pass_list.txt (ratchet) + known_skip.txt +
│                             images.sh + image_pass_list.txt (a SECOND,
│                             independent score for PNG comparisons)
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
return; a shared budget (5M actions/frame) guards runaway scripts.

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
| D2 | Objects in a **handle table** (u32), arena-allocated; **mark-sweep GC** at frame boundaries (`core/avm1/gc.zig`) | save-states are a table walk; no pointer invalidation. The collector landed when a state measured 36 MB: nothing had ever been freed, and `AntiMosquito` held 448,996 slots after sixty frames |
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
./zig-out/bin/handyplay-flash-sdl file.swf --headless-frames 30 --out x.png

# AVM1 conformance
sh tests/conformance/run_avm1.sh              # full run (SLOW serially)
sh tests/conformance/run_avm1.sh <dir>        # one test + diff (dir may be nested,
                                              #   e.g. target_paths/swf4)
sh tests/conformance/run_avm1.sh --ratchet    # regression check vs pass_list
sh tests/conformance/run_avm1.sh --update     # rewrite pass_list.txt
```

### ⚠️ Fast corpus runs (10 min → 21 s)

Now committed — `tests/conformance/sweep.sh` (the recreate-it-yourself
recipe that used to live here is gone; the script IS the recipe):

```sh
~/.zvm/0.16.0/zig build -Doptimize=ReleaseFast      # REQUIRED first
sh tests/conformance/sweep.sh /tmp/r.txt            # prints "679 of 679"
grep PASS /tmp/r.txt | sed 's/^PASS //' | sort > /tmp/new.txt
comm -23 <(sort tests/conformance/pass_list.txt) /tmp/new.txt   # LOST — stop
comm -13 <(sort tests/conformance/pass_list.txt) /tmp/new.txt   # gained
cp /tmp/new.txt tests/conformance/pass_list.txt     # only when LOST is empty
```

### Diagnosing one failing dir

In order of how often it settled things this session:

1. **`cat $CORPUS/<dir>/*.as`** — the corpus ships each test's SOURCE
   (`test.as`, plus per-class files). This is decisive far more often
   than reading bytecode, and it is easy to forget it exists.
2. **`python3 tools/swfstruct.py <test.swf>`** — the timeline shape:
   which sprite holds which DoAction, in what tag order, at what depth.
   Read this BEFORE theorising about action-queue ordering. It is what
   proved our queue is plain FIFO and the real `default_names` bug was
   the loop rewind.
3. **`python3 tools/avm1dis.py <test.swf>`** — recurses into
   DefineFunction/DefineFunction2 bodies and prints the fn2 flags.
   `preload_super` means `super` is in a REGISTER; preloads fill r1.. in
   the order printed, which is the only way to read a compiled
   `super.m()` call site.
4. Side-by-side beats a diff when ordering is the question:
   `paste -d'|' <(./zig-out/bin/trace_runner $D/test.swf --frames N) \
                <(cat $D/output.txt) | cat -n`

### ⚠️ `zig build` does NOT build the SDL frontend

`zig build` installs the tools and the core; the frontend is its own step,
`zig build sdl`. A visual check run without it renders with whatever
binary was last built — which silently made a whole session's worth of
"verified visually" claims meaningless once. Always `zig build sdl`
before `--headless-frames`, and check the binary's mtime if a change
seems to have had no effect.

### Visual gate (renderer / timeline changes)

```sh
~/.zvm/0.16.0/zig build sdl -Doptimize=ReleaseFast
./zig-out/bin/handyplay-flash-sdl <file.swf> --headless-frames N --out after.png
python3 tools/pngdiff.py before.png after.png
```

Dump frames 1/5/30 of `squares`, `homestuck-beta`, `homestuck-beta2`,
`morph`, `shumway-3` from `reference/openflash/domu-player/src/static/`.
`git worktree add <dir> <base-commit>` gives you the "before" build;
symlink `reference/` and `vendor/simdra` into it. pngdiff's BOUNDING BOX
is the point — the one pixel change in all of workstream A was a 17x17
box in a 728x90 banner (a looping nested sprite whose phase the goto-on-
loop fix corrected), which a bare `cmp` would have reported as alarming.

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

**Documented stubs** — listed with rationale in `docs/AVM1.md`. A4-A6
retired CloneSprite, RemoveSprite and `Call`; StartDrag is the notable
one left. Some are also no-ops in Ruffle (StrictMode, FsCommand2, and
WaitForFrame which is behaviorally identical for local files).

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

**M4 workstream A2-A6** — target paths (`SetTarget`/`TargetPath`, tri-state
`target_clip`), clip member resolution, runtime clip creation
(`CloneSprite`/`RemoveSprite` + `duplicateMovieClip`/`attachMovie`/
`createEmptyMovieClip`/`removeMovieClip`/`swapDepths`/`getDepth`/
`getNextHighestDepth`), `Call`, cross-function `Throw`, and `super`.
Load-bearing details that are easy to undo:
- the AS depth space is offset by `AVM_DEPTH_BIAS`, and REMOVAL is gated on
  that offset — there is no `placed_by_script` flag;
- clip state a clone inherits (matrix, cxform, `onClipEvent` handlers,
  drawing) must be copied BEFORE the clone runs its first frame, because
  that frame dispatches `load`;
- looping past the last frame is a GOTO (rewind + replay), not a replay of
  frame 1 on top of the existing display list;
- a method found directly on `this` still gets a `super` one prototype
  layer up (`depth.max(1)`), and `super.x` resolves from
  `SuperObject::proto()` — two layers up for `super.__proto__`;
- a display object reached AS a prototype ends the chain (corpus
  `super_edge_cases`; ruffle walks through it, real Flash does not).

**M4 workstream B** — the rest of the `MovieClip` class, `flash.geom`,
`Object.registerClass`, `watch`/`unwatch`, timers, `Date`, the
AsBroadcaster family, and the input seam. Load-bearing details that are
easy to undo, beyond the five in §8:
- `Matrix` is f32 because ruffle's is, and the precision is observable;
- number→string is Flash's 15-digit algorithm, exponent notation from
  1e15, with a genuinely broken rounding carry ("-e+16");
- a clip's Construct is queued BEFORE its first frame runs;
- the initObject's keys go on in insertion order when a constructor is
  involved and in reverse otherwise;
- `unload` handlers run for an already-removed clip (`on_removed` on the
  queue entry); everything else queued for a removed clip is dropped;
- a freed display object keeps a `removed_display` native marker so a
  retained reference stops receiving broadcasts and timer callbacks.

**Flash Lite** — `core/avm1/fscommand.zig` is one command table with two
entry points: opcode `0x2D` (`fscommand2`, which no compiler emits and
ruffle does not implement) and plain `fscommand`, which arrives as
`getURL("FSCommand:cmd","arg")` and used to be recognised and dropped at
three sites. The core NEVER acts on a command — it answers the script and
reports the call to the host, because ruffle's 679 corpus movies all end
with `fscommand("quit")` and a core that quit would truncate every one of
them. The Player owns the acting part (soft-key labels, the quality
switch, a `quit_requested` flag the trace runner never reads), and
`Player.profile` (`avm1`/`lite`/`avm2`) is detected by an opcode walk for
`fscommand2` and decides only how a frontend maps the keyboard. The SDL
frontend adds `--profile`, a handset key map and the soft-key strip.
See `docs/FLASH-LITE.md`; tests are `tests/as2/fscommand` (checked against
ruffle) and `tests/as2/fscommand2` (self-referential, SWF bytes written by
`tools/make_fscommand2_test.py`).

**libretro core** — `frontends/libretro/core.zig` exports the `retro_*`
C ABI over the same `core/` the SDL player uses; `zig build libretro`
installs `zig-out/libretro/flash_libretro.dylib`. The screen is the
movie's own stage box at 1:1, the clock is a fixed per-frame timestep
(not host elapsed time), and the framebuffer is presented zero-copy. The
PAD IS BOUND BY THE MOVIE — every button asks the key survey for the
code that answers its action, and the resolved map is published as input
descriptors. `frontends/libretro/test_host.zig` (`zig build
libretro-test`) dlopens the core and drives it through the real ABI, so
none of this needs RetroArch to be tested: 30 of the 36 games in
`games/` react to a pad button and five of the remaining six react to a
click. Save-states are live — `retro_serialize_size` measures itself once
and the three state gates run from the same harness — and audio plays
through `audio_batch_cb`. See `docs/LIBRETRO.md` and `docs/SAVESTATE.md`.

**Audio (M6)** — `core/audio/mixer.zig` + `core/codecs/{pcm,adpcm,mp3}.zig`,
with minimp3 vendored (CC0) behind a flat C shim and `-Dmp3=false` to
compile it out. The rule that makes it safe: everything a script can
observe moves by exactly one frame's worth of samples per FRAME, never by
what a sink consumed, so `Mixer.render` and `Mixer.advance` reach
identical positions and completions — all 694 corpus dirs trace
identically with `trace_runner --audio` and without. That is also ruffle's
own test-backend rule, which is why the 17 scored sound dirs survived
completion going from instant to real. Streams belong to a timeline (a
sprite may stream over the root's), FLV carries MP3 audio into the same
mixer, and both frontends are pure PCM sinks. See `docs/AUDIO.md`.

**Playing it on macOS** — `sh tools/build-libretro-mac.sh install`. Two
things cost a debugging round each and are worth knowing: the macOS
RetroArch cask is **x86_64** (so the core must be universal or it never
appears in the list), and per-movie core options only survive through
`SET_CORE_OPTIONS_V2` — the v0 `SET_VARIABLES` is read once and a second
call is ignored.

**The boot shell** — `frontends/libretro/shell.zig`: an ad, then a
legend of what the pad became, then the game. Drawn in the project's
visual language (indigo gradient, the gradient mark, drifting circles,
anti-aliased Poppins Medium embedded from `vendor/fonts/` under the OFL
and rasterised through simdra), and laid out by MEASURING the stage — one
column or two, and the type size, chosen to fit 176x208 as well as
800x600. Rows are named by RetroPad button, since libretro never exposes
the physical controller's own labels. It
deliberately does not EDIT the mapping: RetroArch already remaps physical
buttons, so the editing is `flash_bind_*` core options whose values are
re-declared per movie from the survey.

**Key survey / dynamic input** — `core/key_survey.zig` answers, at load,
which keys a movie can possibly notice: button `keyPress` conditions and
clip `keyPress` events (already parsed), plus `Key.isDown(<literal>)` and
`Key.getCode() == <literal>` found with a small abstract stack over the
bytecode — needed because the method name lives in the CONSTANT POOL, so
a byte scan finds the pool and misses every call, and because
`var k = Key.getCode()` has to be followed into a register or a local.
A frontend binds ACTIONS (`up`, `select`, `soft_left`) and asks
`key_survey.resolve` for the code THIS movie wants, with the rule that a
key whose own code the movie already reads is passed through untouched.
The same walk answers "is this Flash Lite?" (`fs_command2`), so profile
detection costs nothing extra. `tools/keymap.py` is the offline twin.

**M4 drawing API** — `core/display/drawing.zig` holds one open fill subpath
and one open stroke subpath per clip and emits the same `DrawPath` IR the
SWF shape distiller does, so script paths render through the existing
rasteriser. It is a clip's SELF bounds, so `_width`/`_height` see it, and
`duplicateMovieClip` deep-copies it.

---

## 8. What's next

**M4 is fully specified in `docs/M4-SPEC.md`** — six workstreams
(interpreter stubs → MovieClip methods/globals → events+buttons → text →
bitmaps → blend modes), each with exact semantics and the authoritative
Ruffle reference file, plus the M3 failure clusters and a near-miss hit
list. Gate: **≥300/697 — cleared.**

**M4 IS CLOSED. Every workstream — A, B, C, D, E, F and L — is done and
the trace corpus is GREEN: 679 of 679** (images 21/26). F was the last:
PlaceObject3 blend modes and `cacheAsBitmap` now draw the object onto a
layer of its own and composite the layer, which is what a blend mode
means for a clip with children. No corpus dir and no sample movie
exercises it — that was measured, not assumed — so it ships with
hand-computed pixel tests and `tools/make_blend_demo.py`.
`docs/M4-SPEC.md` §4 to §8 name, by dir and cause, everything those
workstreams could not reach at the time; the last 54 of those are now
closed and the tables are history, not a hit list.

**M5, save-states**: DONE and on by default. The container (vendored
`statefmt`, `flash_core = 7`) carries the player and VM scalars, the
display tree (drawings, buttons, text fields and the mouse anchors
included), runtime-loaded movies and levels, the timers, the constant
pools and all three `registerClass` registries, the audio voice table,
the AVM1 heap with its string pool and closures, and the arena-owned
natives — BitmapData pixels, TextFormats, XML trees, NetStream buffers.
**36 of 36 games** and **195 of 195** multi-frame corpus dirs round-trip,
and 655 of 659 corpus dirs pass the byte-level container gates (the four
that do not are movies the libretro host cannot load at all).
`docs/SAVESTATE.md` has the section table, the cost measurements and the
bug diary.

Two engine defects surfaced there rather than in the interpreter: the
AVM1 heap **never freed anything** (now `core/avm1/gc.zig`), and constant
pools were re-decoded per call. Both are fixed.

**M5 is DONE**: the libretro core runs the games through the real C ABI,
binds a RetroPad from the key survey (`docs/LIBRETRO.md`), plays audio,
and saves, restores and rewinds. Then M7
(morph tweening, EditText polish, and the visual FILTER kernels — the
filter list already decodes, and F's layer machinery is what they draw
through).

**The one dir the corpus does NOT score, and why.**
`bitmap_data_thorough/pixelDissolve` carries
`known_failure.panic = "attempt to add with overflow"`: ruffle crashes
on it, so it is not part of the set anyone expects to pass, and the
sweep now honours all three spellings of that flag. It is worth knowing
how far off we are anyway: the dissolved PIXELS match Flash in every
case, and what differs is the permutation index the call RETURNS, in
ten of about two hundred argument permutations — the ones passing null,
undefined, `{}` or a negative where a seed or a count belongs. Flash's
Feistel round function is not ruffle's (ruffle's is a stated guess), and
eleven recorded return values are not enough to recover the real one.

**The IMAGE score is 21 of 26, and the five that remain are each one
thing.** Two of them are not ours to fix: `define_font_glyph_table_order` and
`_overlap` render their content entirely from ActionScript 3 — five
DoABC blocks and nothing on the timeline — so they need an AVM2
interpreter, which this player does not have and is not going to grow.

Both video dirs now pass. `netstream_play_flv_screen` was never a
decoder problem: the frame decoded on all sixty ticks and was scaled to
nothing, because a `Video` had no self-bounds and the FLVPlayback
component sizes itself by dividing by them. `netstream_play_flv` needed
a real Sorenson H.263 decoder, which `core/codecs/h263.zig` now is —
I-frames and P-frames, deblocking filter included.

The other three are close and specific:

| dir | what is left |
|---|---|
| `movieclip_begin_gradient_fill`, `movieclip_line_gradient_style` | 113 pixels between them, down from 13022. Twenty-two of the twenty-four cells are exact. What is left is 37 pixels of the cell whose two ratios are both 50 — a hard step in a REFLECTED radial, where the two renderers place the sample three hundredths of a pixel apart and the step turns that into a colour — and 8 pixels at the singularity of a focal gradient, whose formula is algebraically the two-circle one we tessellate but is not evaluated the same way near the focus. |
| `edittext_stylesheet` | two pixels, both the bottom-right corner of a field's border. Flash draws that border as FOUR SEPARATE LINES and the bottom-right corner is missing entirely (`edit_text.rs:2841`); the reference draws them as GPU line primitives, and the corner ends up 5/8 covered by two overlapping partial samples. No whole-pixel model produces 5/8: fully drawn is 95 away and fully missing is 160, against a tolerance of 64. |

**A fourth harness layer: our own AS2 corpus.** `tools/as2/` compiles
ActionScript 2 we write (mtasc, built from source in a container) and
runs it in BOTH ruffle's prebuilt wasm and this player, comparing traces
and pixels. 18 cases today, all passing. It exists because ruffle's
corpus cannot see everything: no dir there places an object with a blend
mode, which is why workstream F shipped blind. The first run of it found
two real bugs — `alpha`/`erase` punching a hole through the stage, and
`cacheAsBitmap` not snapping — and recorded two divergences with
measurements rather than guesses. See docs/TESTING.md §4.

**Two harness gaps closed along the way**: `images.sh` now replays
`input.json` (the SDL frontend gained `--input`, shared with the trace
runner) and honours `quality = "low"`, and `pngdiff` reads palette,
greyscale and sub-byte PNGs rather than calling them a format mismatch.
The six `trigger` dirs are still skipped, but `--capture TICK:file.png`
now exists to drive them: the focus highlight they compare renders
correctly in isolation, and what differs is which object holds focus at
each capture.

Eight things to know before you start:

1. **Filters are DECODED but not APPLIED.** `core/swf/filters.zig` parses
   PlaceObject3's list and `core/avm1/globals/filters.zig` has the whole
   AVM1 property surface, so a script reads back exactly what the tag
   carried — but nothing draws a blur or a glow. The one filter that IS
   applied is `ColorMatrixFilter`, through `BitmapData.applyFilter`,
   because it is a per-pixel function rather than a convolution. M7 owns
   the kernels; the decode half is done and should not be redone.
2. **§A4/§A5 record diagnoses that turned out to be WRONG** and the real
   causes next to them. In particular: `default_names` was NOT
   action-queue priority (our FIFO matches Flash — it was the loop
   rewind), and `remove_movie_clip` was NOT Button/EditText
   stringification (it was `swapDepths`). Read those notes before
   trusting any "blocked on X" claim elsewhere in the spec, including the
   §8b cluster table, which is an M3-close snapshot.
3. **One rule in the tree is corpus-derived, not Ruffle-derived**: a
   display object reached AS a prototype ends the chain
   (`Objects.findChained` + `Vm.protoValue`). Ruffle walks straight
   through it; real Flash does not (`super_edge_cases`). If something
   later looks wrong around `__proto__` chains through clips, this is the
   first suspect — it is deliberately marked in both call sites.
4. **The one dir workstream A could not reach** is reachable now:
   `interface_implements_op` needed `MovieClipLoader.loadClip` of an
   external SWF plus cross-movie AVM1, and workstream L built both. Its
   sibling `clone_sprite_edittext` is down to one thing: `filters` are
   reported as an empty array and never stored, so a field cannot carry
   one.
5. **The action queue is now three FIFO buckets** (Initialize, Construct,
   Normal) drained highest-first on every pop, and `#initclip` runs at
   PRELOAD rather than on the timeline. Both were needed for
   `Object.registerClass` to apply at the right moment; workstream C's
   event ordering builds directly on them
   (`Context.queue`/`popAction`, `Player.runInitActions`).
6. **`swf.reader.Matrix` is f32 and number→string is Flash's own
   algorithm, not ES3.** Both look like sloppiness and are not — the
   corpus fails either one if it is "corrected". See the workstream-B
   notes at the end of `docs/AVM1.md`.
7. **Everything asynchronous lands at the END of the tick**, in
   `Player.finishTick` — ruffle's `executor.run()`, which its harness
   calls after `run_frame` and the timers. Loads, socket traffic and file
   dialogs all resolve there, and the one-tick lag that produces is
   OBSERVABLE: `loadvariables2` polls on an interval precisely because
   the data is not there when `loadVariables` returns, and `onLoadInit`
   is a whole tick behind `onLoadComplete` because the loaded movie has
   to run its own first frame in between. Do not "fix" it by resolving
   inline.
8. **A device font is a HOST input, never a built-in.** `Options.device_font`
   takes TTF bytes; with none, a face the movie did not embed measures
   zero, which is what a machine without it installed does. The four
   corpus dirs that need one declare `with_default_font`, and the harness
   passes ruffle's Noto Sans subset for exactly those. Do not bake a
   fallback face into `core/` — see the workstream-D notes in
   `docs/AVM1.md`.

**M5** libretro core + save-states — DONE (the core plays in RetroArch,
states and rewind are on by default and gated three ways;
`docs/LIBRETRO.md`, `docs/SAVESTATE.md`) ·
**M6** audio — DONE (ADPCM/PCM/minimp3, StartSound, the Sound class,
SoundStreamBlock sync and FLV audio; `docs/AUDIO.md`) ·
Then **M7** polish (morph shapes, device fonts, clipDepth masks —
simdra's `clipPath` is ready — PlaceObject3 filters/blend modes).

Afterwards, adoption into handyplay-oss: a `build-cores.sh` entry and the
libretro-web 6th-core registration. The save-states already use their
`common/statefmt.zig`, vendored under `vendor/statefmt/` as
`flash_core = 7`.

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
