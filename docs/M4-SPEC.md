# M4 Specification — Objects, Stage, Buttons, Text, Bitmaps

**Handover document.** Self-contained spec for executing milestone M4 of
handyflash (Flash Player in Zig 0.16, AVM1 only). Written at the close of
M3 (full interpreter). Read this top to bottom before writing code.

**Exit gate: ≥300/697 ruffle AVM1 conformance dirs pass** (see §9), plus:
buttons respond to mouse in the SDL frontend, a JPEG-bearing SWF shows the
image, static text renders glyphs, and
`reference/openflash/domu-player/src/static/homestuck-beta.swf` remains
visually correct.

---

## 1. Environment & ground rules

- **Zig 0.16 only**: `~/.zvm/0.16.0/zig`. Plain `zig` on PATH is 0.15.2 —
  wrong for this repo. `zig build` / `zig build test` / `zig build sdl`.
- Repo: `/Users/narekh/Projects/notconsole/handyflash` (standalone git,
  commit directly on `main` — user convention).
- References on disk (git-ignored `reference/`):
  - `reference/ruffle/` — full Ruffle clone. **The behavior authority.**
  - `reference/openflash/open-flash/content/documentation/avm1/actions/`
    — complete per-action spec pages.
  - Ruffle errata wiki (fetch if needed):
    https://github.com/ruffle-rs/ruffle/wiki/SWF-AVM-Specification-Errata
- Vendored rasterizer: `vendor/simdra` (the user's own MIT canvas lib,
  already extended for Flash: cxform, spread gradients, bilinear patterns,
  BGRA surfaces, Flash blend modes, colorMatrix). Its API root:
  `vendor/simdra/simdra.zig`.
- **Never run the 5-gamelet/global smokes for unrelated cores** — this
  repo's own gates only.
- User preference: when launching the SDL player for visual checks, run it
  in the background with NO timeout and leave it open.

### Critical lesson from M3 (do not repeat)

Zig test blocks are only collected from files reached by a TEST-context
import. `core/flash.zig`'s root `test` block therefore **explicitly
imports every test-bearing file**. When you add a new file with tests,
ADD IT THERE — `refAllDecls` alone silently drops tests from the binary.

### Test fixture gotchas already hit twice

- SWF signed bit-fields need the sign bit: +200 needs 9 bits, not 8.
- `comptime` float arithmetic folds in f128 — force runtime vars when a
  test depends on f64 rounding (`var x: f64 = 0.1; x += 0.2;`).
- simdra AA coverage rounds ±1 LSB — pixel assertions use tolerance ≥2.

---

## 2. Current architecture (what exists after M3)

```
core/flash.zig            Player: create/tick/framebuffer (XRGB8888), VM+display+render owner
core/swf/                 Complete tag parser (M1) — movie.load() → Movie{lib, frames[]}
core/display/
  library.zig             Character dict (frozen after preload) + per-frame Control lists
  display_object.zig      Placed instance: matrix/cxform/depth/name/ratio/clip_depth/kind
  movie_clip.zig          Timeline: runFrame, goto rewind+replay, DoAction QUEUEING
core/avm1/
  opcodes.zig             Full 0x00-0x9F decoder (allocation-free)
  string.zig              UCS-2 AvmString, ascii() literals, case folding
  value.zig               Value union + exact ES3 coercions + JS number formatting
  object.zig              Handle-table ScriptObject, NativeInfo union, scope_parent links
  runtime.zig             Vm: stack/registers/pools/prototypes/Host hooks/callFunction
  activation.zig          The linear interpreter (all ops; stubs listed in §3)
  globals/globals.zig     Object/Function/Array/String/Number/Boolean/Math/globals
core/render/
  shape_utils.zig         SWF dual-edge records → DrawPath IR (twips)
  renderer.zig            Display-tree walk → simdra (solid/gradient fills, strokes)
  canvas.zig              BGRA SmSurface wrapper (pixels() = libretro XRGB8888)
tools/                    swfinfo, swfdump, trace_runner
tests/conformance/run_avm1.sh   corpus runner + pass_list.txt ratchet
frontends/sdl/main.zig    SDL3 playback + --headless-frames N PNG dump
```

