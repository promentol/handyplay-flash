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
| StrictMode (0x89), FsCommand2 (0x2D) | no-ops in Ruffle too | done-as-is |
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
| 0x2D | FsCommand2 | exec | Flash Lite; undocumented |
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
