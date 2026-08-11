# AVM1 action coverage matrix

Seeded from `reference/openflash/open-flash/content/documentation/avm1/actions/_index.md`
(cross-validated against ruffle `swf/src/avm1/opcode.rs`). Per-action spec:
the open-flash `actions/*.md` page of the same name.

Encoding rule: code `< 0x80` ⇒ no payload (1 byte). Code `>= 0x80` ⇒ u16le
length + payload.

Status: `todo` → `decode` (opcodes.zig) → `exec` (interpreter) → `done`
(corpus-verified). Milestones: M3 = SWF3/4/5 core, M4 = objects/classes/v6-7.

**M3 CLOSED**: every opcode 0x00–0x9F decodes and executes.
**M4 workstreams A and B CLOSED.** Corpus: 205/680
(tests/conformance/pass_list.txt).

**Workstream A complete (A1-A6)**: display properties, target paths, clip
member resolution, runtime clip creation, `Call`, throw propagation and
`super` all land.

**Workstream B complete**: the rest of `MovieClip.prototype`, flash.geom,
`Object.registerClass`, `watch`/`unwatch`, the timers, `Date`, and the
AsBroadcaster family (Key, Mouse, Stage, System, Color). See the notes at
the end of this file; `docs/M4-SPEC.md` §4 records what shipped and what is
still out of reach.

The last two action stubs, StartDrag/EndDrag, are real now that the input
seam exists: `Player.mouseMove`/`mouseButton`/`keyDown`/`keyUp` write the
VM's input state, so `_xmouse`/`_ymouse`, `Key.isDown` and `_droptarget`
all report something.

**M4-A1 landed**: GetProperty/SetProperty (0x22/23) are real, sharing one
22-entry table in `core/avm1/stage_object.zig` with the named form
(`mc._x`) reached through GetMember/SetMember/GetVariable/SetVariable.
`_url` comes from the Player (`Options.url`); `_xmouse`/`_ymouse` and
`_droptarget` went live with workstream B's input seam.

**M4-A2 landed**: real target-path resolution. SetTarget/SetTarget2 keep a
tri-state target (base / retargeted / FAILED), a failed `tellTarget` sends
variable reads to `_root` while movie control silently no-ops, and
GetVariable/SetVariable split at the rightmost `:`/`.` and walk the display
tree. TargetPath (0x45) returns the DOT path.

**M4-A4/A5/A6 landed**: CloneSprite/RemoveSprite (0x24/0x25) and the clip
methods that share their primitive (`duplicateMovieClip`, `attachMovie`,
`createEmptyMovieClip`, `removeMovieClip`, `swapDepths`, `getDepth`,
`getNextHighestDepth`). Scripts address depth *N*; the display list stores
*N* + 16384, and REMOVAL is gated on that offset — which is why no
`placed_by_script` flag exists. `swapDepths` is the only way content moves
a timeline-placed object into the script range, and therefore the only way
it becomes removable at all. `Call` (0x9E) runs a frame's DoActions inline.
`Throw` propagates across function boundaries as `error.Avm1Thrown`, and
`Try` truncates the value stack before the catch.

`super` follows ruffle's prototype-depth model: constructors start at
depth 1, a method starts at the depth that owns it but never at 0
(`depth.max(1)`), and `super.x` resolves from `SuperObject::proto()` —
which is why `super.__proto__` reads TWO layers up. Two quirks are
corpus-derived rather than ruffle-derived: an object literal naming
`__proto__` reparents the literal, and a display object reached AS a
prototype ends the chain (`super_edge_cases`).

| Stub | Why | Milestone |
|---|---|---|
| GetURL / GetURL2 (0x83/0x9A) | network/loadMovie | M5 (the loader; `core/` does no I/O) |
| ToggleQuality (0x08) | quality is a no-op for us | never |
| StopSounds (0x09) | audio | M6 |
| StrictMode (0x89) | a no-op in Ruffle too | done-as-is |
| WaitForFrame(2) (0x8A/0x8D) | everything is always loaded — same observable behavior as Ruffle for local files | done-as-is |

## SWF 3 — timeline control (M3, hand-dispatched from M2)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x00 | End | exec | |
| 0x04 | NextFrame | exec | |
| 0x05 | PreviousFrame | exec | |
| 0x06 | Play | exec | |
| 0x07 | Stop | exec | |
| 0x08 | ToggleQuality | exec | no-op for us |
| 0x09 | StopSounds | exec | M6 |
| 0x81 | GotoFrame | exec | |
| 0x83 | GetUrl | exec | fscommand/no-op |
| 0x8A | WaitForFrame | exec | skip-count semantics |
| 0x8B | SetTarget | exec | mutates target_clip |
| 0x8C | GotoLabel | exec | |

## SWF 4 — stack machine (M3)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x0A | Add | exec | SWF4 numeric (string-permissive) |
| 0x0B | Subtract | exec | |
| 0x0C | Multiply | exec | |
| 0x0D | Divide | exec | div-by-0 ⇒ "#ERROR#" in v4! |
| 0x0E | Equals | exec | numeric |
| 0x0F | Less | exec | |
| 0x10 | And | exec | numeric, not boolean |
| 0x11 | Or | exec | |
| 0x12 | Not | exec | |
| 0x13 | StringEquals | exec | |
| 0x14 | StringLength | exec | |
| 0x15 | StringExtract | exec | 1-based index |
| 0x17 | Pop | exec | |
| 0x18 | ToInteger | exec | |
| 0x1C | GetVariable | exec | slash paths |
| 0x1D | SetVariable | exec | |
| 0x20 | SetTarget2 | done | undefined resets to base below SWF7, nulls above |
| 0x21 | StringAdd | exec | |
| 0x22 | GetProperty | done | index into display-prop table (order load-bearing) |
| 0x23 | SetProperty | done | value coerced by index even when the write is dropped |
| 0x24 | CloneSprite | exec | |
| 0x25 | RemoveSprite | exec | |
| 0x26 | Trace | exec | → trace_sink |
| 0x27 | StartDrag | done | operands pop in a fixed order whether or not the target resolves; a bare `startDrag()` drags the current target clip |
| 0x28 | EndDrag | done | ends whatever drag is running — there is only ever one |
| 0x29 | StringLess | exec | |
| 0x2D | FsCommand2 | done | Flash Lite; undocumented, and NOT in ruffle's opcode table. Pops an argument COUNT that INCLUDES the command name, then the name, then `count-1` arguments — so `Push ["SOFT2","SOFT1","SetSoftKeys",3]` is `SetSoftKeys("SOFT1","SOFT2")`. Pushes the answer: a number for the getters, 0 for an action, -1 for anything unrecognised. A STRING getter is the odd one: its argument NAMES A VARIABLE, the answer is written there, and it returns 0. The table is `core/avm1/fscommand.zig`; the same table answers plain `fscommand`, which arrives as `getURL("FSCommand:cmd", "arg")`. Nothing in `core/` ACTS on a command — see docs/FLASH-LITE.md |
| 0x30 | RandomNumber | exec | deterministic rng for states |
| 0x31 | MbStringLength | exec | |
| 0x32 | CharToAscii | exec | |
| 0x33 | AsciiToChar | exec | |
| 0x34 | GetTime | exec | ms since start (deterministic clock) |
| 0x35 | MbStringExtract | exec | |
| 0x36 | MbCharToAscii | exec | |
| 0x37 | MbAsciiToChar | exec | |
| 0x82 | WaitForFrame2 | exec | |
| 0x96 | Push | exec | typed values; f64 = **byte order 45670123** (errata) |
| 0x99 | Jump | exec | si16 rel. end of action; may land mid-action |
| 0x9A | GetUrl2 | exec | **flag order reversed vs Adobe** (errata) |
| 0x9D | If | exec | pops condition |
| 0x9E | Call | exec | executes a frame's actions |
| 0x9F | GotoFrame2 | exec | scene bias + play flag; shares the operand rule and the wrap arithmetic with `gotoAndPlay` (stage_object.gotoFrameNumber) |