Key flow per frame (`Player.runOneFrame` in core/flash.zig):
1. `root.runFrame(ctx)` — timeline advances, control tags execute,
   DoActions APPEND to `ctx.actions` (never run inline).
2. `root.applyPendingGoto(ctx)`.
3. Drain `ctx.actions`: each entry runs an `Activation` with
   `this` = the clip's AVM object, `scope` = that same object handle
   (clip objects double as timeline variable scopes; `scope_parent = 0`
   so lookup falls through to `_global`).
4. Pending gotos re-apply between drained actions.
5. Render on demand.

Clip ⇄ VM linkage: `MovieClip.avm_object: u32` (lazily created in
`Player.clipObject`); the ScriptObject's `native = .{ .clip = *MovieClip }`.
Movie control flows through `Vm.Host` fn-pointer hooks installed by Player
(goto_frame/goto_label/set_playing/next_prev — see `installHost`).

Rendering: `renderer.Transform` (f64, twips) concat down the tree;
cxforms concat (8.8 fixed) and pass STRAIGHT into simdra's
`SmPaint.ColorTransform` (identical layout). Gradient geometry maps the
±16384-twip gradient square through the full matrix into device space.

---

## 3. Interpreter stubs to promote (workstream A)

These ops currently pop correctly but act as stubs (all in
`core/avm1/activation.zig`; search for "M3.5"/"M4" comments):

### A1. GetProperty / SetProperty (0x22/0x23) — ✅ DONE
Landed in `core/avm1/stage_object.zig`, together with the named form
(`mc._x`) since Ruffle serves both from one table. Two corrections to the
spec text below, found while implementing:
  • scale/rotation are a CACHED decomposition, not re-derived per read —
    `sqrt(a²+b²)` drifts and `stage_property_representation` demands 300
    exact round-trips. Store percent and degrees, not units and radians.
  • `Twips::from_pixels` TRUNCATES; `_x = 1.234` is 24 twips, not 25.

The SWF4 indexed property table. Reference:
`reference/ruffle/core/src/avm1/object/stage_object.rs:279` — order is
LOAD-BEARING (it IS the index):
```
0 _x  1 _y  2 _xscale  3 _yscale  4 _currentframe  5 _totalframes
6 _alpha  7 _visible  8 _width  9 _height  10 _rotation  11 _target
12 _framesloaded  13 _name  14 _droptarget  15 _url  16 _highquality
17 _focusrect  18 _soundbuftime  19 _quality  20 _xmouse  21 _ymouse
```
Implement a `displayProperty(vm, clip, index) Value` +
`setDisplayProperty` pair (suggest a new `core/avm1/stage.zig`).
Semantics (all from ruffle stage_object.rs + movie_clip.rs):
- `_x`/`_y`: matrix tx/ty in PIXELS (twips ÷ 20). Setting writes the
  matrix.
- `_xscale`/`_yscale`: percent (100 = 1.0) — scale extracted from the
  matrix a/b and c/d columns (`sqrt(a²+b²)·100`); setting rescales the
  column preserving rotation.
- `_rotation`: degrees from `atan2(b, a)`; setting rotates preserving
  scale.
- `_width`/`_height`: bounds size in px (self bounds transformed by the
  matrix); setting scales to match.
- `_alpha`: cxform alpha mult as percent (`mult[3]/256*100`); setting
  writes `mult[3]`.
- `_visible`, `_name`, `_currentframe`, `_totalframes`,
  `_framesloaded` (= `_totalframes` — always loaded).
- `_target`: slash path from root (`"/mc/child"`); `_url`,
  `_droptarget` → `""`; `_highquality` 1, `_quality` "HIGH",
  `_focusrect` true, `_soundbuftime` 5.
- `_xmouse`/`_ymouse`: mouse in the clip's local space (needs the mouse
  state from workstream D; until wired return 0).
- The target operand: `""` = current clip; else resolve via target path
  (§A2). GetProperty on a missing target → undefined.

