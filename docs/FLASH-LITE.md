# Flash Lite — what the `games/` corpus actually needs

35 real Flash Lite games (`games/*.swf`, git-ignored). They are the first
content in this project that is neither a conformance fixture nor a demo:
phone games, shipped, with the device APIs that implies.

## What they are

| | |
|---|---|
| SWF 4 | 17 games — **Flash Lite 1.1**, the Flash-4 ActionScript profile |
| SWF 5/6 | 6 games |
| SWF 7 | 12 games — Flash Lite 2.x |
| stage | 176x208 (Nokia S60) for most; 240x320 for the SWF 7 ones |
| size | 12 KB to 501 KB |

**All 35 load and render.** No parse errors, no crashes, no blank frames:
every one of them draws its splash or menu, and the intros animate.

## `fscommand2` — opcode 0x2D

This is the Flash Lite device call, and it is **not in the SWF spec's
action list nor in ruffle's opcode table**. Its stack shape is: argument
COUNT on top, then the command name, then that many arguments.

    push "1"; push "FullScreen"; push "2"; 0x2D   →  fscommand2("FullScreen", "1")

`tools/avm1dis.py` now prints it as `FSCommand2` instead of `0x2d`.

**24 of 35 games call it.** By use:

| command | calls | games | what a player owes it |
|---|---:|---:|---|
| `SetQuality` | 25 | 12 | maps straight onto stage quality |
| `FullScreen` | 20 | 19 | stage scaling |
| `SetSoftKeys` | 24 | 16 | the two soft-key LABELS, and their keys |
| `StartVibrate` | 8 | 4 | nothing on a desktop; must still return sanely |
| `GetBatteryLevel`, `GetMaxBatteryLevel`, `GetSignalLevel`, `GetMaxSignalLevel`, `GetDevice`, `GetPlatform`, `GetLanguage`, `GetTotalPlayerMemory`, `GetFreePlayerMemory`, `GetNetworkConnectStatus` | 1-4 each | | device facts the games DISPLAY |
| `GetTimeHours/Minutes/Seconds`, `GetDateDay/Month/Year/Weekday` | 3 each | 1 | wall clock |
| `Quit`, `Escape`, `ResetSoftKeys`, `ExtendBacklightDuration`, `SetInputTextType` | 1-3 | | |

### What ours answers

`core/avm1/fscommand.zig` is the whole table, and both entry points reach
it: opcode 0x2D, and plain `fscommand("cmd","args")`, which is a `getURL`
whose URL is `FSCommand:cmd` and whose target is the single argument.
Names are matched CASE-INSENSITIVELY, because the games are inconsistent
about them (`SetSoftKeys` and `SetSoftkeys` both ship).

**The core never ACTS.** It recognises the command, answers the script,
and hands the call to the host — which is the only party allowed to do
anything about it. That is not fastidiousness. Ruffle's test framework
ends every one of its 679 movies with `fscommand("quit")`, so a core that
quit by itself would truncate the entire conformance corpus. Ruffle draws
the line in the same place: `core/src/avm1/fscommand.rs` forwards, and
only the desktop host implements anything.

Three families, and which one you are in decides how the answer arrives:

| family | shape | answer |
|---|---|---|
| actions | `fscommand2("SetQuality","low")` | returns 0 |
| numeric getters | `n = fscommand2("GetBatteryLevel")` | returns the number |
| string getters | `fscommand2("GetDevice","dev")` | writes `dev`, returns 0 |

Anything unrecognised returns `-1`, Flash Lite's own "not supported".

| command | what we answer |
|---|---|
| `GetBatteryLevel` / `GetMaxBatteryLevel` | 80 / 100 |
| `GetSignalLevel` / `GetMaxSignalLevel` | 75 / 100 |
| `GetVolumeLevel` / `GetMaxVolumeLevel` | 50 / 100 |
| `GetPowerSource` | 0 (battery) |
| `GetTotalPlayerMemory` / `GetFreePlayerMemory` | 8 MB / 4 MB, in bytes |
| `GetTotalObjectMemory` / `GetFreeObjectMemory` | the same pair |
| `GetNetworkConnectStatus` / `GetNetworkStatus` | 1 (connected, home network) |
| `GetNetworkRequestStatus` | 0 |
| `GetSoftKeyLocation` | 0 — the strip is at the BOTTOM, which is where the frontend draws it |
| `GetTimeZoneOffset` | the player's zone, in minutes east of UTC |
| `GetTimeHours/Minutes/Seconds`, `GetDateYear/Month/Day/Weekday` | the player's clock — the same deterministic source `Date` uses, and `GetDateMonth` counts from ONE where `Date` counts from zero |
| `GetLocaleLongDate` / `GetLocaleShortDate` / `GetLocaleTime` | `Saturday, February 3, 2001` / `2/3/2001` / `4:05 AM`, en-US shapes because `GetLanguage` says `en` |
| `GetDevice`, `GetDeviceID`, `GetPlatform`, `GetLanguage`, `GetNetworkName`, `GetNetworkConnectionName`, `GetNetworkGeneration` | `handyplay-flash`, `0`, `handyplay-flash`, `en`, `handyplay-flash`, `handyplay-flash`, `none` |
| `SetQuality` | the only command that changes what is DRAWN: `low` turns antialiasing off, everything else turns it on |
| `SetSoftKeys` / `ResetSoftKeys` | the two labels the frontend shows |
| `FullScreen` | recorded, and deliberately does not resize — see below |
| `Quit` | sets a flag the FRONTEND may read. The trace runner does not, which is what keeps the 679 |
| `StartVibrate`, `StopVibrate`, `ExtendBacklightDuration`, `SetInputTextType`, `SetFocusRectColor`, `Escape` | recorded, answer 0 — a game told `StartVibrate` FAILED may decide it is on a broken handset |

