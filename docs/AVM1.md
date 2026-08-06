# AVM1 action coverage matrix

Seeded from `reference/openflash/open-flash/content/documentation/avm1/actions/_index.md`
(cross-validated against ruffle `swf/src/avm1/opcode.rs`). Per-action spec:
the open-flash `actions/*.md` page of the same name.

Encoding rule: code `< 0x80` ⇒ no payload (1 byte). Code `>= 0x80` ⇒ u16le
length + payload.

Status: `todo` → `decode` (opcodes.zig) → `exec` (interpreter) → `done`
(corpus-verified). Milestones: M3 = SWF3/4/5 core, M4 = objects/classes/v6-7.

## SWF 3 — timeline control (M3, hand-dispatched from M2)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x00 | End | todo | |
| 0x04 | NextFrame | todo | |
| 0x05 | PreviousFrame | todo | |
| 0x06 | Play | todo | |
| 0x07 | Stop | todo | |
| 0x08 | ToggleQuality | todo | no-op for us |
| 0x09 | StopSounds | todo | M6 |
| 0x81 | GotoFrame | todo | |
| 0x83 | GetUrl | todo | fscommand/no-op |
| 0x8A | WaitForFrame | todo | skip-count semantics |
| 0x8B | SetTarget | todo | mutates target_clip |
| 0x8C | GotoLabel | todo | |

## SWF 4 — stack machine (M3)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x0A | Add | todo | SWF4 numeric (string-permissive) |
| 0x0B | Subtract | todo | |
| 0x0C | Multiply | todo | |
| 0x0D | Divide | todo | div-by-0 ⇒ "#ERROR#" in v4! |
| 0x0E | Equals | todo | numeric |
| 0x0F | Less | todo | |
| 0x10 | And | todo | numeric, not boolean |
| 0x11 | Or | todo | |
| 0x12 | Not | todo | |
| 0x13 | StringEquals | todo | |
| 0x14 | StringLength | todo | |
| 0x15 | StringExtract | todo | 1-based index |
| 0x17 | Pop | todo | |
| 0x18 | ToInteger | todo | |
| 0x1C | GetVariable | todo | slash paths |
| 0x1D | SetVariable | todo | |
| 0x20 | SetTarget2 | todo | dynamic SetTarget |
| 0x21 | StringAdd | todo | |
| 0x22 | GetProperty | todo | index into display-prop table (order load-bearing) |
| 0x23 | SetProperty | todo | |
| 0x24 | CloneSprite | todo | |
| 0x25 | RemoveSprite | todo | |
| 0x26 | Trace | todo | → trace_sink |
| 0x27 | StartDrag | todo | |
| 0x28 | EndDrag | todo | |
| 0x29 | StringLess | todo | |
| 0x2D | FsCommand2 | todo | Flash Lite; undocumented |
| 0x30 | RandomNumber | todo | deterministic rng for states |
| 0x31 | MbStringLength | todo | |
| 0x32 | CharToAscii | todo | |
| 0x33 | AsciiToChar | todo | |
| 0x34 | GetTime | todo | ms since start (deterministic clock) |
| 0x35 | MbStringExtract | todo | |
| 0x36 | MbCharToAscii | todo | |
| 0x37 | MbAsciiToChar | todo | |
| 0x82 | WaitForFrame2 | todo | |
| 0x96 | Push | todo | typed values; f64 = **byte order 45670123** (errata) |
| 0x99 | Jump | todo | si16 rel. end of action; may land mid-action |
| 0x9A | GetUrl2 | todo | **flag order reversed vs Adobe** (errata) |
| 0x9D | If | todo | pops condition |
| 0x9E | Call | todo | executes a frame's actions |
| 0x9F | GotoFrame2 | todo | scene bias + play flag |

## SWF 5 — objects & functions (M3/M4)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x3A | Delete | todo | |
| 0x3B | Delete2 | todo | **also pushes success bool** (errata) |
| 0x3C | DefineLocal | todo | |
| 0x3D | CallFunction | todo | |
| 0x3E | Return | todo | |
| 0x3F | Modulo | todo | ES3 fmod |
| 0x40 | NewObject | todo | |
| 0x41 | DefineLocal2 | todo | declare-only |
| 0x42 | InitArray | todo | |
| 0x43 | InitObject | todo | |
| 0x44 | TypeOf | todo | movieclip ⇒ "movieclip" |
| 0x45 | TargetPath | todo | |
| 0x46 | Enumerate | todo | pushes null terminator first |
| 0x47 | Add2 | todo | ES3 (string concat rules) |
| 0x48 | Less2 | todo | ES3 relational |
| 0x49 | Equals2 | todo | ES3 == |
| 0x4A | ToNumber | todo | |
| 0x4B | ToString | todo | |
| 0x4C | PushDuplicate | todo | |
| 0x4D | StackSwap | todo | |
| 0x4E | GetMember | todo | always case-insensitive on display props |
| 0x4F | SetMember | todo | |
| 0x50 | Increment | todo | |
| 0x51 | Decrement | todo | |
| 0x52 | CallMethod | todo | empty-string name ⇒ call as function |
| 0x53 | NewMethod | todo | |
| 0x87 | StoreRegister | todo | leaves value on stack |
| 0x88 | ConstantPool | todo | replaces active pool |
| 0x89 | StrictMode | todo | undocumented; no-op |
| 0x94 | With | todo | scope push over a sub-slice |
| 0x9B | DefineFunction | todo | |

## SWF 6 (M4)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x54 | InstanceOf | todo | |
| 0x55 | Enumerate2 | todo | object variant |
| 0x66 | StrictEquals | todo | |
| 0x67 | Greater | todo | |
| 0x68 | StringGreater | todo | |

## SWF 5 bitwise (M3)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x60 | BitAnd | todo | ToInt32 |
| 0x61 | BitOr | todo | |
| 0x62 | BitXor | todo | |
| 0x63 | BitLShift | todo | shift & 31 |
| 0x64 | BitRShift | todo | signed |
| 0x65 | BitURShift | todo | unsigned |

## SWF 7 — classes & exceptions (M4)

| Code | Action | Status | Notes |
|---:|---|---|---|
| 0x2A | Throw | todo | |
| 0x2B | CastOp | todo | |
| 0x2C | ImplementsOp | todo | |
| 0x69 | Extends | todo | |
| 0x8E | DefineFunction2 | todo | registers + preload order this/arguments/super/_root/_parent/_global; `_parent`/`_global` register-swap quirk on root timelines (errata) |
| 0x8F | Try | todo | |

All other codes in 0x00–0x9F are INVALID (open-flash `_index.md`); on decode we
skip by length (>=0x80) or treat as End-adjacent no-op, matching Flash's
tolerance.
