# The libretro core

    sh tools/build-libretro-mac.sh install     # macOS: universal, into RetroArch
    zig build libretro -Doptimize=ReleaseFast  # anywhere else

Then in RetroArch: **Load Core → handyplay-flash**, **Load Content → a .swf**.
Or straight from a terminal:

    /Applications/RetroArch.app/Contents/MacOS/RetroArch \
        -L ~/Library/Application\ Support/RetroArch/cores/flash_libretro.dylib \
        games/Snake.swf

**macOS ships an x86_64 RetroArch.** The cask build (1.22.2 here) is
Intel and runs under Rosetta, and a core is dlopened INTO that process —
so an arm64-only core on an arm64 Mac simply never appears, which reads
as a broken core rather than a mismatched one. `build-libretro-mac.sh`
builds both slices and `lipo`s them, so it loads either way.

The `.info` file is not optional: without
`~/Library/Application Support/RetroArch/info/flash_libretro.info`
RetroArch calls the core "Unknown" and will not associate `.swf` with it,
so its own file browser hides your movies. The install script copies it. The
core is `frontends/libretro/core.zig`; the ABI is hand-declared in
`frontends/libretro/libretro.zig`, so there is no `libretro.h` and no
dependency to install.

Save-states and rewind WORK and are on by default (`docs/SAVESTATE.md`):
all 36 games and all 195 multi-frame corpus dirs round-trip, and the
`.info` file claims `savestate = "true"` with `serialized` features. The
`flash_savestates` core option turns them off; `HANDYPLAY_FLASH_SAVESTATES=1`
turns them on for the harness regardless of the option.

`retro_serialize_size` is MEASURED once, at the first ask: the player
serialises into a scratch buffer that doubles until the state fits, and
the answer is latched at twice that plus a megabyte. It never moves
afterwards, which is what D4 requires. A state that outgrows the latch
makes `retro_serialize` return false — visible in RetroArch, unlike a
truncated blob.
Audio plays (M6, `docs/AUDIO.md`): one frame's worth is mixed per
`retro_run` and handed to `audio_batch_cb` at 44100.

## The pad is bound by the MOVIE

There is no key table in the core. At load, `core/key_survey.zig` reads
which keys the movie can actually notice — button `keyPress` conditions,
clip events, `Key.isDown`, `Key.getCode` comparisons — and each pad
button asks `key_survey.resolve` for the code that answers its ACTION.

| pad | action | example: a desktop game | a phone game | a keypad-only game |
|---|---|---|---|---|
| D-pad | up/down/left/right | arrows (37-40) | arrows | `'2' '8' '4' '6'` |
| A | action_a | `Z` | Enter | `'5'` |
| B | select | Enter | Enter | `'5'` |
| X | action_b | `X` | — | — |
| **Y** | — | **mouse click**, always | | |
| L / R | soft keys | — | PageUp / PageDown | — |
| START | pause | `P` | Enter | — |
| SELECT | back | Esc | PageDown | — |

Two rules make it playable rather than merely correct:

- **A clicks when it cannot type.** A movie that reads no keys at all
  would otherwise have a dead face button.
- **The D-pad aims the cursor when the movie reads no directional key.**
  For a mouse-only movie the D-pad is free, and aiming is the only thing
  worth doing with it.

### Pointing

Six of the shipped games never read a key at all, so the pad has to be
able to point. `flash_pointer` names how, in the same shape melonDS and
DeSmuME use for the same problem — that is the setting a player goes
looking for:

| `flash_pointer` | the stick | the cursor |
|---|---|---|
| `auto` (default) | aims | appears when it moves, dims and leaves after ~2s still |
| `joystick` | aims | always drawn |
| `touch` | does nothing | only a real pointer device moves it |
| `off` | does nothing | never |

The cursor is DRAWN by the core — an outlined arrow, sized against the
stage, so it stays visible over both a white menu and a black level.
`flash_cursor` sets how fast the stick pushes it, scaled by stage width
so a 176x208 game and an 800x600 one take the same time to cross.