### A2. SetTarget / SetTarget2 / TargetPath / slash paths — ✅ DONE
Three corrections to the sketch below, found while implementing:
  • `target_clip` needs THREE states, not `Value`: base / retargeted /
    FAILED. A failed path sends variables to `_root` while play/stop/goto
    silently no-op — except GotoFrame2, the one op that falls back to the
    root (ruffle action_goto_frame_2 vs action_play).
  • SetTarget also REPLACES the timeline scope, which is what makes
    `tellTarget('bogus') { trace(n) }` read `_root`'s `n`.
  • TargetPath returns the DOT path (`_level0.mc`), not the slash path.

`Activation.setTarget` currently no-ops and path resolution in
`getVariable` only walks objects. Implement real clip targeting:
- Add `target_clip: Value` to Activation (init = `this`); `SetTarget("")`
  resets to `this`. Movie-control ops (play/stop/goto/StartDrag/
  GetProperty-with-empty-target) act on `target_clip`, not `this` —
  ruffle activation.rs distinguishes `base_clip` vs `target_clip`.
- Path grammar (ruffle activation.rs `resolve_target_path`): `/` root-
  relative, `..` parent, `.` no-op, `:` separates path from variable,
  `_root`, `_parent`, `_levelN`, else child-by-name. Children are found
  through the DISPLAY tree: add a resolver Host hook or (simpler) walk
  `MovieClip.children` by `DisplayObject.name` (case-insensitive < SWF7).
- `TargetPath` (0x45): pops a clip object → pushes its slash path string
  (`"_level0.mc.child"` DOT form in SWF5+? ruffle returns dot-path via
  `target_path()`; check ruffle `action_target_path` — it returns the
  SLASH path only for clips, undefined otherwise).

### A3. Clip member resolution — ✅ DONE
All A1/A2/A3 gates pass. What still fails in this area needs workstream B
(`createEmptyMovieClip`/`attachMovie`): removed_target_clip_scope,
set_target_2_swf6/7, property_invalid_base_clip, default_names,
named_shapes. Non-clip display objects (buttons, text fields) DID land
here — ruffle gives object1 to MovieClip, Avm1Button and EditText, but not
to Graphic or static Text.

The resolution order below landed EARLY, inside A1 (the table) and A2
(path properties), so A3 itself was only the two loose ends: children in
`for..in` (highest depth first, appended after own keys) and Flash's
automatic `instanceN` names. Two notes for later work:
  • `hasOwnProperty` deliberately does NOT see display properties or
    children — ruffle wires has_display_object_property as the fallback
    for has_property, not has_own_property.
  • `default_names` is NOT a gate for this section: it calls attachMovie,
    so it needs workstream B.

`Activation.memberGet`/`memberSet` and `scopeGet` must learn the
MovieClip name-resolution order (ruffle stage_object.rs:24-57):
1. Path properties: `_root`, `_parent`, `_global`, `_levelN`.
2. **Child display object by instance name** (BEFORE display props).
   A child whose kind is not a clip resolves to... ruffle: non-scriptable
   children (Graphic) return the PARENT instead — mirror that only if
   tests demand.
3. Display properties `_x`…`_ymouse` — ALWAYS case-insensitive.
4. Ordinary object properties (the ScriptObject the clip already is).
Implement as: when `memberGet`'s target object has `native == .clip`,
run steps 1-3 before the normal `getChained`. Same for writes
(display props write through; everything else is a normal put).

### A4. CloneSprite / RemoveSprite (duplicateMovieClip)
`CloneSprite` pops depth, target(new name), source(path). Behavior
(ruffle movie_clip.rs `duplicate_movie_clip`): instantiate a NEW clip of
the same character id at the given depth on the SOURCE'S PARENT, with the
source's current matrix/cxform, name = new name, and it starts playing
from frame 1. RemoveSprite removes a clip placed by CloneSprite (or
attachMovie). Depth arithmetic: AVM1 scripts use 0-based depths that map
to 16384+depth internally in Flash — ruffle adds `AVM_DEPTH_BIAS = 16384`;
mirror it (place tags use 0..16383, scripts 16384+).

