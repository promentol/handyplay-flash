# The Handyplay save-state container format

One container shared by every core (`java`, `mophun`, `mre`, `mrp`, `exen`) and by the
shared software-3D library (`vendor/neonGL`). Implemented in
[`statefmt.zig`](statefmt.zig); neonGL implements the same layout independently in C
(`vendor/neonGL/src/neon_snapshot.c`), with a cross-check test pinning the two together.

There are no save files in the wild. **One format, no migrations** — every version starts
at 1 and a mismatch is refused outright rather than half-read.

## Shape

A blob is a header followed by sections. A section is a header followed by its payload.
The header **is** the section frame: `magic` doubles as the tag and `total_size` as the
skip distance, so there is no second framing layer to keep in agreement.

```
envelope header  (magic = core FourCC)
  section header (magic = subsystem FourCC) + payload
  section header + payload
  ...
```

Inside a section the encoding is positional — sections give the resync boundaries,
independent versioning and independent fingerprints; they do not change how a subsystem
writes its own fields.

## Header — 48 bytes, on every blob and every section

| Off | Field | Meaning |
|---|---|---|
| 0 | `magic u32` | FourCC LE — core tag on the envelope, subsystem tag on a section |
| 4 | `version u32` | **per-section**; exact equality |
| 8 | `header_size u32` | `48 + tail`; exact equality |
| 12 | `total_size u32` | header + payload + padding — skip distance and truncation check |
| 16 | `format u32` | which core wrote this (`Format`) |
| 20 | `features u32` | capability claims; unknown bits refused |
| 24 | `layout u32` | `layoutHash` of the types this section dumps verbatim; 0 = none |
| 28 | `pad u32` | zero |
| 32 | `reserved[4] u32` | zero |

`Format`: `java_core=1, mophun_core=2, mre_core=3, mrp_core=4, exen_core=5, neongl=6`;
`7..15` reserved for future cores.

Every rule is enforced in one place (`statefmt.parse`), so no caller can implement four of
the five:

1. `magic`, `version`, `format`, `header_size`, `layout` must match exactly.
2. `total_size` past the buffer, or smaller than `header_size` → truncated. Trailing bytes
   past `total_size` are tolerated (that is a frontend padding to a constant serialize
   size — see D4).
3. `features & ~features_known` → refused.
4. `pad` or any `reserved` word non-zero → refused. That is what makes the words usable
   later: an old reader rejects a new writer rather than silently ignoring a field it
   needed.

### Tags vs. feature bits

Both are extension points, with deliberately opposite failure modes:

- **A tag is payload framing.** Unknown tag → skipped by `total_size`. Absent tag → that
  subsystem keeps its post-boot default. This is how a new module attaches later, and how
  a core that gains a subsystem stays readable by a build that lacks it.
- **A feature bit is a semantic claim about the whole blob** that a reader must honour —
  "this state is only correct if you also restore a GL context". Unknown bit → refused.

Use a bit when *silently skipping would be wrong*; use a tag otherwise.

### The format-specific tail

