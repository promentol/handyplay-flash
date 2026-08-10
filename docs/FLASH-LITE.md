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

**Ours is a stub**: it pops the arguments and pushes `-1`, which is Flash
Lite's own "command not supported". Nothing crashes and nothing happens.

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

## What is worth doing next

1. **Implement `fscommand2` for real.** The information commands are
   pure functions of the host and cannot fail; `SetQuality` maps onto
   machinery that already exists; `SetSoftKeys` needs the frontend to
   show two labels and route PageUp/PageDown.
2. **A Flash Lite key profile in the frontend** — bind the soft keys and
   a keypad to something a desktop keyboard has, so these are playable
   without hand-written input JSON.
3. **Sound.** Not surveyed here; M6.