### A5. super + cross-function Throw
- Build a real `super` object for DefineFunction2 preloads: a callable
  whose call invokes `this.__proto__.__constructor__` with the parent
  proto chain — ruffle object/super_object.rs. Minimum for corpus: super
  as constructor call + `super.method()` dispatch.
- Replace the swallow-at-boundary throw semantics: `Vm.callFunction`
  should return a `thrown` channel. Suggested: change `callAvm1` to
  return `error.Avm1Thrown` after storing `vm.pending_throw`, and make
  `Activation.exec`'s call sites catch that error and convert to
  `Flow{ .thrown = vm.pending_throw }` so outer Try blocks catch it.

### A6. Call (0x9E)
Pops a frame reference ("label" or number or "path:label") and executes
that frame's DoActions IMMEDIATELY (not queued), without moving the
playhead. Frames come from `MovieClip.frames[n].controls` (filter
`.do_action`). Reference: ruffle `action_call`.

---

## 4. MovieClip AVM methods & globals (workstream B)

New file suggestion: `core/avm1/globals/movie_clip.zig`, installed on a
`movieclip_proto` (add handle to Vm; clip objects' proto = it, chaining
to object_proto). Methods dispatch on `this.native == .clip`. From ruffle
`core/src/avm1/globals/movie_clip.rs`:

Required (corpus-driven, in priority order):
- `gotoAndPlay(frame|label)`, `gotoAndStop`, `play`, `stop`,
  `nextFrame`, `prevFrame` — via the existing Host hooks.
- `getBytesLoaded`/`getBytesTotal` → movie byte length (equal).
- `duplicateMovieClip(name, depth)`, `removeMovieClip()` — share A4 code.
- `attachMovie(exportName, instanceName, depth)` — look up
  `movie.lib.exports` (ExportAssets name→id), instantiate like A4.
- `createEmptyMovieClip(name, depth)` — a clip with zero frames.
- `hitTest(x, y, shapeFlag)` / `hitTest(target)` — bounds test in M4
  (shape-exact via shape_utils winding later).
- `getDepth()`, `swapDepths(target|depth)`.
- `localToGlobal(pt)`, `globalToLocal(pt)` — via the concat matrix.
- `startDrag`/`stopDrag` — with D (mouse) wired.
Properties like `_x` route through A3 automatically.

Other globals the corpus leans on (check failures first, add as needed):
- `Date` — full class; ruffle globals/date.rs. Use a FIXED epoch from
  `vm.now_ms` for determinism (corpus date tests mostly construct
  explicit dates — those are deterministic anyway).
- `Key` (`Key.isDown`, constants), `Mouse` — with D.
- `String()`/`Number()`/`Boolean()` called as FUNCTIONS (coerce) — the
  ctors already handle this via `this == .object` check; verify.
- `Object.registerClass`, `ASSetPropFlags` (sets Attributes bits — the
  undocumented flags: bit0 dont_enum? Actually: 1=hidden(dont_enum),
  2=dont_delete, 4=read_only; second arg props list or null=all).
- `watch`/`unwatch`, `addProperty` (getter/setter) — ScriptObject needs
  an optional accessor form: extend `Property` with
  `getter/setter: ?ObjectHandle` and route get/put through them.
  Ruffle property.rs. Only do this if failures demand (they do in many
  tests — `addProperty` is common).
- `setInterval`/`setTimeout` — timer table on Vm ticked by Player
  (fire before the frame's queued actions; ruffle timer.rs).

---

## 5. Events: ClipActions + buttons (workstream C)

### C1. onClipEvent (PlaceObject2 ClipActions)
Parsed already: `DisplayObject`'s `PlaceObject.clip_actions`
(`swf.place.ClipAction{events, key_code, actions}`) — but NOT stored on
the placed object. Store them at instantiate (display_object field), then
fire per the event model:
- `load`: once, on the clip's first `runFrame` (BEFORE frame 1 tags —
  ruffle run_frame_avm1: first frame Load INSTEAD of EnterFrame).
