# Developing handyplay-flash

Everything behind the [README](README.md): how it is built, how it is tested,
why it is shaped the way it is, and where each decision is written down.

**In short:** a Flash Player written from scratch in Zig 0.16. AVM1 only
(ActionScript 1/2, SWF v4–v8), a software rasterizer, two frontends — SDL3 and
libretro. 679 of 680 scorable Ruffle conformance directories pass.

## Getting set up

Requires **Zig 0.16** (`zvm install 0.16.0`). Plain `zig` on `PATH` may be
0.15.2, which is the wrong one — 0.16 rewrote `std.Io` and this codebase is
written against that rewrite.

```sh
zig build                 # tools → zig-out/bin/ (swfinfo, swfdump, trace_runner, …)
zig build test            # unit tests
zig build sdl             # the SDL3 frontend
zig build run-sdl -- samples/delve/delve.swf \
    --device-font vendor/fonts/Poppins-Medium.ttf
```

Text is in the *device* font, so the player has to be handed a face — without
one an unembedded font measures zero, which is exactly what a machine that
lacks it does. That seam is deliberate: `core/` does no I/O, so the frontend
reads the file and passes bytes.

### The sample movies

`samples/` holds three movies written for this repo, each one ActionScript 2
class compiled by [mtasc](tools/as2/compiler) — no library, no embedded
assets, every pixel drawn by script. `hello` is the animation on the README,
`2048` and `delve` are playable games. They double as smoke tests: `delve` is
deterministic on frame 1, which makes it usable as a conformance case.

---

## Why

### Why AVM1 only?

Flash had two virtual machines, and they share almost nothing. AVM1 runs
ActionScript 1 and 2; AVM2 runs ActionScript 3 with a different bytecode, a
verifier, a class loader and a different runtime library. Supporting both is
not a feature — it is two interpreters in one repository.

AVM1 is the half worth having first. It covers the long tail of 2000s web
games, the whole Newgrounds-and-portals era, and **all** of Flash Lite, which
is what makes this useful on a handheld. AVM2 files are detected and rejected
cleanly, with a message, rather than half-run into confusing failure. Support
for it is a possible future direction, not a goal.

### Why Zig?

Because the target is a **libretro core on a slow ARM handheld**, and that
rules out most of the alternatives on its own. No runtime, no garbage
collector, no hidden allocations — a shared library that dlopens into
RetroArch and runs on a device with a Cortex-A53 and no reliable GPU.