## SWF 5 — objects & functions (M3/M4)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x3A | Delete | exec | |
| 0x3B | Delete2 | exec | **also pushes success bool** (errata) |
| 0x3C | DefineLocal | exec | |
| 0x3D | CallFunction | exec | |
| 0x3E | Return | exec | |
| 0x3F | Modulo | exec | ES3 fmod |
| 0x40 | NewObject | exec | |
| 0x41 | DefineLocal2 | exec | declare-only |
| 0x42 | InitArray | exec | |
| 0x43 | InitObject | exec | |
| 0x44 | TypeOf | exec | movieclip ⇒ "movieclip" |
| 0x45 | TargetPath | done | DOT path (`_level0.mc`), unlike `_target`'s slash form |
| 0x46 | Enumerate | exec | pushes null terminator first |
| 0x47 | Add2 | exec | ES3 (string concat rules) |
| 0x48 | Less2 | exec | ES3 relational |
| 0x49 | Equals2 | exec | ES3 == |
| 0x4A | ToNumber | exec | |
| 0x4B | ToString | exec | |
| 0x4C | PushDuplicate | exec | |
| 0x4D | StackSwap | exec | |
| 0x4E | GetMember | exec | always case-insensitive on display props |
| 0x4F | SetMember | exec | |
| 0x50 | Increment | exec | |
| 0x51 | Decrement | exec | |
| 0x52 | CallMethod | exec | empty-string name ⇒ call as function |
| 0x53 | NewMethod | exec | |
| 0x87 | StoreRegister | exec | leaves value on stack |
| 0x88 | ConstantPool | exec | replaces active pool |
| 0x89 | StrictMode | exec | undocumented; no-op |
| 0x94 | With | exec | scope push over a sub-slice |
| 0x9B | DefineFunction | exec | |

## SWF 6 (M4)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x54 | InstanceOf | exec | |
| 0x55 | Enumerate2 | exec | object variant |
| 0x66 | StrictEquals | exec | |
| 0x67 | Greater | exec | |
| 0x68 | StringGreater | exec | |

## SWF 5 bitwise (M3)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x60 | BitAnd | exec | ToInt32 |
| 0x61 | BitOr | exec | |
| 0x62 | BitXor | exec | |
| 0x63 | BitLShift | exec | shift & 31 |
| 0x64 | BitRShift | exec | signed |
| 0x65 | BitURShift | exec | unsigned |

## SWF 7 — classes & exceptions (M4)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x2A | Throw | exec | |
| 0x2B | CastOp | exec | |
| 0x2C | ImplementsOp | exec | |
| 0x69 | Extends | exec | |
| 0x8E | DefineFunction2 | exec | registers + preload order this/arguments/super/_root/_parent/_global; `_parent`/`_global` register-swap quirk on root timelines (errata) |
| 0x8F | Try | exec | |

## Workstream B notes (the non-obvious half)

Things the corpus pins that no document states, kept here so they are not
re-derived:

- **Matrices are f32.** `swf.reader.Matrix` stores a/b/c/d as f32 and does
  every product in f32, because ruffle does and the precision is
  observable: f64 lands one twip off in `localToGlobal`/`getBounds` often
  enough to fail both tests. The scale/rotation cache on DisplayObject
  stays f64 — ActionScript reads back exactly what it wrote.
- **Number→string is not ES3.** Flash's own algorithm: 15 significant
  digits, exponent notation from 1e15 (not 1e21), and a rounding carry that
  is broken — `-9999999999999996` prints as `-e+16`, with no digit.
  `clamp_to_i32` sends NaN *and* +infinity to i32::MIN.
- **`#initclip` runs at PRELOAD**, not on the timeline, so a class it
  registers applies to clips whose PlaceObject tag appears earlier in the
  same frame.
- **A clip's Construct is queued before its first frame runs**, so a parent
  constructs ahead of the children that frame places.
- **The action queue is three FIFO buckets** (Initialize, Construct,
  Normal) drained highest-first on every pop — not one sorted list.
- **`unload` handlers run for an already-removed clip**; every other queued
  action is dropped when its clip goes away.
- **A removed display object stays distinguishable from a plain one** after
  its instance is freed (`NativeInfo.removed_display`), because a retained
  reference must stop receiving broadcasts and timer callbacks.
- **A cyclic prototype chain is a hard stack overflow** that aborts the
  whole action mid-statement.
- **Getters, setters and the watcher for one property share a budget** of
  65 nested calls; over it the call is skipped silently.
- **The clock is a seam.** `Vm.epoch_ms`/`tz_offset_min` default to
  ruffle's deterministic mock (2001-02-03 04:05:06 at +05:45) so the
  conformance runner needs no flag; frontends pass the real values.

## Workstream C notes (events, buttons, focus)

- **`Kind.button` is a container**, and its child containers are frameless
  MovieClips that are NOT scriptable: `clipObject` hands out the button's
  own AVM1 object for either, so `_parent` from inside a button IS the
  button and its typeof is "object", not "movieclip". Below SWF6 a
  reference to a button resolves UP to the first MovieClip ancestor
  (ruffle `process_swf5_references`).