- `enterFrame`: every subsequent runFrame (before tags).
- `unload`: on removal.
- `mouseDown/mouseUp/mouseMove`, `keyDown/keyUp`, `keyPress<n>`: global
  broadcasts — every clip with a matching handler fires, regardless of
  position (that's AVM1!). Wire from SDL/libretro input via Player.
- `press/release/releaseOutside/rollOver/rollOut/dragOver/dragOut`:
  button-like, hit-tested.
- `data`, `initialize`, `construct`: skip until needed.
Queue handler bodies through `ctx.actions` with the clip as target
(same as DoAction), in the documented priority: ruffle uses
Initialize > Construct > Normal — add a `priority` field to QueuedAction
and a stable sort, or three lists.

### C2. Buttons
`DisplayObject.kind == .button` currently never renders or reacts.
- Render: a button shows its `records` filtered by state
  (up/over/down); each record is a character (usually shape) with its own
  matrix/cxform — reuse the renderer's shape path per record. Track
  state per placed button (add a small struct: current state).
- Hit-test: records with `state_hit_test` define the active area — use
  `shape_utils` winding hit-test (port ruffle shape_utils
  `shape_hit_test`; the DrawPath IR already carries the geometry —
  implement point-in-fill via ray winding on the commands).
- Input: Player receives mouse (x, y in px, buttons) from frontends
  (`Player.setMouse` — add to seam + SDL). Each tick after clip frames:
  compute hover/press transitions, fire `ButtonCondAction`s whose
  `conditions` match (bit meanings in `swf.button.CondAction`), queue
  their bytecode on the button's PARENT clip (AVM1 buttons execute in
  parent timeline scope).
- Keypress conditions (bits 9-15) fire on key input.

---

## 6. Static text + fonts (workstream D)

`DisplayObject.kind == .text` renders nothing today.
Reference: `reference/ruffle/core/src/display_object/text.rs:135` (~50
lines — the model) + font.rs.

- In renderer: for `.text`, walk `swf.font_text.Text.records` with
  STICKY state (font_id/color/height/x/y persist until overridden).
  For each glyph entry: look up the font character → glyph →
  `shape.parseRecords`-style records — glyphs were parsed at preload as
  `[]shape.ShapeRecord`; distill each glyph ONCE (cache like shapes,
  key (font_id, glyph_index)) with a single implicit solid fill
  (StyleChange fill1=1 semantics — glyph records reference fill 1).
- Transform per glyph: text.matrix ∘ translate(x_offset, y_offset) ∘
  scale(height/1024) — **DefineFont3 glyphs are 20× resolution: divide
  by 20480 instead** (`swf.font_text.Font.version == 3`).
- Advance: `GlyphEntry.advance` is in twips already scaled? Ruffle:
  advance in the text record is in TWIPS (add to x after each glyph).
- Color: record color × cxform → paint solid + `setColorTransform`.
- EditText: render `initial_text`/bound variable via the same glyph
  pipeline with the field's font — only if corpus/visual targets demand;
  full EditText is M7.

---

## 7. Bitmaps (workstream E)

Replace the renderer's gray placeholder for `.bitmap` fills AND
`DisplayObject.kind == .bitmap`.

New: `core/render/bitmap_cache.zig` — decode on first use, cache by
character id (movie arena):
- `library.Bitmap.jpeg2/.jpeg_needs_tables/.jpeg3`:
  - Strip a leading EOI/SOI pair (bytes FF D9 FF D8) if present
    (ruffle `remove_invalid_jpeg_data`).
  - `jpeg_needs_tables`: splice `movie.jpeg_tables` (minus its trailing
    EOI) before the tag data (minus its leading SOI) — ruffle
    `glue_tables_to_jpeg`.
  - Decode via simdra: `simdra.decode` (stb; PNG/GIF payloads in v8+
    JPEG2 are auto-sniffed by stb) → RGBA `SmBitmap`.
  - `jpeg3`: zlib-inflate `alpha_zlib` (std.compress.flate, container
    .zlib) → one byte per pixel → multiply into the decoded RGBA's alpha
    (and PREMULTIPLY quirk: Flash JPEG3 alpha is applied straight; ruffle
    multiplies color channels? check ruffle bitmap decode — use straight
    alpha first, fix against a corpus image test).