Every call, recognised or not, is reported to the host with its name,
arguments and result. The SDL frontend prints them:

    [fscommand2] SetSoftKeys("Options", "Exit") -> 0
    [fscommand2] GetBatteryLevel() -> 80

That log is a DEBUG channel and never `trace()` — one traced line would
appear in all 679 corpus dirs.

### Why `FullScreen` does not resize

A handset scaled the movie to a screen we deliberately do not emulate.
Every one of these games was authored AT its target screen — 176x208,
240x320 — so the movie's own stage box is already the right picture, and
the player always presents it at that size. `FullScreen` is recorded and
answers 0; nothing moves.

## Keys: the phone, not the keyboard

25 of 35 games bind keys through BUTTON `keyPress` conditions rather than
`Key` listeners, and the codes are the Flash Lite mapping:

| binding | binds | games | what it is on a phone |
|---|---:|---:|---|
| `Enter` | 148 | 20 | the centre SELECT key |
| `PageUp` / `PageDown` | 110 / 105 | 15 / 16 | **the two SOFT KEYS** |
| Up / Down / Left / Right | ~99 each | ~21 | the D-pad |
| `'5'` | 65 | 12 | centre of the keypad, an alias for select |
| `'0'`-`'9'`, `'*'`, `'#'` | | 5-12 each | the keypad |

Feeding that set blind — soft keys, select, D-pad, keypad, and mouse
clicks scaled to each stage — moves **33 of the 35** past their menus:
a Sudoku board with a running clock, Snapper at level 1, a Tetrix piece
falling, KCLY Diamond reaching GAME OVER.

Three details decided most of it, and each cost a round of testing:

- **The soft keys are PageUp and PageDown.** Arrows alone move almost
  nothing.
- **Six games are POINTER-driven** with no key bindings at all (`IQ test`
  has 1070 mouse conditions), and their stages are 240x320 to 800x600 —
  clicks aimed at a 176x208 centre miss entirely.
- **Some want the key before their menu exists.** `AntiMosquito` only
  moves if keys arrive from the FIRST tick; `Remember` places its
  keyPress button on the title frames and then replaces it at the same
  depth, so a script that waits has already missed it.

### 33 of 35 advance

The count only got there because the disassembler learned where AVM1
actually hides. `tools/avm1dis.py` now walks BUTTON condition actions and
PlaceObject2 CLIP EVENTS as well as DoAction, and prints both with their
trigger — `on(keyPress <PageUp/SoftL>)`, `onClipEvent(keyDown)`. Without
that, four games looked broken and were merely being asked the wrong
question:

- **Copter** says "CLICK TO START" and is driven by
  `onClipEvent(keyDown) { this.nextFrame() }` — ANY KEY. Its only two
  buttons are `getURL` adverts. It had been given nothing but clicks.
- **superTORCH** says "move around with navi key", and its navi-key
  button is real — but it lives inside the GAME, not the menu. The menu
  is a grid of MOUSE buttons.
- **Remember** and **MiniPet** likewise want the pointer for the menu and
  the keys afterwards.

Feeding keys and a stage-scaled click grid together, from the first tick,
moves all four.

### The two that still do not

| game | what it shows | what is known |
|---|---|---|
| `Tank Commander` | START GAME / INSTRUCTIONS / CREDITS | its `onClipEvent(keyDown)` is the in-GAME firing handler (`Key.isDown(13)` and `mode == "FIRING"`); the menu's own button binds arrows but is never offered a key, so it is not on the display list when the menu is up |
| `Photo Rave` | an attract loop, still animating | keypad-bound with 133 mouse conditions across 168 sprites |

Neither is a parse or render failure.

## The profile

`Player.profile` is `avm1`, `lite` or `avm2`, and it decides ONE thing:
how a frontend maps the keyboard. It changes nothing about what is drawn
or how big it is.