- **Every stage object pushed on the AVM1 stack becomes a path-based
  reference** (ruffle `stack_push`), so `==` and `===` compare clips by
  PATH. Two distinct instances that share a name are equal — which only
  happens after a goto rewind leaves both alive.
- **The AVM1 mouse pick needs BUTTON MODE**: only buttons (through their
  hit-area records) and clips with a mouse handler are pickable, whatever
  they draw. A clip tests ITSELF before its children. `enabled` is a
  button-only property here, read when the event is dispatched.
- **Ruffle collects the mouse events before it mutates hovered/pressed**,
  then fires them. A handler that disables the button it is on has to be
  able to clear the hover that same event already recorded.
- **Sibling timelines tick HIGHEST DEPTH FIRST.** There is no tree walk in
  ruffle: one global list that new clips are PREPENDED to, so enterFrame
  runs in reverse instantiation order.
- **keyPress goes the other way** — render-list order, low depth to high —
  and the FIRST handler consumes it. Its key numbering is ruffle's
  ButtonKeyCode, which is neither ASCII nor the virtual-key codes.
- **Key HANDLERS need focus.** `clip.onKeyDown` and `btn.onKeyDown` fire
  only for the focused object with an active highlight (Flash #2120); the
  `onClipEvent(keyDown)` bodies fire for everyone. Any mouse activity below
  SWF9 clears the highlight.
- **The focus moves the hover.** `setFocus` rolls out of the old hovered
  object and over the new focus every time, even when the focus does not
  actually change; the events are queued, and only a Tab runs them
  synchronously.
- **Automatic tab order is spatial**, ranked by `6y + x` of the top-left
  world-bounds corner, with duplicate keys dropped — not left-to-right,
  top-to-bottom.
- **`_droptarget` is stored, not computed on read**: recomputed while the
  drag is live and left behind by `stopDrag`, and it names the INNERMOST
  clip under the pointer.
- **`_xmouse` is quantised to whole DEVICE PIXELS** before being pushed
  into the object's space, which is why it reads as a whole number on an
  unscaled clip however fractional the clip's position is. A clip scaled to
  zero has a singular matrix and falls back to the identity, so it reports
  the device pixel count read as twips. Do the chain hop by hop —
  collapsing it into one multiply loses the intermediate roundings and
  lands a pixel out.
- **An idle pick does not disturb an existing hover** (ruffle
  `skip_mouse_hover`), and a `MouseMove` to where the pointer already is
  is not a move. Both matter because Tab sets the hover as well as the
  focus, and the next idle tick would otherwise roll straight back out of
  it.

## Workstream D notes (text, fonts, TextField)

- **A font's scale is 20480 for DefineFont3 and 1024 otherwise.** Miss it
  and every Font3 glyph is twenty times too big. The font's own LEADING is
  ignored entirely — line spacing is `TextFormat.leading` and nothing else
  (ruffle `html/layout.rs:253`).
- **Faces resolve by NAME, never by id**, and only among EMBEDDED fonts. A
  DefineFont with an empty glyph table does not count. Everything else is a
  "device" font, which under the conformance harness resolves to nothing
  and measures zero — that is correct, not a gap: the four dirs that need a
  real one say so in their toml (`with_default_font`).
- **A DefineFont1 has no name of its own.** The DefineFontInfo beside it
  carries the name and the bold/italic pair, so the fold at preload is what
  makes a v1 face findable at all.
- **A field's format comes off its tag fully populated**, in PIXELS, with
  the colour's ALPHA DROPPED and the channels in script order. A fresh
  black field reports `color == 0`, not `0xFF000000`.
- **The engine packs colours ABGR** (red in the low byte, as RGBA arrives
  on the wire) and script reads `0xRRGGBB`. Every colour crossing the AVM1
  boundary swaps.
- **`GUTTER` is 40 twips on all four sides** and it is observable
  everywhere: in `textWidth` vs `_width`, in `getTextExtent`, and in where
  the first glyph sits. An empty autosizing field is 4px square.
- **Layout puts the cursor ON THE BASELINE** and fixes the line up
  afterwards — that ordering is what lets two font sizes on one line share
  a baseline. Only the FIRST line contributes its leading to the measured
  height; a non-input field drops a trailing empty line while an input
  field keeps it (you have to be able to click there).
- **Autosize bounds are applied LAZILY**, at the top of a render or a
  geometry read and never inside the setter that caused it. `autoSize`,
  then `wordWrap`, then `autoSize` again must not bake the first answer in.
- **Word wrapping changed in SWF8**: below it every space is a break point
  and only the final space of a slice is dropped when measuring; from SWF8
  only the last space of a run breaks and the whole run is trimmed.
- **`TextField.prototype`'s declaration order is an ABI** — enumeration is
  reverse-insertion and `textfield_props_swf5..8` print it four times. Two
  rules fall out of it: a version-HIDDEN accessor is not virtual on the
  WRITE path (so the five SWF8 members take an assignment below SWF8 while
  the other thirty swallow it), and `tabEnabled` is deliberately NOT a
  built-in TextField property.
- **A field's `tabIndex` is a u32** where a clip's is an i32 — the same
  stored value reported unsigned. `-1` means UNSET whatever the object.
- **`setTextFormat` writes the SPANS, `setNewTextFormat` the new-text
  format.** Keeping them apart is what stops `setTextFormat({color})` from
  moving `textColor`. An EMPTY range reports the all-null default format,
  which is why `getTextFormat()` on an empty field is nulls.
- **The HTML writer is not the reader's inverse.** It always emits a `<P>`
  (or `<LI>`) and a fully-specified first `<FONT>`, wraps in `<TEXTFORMAT>`
  only when a margin/indent/leading/tab stop is non-zero, and keeps its
  tags in a fixed order — a tag that would open out of order is skipped. A
  newline CLOSES the paragraph rather than emitting `<BR>`.
- **`</P>` emits a newline whose span takes the font of the last `</FONT>`
  seen** and resets style, url and target. It makes no sense; Flash does it.
- **A CARRIAGE RETURN in a traced string prints as a NEWLINE.** That is a
  general `trace` rule, not a text one, and it is what makes a field's line
  breaks come out as lines.
- **The `variable` binding lives on the TARGET**, not on the field: a write
  to `_root.myVar` has only the target in hand and must find every field
  watching that name. Variable→field rides the ordinary write path
  (including the fast one that skips watchers, and `DefineLocal`);
  field→variable runs behind a re-entrancy guard and can fire a virtual
  setter, which the other direction cannot. Re-pointing `variable` resets
  the field to the text its TAG was born with.
- **A key or a script focus selects the whole field; a mouse focus does
  not** — it places a caret. Losing focus CLEARS the selection in AVM1, so
  every `Selection` index query answers -1 on an unfocused field.
- **A selectable field is pickable through its whole box**; a dynamic
  non-selectable one is invisible to the mouse and neither takes focus nor
  blocks what is behind it. A press on NOTHING goes to the stage, which
  cannot hold focus, so a focused field loses it.
- **Printable ASCII raises its button `keyPress` from the TEXT INPUT
  event, not the key-down** (`ButtonKeyCode::from_input_event`); only the
  SPECIAL keys come from the key-down, and space is not one of them.
  Since a claimed keyPress suppresses the rest of that same event,
  deriving the ASCII one from the key-down fires the handler AND still
  lets the character reach the focused field.
- **Enter and Space press the focused object only when the highlight is
  VISIBLE**, which `_focusrect` can switch off independently of the
  highlight being active. A text field cannot render one at all.
- **A `TextSnapshot` captures at construction**, so one taken earlier
  keeps reporting what the clip said then.
- **A DEVICE font is a host input.** `Player.Options.device_font` takes
  TTF bytes; `core/` does no I/O and never carries a built-in face. Two
  rules only device faces have: kerning is always consulted whatever the
  format's flag says, and an advance is rounded to a whole PIXEL before
  letter spacing is added, with the spacing unable to make it negative.
- **A filter is a typed property bag, and the TYPES are the class.** An
  angle round-trips through radians (`angle = 360` reads 0, `361` reads
  1), a colour keeps its alpha because `color` and `alpha` are two views
  of one value, alpha quantises to a byte (0.5 reads 0.498039215686275),
  and strength is 8.8 fixed clamped to 0..0xFF00.
- **Cloning a dynamically created TEXT FIELD does not copy it.** Flash
  makes a fresh 0x0 field carrying only the matrix, the colour transform
  and `editable` — its text, bounds, format and every flag start over.
- **An IME preedit sits IN the field** and each new one replaces the last
  wholesale; losing focus COMMITS by typing it back as ordinary input,
  which is what makes `onChanged` fire for it.
- **`TextField.text` must hand out a COPY.** Returning the field's own
  buffer let a later edit rewrite a string already stored in a variable —
  a real aliasing bug the corpus caught through `replaceSel`.

All other codes in 0x00–0x9F are INVALID (open-flash `_index.md`); on decode we
skip by length (>=0x80) or treat as End-adjacent no-op, matching Flash's
tolerance.

## Workstream E notes (bitmaps)

`flash.display.BitmapData` and the `DefineBits*` families. Full close-out
in `docs/M4-SPEC.md` §7; what follows is the handful of rules that are
not derivable from any document.

**Two colourspaces, and every function picks one.** Storage is
premultiplied; the script view is not. Un-premultiplying is a
brute-forced 256-entry table (`core/bitmap/pixels.zig`), not a divide —
Flash's own rounding, and a `c * 255 / a` is off by one across most of
the range. `colorTransform` and `merge` operate unmultiplied;
`threshold`, `getColorBoundsRect` and `compare` operate premultiplied.

**`getPixel32` skips the un-premultiply on an opaque bitmap.** Its stored
alpha is normally 255 so it never shows — until `threshold` or
`paletteMap` writes a translucent pixel into one, which both do, because
both premultiply as though the target were transparent. `getPixel` is
NOT `getPixel32` masked: it un-multiplies unconditionally.

**Return codes are per-function.** `colorTransform` reports -1 on
SUCCESS. `compare` uses -2 for an argument that is not a live BitmapData
where the source→destination members use -3 for a disposed one and -2
for a non-BitmapData. `fillRect`, `scroll` and `noise` return 0;
`floodFill` returns 1 when it filled and 0 when it refused (replacing a
colour with itself is the refusal). `paletteMap` and `copyChannel` also
report -1 on success.

**Duck-typing is not uniform.** Every rectangle argument is duck-typed —
any object with x, y, width and height. A `ColorTransform` argument must
be a REAL one, made by the constructor. `hitTest` reads its point
properties as OWN properties, so an inherited `x` does not qualify.

**A colour transform is 8.8 fixed and 16-bit.** Script hands over f64s;
Flash snaps each multiplier to n/256 first, multiplies at 16-bit
precision, saturating-adds the i16 offset, and only then clamps to
0..255. A pixel with zero alpha is skipped entirely — not even the
additive terms reach it. And a transform that ONLY raises alpha does
nothing at all, which is a Flash bug the corpus depends on.

**Two exact-match PRNGs.** `noise` is Lehmer
(`x = x * 16807 % 2147483647`) with a seed of zero or below reflected
rather than clamped, drawing R, G, B, A in order and skipping — not
consuming — an unselected channel; a `high` below the `low` is raised to
it. `pixelDissolve` is a single Feistel round over the next even power of
two, mixing with `n² + 1`, always writing the region's origin pixel
before the permutation starts and outside the count; it returns the raw
permutation index so the next call continues where it stopped.

**Sizes are version-gated** (`isSizeValid`): zero is invalid everywhere;
SWF≤9 caps each side at 2880; ≤12 requires each side < 0x2000 and
`w*h < 0x1000000`; above that the undocumented 0x6666666 and
`w*h < 0x20000000`. An invalid size makes the CONSTRUCTOR return
undefined rather than an object.

**Tag pixels are already premultiplied** for `DefineBitsLossless2` and
`DefineBitsJPEG3`, which is also BitmapData's storage form — so
`loadBitmap` copies them across rather than converting, and the renderer
un-premultiplies them for the pattern instead. Round-tripping costs a
unit in the last place per channel.

**`BitmapData.draw` blits** when the source is a BitmapData and the
matrix has no scale or skew. That is what Flash does, and the result
differs from a real render, so it is the answer rather than a shortcut.
A blend mode of `alpha` or `erase` against a BitmapData source does
NOTHING at all, whatever the pixels are.

**The same blit happens on the STAGE**, for any bitmap drawn unscaled and
axis-aligned on whole pixels. Flash's composite there is premultiplied
source-over with a truncating divide; the rasteriser's pattern path
un-premultiplies, blends and un-premultiplies again. Three roundings
against one, worth a unit per channel, which two tolerance-zero image
dirs measure.

**`perlinNoise` writes its output RAW**, so a channel can exceed its own
alpha — an impossible premultiplied pixel. Un-premultiplying one must
CLAMP (the corpus reads the 0xFFs back) and putting one on screen must
SATURATE; the pixel operations keep the wrapping blend, which is what
their own traces pin and which a valid pixel can never reach. Its
channel index counts only the SELECTED channels, so asking for blue
alone gives the field red would have got, and an unselected channel is
forced to -1 (colour) or +1 (alpha) rather than left alone.

**Only `ColorMatrixFilter` is applied.** Four rows of five over the
un-premultiplied colour, clamped per channel on the 0..1 value and only
then premultiplied. The fourth column multiplies alpha as it stands
while the other three take colour divided BY that alpha, so a fully
transparent pixel contributes nothing but its own alpha. Every other
filter reports -1, which is what Flash reports for one it cannot build.

## Filters (workstream E follow-on)

`flash.filters` and PlaceObject3's filter list. Everything DECODES and
round-trips; nothing is APPLIED except `ColorMatrixFilter` through
`BitmapData.applyFilter`, because that one is a per-pixel function rather
than a convolution. M7 owns the kernels.

**An angle keeps the sign of its remainder.** -1 stays -1; only whole
turns come off, so 361 is 1 and 366 is 6. It is `@rem`, not `@mod`.

**A bevel `type` is matched CASE-SENSITIVELY** against "inner" and
"outer", and everything else — including "INNER" and the number 0 — is
`full`, not the constructor's own default of `inner`.
`DisplacementMapFilter.mode` works the same way with `wrap` as the
fallback.

**`ColorMatrixFilter.matrix` has three answers.** `null` and `undefined`
leave the matrix ALONE; any other non-object wipes it to twenty NaNs; an
object is read element by element with NaN past its `length`. Entries
round through f32, which shows in the traced values. The constructor's
default is the 4x5 identity.

**A gradient filter holds ONE list, not three arrays.** Sixteen (colour,
alpha, ratio) records plus a count, with `colors`, `alphas` and `ratios`
as views onto the first `count`. Writing `colors` resizes it but leaves
the alphas already sitting in those slots; writing `alphas` never
resizes it and fills past the end with OPAQUE; writing `ratios` can only
make it SHORTER. A string resizes it too — it has a `length` and no
elements, so the entries read as zero.

**A convolution matrix is variable length** and only ever GROWN to
`matrixX * matrixY` — shrinking a dimension leaves the entries behind,
and the next growth reuses them. `matrixX`/`matrixY` clamp to 0..15.

**`mapPoint` needs BOTH coordinates as OWN properties** or it is the
origin, and a non-object resets it rather than being ignored.
`mapBitmap` silently keeps the previous bitmap when handed anything that
is not one. `scaleX`/`scaleY` clamp to ±65535 through f32.

**`clone` is ENUMERABLE**, unlike almost every other native method: a
`for..in` over a filter lists it alongside the properties.

**`MovieClip.filters` copies in BOTH directions.** The array is fresh and
so is every filter in it, so neither mutating what you read nor holding
on to what you assigned reaches the object; anything in the assigned
array that is not a filter is dropped rather than stored. Until a script
assigns a list, the property reports what the PLACEMENT carried.

**The tag disagrees with its own spec.** SWF19 has BevelFilter's two
colours the wrong way round — Flash writes HIGHLIGHT first.
`hideObject` is the INVERSE of the composite-source bit. A bevel or
gradient pass count is four bits, not five, because `onTop` took one.
A blur's is five bits shifted up by three.

## Coercion and opcode notes (near-miss sweep)

Rules found by fixing every corpus dir that was failing by one or two
lines. Each is a Flash behaviour, not an oversight, and each cost a dir.

**Strings are CESU-8 on the way in and code points on the way out.**
Flash's compilers write a character above the BMP as its two surrogate
halves, three bytes each; a strict UTF-8 decoder rejects that and throws
the whole string back to Latin-1, turning four units into six. Ordering
then compares CODE POINTS, so "｡" sorts below "𐀂" although the raw
units say the opposite.

**A BARE object compares equal to null.** Only a NON-primitive result
stops an object-to-primitive equality; undefined is primitive, and an
object with no prototype has no `valueOf` to call. `_global` is one.

**`escape` spares only alphanumerics** — ECMA-262 also leaves `@*_+-./`
alone and Flash does not. **`isFinite()`** with no argument is false
outright, not the coercion of undefined.

**`new Array(n)` treats a single NUMBER as a length whatever it is.**
`new Array(-1)` stores -1 and reads it back, while everything that walks
the array treats it as empty. Only a genuine Number counts.

**`addProperty` creates an ENUMERABLE property**, and its SETTER
argument must be present: an object installs it, an explicit `null`
means getter-only, and leaving it off refuses the call.

**`f.prototype` is undeletable** on every function, script-defined as
much as native.

**`InitArray` / `InitObject` with a count outside 0..i32::MAX** pop
nothing and push undefined — the elements stay on the stack.

**`>>>` has a SIGNED result in SWF8 and SWF9 only.** `4294967295 >>> 0`
is -1 at those versions and 4294967295 at every other one.

**Inside a function body the version is at least 5**, even in a SWF4
movie: `DefineFunction` is a SWF5 construct and its body gets SWF5
semantics, so `1 == 1` is `true` there and `1` outside it.

**An absent `_parent` does not take a DefineFunction2 register** — it is
skipped and `_global` moves up into the slot. The value comes from the
BASE CLIP, not from `this`.

**`WaitForFrame` has a frame ceiling.** Past 16000 (16001 for the
dynamic form) the frame is never loaded and the guarded actions are
skipped, counted in ACTIONS rather than bytes. The dynamic form routes a
non-integer through its string form and lands on frame 0, and wraps into
an i32 — so `Infinity`, `16002.5` and `2147483649` are all "loaded".

**A clip UNLINKED from its parent stringifies empty.** Flash re-resolves
a reference by walking down from the level by name; its children keep
reporting their paths through their own `onUnload`.

## XML (workstream E follow-on)

`XML` and `XMLNode`, over `core/xml/parser.zig`. Everything but the
network half — `load`, `sendAndLoad` and the `_bytesLoaded` the loader
would write.

**The tree lives beside the script objects.** A node's AVM1 object is
made LAZILY, on the first read that hands it to script, and is then the
node's identity: `n.firstChild == n.firstChild` is true. An `XML`
document IS an `XMLNode` — its object carries both natives and every
node accessor reaches it through the root, which is an element with NO
name, which is why `doc.toString()` concatenates its children rather
than wrapping them.

**`nodeName` reads null on anything but an element and `nodeValue` reads
null on an element** — one storage slot, two accessors with opposite
guards — and they SHARE a setter, so writing either rewrites the slot
whatever the node type.

**Attributes are stored in REVERSE definition order.** A `for..in` pushes
properties in storage order and the script pops them, so reversing is
what makes script see them the way the document wrote them; the
serialiser and every namespace lookup walk back the other way.

**`XMLNode.prototype` is read FRESH for every node the parser makes**, so
content that reassigns it changes what later nodes inherit.

**The parser is lenient where a conforming one is not.** An entity runs
from `&` to the next `;` with NO intervening `&`, so a bare ampersand is
left alone rather than swallowing what follows, and an unrecognised
entity is copied through verbatim. A doctype's internal subset nests
`<…>` so the scan balances rather than stopping at the first `>`. A
declaration and a doctype are captured VERBATIM rather than interpreted.
An unquoted attribute value has its own `status` code — the status
numbers are script-visible and part of the behaviour.

## Arrays, strings and Math (near-miss sweep, second pass)

**Every array mutator DELETES an element before setting it**, so the
property lands at the end of the property list — `for..in` walks that
list and the corpus dumps the enumeration after each operation.
`reverse` deletes both ends before setting either.

**`Array.sort` is Flash's own quicksort**: unstable, leftmost pivot, so
the permutation it leaves equal elements in is observable. DESCENDING is
applied by reversing AFTERWARDS rather than by flipping the comparison,
precisely because of that. UNIQUESORT answers 0 and abandons the result
using the BUILT-IN comparison whatever comparator ordered the array.
`sortOn` honours an options array only when it is exactly as long as the
field list, and reads fields as OWN properties.

**`substr`'s length is not clamped**: `start + length` is a WRAPPING end
index, so `substr(0, -1)` is everything but the last character. `slice`
wraps both indices, `substring` clamps both and swaps them if they
cross. `charAt`/`charCodeAt` wrap their index into an i32 first.

**`Math.min`/`max` are BINARY**, and a missing second argument is
undefined — NaN above SWF6 — so `Math.min(1)` is NaN. Every Math method
coerces its first two arguments whether or not it uses them, and below
SWF7 its arity is checked before it runs.

**`toUpperCase`/`toLowerCase` use Flash's own tables**
(`core/avm1/case_tables.zig`), which are not Unicode's. Case folding for
PROPERTY LOOKUP stays ASCII-only — a different rule.

## Workstream L — loading (453 → 522)

**`core/` still does no I/O.** A load is a `runtime.FetchRequest` posted
to the Player through `Host.fetch`; the Player asks the frontend through
`Options.load_file` and applies the answer. Everything asynchronous —
loads, socket traffic, file dialogs — resolves in `Player.finishTick`,
which is ruffle's `executor.run()`: after the frame, after the timers.

**That one-tick lag is behaviour, not an artefact.** `loadvariables2`
polls on a `setInterval` precisely because the data is not there when
`loadVariables` returns; `LoadVars.loaded` reads false until a later
tick; and `onLoadInit` trails `onLoadComplete` by a whole tick because
the loaded movie has to run its own first frame in between. Resolving a
load inline breaks all three.

**The GetURL2 flag byte is documented backwards.** SWF19 lists the
layout reversed; the real one is bits 0-1 = send method, bit 6 =
LoadTarget, bit 7 = LoadVariables. A real `loadVariables(url, clip)`
emits 0xC0 — both high flags — which the spec's layout reads as a
nonexistent method 3. The static `GetURL` and `GetURL2` also disagree on
their level test: `len > 6` for the static form, `len >= 6` for the
dynamic one, so a bare `"_level"` is a window name to one and level 0 to
the other.

**Five statements share the GetURL2 opcode** and which one you wrote is
recovered from two flag bits plus the SHAPE of the target. The subtle
rule is the LoadVariables demotion: with neither `is_target_sprite` nor
a `_levelN` target, a `loadVariables` whose target resolves to anything
other than the movie's own root is not a load at all — Flash opens the
URL in the browser instead.

**Two different percent-encodings.** `escape()` spares only
alphanumerics and writes a space as `%20`; a request BODY is
`application/x-www-form-urlencoded`, which spares `*-._` as well and
writes a space as `+`. `LoadVars.toString` uses the first and
`sendAndLoad` the second, and the corpus checks both byte for byte.

**A loaded SWF brings its own library, version and timeline.**
`MovieClip.movie` names it and `executeFrame`/`runGoto` swap it into the
walk context for the duration of the subtree, so a nested sprite inside
a loaded movie resolves ITS characters. Levels are parentless clips with
a `level_id`; they tick and render above the root, NEWEST FIRST — ruffle
has no tree walk here at all, it iterates one global list that every new
clip is prepended to.

**`unloadMovie` empties a clip in place rather than removing it.**
Children retire with their `onUnload` fired, the clip fires its own, and
then `reset_for_movie_load` clears every flag but `_lockroot` — which is
what revives it, and what leaves `_level1` still naming something after
`unloadMovieNum(1)`.

**A fetch that succeeds but brings no SWF is still a SUCCESS.** Ruffle
sniffs the content type and substitutes an empty "error movie" for
anything unrecognised; only a fetch FAILURE reaches `onLoadError`. An
image becomes the clip's one child at depth 1.

**MovieClipLoader events go through `broadcastMessage`**, the method, not
straight down `_listeners` — content replaces it to intercept the whole
stream. `FileReference` is the other way round: ruffle's
`broadcast_internal` walks the list directly. The inits fire in REVERSE
load order.

**XMLSocket frames on NUL and nothing else.** Segmentation is the
receiver's job: one delivery of `"One\0Two\0Three\0"` is three `onData`
calls, and `"Hello"` followed later by `"World!\0"` is one.

**FileReference's three sequences differ on purpose.** A DNS failure
never reports `onOpen`, because nothing ever opened. An HTTP failure
does — and then still reports `onProgress` AFTER the error. An upload's
`onProgress` counts the bytes it sent.

**Player warnings share the trace sink.** Flash prints them with a
"Warning: " prefix and ruffle's harness has `log_warnings` on by
default, so they are expected output. They must stay quiet during a GOTO
replay: ruffle aggregates a goto into a placement delta and never
re-places a depth it already filled, while our correctness-first replay
does (`Context.replaying`).

## After L — the near-miss sweep (522 → 539)

**`clampToI32` is not ToInt32.** Anything outside i32's range — both
infinities AND NaN — becomes `i32::MIN`, where `toInt32` wraps. Flash
uses each in different places and the corpus tells them apart
(`_soundbuftime` set to +Infinity reads back -2147483648).

**Overwriting a property clears its SWF-version gate.** A member hidden
by `ASSetPropFlags` becomes visible again the moment script assigns to
it (ruffle property.rs `set_data`).

**Above SWF9 the version-gate table runs out rather than saturating**, so
a SWF10 movie hides nothing at all. Clamping to the v9 row instead is
what made a v10 child report itself as 9.

**`isNaN()` with no argument is TRUE and `Boolean()` with none is
UNDEFINED** — neither is the coercion of a missing argument, which below
SWF7 would make both false. `isFinite()`'s bare-false is the third of
the set.

**`hasOwnProperty("__proto__")` is true for anything with a prototype**:
ruffle keeps `__proto__` as a real entry in the property map rather than
a synthesized accessor.

**A second construction changes nothing.** A native constructor run on an
object that already carries its payload evaluates its arguments — a
`valueOf` still fires — and stores none of them.

**An ENGINE-initiated call keeps the function's defining base clip even
below SWF6**, where an ordinary call adopts `this`'s instead (ruffle's
`ExecutionReason::Special`). It is what lets an `XML.onLoad` defined in
a loaded SWF7 movie see that movie's timeline variables when the root
that loaded it is SWF5.

