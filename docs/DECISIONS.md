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

## D3 — JPEG: pure-Zig baseline decoder

`codecs/jpeg.zig`, ~1.5k lines expected. We must own SWF stream surgery
regardless of decoder (leading EOI/SOI strip, JPEGTables splice before SOS for
DefineBits, JPEG3 alpha = separate zlib plane composited after decode).
exen-core has a pure-Zig PNG precedent; zero C deps keeps the future wasm
build clean. Progressive JPEG: clean error, out of scope. **Contingency**: if
it stalls M4 by more than a week, vendor nanojpeg (single-file C) behind the
same interface.

## D4 — LZMA (ZWS) deferred

`error.LzmaUnsupported` with a clear message. ZWS is SWF ≥ 13 — outside the
AVM1-era target. zig 0.16 std ships `std.compress.lzma`, so lifting this later
is cheap (note: SWF-LZMA layout differs from raw .lzma — u32 compressed length
after the header, then 5-byte props; uncompressed size comes from the SWF
header, not the stream).

## D5 — Save-states: own HFS0 TLV container

Magic `HFS0`, u32 version, `[tag:u32][len:u32][bytes]` sections (SWFH movie
hash, DISP display list, AVM1 object table + stack + registers, TIMR, RAND,
INPT). Deterministic serialization; libretro layer latches `serialize_size`
once (+headroom) and zeroes the tail. **SharedObject/LSO excluded** — rewind
must not un-write persistence. Future: optional migration to handyplay-oss
`common/statefmt.zig` framing (`flash_core = 7` is reserved there) — a
mechanical change.

## D6 — License: AGPL-3.0 (+ commercial dual, like handyplay-oss) — **flagged**

Matches the handyplay-oss model (`LICENSE` copied from there). **Confirm with
user before first public release.** Compatibility notes: ruffle corpus is
MIT/Apache (fine to test against, never vendored); minimp3 is CC0; open-flash
docs have no license and quote Adobe prose — read as reference, never copy
text into this repo.

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
