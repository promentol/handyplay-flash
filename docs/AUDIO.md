# Audio (M6)

Sound arrives two ways in SWF and both work here: **event sounds**
(`StartSound`, and the AVM1 `Sound` class) and the frame-synced
**stream** (`SoundStreamHead` + a block per frame). FLV audio from a
`NetStream` feeds the same mixer.

    core/codecs/{pcm,adpcm,mp3}.zig   decoders
    core/audio/mixer.zig              voices, the clock, the output
    core/audio/stream.zig             SoundStreamHead/Block bookkeeping
    frontends/sdl/audio.zig           SDL3 sink
    frontends/libretro/core.zig       retro_audio_sample_batch

## The clock rule

Everything a script can observe — `Sound.position`, whether a sound is
still playing, when `onSoundComplete` fires — moves by **exactly one
frame's worth of samples per movie frame**, and by nothing else. Never by
what a sound card consumed.

`Mixer.render` and `Mixer.advance` walk identical arithmetic; only the
first also sums samples. So a headless `trace_runner` and a player with
speakers agree to the tick. This is not a claim, it is a test:

    trace_runner test.swf --frames N          # advance path
    trace_runner test.swf --frames N --audio  # render path

All **694** dirs of ruffle's AVM1 corpus produce byte-identical traces
either way.

**Playback speed rides on the same rule.** `flash_speed` (docs/LIBRETRO.md)
does not touch the frame clock: the Player asks for `44100 / fps / speed`
samples per movie frame and the mixer walks each voice `speed` times
further per output sample, so at 2x a second of sound lands in half a
second of output — pitched, in step with the picture, at an unchanged
44100. The frontend's per-call sample count never changes, and at
`speed = 1.0` every multiplication is by exactly one, which is why the
694-dir A/B above is unaffected.

The rule also comes from ruffle: its own test backend
(`tests/framework/src/backends/audio.rs`) sizes a buffer to
`channels * 44100 / frame_rate` and mixes exactly one of them per tick.
Matching its completion timing is a consequence of copying that, which is
why the 17 scored sound dirs survived audio going from "instant" to real
— including `sound_duration_position_props`, which counts seven
completions and reads a duration of 1045 ms.

`Sound.getDuration()` deliberately does **not** come from the decoder: it
is the MP3 frame-header walk in `codecs/mp3.zig`, which is what produced
ruffle's exact numbers before any of this existed.

## Codecs

| SWF format | what we do | why |
|---|---|---|
| 0, 3 — uncompressed PCM | `codecs/pcm.zig` | 8-bit is unsigned around 128; 16-bit is little-endian in both formats |
| 1 — ADPCM | `codecs/adpcm.zig`, hand-written | 2-5 bit, sign-magnitude, unaligned bit stream, initial pair repeating every 4095 samples |
| 2 — MP3 | vendored **minimp3** (CC0, `vendor/minimp3`) behind `codecs/mp3_impl.c` | the format every embedded sound in `games/` uses |
| 4, 5, 6 — Nellymoser | **silent** | appears in no corpus dir, no game and no sample |
| 11 — Speex | **silent** | likewise |

`-Dmp3=false` compiles the C out completely: MP3s then play silent while
durations and completion timing are unchanged, because those come from
the header walk and the mixer's clock rather than from decoded samples.

Two wrappers are easy to miss and both are handled: a DefineSound MP3
begins with a 2-byte encoder seek offset, and an MP3 SoundStreamBlock
begins with a sample count and a seek offset (4 bytes) before its frames.
An ADPCM stream block carries its own header, unlike every other format,
so its decoder is rebuilt per block.

## Streams

A stream belongs to a TIMELINE, not to the movie: `library.Sprite` and
`MovieClip` each carry their own `stream_head`, because a sprite may
stream music over the root's. Blocks are appended to a GROWING mixer
source — running out of samples means "not fed yet", not "finished" — and
a playhead that jumps backwards (a loop, a `gotoAndPlay`) restarts the
stream rather than letting the music run on under a rewound picture.

## The sinks

Both are pure consumers; neither can change what a script sees.

- **SDL3** (`frontends/sdl/audio.zig`): a push-model `SDL_AudioStream`
  pumped once per main-loop iteration after `tick`, keeping ~100 ms
  queued. `HANDYPLAY_FLASH_NO_AUDIO=1` or a device that will not open gives a
  silent run and nothing else changes.
- **libretro**: `retro_run` renders one frame's worth and hands it to
  `audio_batch_cb` at 44100.

Headless mode reports what it heard, which is how this gets tested
without ears:

    handyplay-flash-sdl game.swf --headless-frames 300 --out out.png
    # → frame N → out.png (… bytes), audio energy 1317400242, 94/94 sounds started

    libretro_test_host core.dylib game.swf --frames 400 --audio
    # → 551200 audio frames, energy 2789078306 (AUDIBLE)

`sounds started` is the useful pair when something is silent: `0/0` means
the playhead never reached a `StartSound` (true of `Pacman` and
`Galactic War`, whose sounds sit in sprites you only reach by playing),
while `0/40` would mean the tags ran and nothing decoded.

## What plays today

`Super Mario 63` (182 sounds, 345 StartSounds, 1173 stream blocks),
`Journe Yofj` and `KCLY Diamond` make sound unprompted; the corpus's own
`netstream_play_flv` decodes its 41 MP3 audio tags. Of the 36 games, 21
carry sound at all.

## Not done

- **Nellymoser and Speex** — no decoder, deliberately (see above).
- **AAC in FLV** — MP3 only; AAC would be a second vendored dependency
  for content none of the corpus has.
- **Save-states** must eventually carry the voice table (M5's other
  half). Mixer state is presentation, but WHICH sounds are playing and
  where is not.