**SWF5 calls `valueOf` on BOTH sides of `==` before comparing**, objects
included — `Object.prototype.valueOf` returns `this`, so the pointer
comparison still applies afterwards, but `new Number(1) == new Number(1)`
comes out TRUE.

### The sweep continued (539 → 545)

**`sandboxType` answers for the running script's own movie**, not the
root's — a SWF fetched over http reports "remote" inside a local movie.

**A rewind keeps the child it is about to place again.** Ruffle reduces a
goto's range to one command per depth before applying anything, so a
`Remove` later refilled at the same depth never happens; replaying tag by
tag we destroyed and re-created the survivor, and the replacement re-ran
its first frame. The collapse is deliberately narrow — REWIND only, and
only when the sitting child is the same character the replay will place.

**`_global` is the last scope a dotted variable path is tried against.**
Ruffle walks `Scope::ancestors`, which ends at the global scope; our
chain ends one link earlier, so `a.b.c` gave up once the timeline's own
`a.b` turned out to be a string instead of finding `_global.a.b.c`.

**A text field's `variable` binding carries HTML both ways.** Writing the
variable of an html field PARSES it, so `.text` afterwards is the plain
text. The early return on an unchanged value is ruffle's and is
observable: not every set of spans round-trips through HTML.

**The per-property recursion budget belongs to the PROPERTY, not to its
name.** Ruffle keys on `Property::id`, so a getter that deletes and
re-adds its own property gets a fresh budget every call — and runs on
until the CALL-DEPTH limit, which kills the whole action rather than
falling back to the data slot.

