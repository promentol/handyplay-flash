# Architecture decision records

Short-form ADRs. Status: **accepted** unless flagged.

## D0 — Ruffle-style linear interpreter (not open-flash CFG)

Interpret AVM1 bytecode with a byte reader over the action slice: If/Jump seek
the reader, end-of-slice is an implicit return, action budget checked every
2000 actions. open-flash's CFG model is more robust against pathological
bytecode and enables decompilers/JITs, but costs significant upfront design;
Ruffle's model is battle-tested against real content. User-confirmed.

## D1 — Runtime strings are []u16 UCS-2 code units

`AvmString` = UTF-16/UCS-2 code units, single wide representation (we skip
Ruffle's narrow/wide dual repr). SWF strings are transcoded once at the parse
boundary: SWF ≥ 6 UTF-8 → UTF-16; SWF < 6 Latin-1 passthrough (Shift-JIS
best-effort table later, R6). Rationale: `String.length`/`charCodeAt`/
`substring` are code-unit semantics and the conformance corpus tests
non-ASCII; a UTF-8 internal repr would convert constantly. Cost: ~2× memory,
one transcode at trace/output boundaries.

## D2 — GC: object table + mark-sweep, u32 handles

AVM1 objects are u32 handles into a slot table; roots = value stack, scopes,
registers, constant pools, display list, globals; sweep on allocation
threshold. Refcounting rejected (prototype/closure cycles). Follows the
exen-core precedent; handles give stable ids ⇒ save-state serialization is a
table walk and nothing is pointer-invalidated.

**Implemented (2026-08-11), `core/avm1/gc.zig`.** The table went unswept for
a long time and the cost only became visible through a save-state:
`AntiMosquito` reached 448,996 slots in sixty frames and serialized 36 MB.
The collector runs at a FRAME BOUNDARY only — no activation live, the
operand stack cleared — which is what makes "roots" a closed set. Roots are
found by REFLECTION over `Vm`'s handle fields plus the display tree the
Player walks; sweeping empties dead slots onto a free list and truncates the
top of the table. The risk is a missed root aliasing a live object, so the
corpus is the gate: 679 trace dirs and 195 save/restore dirs stay green.

## D3 — JPEG: via simdra's stb_image (amended 2026-08-06, was: pure-Zig)

Superseded by D7: simdra vendors stb_image (single-file C, forced RGBA
output), which decodes baseline **and progressive** JPEG plus PNG/GIF —
DefineBitsJPEG2 in SWF v8+ may legally contain PNG/GIF, so this covers more
than the original plan did. We still own all SWF stream surgery in
`codecs/jpeg.zig` (leading EOI/SOI strip, JPEGTables splice before SOS for
DefineBits, JPEG3 alpha = separate zlib plane composited after decode);
only the final bytes→pixels step goes through stb. A future pure-Zig decoder
can replace stb behind the same seam if the wasm build wants zero C.

## D4 — LZMA (ZWS) deferred

`error.LzmaUnsupported` with a clear message. ZWS is SWF ≥ 13 — outside the
AVM1-era target. zig 0.16 std ships `std.compress.lzma`, so lifting this later
is cheap (note: SWF-LZMA layout differs from raw .lzma — u32 compressed length
after the header, then 5-byte props; uncompressed size comes from the SWF
header, not the stream).

## D5 — Save-states: handyplay-oss `statefmt`, not our own container

**Superseded 2026-08-11** (was: a bespoke `HFS0` TLV container). The
sibling's `common/statefmt.zig` already implements the framing this needed
— self-describing recursive sections, per-section version and layout
fingerprints so a changed struct rejects stale blobs by itself, and the
four rewind rules (fixed-size sections first, 16-byte alignment, no
indeterminate bytes, constant `serialize_size`) as an enforced discipline
rather than a convention. It also reserves `7..15` for future cores, which
is where `flash_core = 7` was always meant to go. Vendored verbatim under
`vendor/statefmt/` so it can be re-synced without a merge; the enum member
is claimed by value in `core/savestate.zig` rather than by editing the
copy.

The rest stands: deterministic serialization, `serialize_size` latched
once with headroom and the tail zeroed, and **SharedObject/LSO excluded**
— rewind must not un-write persistence. One rule the format's D3 forces
that is easy to miss: anything serialized by iterating a hash map must be
written in sorted key order, or a restored map re-serializes differently.

Progress and what remains: `docs/SAVESTATE.md`.

## D6 — License: AGPL-3.0 (+ commercial dual, like handyplay-oss) — **flagged**

Matches the handyplay-oss model (`LICENSE` copied from there). **Confirm with
user before first public release.** Compatibility notes: ruffle corpus is
MIT/Apache (fine to test against, never vendored); minimp3 is CC0; open-flash
docs have no license and quote Adobe prose — read as reference, never copy
text into this repo.

## D7 — Rasterizer backend: vendor simdra's Zig core (added 2026-08-06)

`handyplay-oss/vendor/simdra` (MIT, Narek's own project) is a SIMD-accelerated
2D canvas in Zig with Skia-style primitives. Its core covers nearly the entire
`core/render/` plan: `SmPath` (moveTo/lineTo/quadratic+cubic curves),
`SmScan` scanline fill with **even-odd + nonzero** fill rules and 8×-subsample
**AA coverage**, `SmPaint` strokes with **butt/round/square caps +
miter/round/bevel joins + miter limit** (exactly DefineShape4's set),
`SmGradient` linear/radial (two-circle radial ⇒ SWF focal gradients map
directly), `SmPattern` bitmap fills, `SmMatrix`, `clip`/`clipPath` (clipDepth
masks), `isPointInPath` (button hit-testing), NEON/SSE/WASM-SIMD kernels with
generic fallback, plus PNG/JPEG/BMP *encoders* (useful for
`--headless-frames` dumps) and stb_truetype (`SmFont`) as a future device-font
fallback. **Verified: the whole Zig core semantic-checks under zig 0.16
unmodified** (`zig build-obj simdra.zig -fno-emit-bin -I . -lc`).

Consequences:
- `render/raster.zig`/`fills.zig`/`stroke.zig`/`mask.zig` become a thin
  adapter: `shape_utils.zig` (SWF dual-edge records → SmPath, still ours and
  still the hard part) + FillStyle→SmPaint/SmGradient/SmPattern mapping +
  cxform application. M2 gets AA from day one; M7 drops the AA + stroke-quality
  items.
- Vendor a copy of `zig/simdra/` (+ `stb_image.{h,c}`) into
  `handyplay-flash/vendor/simdra/` — standalone repo stays standalone. This amends
  the "no C deps" rule: stb_image is the one sanctioned C file (pre-existing,
  battle-tested, already in the handyplay ecosystem).
- Pixel format: simdra outputs rgba_unorm8 (byte order R,G,B,A). libretro
  wants XRGB8888 — one swizzle pass at the frame boundary (same as exen-core
  does today), or add a BGRA output path to simdra later.
- Per-channel cxform (mult+add incl. alpha): solids fold into the paint
  color; gradient/bitmap fills need transformed stops / a small post-pass —
  ours to write.
- Determinism: SIMD kernels may differ across ISAs, but save-state
  roundtrip verification is same-machine — fine.

**Rejected: neonGL** (`vendor/neonGL`, software OpenGL ES 1.1). Wrong
abstraction for 2D vector art: fixed-function triangles only — winding-rule
path fills would need tessellation + stencil tricks, gradients need texture
uploads, strokes are manual. It exists for the 3D micro3d/mascot content in
mophun/java-core; simdra supersedes it entirely for Flash.

## Open risks

- ~~R1: zig 0.16 build runner on this machine~~ — **resolved in M0**: exe,
  dynamic dylib, and tests all build/run fine (the 0.15.2 host-libc breakage
  does not affect 0.16). `build.sh` fallback deemed unnecessary; drop unless
  it regresses.
- R2: zig 0.16 std churn — mitigated: swfinfo exercises std.Io reader/writer,
  Io.Dir file reads, flate Decompress/Compress; all working (see M0 notes in
  git history).
- R3: stroke quality (miters, thin lines at small scales) — iterative.
- R4: no pixel-diff harness — rendering correctness is judged visually +
  trace-diff only; acceptable for now.
- R5: frame-rate oddities (0 fps, > 120) — clamp at player layer, document.
- R6: Shift-JIS for SWF < 6 — best-effort, tracked in AVM1.md notes.
