# Spec stack — what to read, in priority order

All local paths are under `reference/` (git-ignored clones of
[ruffle](https://github.com/ruffle-rs/ruffle) and the
[open-flash](https://github.com/open-flash) repos).

## 1. AVM1 actions — open-flash (complete, authoritative)

`reference/openflash/open-flash/content/documentation/avm1/actions/`

- `_index.md` — the full opcode table 0x00–0x9F (incl. explicit INVALID slots).
  Seeds `docs/AVM1.md`.
- 101 per-action pages: stack effect, action code, minimum SWF version,
  byte-level operand tables, Adobe's prose **plus open-flash corrections**.
- Richest pages (read before implementing): `define-function2.md` (register
  preloading), `push.md` (typed values; float64 encoding), `try.md`,
  `get-url2.md`, `goto-frame2.md`, `get-property.md`.
- The `avm1/_index.md` essay argues for a CFG model — we deliberately use
  Ruffle's linear model instead (see DECISIONS.md); read it anyway for the
  pathological-bytecode cases it catalogs.

## 2. Ruffle "SWF-AVM Specification Errata" wiki — mandatory overlay

https://github.com/ruffle-rs/ruffle/wiki/SWF-AVM-Specification-Errata

Where Adobe's PDF is *wrong*. Apply as each item lands, record in the matrix
notes column. Highlights:
- `ActionPush` doubles are two byte-swapped 32-bit halves — byte order
  `45670123`, NOT plain IEEE LE (`LE32_FLOAT64` in open-flash terms).
- `ActionGetURL2` flag order is reversed vs the spec.
- `ActionDelete2` also pushes a success bool (undocumented).
- `PlaceObject3` ClassName presence condition is inverted.
- `DefineButtonCxform` may hold multiple color transforms.
- Undocumented tags: NameCharacter (40), ProductInfo (41), DebugId (63).

## 3. Ruffle `swf` crate — the de-facto binary spec

`reference/ruffle/swf/src/`
- `read.rs` — every tag's field-by-field decode, validated against decades of
  real content. **Final tiebreaker for any binary-layout question.**
- `types.rs` + `types/` — struct shapes; `avm1/{opcode,types,read}.rs` — the
  action set.
- `test_data.rs` — bytes↔struct fixtures; the model for our unit tests.
- `swf/tests/swfs/` — 56 minimal SWFs, one per tag, with `.fla` sources: the
  parser bring-up corpus.

## 4. open-flash SWF container docs (container only!)

`reference/openflash/open-flash/content/documentation/swf/`
- `swf.md` — FWS/CWS/ZWS grammar; `primitives.md` — primitive encodings.
- **Do NOT use the per-tag pages** (`swf/tags/*.md`): 39 of 51 are TODO stubs.

## 5. Adobe SWF File Format Specification

- Local: `reference/openflash/open-flash/specs/swf-spec-10.pdf`
- v19 mirror: https://open-flash.github.io/mirrors/swf-spec-19.pdf
- Use for per-tag layouts (shape records, font layout, edit-text flags),
  always cross-checked against #2 and #3.

## 6. Behavior references (runtime semantics)

- `reference/ruffle/core/src/avm1/` — interpreter decomposition (activation,
  runtime, value, object/{script,stage}_object, scope, function, property_map).
- `reference/ruffle/core/src/display_object/movie_clip.rs` — timeline:
  `run_frame_avm1`, `determine_next_frame`, `run_frame_internal`, `run_goto`,
  `preload`.
- `reference/ruffle/core/src/{player.rs,context.rs,frame_lifecycle.rs}` —
  frame order + ActionQueue.
- `reference/ruffle/render/src/shape_utils.rs` — dual-edge shape records →
  paths (the least-documented part of SWF; this file is the reference impl).
- `reference/ruffle/core/src/display_object/text.rs` — static text rendering.
- ECMA-262 3rd ed. (mirror: https://open-flash.github.io/mirrors/ecma-262-3.pdf)
  — AVM1's Object/coercion/`==` semantics are ES3.
- Tertiary: swfdec (dead C impl, closest structural analogue), Lightspark
  `src/scripting/avm1/`, JPEXS decompiler (the inspection tool of choice).

## Test corpora

- `reference/ruffle/tests/tests/swfs/avm1/` — **697 conformance dirs**
  (test.swf + expected trace in output.txt + recompilable test.as). MIT/Apache.
  Our acceptance suite; see TESTING.md.
- `reference/ruffle/swf/tests/swfs/` — parser corpus (56 SWFs).
- Optional extra: https://github.com/open-flash-db (avm1 bytecode + expected
  output; tags; movies) — not cloned locally.
- Sample movies: `reference/openflash/domu-player/src/static/{squares,morph,homestuck-beta}.swf`.