**A closure's base clip is a PATH.** Ruffle keeps it as a
`MovieClipReference`; remove the clip and the closure's `_parent` dies,
put a clip back at the same path and it revives. A raw handle cannot do
that. Both readers go through the re-resolution — the activation's own
base clip and the `preload_parent` register.

---

## Notes from the semantics sweep (569 → 623)

**A SWF5 call is not a closure, and the CALLER decides.** Ruffle branches
on `activation.swf_version()` — the frame doing the calling, not a global
and not the function's own version. Below 6 a call keeps nothing of the
definition site: it adopts `this`'s display object (or the caller's
target when `this` is not one), allocates a fresh scope over `_global`
rooted at that clip, and runs at that clip's movie version. A SWF5 movie
calling a SWF6 movie's function therefore reads `_target: /` and finds
none of the child's timeline variables.

**`ExecutionReason::Special` exempts a call from that rule, and belongs
to ONE call.** Implicit coercion calls (`valueOf`, `toString`) set it. A
native callee never reaches the bytecode path to consume it, so it has
to be cleared where the dispatch happens or the exemption leaks onto the
next ordinary call.

**A function that PRELOADS `this` does not get a `this` of its own.**
`is_this_inherited` makes the activation's `this` the caller's, so a
constructor whose body preloads sees the new object in r1 and the
caller's timeline under the NAME, and `r1 === this` is false. `this` is
never a local variable — it lives on the activation and `resolve`
answers it before the scope chain. Below SWF6 the name is matched
case-sensitively only inside a LOCAL scope, so `tHiS` finds nothing
there but resolves at the top level and inside a `with` body, which is a
different scope class. `arguments` follows the same preload rule (but
setting both flags is equivalent to preload alone, unlike `this`), and
`arguments.caller` is the CALLER's callee — null for timeline code.

