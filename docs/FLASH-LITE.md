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

Feeding that set blind — soft keys, select, D-pad, keypad — moves **16 of
the 35** past their menus into real gameplay: a Sudoku board with a
running clock, Snapper at level 1, a Tetrix piece falling, KCLY Diamond
reaching GAME OVER.

The remaining 19 are not known to be broken; they simply need a
navigation sequence a blind script does not stumble into.

## What is worth doing next

1. **Implement `fscommand2` for real.** The information commands are
   pure functions of the host and cannot fail; `SetQuality` maps onto
   machinery that already exists; `SetSoftKeys` needs the frontend to
   show two labels and route PageUp/PageDown.
2. **A Flash Lite key profile in the frontend** — bind the soft keys and
   a keypad to something a desktop keyboard has, so these are playable
   without hand-written input JSON.
3. **Sound.** Not surveyed here; M6.
