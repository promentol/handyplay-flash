# handyflash — agent notes

Flash Player in Zig 0.16, AVM1 only. Standalone repo; shaped like the
handyplay-oss cores. Plan of record: milestone table in README; per-file
contracts are in each stub's `//!` header; ADRs in docs/DECISIONS.md.

## Build

- **Zig 0.16 required**: `~/.zvm/0.16.0/zig` (plain `zig` on PATH may be
  0.15.2 — wrong). The 0.16 build runner works on this machine (unlike
  0.15.2's); `zig build` / `zig build test` are the real paths.
- Commit directly on `main` (user convention).

## Zig 0.16 idioms used here (std.Io rewrite)

- CLI entry: `pub fn main(init: std.process.Init) !void` — gives `init.gpa`,
  `init.io`, `init.arena`, `init.minimal.args.toSlice(arena)`.
- Files: `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))`.
- Stdout: `std.Io.File.stdout().writer(io, &buf)` → use `.interface`, flush.
- In-memory reader: `std.Io.Reader.fixed(bytes)`; growing writer:
  `std.Io.Writer.Allocating` (give it capacity before handing to flate
  Compress — it asserts buffer len > 8).
- flate: `std.compress.flate.Decompress.init(&reader, .zlib, &window)` then
  `.reader.streamRemaining(&writer)`; Compress: `try .init(&writer, &buf,
  .zlib, .default)` … `.finish()`.
- ArrayList: `std.array_list.Managed(u8)` (no `.writer()` anymore).

## Rules

- **No new dependencies** (user preference: Zig + stdlib; minimp3 vendored in
  M6 is the only planned exception).
- `core/` never does I/O and never sees pixels-vs-twips confusion (twips
  inside, px only in canvas.zig/frontends).
- Parsed structs slice into the movie buffer — don't copy tag payloads.
- Match Ruffle behavior over Adobe prose when they disagree; the errata wiki
  overrides both. Record quirks in docs/TAGS.md / docs/AVM1.md notes.
- Trace-conformance ratchet: never remove entries from
  tests/conformance/pass_list.txt.
- When running the SDL player for user feedback: background, **no timeout**.

## Reference map (git-ignored reference/)

- Binary layouts: `reference/ruffle/swf/src/read.rs` (final tiebreaker)
- Action semantics: `reference/openflash/open-flash/content/documentation/avm1/actions/`
- Interpreter/timeline behavior: `reference/ruffle/core/src/avm1/`,
  `display_object/movie_clip.rs`, `player.rs`
- Shape records → paths: `reference/ruffle/render/src/shape_utils.rs`
- Corpora: `reference/ruffle/swf/tests/swfs/` (117 parser),
  `reference/ruffle/tests/tests/swfs/avm1/` (697 trace conformance)
- Samples: `reference/openflash/domu-player/src/static/*.swf`