**The operand stack is shared and cleared between FRAMES.** Every
DoAction in the movie pushes and pops the same stack, across clips and
across levels, so a block that leaves a value behind hands it to
whatever runs next. The frame boundary wipes it, along with the four
global registers.

**Builtins are numbered slots.** `Math.pow` IS `ASnative(200, 17)`;
Flash's own globals.as wires the prototypes up by walking those numbers
with `ASSetNative`. Modelling them as individual natives cannot express
what the corpus checks — that every Math method coerces its first two
arguments whether or not it uses them, and that an undefined index
answers NaN. `ASSetNative`'s leading-digit version prefix is odd and
pinned: a leading '1' is always eaten but only "10" is a gate, so "11k"
installs ungated as "1k".

**Coercions propagate.** A `valueOf` that throws — or a `valueOf`
PROPERTY that is a throwing getter — unwinds the whole expression. Add2
runs `to_primitive` on both operands and then coerces the results, so a
`valueOf` returning an OBJECT is called TWICE. `Trace` prints
"[type Object]" and then rethrows. An object with no callable `valueOf`
coerces to UNDEFINED, not to itself.

**SWF4 has no NaN, no Infinity, and no numbers where booleans belong.**
`NaN` and `Infinity` read as undefined there (they are accessors for
that reason), so `x == NaN` is `x == undefined` and a zero compares
EQUAL. Equals, Less, Not, And and Or all push booleans at every version;
And/Or read their operands as booleans, so an object is true without its
`valueOf` running. `ToInteger` is ECMA ToInt32 — it wraps and NaN
becomes 0.

