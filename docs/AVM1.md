# AVM1 action coverage matrix

Seeded from `reference/openflash/open-flash/content/documentation/avm1/actions/_index.md`
(cross-validated against ruffle `swf/src/avm1/opcode.rs`). Per-action spec:
the open-flash `actions/*.md` page of the same name.

Encoding rule: code `< 0x80` ⇒ no payload (1 byte). Code `>= 0x80` ⇒ u16le
length + payload.

Status: `todo` → `decode` (opcodes.zig) → `exec` (interpreter) → `done`
(corpus-verified). Milestones: M3 = SWF3/4/5 core, M4 = objects/classes/v6-7.

**M3 CLOSED**: every opcode 0x00–0x9F decodes and executes. All ops are
`exec` except the stubs listed below (they pop their operands correctly
but have no effect yet) — promotion is workstream A of docs/M4-SPEC.md.
Corpus: 108/680 (tests/conformance/pass_list.txt).

**M4-A1 landed**: GetProperty/SetProperty (0x22/23) are real, sharing one
22-entry table in `core/avm1/stage_object.zig` with the named form
(`mc._x`) reached through GetMember/SetMember/GetVariable/SetVariable.
`_xmouse`/`_ymouse` read the (still-zero) `Vm.mouse_*` until workstream C
wires the frontend; `_droptarget` awaits StartDrag; `_url` is always "".

**M4-A2 landed**: real target-path resolution. SetTarget/SetTarget2 keep a
tri-state target (base / retargeted / FAILED), a failed `tellTarget` sends
variable reads to `_root` while movie control silently no-ops, and
GetVariable/SetVariable split at the rightmost `:`/`.` and walk the display
tree. TargetPath (0x45) returns the DOT path.

| Stub | Why | Milestone |
|---|---|---|
| CloneSprite / RemoveSprite (0x24/25) | duplicateMovieClip | M4 |
| StartDrag / EndDrag (0x27/28) | needs mouse state | M4 |
| Call (0x9E) | call-frame-actions | M4 |
| GetURL / GetURL2 (0x83/0x9A) | network/loadMovie | out of scope (M4 partial for loadMovie tests) |
| ImplementsOp (0x2C) | interface registry unused | as needed |
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
| 0x27 | StartDrag | exec | |
| 0x28 | EndDrag | exec | |
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
| 0x9F | GotoFrame2 | exec | scene bias + play flag |

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

All other codes in 0x00–0x9F are INVALID (open-flash `_index.md`); on decode we
skip by length (>=0x80) or treat as End-adjacent no-op, matching Flash's
tolerance.