- `lossless`: zlib-inflate `zlib_data`; format 3 = 8-bit palette
  (colormap RGB or RGBA for v2, row-padded to 4 bytes!), 4 = PIX15
  (v1 only), 5 = PIX24/ARGB32 (v2: straight ARGB with alpha) → RGBA.
  Row padding: colormap rows pad to 32-bit boundaries — ruffle
  `decode_define_bits_lossless`.
- Renderer `.bitmap` fill: build/cache an `SmPattern` from the RGBA
  pixels; `setFilter(.bilinear)` when `is_smoothed`; repetition per
  `is_repeating` (.repeat vs .no_repeat); `setTransform` with the
  INVERSE of (combined ∘ fill matrix) — note SmPattern.setTransform
  takes the FORWARD matrix and inverts internally (check
  vendor/simdra/simdra/effects/SmPattern.zig:75).
- `.bitmap` display objects (rare, PlaceObject of a bitmap id): draw as
  a bitmap-filled unit rect via drawImage-style path.

---

## 8. Renderer additions (workstream F)

- PlaceObject3 `blend_mode` byte → simdra BlendMode: 0/1 normal
  (src_over), 2 layer (src_over for now), 3 multiply, 4 screen,
  5 lighten, 6 darken, 7 difference, 8 add, 9 subtract
  (`flash_subtract`), 10 invert (`flash_invert`), 11 alpha
  (`flash_alpha`), 12 erase (`flash_erase`), 13 overlay, 14 hardlight.
  Set via canvas `blendMode` around the object's draws.
- clipDepth masks CAN land here if cheap (simdra `clipPath` +
  save/restore; mask shape's fills → clip region; maskees = depths in
  (depth, clip_depth]) — else defer to M7 as planned.

---

## 8b. M3 baseline & near-miss hit list (start here)

**M3 closed at 76/697** ( — the ratchet).
79 more tests fail by ≤3 diff lines; the fastest path to 300 starts with
these. Highest-value clusters observed at M3 close:

| Cluster | Tests | What's needed |
|---|---|---|
| ,  | ~12 | / + MovieClipLoader events (can be stubbed to fire onLoadError/onLoadInit deterministically) |
| ,  | ~15 | attachMovie/duplicateMovieClip (§A4, §B) |
| , ,  | ~25 |  + registerClass + constructor chains (§A5, §B) |
|  | ~20 | BitmapData class (out of M4 scope unless cheap) |
| ,  | ~15 | TextField objects + variable binding (§D) |
| , / paths | ~10 | finish §A2/§A3 (partial: SetTarget landed in M3) |
|  | 5 | version-gate visibility: enumeration gate landed; these still fail — the gate must ALSO hide from reads, but doing so naively broke everything (investigate: apply only to properties whose owner is a built-in) |

Closest single-line misses at M3 close:

  focus_root_movie (1 diff lines)
  goto_rewind3 (1 diff lines)
  issue_3169 (1 diff lines)
  issue_9885 (1 diff lines)
  loadmovie (1 diff lines)
  loadmovie_fail (1 diff lines)
  loadmovie_method (1 diff lines)
  tell_target_invalid_swf6 (1 diff lines)
  unloadmovie_method (1 diff lines)
  amf_sharedobject_strict_array_serialization (2 diff lines)
  as_set_prop_flags_version_swf5 (2 diff lines)
  as_set_prop_flags_version_swf6 (2 diff lines)
  as_set_prop_flags_version_swf7 (2 diff lines)
  as_set_prop_flags_version_swf8 (2 diff lines)
  as_set_prop_flags_version_swf9 (2 diff lines)
  attach_movie_export_not_yet_run (2 diff lines)
  attach_movie_stop (2 diff lines)
  drag_over_from_outside (2 diff lines)
  drag_over_without_startdrag (2 diff lines)
  edittext_input (2 diff lines)
  escape (2 diff lines)
  execution_order1 (2 diff lines)
  execution_order2 (2 diff lines)
  export_assets (2 diff lines)
  form_loader_encoding_1 (2 diff lines)
  global_is_bare (2 diff lines)
  hittest_morph_input (2 diff lines)
  issue_710 (2 diff lines)
  issue_768 (2 diff lines)
  lessthan_swf5 (2 diff lines)
  loadmovienum (2 diff lines)
  lock_root (2 diff lines)
  mcl_loadclip_replace_root (2 diff lines)
  mouse_hover_events_while_dragging (2 diff lines)
  new_method_wrap (2 diff lines)
  new_object_wrap (2 diff lines)
  o (2 diff lines)
  recursive_prototypes (2 diff lines)
  removed_base_clip_tell_target (2 diff lines)
  root_onload (2 diff lines)