**`var` is a real assignment.** DefineLocal runs virtual setters,
including inherited ones; outside a function a dotted or slash path
makes it a path assignment (so `function /:f1() {}` defines `f1` on the
root); inside a `with` it writes to the target only when the target
already owns the name. A scope write is a full `set` for the same
reason.

**Case folding is Flash's table, not Unicode's.** Below SWF7 property
names fold past ASCII — `this['Ä']` and `this['ä']` are one property —
but the table stops where Flash's did, so Ⱥ (cased later by Unicode)
stays distinct from ⱥ. SWF5 and below decode strings as WINDOWS-1252,
not Latin-1; the two differ only at 0x80..0x9F, where CP1252 has
typography and Latin-1 has controls.

---

## Notes from the second sweep (626 → 668)

**Removal waits a tick when something is listening.** A subtree with an
unload handler is not unlinked when it is removed: it stays in its
parent's child list at a NEGATED depth (`-depth - 1`), its unload fires
immediately, and the unlink happens at the start of the next frame. So
the script that called `removeMovieClip` still sees the clip. The
action queue drops everything a pending-removal clip queued except its
own unload, or the extra tick runs an extra enterFrame.

**There are TWO global environments**, one for SWF6 and below and one
for SWF7 and above, and they are separate all the way down: separate
`_global`, separate `Object.prototype`, separate `registerClass`
registry. A loaded movie's clip belongs to ITS OWN — a SWF8 movie in
`_level2` gets the SWF7-side `MovieClip.prototype` whatever version
loaded it. `_global` itself is NOT a property of the globals object; the
name resolves through the display-path machinery, gated to SWF6+, which
is why a SWF5 movie sees it only through the `preload_global` register.