Drawing it is the one frame that is not zero-copy: the picture has to be
copied before an arrow can go on top, so that copy happens only while the
cursor is actually shown.

`RETRO_DEVICE_POINTER` — a touchscreen, or RetroArch's mouse — is
absolute and works in every mode but `off`.

The resolved map is published as INPUT DESCRIPTORS, so RetroArch's
control menu names what this movie made of each button ("Fire (Z)",
"Soft left (PageUp)"), and logged through the frontend's logger at load.

## The boot shell

Loading a game shows an ad, then a LEGEND of what the pad became, then
plays:

    ad (3 seconds of the movie's own fps, START skips)  ->  controls  ->  play

The legend is the point. The mapping is DERIVED, so unless something says
"A is Z, L is Quality −", the player is guessing. It lists all sixteen
buttons — a button the movie gave nothing to is dimmed rather than
dropped, because an absent row is a mystery — and it picks one column or
two, and the text size, by measuring the stage: two columns at double
size on a 450x300 movie, one column on a 176x208 phone game.

It is drawn in the project's own visual language — the indigo gradient,
the rounded-square mark with its orange-to-purple sweep, drifting circles
and real anti-aliased type, the same picture `samples/hello` renders
through the Flash engine. The type is **Poppins Medium (SIL OFL)**,
vendored in `vendor/fonts/` and embedded in the core, rasterised through
simdra's stb_truetype binding: RetroArch ships no font a core may use and
a system font is not ours to distribute, so embedding is the only way the
screen looks like anything on a stock install. (A 3x5 bitmap font came
first and read as a debug overlay.) `flash_boot = off` skips it.

Rows are named by the **RetroPad button** — `A`, `L2`, `START` — not by
our word for the role. libretro never tells a core what the physical
controller calls its buttons, only the abstraction, so that is as close
to the real names as exists, and it is the vocabulary the frontend's own
menus use. The prompt says `PRESS A` for the same reason.

**It does not edit anything, on purpose.** A core that draws its own
remapper ends up fighting the frontend: RetroArch already remaps physical
buttons to RetroPad ids, per game, with persistence and a UI everyone
knows, and two remappers composed multiplicatively is a support problem.
Editing happens in core options instead — see below.

## Speed

`flash_speed` multiplies the movie's clock, and it is not RetroArch's
fast-forward. Fast-forward runs the core as often as the host can manage
and lets the frontend deal with the audio; this changes how much movie
each `retro_run` covers, so the frontend still gets exactly one frame and
`44100 / fps` samples per call. Vsync, save-states and rewind all behave
as they do at 1x, and the sound is PITCHED rather than dropped.

Two halves make that work, and they have to agree:

- `Player.tick` is handed `one frame period x speed`. Its accumulator
  turns that into two frames at 2x and a frame every other call at 0.5x,
  so the timeline, `getTimer`, `setInterval` and streamed sound all move
  together. `MAX_FRAMES_PER_TICK` is why 4x is the top of the list.
- The mixer walks each voice `speed` times further per OUTPUT sample
  (`core/audio/mixer.zig` `step`), and the Player asks for
  proportionally FEWER samples per frame. A second of sound therefore
  lands in half a second of output at 2x — pitched up, in step with the
  picture, and at an unchanged sample rate.

Measured on `Dawn of the Fly`, which is 24 fps and noisy: 300 calls at
1x, 150 at 2x, 75 at 4x and 600 at 0.5x all render the SAME frame
pixel-for-pixel, and the audio energy across them is E, E/2, E/4 and 2E —
the same sound squeezed into proportionally fewer samples. The per-call
sample count never moves off 2756.

RetroArch's own fast-forward still works and is still the right tool for
"skip this cutscene": hold the hotkey. `flash_speed` is for a movie
authored at 12 fps that you want to *play* at 24.

## Core options

| option | values | effect |
|---|---|---|
| `flash_profile` | auto / lite / avm1 / avm2 | overrides the detection (a movie that calls `fscommand2` is Flash Lite); a change re-loads the movie |
| `flash_quality` | high / low | the stage quality switch, live |
| `flash_cursor` | normal / slow / fast / off | analog-cursor speed, live |
| `flash_pointer` | auto / joystick / touch / off | how the movie is pointed at (see above) |
| `flash_boot` | on / off | the ad and the controls legend |
| `flash_savestates` | on / off | save-states and rewind (docs/SAVESTATE.md) |
| `flash_speed` | 0.5x … 4x | how fast the MOVIE runs, live (see below) |
| `flash_bind_<button>` | auto / none / **this movie's keys** | what that pad button sends |

The `flash_bind_*` options are the remapper, and they are **rebuilt for
every movie**: their values are the keys the survey found, so Super Mario
63 offers `Z X Space C Ctrl Shift Enter P …` and a keypad game offers
`2 4 5 6 8`. That is only possible because the option list is re-declared
in `retro_load_game` rather than at startup — a core option declared
before any content exists cannot know what the content reads.
(dosbox-pure builds its mapper the same way.)

**It has to go through `SET_CORE_OPTIONS_V2`, and that was measured.**
The old `SET_VARIABLES` is read exactly ONCE: RetroArch logs the second
call, keeps the first list, and the per-movie bindings never reach its
menu — verified here by loading a game and finding only the five fixed
options in `config/handyplay-flash/handyplay-flash.opt`. With v2 the same second
call lands, and the core can then ask `GET_VARIABLE` for
`flash_bind_a` and be answered. The v0 path is kept as a fallback for
frontends that report an older options version.

`auto` leaves the survey's own choice in place, which is what every one
of them defaults to. Changing one mid-game applies immediately: the map
is rebuilt, the movie is made to let go of any key the old binding was
holding, and the input descriptors are re-published so the frontend's
control menu keeps up.

There is no screen-size option, unlike the J2ME core: a SWF carries its
stage box and frame rate in its header, and `retro_get_system_av_info`
reports them unchanged. Nothing is scaled.

## Testing it without RetroArch

    zig build libretro-test -Doptimize=ReleaseFast
    ./zig-out/bin/libretro_test_host zig-out/libretro/flash_libretro.dylib \
        "games/Snake.swf" --frames 210 --hold a

`frontends/libretro/test_host.zig` dlopens the core and drives it through
the real C ABI — so a wrong `callconv`, a missing export or a crash in
`retro_run` shows up here, which calling into `core/` directly could
never catch. With `--hold` it runs the movie twice, once untouched and
once with a button pressed, and reports how many pixels differ.

`--hold` **pulses** (two frames down, then up, every ten) rather than
holding. That is not a detail: a movie sees key EVENTS, so a button held
from frame 1 produces exactly ONE edge, at a moment when most of these
games are still on a preloader. Holding found 7 of 36 games reacting;
pulsing found 30. `--solid` restores the held behaviour.

`--point x,y` (fractions of the stage) drives the absolute pointer and
pulses its press — the only way to exercise the movies that never read a
key. `--pointer <mode>` answers the `flash_pointer` option, `--shell`
keeps the intro and legend (off by default, so a reaction test is not
measuring three seconds of ad), and `--reset-at N` calls `retro_reset`
mid-run — RetroArch's Restart button is a lifecycle path a player can
reach in one click, and it tears the Player down and boots it again.

Checked before every install: all 36 games load, run, survive a
`retro_reset` at frame 40, and unload without leaking (peak RSS moves 3 MB
between one load and four of a 19 MB movie).

### What the corpus does through the ABI

All 36 files in `games/` load and run. **30 react to a pad button**, and
of the six that do not, five react to a CLICK — `IQ test`, `MiniPet`,
`Pacman`, `Magic 666 Ball`, `superTORCH`, and Super Mario 63, whose
intro advances on a click at the bottom of the stage. Only `Photo Rave`
is unreached, and it was already one of the two holdouts before any of
this (docs/FLASH-LITE.md).
