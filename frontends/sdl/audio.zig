//! SDL3 audio sink — a pure PCM consumer, like the sibling cores'.
//!
//! Push model on the MAIN THREAD: no callback ever touches the player, so
//! there is no lock and no chance of a callback reading a half-updated
//! mixer. `pump` is called once per loop iteration after `tick`, keeps
//! about 100 ms queued, and that cushion is what absorbs a slow frame.
//!
//! Skipping audio entirely — `HANDYPLAY_FLASH_NO_AUDIO=1`, or a device that
//! will not open — changes NOTHING a movie can observe: the mixer's clock
//! runs off the frame loop either way (core/audio/mixer.zig), so traces
//! and completion timing are identical silent or not.

const std = @import("std");
const flash = @import("flash");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "");
    @cInclude("SDL3/SDL.h");
});

/// 0.16's std has no `getenv`, and the escape hatch is worth more than
/// the purity: libc is already linked here through SDL.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

var stream: ?*c.SDL_AudioStream = null;

const BYTES_PER_FRAME = 2 * @sizeOf(i16); // stereo s16
/// ~100 ms at 44100.
const TARGET_QUEUED: c_int = 4410 * BYTES_PER_FRAME;
const CHUNK_FRAMES = 1024;
var buf: [CHUNK_FRAMES * 2]i16 = @splat(0);

/// Open the default playback device. Failure is not fatal — it is a
/// silent run, and it SAYS so: silence with no explanation is the one
/// audio bug a user cannot tell from "this movie has no sound".
pub fn init() void {
    if (getenv("HANDYPLAY_FLASH_NO_AUDIO") != null) return;
    if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
        warn("audio: SDL_InitSubSystem failed");
        return;
    }
    const spec = c.SDL_AudioSpec{
        .format = c.SDL_AUDIO_S16,
        .channels = 2,
        .freq = @intCast(flash.audio.mixer.SAMPLE_RATE),
    };
    stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
    if (stream) |s| {
        _ = c.SDL_ResumeAudioStreamDevice(s);
    } else warn("audio: no playback device, running silent");
}

fn warn(msg: []const u8) void {
    _ = c.SDL_Log("%s", msg.ptr);
}

pub fn deinit() void {
    if (stream) |s| c.SDL_DestroyAudioStream(s);
    stream = null;
}

/// Refill the cushion from whatever the player has mixed. Call once per
/// main-loop iteration, after `tick`, so this frame's sounds are audible
/// in this frame.
pub fn pump(player: *flash.Player) void {
    const s = stream orelse return;
    while (c.SDL_GetAudioStreamQueued(s) < TARGET_QUEUED) {
        player.renderAudio(&buf, CHUNK_FRAMES);
        if (!c.SDL_PutAudioStreamData(s, &buf, @intCast(buf.len * @sizeOf(i16)))) return;
        // Only one chunk per iteration when the player has nothing more
        // mixed: pulling harder would just queue silence and add latency.
        if (player.audioPending() < CHUNK_FRAMES * 2) return;
    }
}