Extra `u32`s inside `header_size`, for counts a reader needs before parsing the payload
(neonGL's `tex_count`). **The tail must be a multiple of 16 bytes** — otherwise two
different tails produce the same `header_size` and a reader can mistake one for the other.
Pad with unused zero words rather than picking an odd size.

Layout fingerprints do *not* go here. `layout` is a first-class header field precisely
because a reader expecting a fingerprint and handed a blob without one must see a
mismatch, not a zero it skips.

### `layout` — what it does and does not guard

`layoutHash` is a comptime fingerprint over the `@typeName`/`@sizeOf`/`@alignOf` of the
types a section dumps verbatim. Recording it makes staleness self-detecting: change a
struct and old blobs start being rejected on their own, instead of parsing into the wrong
fields — a failure that is silent and produces plausible-looking wrong state.

It guards **layout drift only**. It says nothing about padding: a non-`extern` Zig struct
has `undefined` padding bytes, and dumping one violates D3 below no matter how well
fingerprinted it is. Those are two separate problems, and a section that dumps structs
verbatim generally needs both fixed.

## Delta-friendliness (rewind) — D1…D5

`README.md` states the determinism work exists so "replay and rewind reproduce exactly". A
libretro frontend implements rewind by XOR-ing each state against the previous one and
compressing the near-zero result. That constrains layout, and **sections make the first
constraint sharper, not softer**: a section that changes size shifts every offset after
it, turning a near-zero delta into dense noise.

**D1 — fixed-size sections first, variable-size last.** The bulk of every blob is
naturally fixed size (guest RAM, framebuffer, register file, palette) and the variable
parts are small (heaps, handle tables, stream slots, texture objects). Order sections so
the fixed ones form a stable prefix whose offsets never move across frames, and confine
resizing to the tail. This is a rule about section *order*, owned by whoever writes the
section list — `statefmt` cannot enforce it.

**D2 — 16-byte relative alignment.** The header is 48 bytes (itself a multiple of 16) and
`total_size` rounds up to 16, so every section starts at a 16-aligned offset relative to
the blob start and a delta can be taken in wide words. Only *relative* alignment is
required — two blobs need matching offsets, not any particular absolute address, which is
the frontend's to arrange if it wants the SIMD win. `SectionWriter` handles this.

**D3 — no indeterminate bytes.** Every byte must be a deterministic function of VM state,
or two snapshots of identical state XOR to garbage. `SectionWriter` zero-fills every pad
byte it introduces; callers own the rest:

- Never `@memcpy` a non-`extern` struct — its padding is `undefined`.
- Zero any tail between the written length and the size the frontend asked for.

**D4 — constant serialize size.** A rewind buffer XORs fixed-size slots, so
`retro_serialize_size()` must not move frame to frame. Keep an upper bound with slack and
zero-pad the envelope out to it; rule 2 permits the trailing bytes.

**D5 — per-section content hash** (optional) in the tail, so a rewind layer can skip
unchanged sections instead of XOR-ing them, and so "which subsystem changed this frame"
becomes observable during triage.

**D6 — store derived duplicates XOR-ed against their source.** Measured across all five
cores, the per-frame delta is ~5–10 bytes of VM state plus the framebuffer; the pixels
dominate completely, and they change because the game repainted them. The only lossless
reduction is not storing the same pixels twice.

mophun had exactly that: `vFlipScreen` copies the back buffer into `front`, so at a frame
boundary — where a frontend saves, since it runs the guest until it presents — the two are
identical, and storing both doubled the delta for no information. `front` is now written as
`front XOR pixels`: the equal case is all zeros and contributes NOTHING between frames,
while mid-composition the XOR is exactly (and only) where they differ.

Two designs were tried first and are worse, both for reasons D1 predicts:

- *Conditional inside the section* — presence varied per frame, which made a section in
  the FIXED PREFIX resize and shifted every section after it. Measured: the blob moved 32 KB
  between frames and the whole tail re-aligned, costing far more than the copy ever did.
- *A separate section at the tail* — no shifting, but toggling presence still paid the
  whole buffer each time it appeared or disappeared.

Fixed size plus XOR has neither problem. Results: FirePower 28,995 → 14,529 bytes/frame,
Boxing3D 36,763 → 6,352, Boulder 42,236 → 22,383.

The technique only applies where a core stores a derived DUPLICATE. exen, mre and mrp keep
a single framebuffer, and java's is itself a surface in the table — none has a second copy
to fold away, so their pixel deltas are irreducible.

## Persistent game saves

Persistent storage — RMS, EEPROM, on-disk game saves — is a `SAVE` section gated by the
`FEAT_SAVES` bit, as a `{name, bytes}` entry list.

- **Set** for user-initiated savestates: the state is hermetic, and loading restores the
  backing store ("savestate is truth, disk follows").
- **Clear** for rewind states: storage is left alone. This is what stops a rewind past a
  save write from un-writing it (real hardware keeps it), and it keeps `SAVE` — which is
  variable-size — from perturbing a rewind delta, since with the bit clear it contributes
  zero bytes.

The bit, not a global mode, decides per state. Open file *handles* (path, offset, mode)
are VM state, not storage, and belong in their own section alongside the register file.

What each core's storage actually is, and how it is captured:

| Core | In-game storage | Captured by | Durable across runs via |
|---|---|---|---|
| java | RMS record stores | `SAVE`, through the injected `SaveBackend` | SDL `SaveDir` (`HANDYPLAY_RMS_DIR`) |
| java | JSR-75 filesystem (`C:/`, `E:/`) | `FSYS`, by walking the injected `FileBackend` | SDL disk `FsDir` |
| mophun | the VM's `FileStore` (`vStreamOpen` files) | `STRM` (always in-state; it is pure memory) | `--save-dir=` / `HANDYPLAY_SAVE_DIR` |
| mre | host files under `fs/<drive>/` | `SAVE` (contents) + `FDES` (open handles) | the host files themselves |
| mrp | host files in the game's working directory | `SAVE` (contents) + `FDES` (open handles) | the host files themselves |
| exen | the 300-byte per-gamelet save slot | `SAVE` | `<flash>/save-<gamelet>.dat` |

Two rules the capture side follows everywhere:

- **Only guest-authored paths travel.** mre and mrp record every path the game
  *created or wrote* rather than walking a directory, so a game's own package,
  bundled assets and anything it merely read stay out of the state — and out of the
  overwrite that a load performs.
- **A restore truncates before writing.** Otherwise a shorter restored save leaves
  the tail of a longer later one behind, and the result is a splice of two states
  rather than either of them.

java captures through the *injected vtable* rather than the built-in in-memory
default, which is not a detail: serializing the concrete `MemFs` by name captured the
wrong object the moment a frontend injected its own, and the load then re-pointed the
live backend at that empty tree — silently swapping the player's filesystem out from
under the game.

## Section list per core

Ordered fixed-size first, variable-size last (D1). `~` = variable size.

| Core | Sections |
|---|---|
| **java** (`HPSS`) | `VMST` `KEYS` `M3GS`; `CLSS`~ `HEAP`~ `INTR`~ `THRD`~ `EVNT`~ `PENC`~ `MEDA`~ `M3DS`~ `FSYS`~ `NGLM`~ `NGLG`~ `SAVE`~. Reserved: `RMSD` `NETW` `INPT` |
| **mophun** (`MPHS`) | `MEMI` `REGS` `HEAP` `SCRN` `CLOK` `SYST` `TEXT` `SFNT` `D3DS`; `TASK`~ `STRM`~ `TMAP`~ `SPRT`~ `TXCK`~ `NGLC`~ |
| **mre** (`MRES`) | `MEMI` `REGS` `HOST` `TIMR` `GFXL`; `ALOC`~ `FDES`~ `SAVE`~ |
| **mrp** (`MRPS`) | `MEMI` `ALOC` `REGS` `BRDG` `HOST` `GFXL` `TIMR`; `FDES`~ `SAVE`~ |
| **exen** (`EXNS`) | `VMST` `SLAB` `VMEM` `EXNR` `HOST` `GFXL`; `CLST`~ `OHEP`~ `SAVE`~ |
| **neonGL** (`NGLS`) | `GLST` `MTRX` `LITE`; `TEXS`~ |

With `FEAT_SAVES` clear, mrp is entirely fixed-size — the best-behaved core for
rewind, and the reference case when comparing delta density.

## The two 3D engines

Both java-core renderers keep state the guest heap does not, and both needed more
than a GL snapshot:

- **Mascot Capsule Micro3D v3** — `M3DS` carries resources as source bytes plus handle
  slots, and per `Graphics3D`: the **projection registers** (§6.3), the **effect block**
  (light/toon/transparency/sphere-map), and the **engine texture table**. The projection
  registers are set once and read by every later render, so a state without them resumes
  at the constructor defaults — the same failure mophun-core hit when its `[d3d]` state
  was missing and every vertex transformed away. The texture table is built from draw
  traffic, and a figure's material references it *by index*, so losing it silently skips
  textured draws. Pointers into either table travel as **handles**, never addresses.
- **JSR-184 M3G** — the scene graph, Transforms, the Loader and animation are Java, so
  the guest heap (the `HEAP` chunk) already holds every M3G object. What it does not hold
  is `M3GS`: the **target binding** and the camera/viewport/light state. `bindTarget` and
  `releaseTarget` are separate guest calls with ordinary Java in between, so that window
  spans tick boundaries — exactly where a savestate is taken.

Both then carry their neonGL context (`NGLM`/`NGLG`), because GL latches state at call
time: a light's position is stored already transformed by the model-view in force at
`glLight`, and `glTexImage2D` copies its texels.

A bound surface travels as a **handle**, and the pixel slice is re-derived from the
restored `PENC` table on load. If the surface is gone the binding is dropped rather than
left pointing at the previous process's memory — and a frame cannot be open with nothing
to draw into.

## Adding a section

1. Pick a FourCC and add it to the core's tag list, in D1 order — fixed-size sections
   before variable-size ones. This is the part that is easy to get wrong later and
   invisible when you do: the state still loads, rewind just quietly gets expensive.
2. If the section dumps any struct verbatim, declare `layout = layoutHash(.{T, ...})` —
   and check whether that struct should be `extern` first (D3).
3. If a reader that does not understand the section would be *wrong* rather than merely
   incomplete, add a feature bit too.
4. Add the round-trip test, and the negative ones: an injected unknown section is skipped,
   and the section's absence still loads.
