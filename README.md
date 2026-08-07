# handyflash

A from-scratch **Flash Player** in **Zig 0.16** — **AVM1 only** (ActionScript
1/2, SWF v4–v8), with a software rasterizer and two frontends: **SDL3** and
**libretro**. No dependencies beyond the Zig standard library (minimp3 will be
vendored for MP3 audio later).

Sibling in spirit to the [handyplay-oss](../handyplay-oss) emulator cores
(exen/java/mophun/mre/mrp) and shaped the same way — `core/` is
frontend-agnostic, frontends are thin — so it can later be adopted as their
6th core.

AVM2 (ActionScript 3) files are detected and rejected; AVM2 support is a
possible future direction, not a goal.

## Status

Early — M1 (full AVM1-scope tag parser; ruffle corpus scans clean). See the living coverage
matrices: [docs/TAGS.md](docs/TAGS.md), [docs/AVM1.md](docs/AVM1.md), and the
conformance ratchet `tests/conformance/pass_list.txt`.

| Milestone | Deliverable | State |
|---|---|---|
| M0 | repo + specs + `swfinfo` (header/decompression) | ✅ |
| M1 | full tag parser + `swfdump` (56-SWF corpus clean) | ✅ |
| M2 | display list + timeline + rasterizer v1 + SDL3 pixels | — |
| M3 | AVM1 interpreter (SWF4/5) + trace conformance ≥80/697 | — |
| M4 | objects/globals/buttons/text/bitmaps, ≥300/697 | — |
| M5 | libretro core + save-states (byte-identical roundtrip) | — |
| M6 | audio (PCM/ADPCM → MP3 → streaming sync) | — |
| M7 | polish: morph shapes, edit text, AA, masks, ≥450/697 | — |

## Building

Requires **zig 0.16** (`zvm install 0.16.0`).

```sh
zig build                 # tools → zig-out/bin/ (swfinfo, …)
zig build test            # unit tests
zig build run-swfinfo -- file.swf
# later: zig build sdl (M2) · zig build libretro (M5)
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — module map, frame lifecycle, memory model
- [docs/SPEC.md](docs/SPEC.md) — the spec stack (open-flash AVM1 docs, Ruffle errata, Adobe PDF, ruffle source)
- [docs/TESTING.md](docs/TESTING.md) — parser corpus, 697-case AVM1 trace conformance, determinism gates
- [docs/DECISIONS.md](docs/DECISIONS.md) — ADRs (linear interpreter, UCS-2 strings, gc handles, …)

Reference clones of [ruffle](https://github.com/ruffle-rs/ruffle) and
[open-flash](https://github.com/open-flash) are expected at `reference/`
(git-ignored); test corpora are read from there.

## License

AGPL-3.0 (see LICENSE). Commercial licensing available separately, following
the handyplay-oss model.
