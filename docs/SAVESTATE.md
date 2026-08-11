# Save-states and rewind — WORKING

**All 36 games** and **all 195 multi-frame corpus dirs** round-trip. They
are ON by default; turn them off with the `flash_savestates` core option
(RetroArch → Quick Menu → Core Options) if you want the memory back.

    core/savestate.zig        the container, the primitives, the walker
    core/flash.zig            Player.saveState / loadState, the sections
    core/avm1/natives.zig     stable ids for natives made after boot
    vendor/statefmt/          the container format, vendored verbatim

Three gates, each stricter than the last:

| gate | what it proves | result |
|---|---|---|
| `tests/conformance/savestate.sh` | a restored run TRACES identically | 195 of 195 |
| `tests/conformance/games.sh` | the four container rules on real games | 36 of 36 |
| `tests/conformance/statebytes.sh` | those rules on the whole corpus | 655 of 659 |

The four `statebytes` failures are host-side, not state-side:
`define_font_glyph_table_{order,overlap}` do not load in the libretro
host at all, and the two `file_reference_download_httperror_*` produce no
output in it either way.

## What it is

The container is `statefmt` — the same self-describing recursive-section
format every Handyplay core uses, vendored from `handyplay-oss/common`
and registered as `flash_core = 7` (upstream reserves 7..15). ADR D5's
bespoke HFS0 is superseded: statefmt already implements the framing, the
layout fingerprints, and the four rules a rewind layer needs.

    D1  fixed-size sections first, variable-size last
    D2  16-byte relative alignment
    D3  no indeterminate bytes
    D4  serialize_size constant across a run

**A state carries only what cannot be RE-DERIVED from the movie.**
Restoring builds a fresh `Player` from the same SWF — with
`Options.skip_first_frame`, so the display tree starts EMPTY — and
applies the state over it. The character library, decoded shapes, glyph
caches, decoded library sounds and the prototypes the globals installer
builds are never written. That rule is also the rewind budget, and it is
why a loaded child SWF travels as a URL to re-fetch rather than as
megabytes of bytes.

### The walker

`savestate.writeScalars`/`readScalars` walk a struct at COMPTIME. Every
field is either serialized by type — bool, any int width and signedness,
float, enum, array, optional, nested struct — or named in that struct's
skip list. **A field that is neither fails the build**, with its name in
the error. A hand-maintained field list is exactly the thing that rots
silently; this one cannot.

Two details it gets right on purpose: a NaN is canonicalised (its payload
bits are not a function of state, and D3 forbids bytes that are not), and
an optional writes its payload even when absent, so its size does not
depend on its value (D1).

## The sections

| section | contents |
|---|---|
| `PLYR` | the frame clock, instance counter, background, quality, sound counters |
| `VMSC` | ~90 `Vm` scalars and prototype handles, walked at comptime |
| `MOVS` | runtime-loaded movies (by URL), `_levelN`, in-flight loads, external sounds |
| `AUDI` | the mixer's voice table |
| `DISP` | the display tree: every scalar, names, drawings, buttons, text fields, the mouse anchors |
| `STRS` | the string pool |
| `TIMR` | `setInterval`/`setTimeout`, callbacks and arguments |
| `POOL` | the AVM1 constant pools and the `registerClass` bindings — all three registries |
| `HEAP` | the AVM1 object table, natives, closures |
| `NATV` | BitmapData pixels, TextFormats, XML trees, NetStream buffers |

Excluded permanently, per ADR D5: **SharedObject/LSO**. Rewinding past a
write must not un-write it.

Serialization happens BETWEEN FRAMES, which is a simplification worth
naming: at a frame boundary the AVM1 operand stack is cleared, the four
global registers are reset and no activation is live, so none of that
transient state has to be written — it is empty by construction.

### Three things the sections do NOT carry, on purpose

- **A `Drawing`'s bitmap fill pointer to a live `BitmapData`** is written
  as the fill's style minus the pointer; `NATV` re-attaches the pixels an
  `attachBitmap` borrows, but a `beginBitmapFill` against a live
  BitmapData paints flat until it is set again.
- **A NetStream's decoder state** — the Sorenson reference picture. A
  restored stream resumes at the next keyframe.
- **Sound envelopes**, which point into the movie arena and are
  re-derived by whoever restarts the sound.

## What it costs

    36 games: state 1.26 MB median (3.0 MB worst), and the
    one-frame delta a rewind layer stores is 96 B median,
    27 of 36 under 4 KB/frame.