It is DETECTED at load, by asking the only question that separates the
two worlds: does the movie call `fscommand2`? A byte scan would answer
wrongly — 0x2D is `-` in ASCII and turns up inside any pushed string — so
`detectProfile` runs a real opcode walk over every action blob the movie
has (frame actions, init actions, button conditions, clip events) and
descends into every function body they define. On `games/` it says `lite`
for 31 of the 35 and `avm1` for the four that genuinely never call the
instruction (`Bugs War`, `Copter`, `IQ test`, `Pacman`).

`--profile lite|avm1|avm2` overrides it. `avm2` is accepted and reserved:
there is no AVM2 here, and it maps keys like `avm1`.

### The key map is DERIVED, not written down

The frontend does not ship a key table per kind of movie. At load,
`core/key_survey.zig` walks the movie and records every key it can
possibly notice, from all four places AVM1 hides them:

| where | how it is found |
|---|---|
| BUTTON `keyPress` conditions | already parsed — the key is a FIELD of the condition, and no bytecode mentions it |
| `onClipEvent(keyPress "x")` | likewise a byte in the event record |
| `Key.isDown(<code>)` | a small abstract stack over the bytecode |
| `Key.getCode()` compared against a literal | the same, following the answer through registers and locals |

The bytecode half needs the stack machine because the method name almost
always lives in the CONSTANT POOL: `Key.isDown(90)` is four actions and a
`cp8`, so a byte scan for "isDown" finds the pool and misses every call.
Following `var k = Key.getCode()` into a register or a local matters just
as much — three of the shipped games surveyed as ZERO keys until it did.
`Key.getAscii()` is tracked separately, because it answers in ASCII and
`'z'` is 122 there and 90 as a key.

A frontend then binds ACTIONS — `up`, `select`, `soft_left` — and asks
`key_survey.resolve` what code THIS movie wants for each. One rule keeps
it safe:

> If the movie already reads what a physical key IS, that key is passed
> through untouched. Only a key the movie has no use for is repurposed.

So `Z` stays `Z` in a desktop platformer that reads `Z`, and becomes
whatever the game's fire button is in one that does not. The arrows send
37-40 to a game that reads arrows and `'2'`/`'4'`/`'6'`/`'8'` to a phone
game that only knows the keypad — from the same keyboard, with no flag.
A repurposed key does not deliver its character either: `Key.getAscii`
reports 0 and the text input SDL raises after it is swallowed, or the
left soft key would also type a `q` into whatever had focus.

`handyplay-flash-sdl` prints what it found and what it bound:

    keys: 23 code(s) read, a Key listener
      Backspace Enter Shift Ctrl Space PageUp PageDown Left Up Right Down …
      bind: up=Up down=Down left=Left right=Right select=Enter action_a=Z
            action_b=X soft_left=PageUp soft_right=PageDown pause=P

`tools/keymap.py` answers the same question offline, without running the
movie, and prints the call sites with `--sites`.

The libretro core binds a RetroPad from the same survey — the D-pad
sends arrows to one game and `'2'`/`'4'`/`'6'`/`'8'` to the next, and L/R
are the soft keys wherever the movie has them (`docs/LIBRETRO.md`).

### The fallback: a fixed Lite map

A movie whose key handling could not be enumerated — a listener
switching on variables, or a remappable control scheme like Super Mario
63's — leaves the survey empty. Then, and only then, the `lite` profile's
fixed table applies:

| keyboard | Flash code | phone |
|---|---:|---|
| `F1`, `Q` | 33 (PageUp) | LEFT soft key |
| `F2`, `W` | 34 (PageDown) | RIGHT soft key |
| `Enter`, `Space` | 13 | SELECT |
| arrows | 37-40 | D-pad |
| number row, keypad | 48-57 | the keypad |
| `*`, `#` | 42, 35 | star and hash |

Shift is folded in there too — `Q` and `q` are the same soft key.

### The soft-key strip

`SetSoftKeys("Options","Exit")` puts those two words over the bottom
corners of the stage, on a translucent strip, drawn with SDL3's built-in
debug font — no asset, no font loading. It appears only in the `lite`
profile and only once a movie has set a label. On a handset that strip
was the only clue which key did what, and 14 of the 35 games set it.

## Tests

- `tests/as2/fscommand/` — ActionScript, compiled by mtasc, and CHECKED
  AGAINST RUFFLE. It measures silence: a device command must produce no
  output and must not stop the movie, in either player.
- `tests/as2/fscommand2/` — opcode 0x2D, which no compiler here emits and
  ruffle does not have. `tools/make_fscommand2_test.py` writes the SWF
  bytes; the expectation is OURS, reviewed against the table above rather
  than measured against a second player, and the case says so in its own
  `test.toml`.

## What is worth doing next

1. **Sound.** Not surveyed here; M6.
2. **The two games that still do not advance** (`Tank Commander`,
   `Photo Rave`) — both want the pointer where they were given keys.
3. **`GetSoftKeyLocation` and `FullScreen` are the only device answers a
   frontend could make honest** by drawing a handset instead of a stage.
   Deliberately not done: see above.