It also buys things this particular problem wants. `comptime` builds the tag
and opcode tables without codegen scripts. The allocator is an explicit
parameter, which is what makes a byte-identical save-state round-trip
testable. Cross-compilation to the handheld targets is a flag, not a
toolchain. And there is no package manifest to resolve — the standard library
plus a handful of vendored sources, all listed in [Credits](#credits).

The version pin is real, not incidental: Zig 0.16 rewrote `std.Io`, and the
codebase is written against that rewrite.

### Why CPU rasterization?

Partly the target, partly the shape of Flash itself.

**The target has no GPU worth relying on.** A libretro core has to render into
a framebuffer the frontend hands it, on hardware where GL support ranges from
good to absent. A software rasterizer is the portable answer, and it is the
same answer the sibling [handyplay-oss](https://github.com/promentol) cores
give.

**Flash's model does not map cleanly onto a GPU pipeline.** Even-odd *and*
non-zero fill rules in the same file. Blend modes that composite through a
layer, so a blended clip blends as a whole rather than child by child. Colour
transforms with per-channel multiply *and* add, including alpha. Surfaces
that hold straight rather than premultiplied colour, because that is what
Flash gradients do. Each of those is a special case on a GPU and a
straightforward function on a CPU.

**Determinism is testable.** A conformance ratchet that compares 680
directories of trace output, and a save-state gate that demands a
byte-identical serialise → restore → re-run, both want a renderer that
produces the same bytes every time.

The honest cost: it is **fill-rate bound**. Measured on this machine, a
640×480 stage costs about 12 ms a frame and 320×240 about 4.5 ms — and an idle
stage costs very nearly what a busy one does, because the cost is a full-stage
repaint. Scene complexity is close to free; resolution is nearly everything.
That measurement is why `samples/delve` is a turn-based roguelike rather than
a bullet-hell shooter.

Rendering is [**simdra**](https://github.com/promentol/simdra) (MIT), a
SIMD-accelerated 2D canvas in Zig, vendored as source. It was chosen over a
software OpenGL ES backend for exactly the reasons above — fixed-function
triangles are the wrong abstraction for winding-rule path fills. See
[ADR D7](docs/DECISIONS.md).

### Why does it look so much like Ruffle?

Because [Ruffle](https://github.com/ruffle-rs/ruffle) got there first and got
it right, and this project says so plainly.

Ruffle is the **behavioural reference**: where Adobe's prose and Ruffle
disagree, handyplay-flash matches Ruffle, because Ruffle was written against real
content and the prose was not. The interpreter is Ruffle-shaped by decision —
a linear byte reader over the action slice rather than open-flash's
control-flow graph ([ADR D0](docs/DECISIONS.md)). Ruffle's test corpus is what
the conformance ratchet scores against.

That corpus is MIT/Apache licensed and is read in place from a git-ignored
clone — **never vendored, never copied into this repository**. handyplay-flash is
an independent implementation that treats Ruffle as the spec when the spec is
ambiguous, which it very often is.

---

## Status

**M4 is complete.** All 679 scorable Ruffle conformance directories pass,
clearing M4's ≥300 gate, plus 21 of 26 image comparisons.

Working today:

- **Interpreter** — the full AVM1 opcode set, the whole `MovieClip` surface,
  `flash.geom`, `Date`, timers, `Object.registerClass`, `watch`, the
  AsBroadcaster singletons, `XML`/`XMLNode`, and `flash.filters`.
- **Display list and timeline** — clips, buttons that draw, hit-test and react
  (press/release/roll/drag, `keyPress`, focus, `Selection`, Tab order), masks,
  and PlaceObject3 blend modes and `cacheAsBitmap` compositing through a layer.
- **Text** — static text and text fields both render glyphs: formatting spans,
  HTML in and out, wrapping, alignment, autosize, two-way `variable` binding,
  selection, typing, IME, and an optional host device font.
- **Bitmaps** — every `DefineBits*` family decodes and paints, and
  `flash.display.BitmapData` is complete: build, transform, blit, hit-test,
  dissolve, Perlin fill, colour matrix, and rendering a display object into
  one under any blend mode.
- **Loading** — `loadVariables`, `LoadVars`, `XML.load`, `loadMovie` with real
  `_levelN` levels and cross-movie libraries, `MovieClipLoader` with its full
  event sequence, `XMLSocket`, `FileReference` — all through a host seam.
- **Audio** — PCM, ADPCM and MP3 (vendored minimp3), `StartSound`, the `Sound`
  class, `SoundStreamBlock` sync and FLV audio. See [docs/AUDIO.md](docs/AUDIO.md).
- **Flash Lite** — `fscommand` and `fscommand2` as one command table, a
  `lite`/`avm1`/`avm2` profile detected from the movie itself, and a soft-key
  strip. See [docs/FLASH-LITE.md](docs/FLASH-LITE.md).

### Input binds itself

The neatest trick in here. A load-time survey (`core/key_survey.zig`) walks the
bytecode and records every key a movie can *notice* — button conditions, clip
events, `Key.isDown` arguments, the literals a `Key.getCode()` result is
compared against. The frontend then binds **actions**, not key codes.

So the arrows drive a game that reads arrows, and the same arrows drive a
phone game that only ever reads the keypad, untouched, from the same keyboard.
On a RetroPad the D-pad, A and B land on whatever that particular movie
listens for, and per-movie bindings are exposed as core options.

### Frontends

**SDL3** — `zig build run-sdl -- file.swf`, with `--headless-frames N` for PNG
dumps, `--capture tick:path` for mid-run frames, and `--input` to replay a
recorded event script.

**libretro** — `sh tools/build-libretro-mac.sh install` builds a universal
dylib and drops it into RetroArch: same engine, the RetroPad bound by the same
survey, an intro and controls legend on load, and a dlopen harness that
exercises the whole C ABI without RetroArch.
See [docs/LIBRETRO.md](docs/LIBRETRO.md).

### Milestones

| Milestone | Deliverable | State |
|---|---|---|
| M0 | repo + specs + `swfinfo` (header/decompression) | ✅ |
| M1 | full tag parser + `swfdump` (56-SWF corpus clean) | ✅ |
| M2 | display list + timeline + rasterizer v1 + SDL3 pixels | ✅ |
| M3 | AVM1 interpreter (full opcode set) + trace conformance | ✅ 76/697 |
| M4 | objects/globals/buttons/text/bitmaps, ≥300/697 | 🔶 A+B+C+D+E+L done, **679/679** |
| M5 | libretro core + save-states (byte-identical roundtrip) | ✅ core plays in RetroArch; save-states + rewind on by default, 36/36 games and 195/195 corpus dirs |
| M6 | audio (PCM/ADPCM → MP3 → streaming sync) | 🔶 plays: event sounds, streams, FLV audio |
| M7 | polish: morph shapes, edit text, AA, masks, ≥450/697 | — |

Living coverage matrices: [docs/TAGS.md](docs/TAGS.md),
[docs/AVM1.md](docs/AVM1.md), and the ratchet at
`tests/conformance/pass_list.txt`.

---

## Building

```sh
zig build                 # tools → zig-out/bin/ (swfinfo, swfdump, trace_runner, …)
zig build test            # unit tests
zig build sdl             # the SDL3 frontend
zig build libretro        # the libretro core
zig build run-swfinfo -- file.swf
```

Cross-compiling is a target flag — zig carries the libc for every
platform we ship, so one machine can build them all:

```sh
zig build libretro -Doptimize=ReleaseFast -Dstrip=true -Dtarget=x86_64-windows-gnu
zig build libretro -Doptimize=ReleaseFast -Dstrip=true -Dtarget=aarch64-linux-gnu
```

`-Dstrip=true` is what release builds use; it takes a Linux `.so` from
15 MB to 2.6 MB. **Android is the exception**: zig ships a libc for
everything except Bionic, so it needs the NDK's sysroot —

```sh
NDK=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot
zig build libretro -Dtarget=aarch64-linux-android -Dandroid-api=29 --sysroot "$NDK"
```

### Releases

`.github/workflows/release.yml` builds every platform and attaches the
zips to a GitHub release. Three ways in:

| trigger | what it publishes |
|---|---|
| `git push origin main` | rebuilds the rolling **`nightly`** prerelease, same download links every time |
| `git tag v0.2.0 && git push origin v0.2.0` | a real release named after the tag |
| Actions → release → Run workflow | a release named after the tag you type (draft by default) |

It gates on `zig build test` first — the trace and save-state corpora
need ruffle's test suite, which is not in this repository, so those stay
a local gate. `[skip ci]` in a commit message skips a run, and a new push
cancels the run still going for the same branch.

```
linux    x86_64 · i686 · aarch64 · armhf
windows  x86_64 · i686
macOS    universal (arm64 + x86_64), plus each arch on its own
android  arm64-v8a · armeabi-v7a · x86_64 · x86
```

To rehearse it without pushing a tag — same targets, flags and zips:

```sh
sh tools/build-release.sh                # everything this host can build
sh tools/build-release.sh linux-aarch64  # or one platform
```

Each zip carries the core, `flash_libretro.info` with the tag stamped
into `display_version`, the licence and an install note
(`tools/package-core.sh`).

### Testing

```sh
sh tests/conformance/run_avm1.sh          # 680-dir trace ratchet
sh tests/conformance/images.sh /tmp/i.txt # image comparisons, own ratchet
sh tools/as2/as2.sh check                 # authored AS2 cases, traces + pixels
sh tests/conformance/savestate.sh /tmp/ss.txt 8   # 195 dirs, save/restore
sh tests/conformance/games.sh /tmp/g.txt 60       # 36 games, container gates
sh tests/conformance/statebytes.sh /tmp/b.txt 8   # byte-complete states
```

The AS2 cases are authored here, compiled by mtasc in Docker, and their
expectations recorded from Ruffle's own wasm through headless Chromium. The
expectations are checked in, so `check` needs neither Docker nor a network —
the same bargain Ruffle's own corpus makes.

## Layout

```
core/            the player — no I/O, no pixels-vs-twips confusion
  avm1/          interpreter, objects, globals
  display/       display list, movie clips, text, bitmaps
  swf/           tag parser
  codecs/        ADPCM, MP3, PCM
frontends/sdl/   SDL3 desktop player
frontends/libretro/  the libretro core
samples/         movies written for this repo, with their source
tools/           swfinfo, swfdump, trace_runner, the AS2 toolchain
vendor/          simdra, statefmt, minimp3, a font
docs/            architecture, ADRs, coverage matrices
```

## Documentation

- **[docs/PROJECT-STATE.md](docs/PROJECT-STATE.md) — start here.** Full state, environment traps, workflows, what's next.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — module map, frame lifecycle, memory model
- [docs/DECISIONS.md](docs/DECISIONS.md) — ADRs: linear interpreter, UCS-2 strings, GC handles, the rasterizer choice
- [docs/SPEC.md](docs/SPEC.md) — the spec stack
- [docs/TESTING.md](docs/TESTING.md) — corpora, conformance, determinism gates
- [docs/FLASH-LITE.md](docs/FLASH-LITE.md) · [docs/LIBRETRO.md](docs/LIBRETRO.md) · [docs/AUDIO.md](docs/AUDIO.md) · [docs/SAVESTATE.md](docs/SAVESTATE.md)

Reference clones of [ruffle](https://github.com/ruffle-rs/ruffle) and
[open-flash](https://github.com/open-flash) are expected at `reference/`
(git-ignored); the test corpora are read from there.

## Credits

- [**Ruffle**](https://github.com/ruffle-rs/ruffle) — the behavioural
  reference and the conformance corpus. Where prose and Ruffle disagree,
  Ruffle wins.
- [**open-flash**](https://github.com/open-flash) — the AVM1 action
  documentation.
- [**simdra**](https://github.com/promentol/simdra) (MIT) — the rasterizer.
- [**minimp3**](https://github.com/lieff/minimp3) (CC0) — MP3 decoding.
- **stb_image** / **stb_truetype** (public domain, via simdra).
- [**Poppins**](https://fonts.google.com/specimen/Poppins) (SIL OFL) — the
  device font used by the samples.

## License

AGPL-3.0 — see [LICENSE](LICENSE). Commercial licensing is available
separately, following the handyplay-oss model.
