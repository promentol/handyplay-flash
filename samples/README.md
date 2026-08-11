# samples

## Authored here

Movies written for this repo, checked in with their source. Each is one
AS2 class compiled by the mtasc image from `tools/as2` — no library, no
embedded assets, everything on screen drawn by script.

    hello/    a title card that animates itself: gradients, `add` blending,
              a masked highlight sweep
    2048/     the whole game — 4x4 grid, sliding and merging tiles with
              their own animation, score, one-step undo, game over and
              restart.  640x480
    delve/    a roguelike — procedurally generated dungeons, field of
              view, bump combat, a bestiary that scales with depth, loot,
              a pack, permadeath and a score.  600x400

Both open on a title card that holds until FIRE — the pad's A button,
which is what libretro calls that button and therefore what a player is
told to press. The card is where the control legend lives, so neither
game has to explain itself while it is being played. The board or the
first floor is dealt BEHIND it and frozen, so clearing the card drops
you into a game that already exists rather than one that starts loading.

Build one (the compiler image comes from `sh tools/as2/as2.sh build`):

    docker run --rm -v "$PWD/samples/2048:/work" handyplay-flash-as2c \
        as2-compile Test.as 2048.swf 640 480 60 8
    docker run --rm -v "$PWD/samples/delve:/work" handyplay-flash-as2c \
        as2-compile Test.as delve.swf 600 400 60 8

Play it. Text is in the DEVICE font, so the player needs to be handed a
face — without one an unembedded font measures zero, which is what a
machine that lacks it does:

    zig build run-sdl -- samples/2048/2048.swf \
        --device-font vendor/fonts/Poppins-Medium.ttf

The `ruffle-*.png` beside each source is what ruffle's own wasm drew from
the same file, for comparison.

### 2048 on a handheld

Laid out landscape at 640x480 — the panel in the RG35XX / RG40XX /
RG28XX / RG353 / RG405M line — with the board square on the right and the
HUD in the column that leaves. Retargeting is `W`/`H` at the top of
`Test.as` and the matching `-header` argument; everything else derives.

The KEY CODES it reads were chosen against `core/key_survey.zig`, which
is how the libretro core binds a pad to a movie it has never seen. The
survey reports:

    bind: up=Up down=Down left=Left right=Right select=Space action_a=Z

so the D-pad moves, A undoes, B restarts, and — because nothing in the
`pause` candidate list (P, Esc, 19, Enter) is read — START is left alone
for the frontend's own menu. `R` matches no role and lands on the first
spare button. There is deliberately no WASD: `W` is a `soft_right`
candidate and would turn the R shoulder into a second Up.

At the keyboard the same movie takes the arrows, `Z`, `Space` and `R`,
and a drag on the stage works as a swipe.

### delve, and what it is shaped around

Measured on this machine, 600 headless frames: the player costs about
12 ms a frame at 640x480 and about 4.5 ms at 320x240, and an idle stage
costs very nearly what a busy one does. The cost is a full-stage repaint
— **resolution is nearly everything and scene complexity is nearly
free.** `cacheAsBitmap` on the static layers made it 2.3x SLOWER, so it
is not the lever it looks like.

A roguelike is what that measurement asks for. The world only changes
when the player takes a turn, so generation, field of view and monster
behaviour run once per turn rather than sixty times a second, and the
drawing is kept thin on top: every wall of one colour is a single
`beginFill` path (four cover the whole map — lit wall, remembered wall,
lit floor, remembered floor), floors are 3px dots rather than filled
tiles, and entity glyphs come from a pool of text fields that is reused
and hidden rather than built per turn.

Its keys are chosen the same way 2048's are, one role per button:

    bind: up=Up down=Down left=Left right=Right select=Space
          action_a=Z action_b=X

so the D-pad moves and bumps to attack, A uses the selected pack item or
takes the stairs, B waits a turn, X cycles the pack and L2 restarts.
START and SELECT are again left unbound for the frontend.

## Copied in

Local SWFs for manual testing (git-ignored — `samples/*.swf`). Copy from
the reference clones:

    cp reference/openflash/domu-player/src/static/squares.swf samples/   # M2 first pixels
    cp reference/openflash/domu-player/src/static/morph.swf samples/     # M7 morph shapes
    cp reference/openflash/domu-player/src/static/homestuck-beta.swf samples/  # M4 smoke

The parser/conformance corpora are read in place from reference/ — see
docs/TESTING.md.