The delta is small while the display tree and the object table keep their
SHAPE, and jumps to roughly the state size on a frame where either
resizes — a variable-length section that grows shifts every byte after
it, which is what D1's "fixed-size first" rule is about. `AntiMosquito`
is the worst case at ~1 MB/frame because it creates tens of thousands of
objects every frame; that is the movie's own doing, and it used to be
forty times worse (below).

`libretro_test_host … --state N` prints the whole picture, and each check
fails closer to its cause than a framebuffer comparison would:

    HANDYPLAY_FLASH_SAVESTATES=1 ./zig-out/bin/libretro_test_host \
        zig-out/libretro/flash_libretro.dylib games/Snake.swf --frames 0 --state 40

    [state] D3 ok: two saves byte-identical
    [state] D4 ok: size stable across a run
    [state] restore ok: re-save reproduces the blob
    [state] one-frame delta: 4 words in 4 runs -> ~48B/frame

- **D3** serialises twice into buffers pre-filled `0x00` and `0xFF`, so a
  leftover byte cannot agree by luck, and attributes any difference to a
  section.
- **D4** re-checks the size after 30 more frames.
- **Restore completeness** re-serialises immediately after a load and
  demands the same bytes — anything the load left behind shows up here.
  This is the check that found nearly every bug below.
- **D1** reports the delta per section, walking BOTH section tables in
  step so a section that RESIZED is named as such instead of making the
  whole tail look changed.

## Two engine defects this work exposed

Neither was a save-state bug; both were found because a state makes the
engine's own bookkeeping visible.

- **The AVM1 heap never freed anything.** `AntiMosquito` reached 448,996
  object slots in sixty frames — a leak while merely playing — which is
  why its state was 36 MB. `core/avm1/gc.zig` is the mark-sweep ADR D2
  called for: roots are the globals, the stack and registers, the display
  tree, timers, the class registry, focus and drag; marking walks protos,
  properties and their accessors, scope chains, interfaces, watchers and
  native payloads; sweeping empties dead slots onto a free list and gives
  the top of the table back. The same movie now sits at ~27,000 slots and
  a 1 MB heap section, and the collector runs at a frame boundary only —
  no activation live, stack clear.
- **Constant pools leaked per call.** Every `Push cpN` re-decoded its
  pool; `vm.pool_cache` now keys them by address.

## The bug diary

Kept because none of these would have been obvious from reading the code.

- **An invalid free at teardown**, from allocating restored names out of
  the movie arena when `DisplayObject.deinit` frees them with the gpa. It
  hid *86 dirs* behind a crash.
- **`owns_kind` must not be restored.** Ownership is a fact about how
  THIS instance was built, and the restore built it; taking the saved
  value double-frees.
- **The constant pools.** Without `Vm.pools` every `Push cpN` resolves to
  nothing, so scripts quietly read `undefined`.
- **Appending one list with two allocators.** `readPools` and
  `readClasses` used the gpa where the runtime uses the VM arena; the
  first later append then reallocated arena memory through the gpa.
- **`ctx.movie` is what resolves a character id**, so restoring a clip
  that holds a LOADED movie has to lend that movie to the context for its
  whole subtree — exactly as playback does.
- **A `createTextField` field has character id 0**, so the restore
  rebuilt it as an empty clip and the record read past its end. The
  record's KIND now drives the rebuild, and the bytes are consumed even
  when the two disagree.
- **A restored button was never `ensureInit`ed**, so its hit area was
  empty and the mouse could not find it.
- **A clip's `drawing` is not in the movie.** Without it a scripted clip
  has no bounds at all, which makes it invisible to the pointer.
- **`Object.registerClass` has three registries** — the active one and
  one per SWF-version environment. Carrying only the active one lost
  every binding the moment a SWF6 movie loaded.
- **A native installed on an INSTANCE has no boot-time slot to inherit
  its pointer from.** `Sound`'s `duration`/`position` and every
  `ASnative(cat, i)` function now carry a stable id
  (`core/avm1/natives.zig`).
- **The restore names instances too**, which moved Flash's global
  `instanceN` counter; the saved value is pinned back afterwards.
- **A field's variable must be RE-LINKED, not re-created**: running the
  creation path let the variable overwrite the text the state had just
  restored.
- **Derived state must not be written.** `EditText.dirty` is set true by
  every restore, so writing it made a re-save differ from the save it
  came from.
- **The string pool is now the PLAYER's, not the save's.** Rebuilt per
  save, one new string shifts every index after it and the heap — which
  stores strings by index — rewrites itself: 4005 of 4024 STRS words and
  21919 of 29460 HEAP words changed in a single Snake frame. Stable ids
  fix it; `compact` reclaims dead entries only when they outnumber the
  live ones.