## 9. Conformance workflow (the gate)

```
zig build                                    # tools incl. trace_runner
sh tests/conformance/run_avm1.sh             # full run, prints pass/697
sh tests/conformance/run_avm1.sh <dir>       # one test, shows the diff
sh tests/conformance/run_avm1.sh --update    # rewrite pass_list.txt
sh tests/conformance/run_avm1.sh --ratchet   # verify no regressions
```

Corpus at `reference/ruffle/tests/tests/swfs/avm1/<dir>/{test.swf,
output.txt,test.toml,test.as}` — `test.as` shows the SOURCE of each test:
**read it when a diff is confusing**. `num_frames` in test.toml is the
tick count (the runner reads it).

Method that works: run full → bucket failures by first-diff-line pattern
(`sort | uniq -c`) → fix the biggest bucket → rerun. Common buckets to
expect: number formatting edges, `enumerate` ORDER (Flash pushes keys in
reverse insertion order per prototype level — tune `pushEnumKeys` in
activation.zig against actual diffs), `toString` of classes, undefined
vs "" in SWF6 string coercion (`toStringValue` of undefined in SWF ≤ 6 is
`""` in some contexts — ruffle `coerce_to_string` has the exact rule:
undefined → "" for swf < 7, "undefined" for ≥ 7 — CHECK AND FIX ours,
`Vm.toStringValue` currently always returns "undefined").

The M3 ratchet baseline lives in `tests/conformance/pass_list.txt` —
NEVER remove entries; a formerly-passing dir failing = regression.
Target: **≥300 entries** at M4 close. Update `docs/AVM1.md` +
`docs/TAGS.md` statuses when closing.

Unit tests: every new module gets in-module `test` blocks AND an entry in
`core/flash.zig`'s root test import list (§1 lesson). `zig build test`
must stay green.

Visual gates: `zig build sdl` then
`./zig-out/bin/handyflash-sdl <swf> --headless-frames N --out x.png` and
LOOK at the PNG (the Read tool renders it). Check: homestuck-beta.swf
(regression), a DefineText corpus SWF (text), DefineBitsLossless.swf +
DefineBitsJPEG2 corpus files (bitmaps), a button SWF interactively via
the windowed player (backgrounded, no timeout, user confirms).

---

## 10. Known simplifications you inherit (fix only if tests demand)

- Uncaught throws swallowed at function boundaries (fix in A5).
- `arguments.caller` absent; `super` undefined (A5).
- Enumerate order = insertion order per object (may need reversing).
- `with` scope = proto-link to target (barrier semantics approximated).
- No GC: objects live in the VM arena until destroy (fine for tests;
  M5 save-states serialize the table as-is).
- `Vm.toStringValue(undefined)` → "undefined" always (see §9 — SWF6
  rule needs the version check).
- Slash-path parsing is simplified (A2 replaces it).
- Timeline exec order is tree-order, not instantiation-order (Ruffle
  uses a global exec list; switch only if corpus ordering tests fail).

## 11. Definition of done

1. `sh tests/conformance/run_avm1.sh` ≥ 300/697; `--ratchet` clean;
   pass_list.txt updated and committed.
2. `zig build test` green (all new code unit-tested).
3. Visual: homestuck unchanged; text + bitmap corpus SWFs render; button
   demo responds to mouse (user-confirmed via windowed SDL).
4. `docs/AVM1.md` + `docs/TAGS.md` statuses updated; this spec's
   workstream list annotated with what shipped vs deferred.
5. Committed on main in reviewable increments (one workstream ≈ one
   commit, message style per `git log`).
