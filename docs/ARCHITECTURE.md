# handyplay-flash architecture

A from-scratch Flash Player in Zig 0.16. **AVM1 only** (SWF v4–v8; AVM2 files are
rejected at load). Software rasterizer, SDL3 + libretro frontends. Shaped like the
handyplay-oss cores (`core/` + `frontends/{sdl,libretro}/`) so it can later be
adopted as their 6th core with zero restructuring.

## Module map

```
bytes ──> core/swf (decode only) ──> core/display (timeline/display list)
                    │                        │            │
                    │                 core/avm1 (interpreter)
                    │                        │            │
              core/codecs             core/render (rasterize) ──> framebuffer XRGB8888
                    │                        │
              core/audio (M6) ──────> frontends (sdl / libretro)
```

- **core/swf/** — pure decoding, zero interpretation. `movie.zig` owns the
  decompressed body for the process lifetime; every other structure stores
  *slices into it* (action bytecode, raw JPEG data, glyph shape bytes — never
  copies). Two-pass, Ruffle-style: **preload** walks the tag stream once,
  registering definition tags into `display/library.zig` and building a
  per-frame index of control tags; **run_frame** executes only control tags.
  Unknown tags: log once, skip by length, never fail.
- **core/avm1/** — Ruffle-style **linear interpreter** (decision, ADR in
  DECISIONS.md): `activation.zig` holds a byte reader positioned inside an
  action slice; each step decodes one action and dispatches; `If`/`Jump` seek
  the reader; reader-at-end is an implicit return; an action budget is checked
  every 2000 actions. `runtime.zig` owns the shared value stack, the 4 global
  registers, the constant-pool stack, per-swf-version prototype sets, and the
  **clip-exec list** (intrusive list of MovieClips in *instantiation order* —
  this list, not the display list, determines AVM1 execution order).
  Objects are **one concrete ScriptObject + a NativeObject enum payload** (no
  vtables). All AVM1 allocation goes through `gc.zig` **u32 handles into an
  object table** — mark-sweep collection, and save-states become a table walk.
- **core/display/** — display list + timeline, ported from Ruffle semantics
  (see Frame lifecycle below and `movie_clip.zig` doc comments; `run_goto` is
  the hardest function — rewind + aggregate per-depth place deltas).
- **core/render/** — hard split: `shape_utils.zig` (SWF dual-edge records →
  ordinary closed paths; port of ruffle's shape_utils) vs `raster.zig` (our
  scanline rasterizer; Ruffle has no software renderer so this part is novel).
  Renders directly into XRGB8888 — frontends never convert.
- **core/flash.zig** — the umbrella host seam. Frontends call only this.

## Host seam (core/flash.zig)

```zig
init(allocator)                       // once; libretro passes std.heap.c_allocator
loadSwf(bytes) !MovieInfo             // {width,height px, fps, frame_count, swf_version}
                                      // FileAttributes.ActionScript3 => error.Avm2Unsupported
tick(elapsed_ms)                      // fixed-timestep accumulator; runs 0..n frames
framebuffer() []const u32             // XRGB8888, w*h, valid after tick
setMouse(x,y,buttons) / keyEvent(code,down)
stateSize() / saveState(buf) / loadState(buf)
trace_sink: ?*const fn([]const u8)    // trace() hook (trace_runner, tests)
```

## Frame lifecycle (single-phase AVM1)

Per frame (from ruffle `player.rs` / `frame_lifecycle.rs` — AVM1 has none of
the AVM2 4-phase machinery):

1. Walk the **clip-exec list in instantiation order**; for each clip: fire
   `onLoad` (first frame — *instead of* EnterFrame, before tags) or
   `onEnterFrame`, then execute this frame's control tags (DoAction /
   PlaceObject / RemoveObject / SetBackgroundColor / StartSound /
   SoundStreamBlock) up to ShowFrame. DoAction bodies are *queued*, not run
   inline.
2. Audio update (no-op until M6).
3. **Drain the ActionQueue** by priority (Initialize → Construct → Default),
   `while`-pop because actions enqueue more actions; skip actions whose clip
   was removed since queueing.
4. Update drag, then mouse state → button/clip events.
5. Mark dirty. Rasterization happens on demand when `framebuffer()` is asked,
   only if dirty.

## Memory model

- The decompressed SWF body is immortal (freed at shutdown); parsed structures
  reference it by slice.
- AVM1 objects live in the gc object table (u32 handles). Roots: value stack,
  scopes, registers, constant pools, display-list objects, globals.
- Strings are `[]u16` UCS-2 code units (ADR D1), interned.
- Save-states (`HFS0` TLV, ADR D5) serialize the object table + display list +
  timers + rng + input. **SharedObject/LSO data is excluded** — rewinding a
  state must never un-write persistence.

## Coordinates

Twips end-to-end inside core (1 px = 20 twips); `render/canvas.zig` applies
the stage matrix and ÷20 exactly once. Frontends deal in pixels only.

## Frame pacing

The SWF header's own frame rate is authoritative (clamped 0.01–120 at the
player layer). libretro reports it via `retro_get_system_av_info`; `tick`
advances a **fixed timestep** per frame (determinism for save-states/rewind —
same invariant as the other handyplay cores). The clock is never host elapsed
time.