**A level is its own `_root`.** The walk stops where there is no parent,
so inside a movie loaded into `_level1` `_root` means `_level1` — for
the `preload_root` register too.

**An accessor runs with `super` one level down**, exactly like a
constructor. Without that, a getter reading `super.<its own name>` finds
itself.

**Most native constructors answer UNDEFINED**, which is what `super()`
in a subclass evaluates to; `new X()` still yields the instance, because
`new` ignores the return unless the class declares a separate
constructor half (Object, Function, BitmapData, Transform).

**A register index past a function's own count reads and WRITES the four
global registers.** `ScriptLimits` sets the recursion cap, and the count
includes the frame about to be made.

**`AllEventFlags` is a MASK.** A PlaceObject2 clip-action block starts
with the union of every record's flags, and Flash masks each record with
it: a handler for an event the union does not list never fires.

**`ImplementsOp` takes effect once per class** — a second `implements`
is ignored even when the first named nothing usable — and a display
object is never an interface.

**AMF0's rules that are not in the format spec**: functions are skipped
as properties but a function passed as a VALUE is an ordinary object; a
getter is written as undefined and never called; properties come out in
reverse enumeration order; an array with only numeric keys is a dense
strict array and one non-numeric key makes it an ECMA array; the same
object twice is a reference; and a typed object's class name is the
LATEST alias its constructor was registered under.

**The five states of a loading clip** (default, loading, error, image,
unloaded) are all distinguishable, and the corpus compares snapshots of
each: an error reports -1 for `_framesloaded` and `getBytesTotal` but 0
for `getBytesLoaded`; an image has one frame and it is the current one;
unloaded is entered on the NEXT frame and forgets the load entirely. A
clip a load emptied reports zero frames where a fresh
`createEmptyMovieClip` reports one.

## The last fifty-four, in one place

The dirs that fell after the workstreams closed. Every one of these is a
rule that reads like a bug until you see the test that pins it.

**An array index is a WRAPPING i32.** `a[4294967296]` is element 0 and
`a["302231454903659441160191"]` is element 2147483647: the property NAME
is parsed as digits modulo 2^32 and read as signed (ruffle parses it as
`Wrapping<i32>`). The comparison against `length` is signed too, so once
the length has wrapped negative every further write pushes it one step
up from -2147483648 through -1, 0, 1 and around. Leading whitespace, a
sign and leading zeros are all accepted (`array_length`).

**A variable holding a clip holds a PATH.** The value caches the object,
but the moment the clip is removed the cache is dropped for good and the
reference walks its recorded path down from the level, reporting
whatever it finds there. The path was recorded when the value was
captured, so a `_name` written afterwards is not part of it: remove a
clip called `foo` that was created as `clipInstance2`, put a new
`clipInstance2` in its place, and the dead reference reports
`_level0.clipInstance2` (`string_paths_other`).

**`System.useCodepage` makes the form loader guess.** Flash asks the
operating system for its codepage; a player has none, so ruffle runs a
statistical detector and we do it structurally: valid UTF-8 is UTF-8, a
body whose every high byte begins an assigned Shift-JIS pair is
Shift-JIS, everything else is Windows-1252. Lone half-width katakana
(0xA1..0xDF) deliberately does not count as Japanese — those bytes also
spell `ÄÖÜ ß` (`form_loader_encoding_3`).

**`hitTest(x, y, true)` is not the mouse's hit test.** It skips masks
but NOT invisible objects; the mouse skips both. An object used as a
mask is never hit itself and is hit even while invisible; a masked
object is hit only where its mask is; a clipping LAYER applies the same
rule from the container's side, over the depths up to its `clipDepth`.
Two more: a static text with the CSMTextSettings flashtype bit is hit
through its whole box rather than glyph by glyph, and Flash's 1px stroke
minimum is a DEVICE-space width, so converting it needs the
global→local matrix — pass the wrong direction and a clip scaled 7.8×
gets a hairline 62× too fat (`movieclip_hittest_shapeflag`).

**A morph shape has two boxes and Flash uses both.** `getBounds` answers
with the START shape's box however far the tween has gone (ruffle's
`BoundsMode::Script`); the renderer and the mouse use the interpolated
one (`BoundsMode::Engine`). The outline itself is interpolated edge by
edge as the hit test walks it — the two edge lists need not line up
record for record, so each side carries its own pen and only the side
that produced a record advances (`hittest_morph_input`,
`movieclip_hittest_shapeflag`).

**ExternalInterface's flat value model.** Everything crossing the bridge
loses its prototype, its identity and any cycles; strings become UTF-8
and an object becomes a SORTED list of pairs, because ruffle marshals
through a `BTreeMap`. A clip crosses as null. Below SWF9 a string that
is nothing but whitespace crosses back as the four letters "null"
(`external_interface`).

**A NetStream's status sequence.** `play` says Play.Start before a byte
has arrived; the bytes say Buffer.Full; each tick consumes the FLV tags
whose timestamps have passed, and a script tag's AMF0 name IS the method
it calls (`onMetaData`). Running out of tags with the download finished
is the end — Buffer.Flush, Play.Stop, Buffer.Empty, and the stream
pauses itself; running out while still downloading says only the first
and the last. A seek is queued and executed by the next tick, which is
why Seek.Notify lands after whatever else that frame traced — and why a
seek still works while paused (`netstream_play_flv`,
`netstream_seek_flv`).

**A timeline loops on what the STREAM held, not what its header said.**
Two exceptions to "run off the end and go back to frame 1": there was
really only one frame however many the header declared, or the tag
stream never ended. `frames_loaded` counts ShowFrames — a stream ending
mid-frame leaves a trailing partial frame that runs once and is never
returned to — and a sprite with two full frames and no End tag stops
dead (`looping_child_swf5`, `_swf9`, `_swf32`).
