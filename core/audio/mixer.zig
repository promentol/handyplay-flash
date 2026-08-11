//! Event + stream sounds -> interleaved stereo i16 @ 44100.
//!
//! **The clock rule.** Everything a script can observe — `position`,
//! whether a sound is still playing, when `onSoundComplete` fires — moves
//! by exactly one frame's worth of samples per player frame, and by
//! nothing else. Never by how much a sound card happened to consume.
//! `render` and `advance` walk identical arithmetic; only one of them
//! also sums samples. So a headless `trace_runner` and the SDL player
//! agree to the tick, which is what keeps the 679-dir trace ratchet
//! honest now that sounds have real durations.
//!
//! That is also what ruffle's own test backend does
//! (`tests/framework/src/backends/audio.rs`: a buffer of
//! `channels * 44100 / frame_rate`, mixed once per tick), so matching its
//! completion timing is a consequence of the design rather than luck.
//!
//! Sources are DECODED ONCE and shared: a DefineSound played fifty times
//! is fifty voices pointing at one PCM buffer.

const std = @import("std");

pub const SAMPLE_RATE: u32 = 44100;
/// Flash itself had no fixed limit; 32 is the sibling core's number and
/// more than any of the games ask for at once.
pub const MAX_VOICES = 32;

/// SWF's sound transform is a 2x2 matrix — a sound can be routed left to
/// right and back. `Sound.setPan` is a convenience over it, and the
/// corpus reads the matrix form back out (`sound_gettransform_props`).
pub const Transform = struct {
    ll: f32 = 1,
    lr: f32 = 0,
    rl: f32 = 0,
    rr: f32 = 1,

    pub fn fromVolumePan(volume: f32, pan: f32) Transform {
        // Flash pans by attenuating one side, never by boosting the
        // other: pan +100 is "left silent", not "right doubled".
        const l = if (pan > 0) 1 - pan else 1;
        const r = if (pan < 0) 1 + pan else 1;
        return .{ .ll = volume * l, .rr = volume * r };
    }

    pub fn combine(a: Transform, b: Transform) Transform {
        return .{
            .ll = a.ll * b.ll,
            .lr = a.lr * b.lr,
            .rl = a.rl * b.rl,
            .rr = a.rr * b.rr,
        };
    }
};

/// One envelope point, in the mixer's own terms: a position in SOURCE
/// frames and the two channel levels there.
pub const EnvelopePoint = struct {
    at: u32,
    left: f32,
    right: f32,
};

/// Decoded audio, owned by the mixer and shared by every voice playing
/// it. `samples` is interleaved; mono sources have one channel and are
/// doubled at mix time rather than in memory.
pub const Source = struct {
    samples: []i16,
    channels: u8 = 1,
    rate: u32 = SAMPLE_RATE,
    /// A stream keeps growing while its timeline feeds it, so a voice
    /// that runs out of samples STALLS instead of finishing.
    growing: bool = false,

    pub fn frames(self: Source) usize {
        return self.samples.len / @max(1, self.channels);
    }
};

pub const PlayOptions = struct {
    /// Where to start, in source frames.
    in_point: u32 = 0,
    /// Where to stop, in source frames; null plays to the end.
    out_point: ?u32 = null,
    /// How many EXTRA times to play. SWF counts total plays, so the
    /// caller subtracts one.
    loops: u16 = 0,
    transform: Transform = .{},
    envelope: []const EnvelopePoint = &.{},
    /// Whatever the caller wants back in the completion notice — an AVM1
    /// object handle for `Sound`, or 0 for a timeline sound.
    owner: u32 = 0,
};

const Voice = struct {
    active: bool = false,
    id: u32 = 0,
    handle: u32 = 0,
    /// Playback position in SOURCE frames, fractional because the source
    /// rate and the output rate rarely agree.
    pos: f64 = 0,
    in_point: u32 = 0,
    out_point: ?u32 = null,
    loops: u16 = 0,
    transform: Transform = .{},
    envelope: []const EnvelopePoint = &.{},
    owner: u32 = 0,
};

pub const Notice = struct { id: u32, owner: u32 };

pub const Mixer = struct {
    gpa: std.mem.Allocator,
    sources: std.AutoHashMapUnmanaged(u32, Source) = .empty,
    voices: [MAX_VOICES]Voice = @splat(.{}),
    next_id: u32 = 1,
    /// Finished voices, waiting for the Player to turn them into
    /// `onSoundComplete`. A ring so a runaway movie cannot grow it.
    notices: [MAX_VOICES]Notice = @splat(.{ .id = 0, .owner = 0 }),
    n_notices: usize = 0,
    master: Transform = .{},
    /// Playback speed, 1.0 = the movie's own. It multiplies how far each
    /// voice walks per OUTPUT sample, which is the whole of a pitch
    /// shift: at 2x a second of sound is squeezed into half a second of
    /// output, exactly as the frames it belongs to are. The Player keeps
    /// the other half of the bargain by asking for proportionally fewer
    /// samples per frame (`audioFramesPerFrame`), so the rate handed to
    /// the frontend never changes.
    speed: f64 = 1.0,

    pub fn init(gpa: std.mem.Allocator) Mixer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Mixer) void {
        var it = self.sources.valueIterator();
        while (it.next()) |s| self.gpa.free(s.samples);
        self.sources.deinit(self.gpa);
        self.* = undefined;
    }

    // --- sources ------------------------------------------------------------

    /// Hand the mixer decoded PCM under a caller-chosen handle (a
    /// character id for a library sound). Replacing a handle frees what
    /// was there.
    pub fn register(self: *Mixer, handle: u32, pcm: Source) !void {
        const gop = try self.sources.getOrPut(self.gpa, handle);
        if (gop.found_existing) self.gpa.free(gop.value_ptr.samples);
        gop.value_ptr.* = pcm;
    }

    pub fn has(self: *const Mixer, handle: u32) bool {
        return self.sources.contains(handle);
    }

    pub fn source(self: *Mixer, handle: u32) ?*Source {
        return self.sources.getPtr(handle);
    }

    /// Append to a growing (stream) source. The voice playing it picks the
    /// new samples up on the next frame.
    pub fn appendTo(self: *Mixer, handle: u32, samples: []const i16) !void {
        const s = self.sources.getPtr(handle) orelse return;
        const grown = try self.gpa.realloc(s.samples, s.samples.len + samples.len);
        @memcpy(grown[s.samples.len..], samples);
        s.samples = grown;
    }

    // --- voices -------------------------------------------------------------

    pub fn play(self: *Mixer, handle: u32, opts: PlayOptions) u32 {
        if (!self.sources.contains(handle)) return 0;
        const slot = self.freeSlot() orelse return 0;
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        self.voices[slot] = .{
            .active = true,
            .id = id,
            .handle = handle,
            .pos = @floatFromInt(opts.in_point),
            .in_point = opts.in_point,
            .out_point = opts.out_point,
            .loops = opts.loops,
            .transform = opts.transform,
            .envelope = opts.envelope,
            .owner = opts.owner,
        };
        return id;
    }

    /// Stop one instance. No notice is posted: a script that called
    /// `stop()` is not told the sound completed, which is Flash's
    /// behaviour and the corpus's (`sound_start_stop` expects silence).
    pub fn stop(self: *Mixer, id: u32) void {
        for (&self.voices) |*v| {
            if (v.active and v.id == id) v.* = .{};
        }
    }

    /// Every instance of one source — what `Sound.stop()` does when the
    /// object has a sound attached, and what a timeline does on unload.
    pub fn stopHandle(self: *Mixer, handle: u32) void {
        for (&self.voices) |*v| {
            if (v.active and v.handle == handle) v.* = .{};
        }
    }

    pub fn stopAll(self: *Mixer) void {
        self.voices = @splat(.{});
    }

    pub fn stopOwner(self: *Mixer, owner: u32) void {
        for (&self.voices) |*v| {
            if (v.active and v.owner == owner) v.* = .{};
        }
    }

    /// Is any voice playing this source? `SoundInfo`'s no-multiple flag
    /// asks exactly this before starting another.
    pub fn playingHandle(self: *const Mixer, handle: u32) bool {
        for (self.voices) |v| {
            if (v.active and v.handle == handle) return true;
        }
        return false;
    }

    pub fn playingAny(self: *const Mixer) bool {
        for (self.voices) |v| {
            if (v.active) return true;
        }
        return false;
    }

    pub fn isPlaying(self: *const Mixer, id: u32) bool {
        for (self.voices) |v| {
            if (v.active and v.id == id) return true;
        }
        return false;
    }

    pub fn setTransform(self: *Mixer, id: u32, t: Transform) void {
        for (&self.voices) |*v| {
            if (v.active and v.id == id) v.transform = t;
        }
    }

    /// Where an instance has got to, in milliseconds of its SOURCE — what
    /// `Sound.position` answers.
    pub fn positionMs(self: *const Mixer, id: u32) ?f64 {
        for (self.voices) |v| {
            if (!v.active or v.id != id) continue;
            const s = self.sources.get(v.handle) orelse return 0;
            return v.pos * 1000.0 / @as(f64, @floatFromInt(s.rate));
        }
        return null;
    }

    /// The newest instance this owner started, in ms — what
    /// `Sound.position` reads.
    pub fn positionMsOfOwner(self: *const Mixer, owner: u32) ?f64 {
        var best: ?f64 = null;
        var newest: u32 = 0;
        for (self.voices) |v| {
            if (!v.active or v.owner != owner or v.id < newest) continue;
            const s = self.sources.get(v.handle) orelse continue;
            newest = v.id;
            best = v.pos * 1000.0 / @as(f64, @floatFromInt(s.rate));
        }
        return best;
    }

    /// A volume or pan change reaches everything this owner has playing.
    pub fn setOwnerTransform(self: *Mixer, owner: u32, t: Transform) void {
        for (&self.voices) |*v| {
            if (v.active and v.owner == owner) v.transform = t;
        }
    }

    pub fn takeNotice(self: *Mixer) ?Notice {
        if (self.n_notices == 0) return null;
        const n = self.notices[0];
        std.mem.copyForwards(Notice, self.notices[0 .. self.n_notices - 1], self.notices[1..self.n_notices]);
        self.n_notices -= 1;
        return n;
    }

    fn freeSlot(self: *Mixer) ?usize {
        for (&self.voices, 0..) |*v, i| {
            if (!v.active) return i;
        }
        return null;
    }

    fn post(self: *Mixer, v: Voice) void {
        if (self.n_notices == self.notices.len) return;
        self.notices[self.n_notices] = .{ .id = v.id, .owner = v.owner };
        self.n_notices += 1;
    }

    // --- the clock ------------------------------------------------------------

    /// Move every voice on by `frames` output frames AND sum them into
    /// `out` (interleaved stereo, `frames * 2` samples).
    pub fn render(self: *Mixer, out: []i16, frames: usize) void {
        @memset(out[0 .. @min(out.len, frames * 2)], 0);
        self.step(frames, out);
    }

    /// The same movement with nothing to hear. A headless run takes this
    /// path and reaches identical positions and completions.
    pub fn advance(self: *Mixer, frames: usize) void {
        self.step(frames, null);
    }

    fn step(self: *Mixer, frames: usize, out: ?[]i16) void {
        for (&self.voices) |*v| {
            if (!v.active) continue;
            const s = self.sources.getPtr(v.handle) orelse {
                v.* = .{};
                continue;
            };
            const total: f64 = @floatFromInt(s.frames());
            const end: f64 = if (v.out_point) |o| @min(@as(f64, @floatFromInt(o)), total) else total;
            const advance_per_out = @as(f64, @floatFromInt(s.rate)) /
                @as(f64, @floatFromInt(SAMPLE_RATE)) * self.speed;

            var i: usize = 0;
            while (i < frames) : (i += 1) {
                if (v.pos >= end) {
                    // A growing source has simply not been fed yet: hold
                    // position and wait rather than declare the end.
                    if (s.growing and v.out_point == null) break;
                    if (v.loops > 0) {
                        v.loops -= 1;
                        v.pos = @floatFromInt(v.in_point);
                    } else {
                        self.post(v.*);
                        v.* = .{};
                        break;
                    }
                }
                if (out) |buf| {
                    if (i * 2 + 1 < buf.len) self.mixOne(v.*, s.*, buf[i * 2 ..][0..2]);
                }
                v.pos += advance_per_out;
            }
        }
    }

    /// One output frame from one voice, resampled by linear interpolation
    /// between the two source frames it falls between.
    fn mixOne(self: *const Mixer, v: Voice, s: Source, out: *[2]i16) void {
        const total = s.frames();
        if (total == 0) return;
        const idx: usize = @intFromFloat(@floor(v.pos));
        if (idx >= total) return;
        const frac: f32 = @floatCast(v.pos - @floor(v.pos));
        const next = @min(idx + 1, total - 1);

        const ch = @max(1, s.channels);
        const l0: f32 = @floatFromInt(s.samples[idx * ch]);
        const l1: f32 = @floatFromInt(s.samples[next * ch]);
        const r0: f32 = if (ch > 1) @floatFromInt(s.samples[idx * ch + 1]) else l0;
        const r1: f32 = if (ch > 1) @floatFromInt(s.samples[next * ch + 1]) else l1;
        var left = l0 + (l1 - l0) * frac;
        var right = r0 + (r1 - r0) * frac;

        const env = envelopeAt(v.envelope, v.pos, s.rate);
        left *= env[0];
        right *= env[1];

        const t = Transform.combine(v.transform, self.master);
        const ml = left * t.ll + right * t.rl;
        const mr = left * t.lr + right * t.rr;

        out[0] = saturate(@as(f32, @floatFromInt(out[0])) + ml);
        out[1] = saturate(@as(f32, @floatFromInt(out[1])) + mr);
    }

    fn saturate(v: f32) i16 {
        return @intFromFloat(std.math.clamp(v, -32768, 32767));
    }

    /// SoundInfo's envelope: levels at given positions, linear between
    /// them, held flat before the first point and after the last.
    fn envelopeAt(points: []const EnvelopePoint, pos: f64, rate: u32) [2]f32 {
        if (points.len == 0) return .{ 1, 1 };
        // Envelope positions are in 44.1 kHz frames whatever the source
        // rate is — one of the few places SWF fixes a rate.
        const at = pos * @as(f64, @floatFromInt(SAMPLE_RATE)) / @as(f64, @floatFromInt(@max(1, rate)));
        if (at <= @as(f64, @floatFromInt(points[0].at))) return .{ points[0].left, points[0].right };
        var i: usize = 1;
        while (i < points.len) : (i += 1) {
            const a = points[i - 1];
            const b = points[i];
            if (at > @as(f64, @floatFromInt(b.at))) continue;
            const span: f64 = @floatFromInt(b.at - a.at);
            if (span <= 0) return .{ b.left, b.right };
            const k: f32 = @floatCast((at - @as(f64, @floatFromInt(a.at))) / span);
            return .{ a.left + (b.left - a.left) * k, a.right + (b.right - a.right) * k };
        }
        const last = points[points.len - 1];
        return .{ last.left, last.right };
    }
};

// --- save-states ------------------------------------------------------------
//
// The VOICES travel; the sources do not. A library sound re-decodes from
// the movie on restore (deterministic, and the state stays small), so a
// voice carries the handle it plays and the mixer asks for that handle to
// be re-registered before the voices are applied.

pub const SavedVoice = extern struct {
    active: u8,
    handle: u32,
    pos: f64,
    in_point: u32,
    out_point: u32,
    has_out: u8,
    loops: u16,
    owner: u32,
    ll: f32,
    lr: f32,
    rl: f32,
    rr: f32,
    id: u32,
};

pub fn savedVoices(self: *const Mixer, out: *[MAX_VOICES]SavedVoice) void {
    for (self.voices, 0..) |v, i| {
        // A STREAM voice is not saved. Its source grows as the timeline
        // feeds it and none of those samples are in the state, so a
        // restore could only drop the voice — and a voice that is written
        // but cannot come back makes the state disagree with itself
        // (the re-save after a load differs, which is what found this).
        // The music restarts when the playhead feeds the stream again.
        const growing = if (self.sources.get(v.handle)) |src| src.growing else false;
        if (!v.active or growing) {
            // A record that cannot come back is written ZEROED, not
            // half-filled: the re-save after a load has to produce the
            // same bytes, and a dropped voice restores as nothing.
            out[i] = std.mem.zeroes(SavedVoice);
            continue;
        }
        out[i] = .{
            .active = 1,
            .handle = v.handle,
            .pos = v.pos,
            .in_point = v.in_point,
            .out_point = v.out_point orelse 0,
            .has_out = @intFromBool(v.out_point != null),
            .loops = v.loops,
            .owner = v.owner,
            .ll = v.transform.ll,
            .lr = v.transform.lr,
            .rl = v.transform.rl,
            .rr = v.transform.rr,
            .id = v.id,
        };
    }
}

/// Apply saved voices. A voice whose source is not registered is dropped
/// rather than left pointing at nothing — the sound is simply lost, which
/// is what a restore into a player that cannot decode it means.
pub fn restoreVoices(self: *Mixer, saved: *const [MAX_VOICES]SavedVoice, next_id: u32) void {
    self.voices = @splat(.{});
    for (saved, 0..) |sv, i| {
        if (sv.active == 0) continue;
        if (!self.sources.contains(sv.handle)) continue;
        self.voices[i] = .{
            .active = true,
            .id = sv.id,
            .handle = sv.handle,
            .pos = sv.pos,
            .in_point = sv.in_point,
            .out_point = if (sv.has_out != 0) sv.out_point else null,
            .loops = sv.loops,
            .transform = .{ .ll = sv.ll, .lr = sv.lr, .rl = sv.rl, .rr = sv.rr },
            .owner = sv.owner,
            // Envelopes point into the movie arena and are re-derived by
            // whoever restarts the sound; a restored voice plays flat.
            .envelope = &.{},
        };
    }
    self.next_id = @max(1, next_id);
    self.n_notices = 0;
}

// --- tests -------------------------------------------------------------------

fn testSource(gpa: std.mem.Allocator, n: usize, value: i16) !Source {
    const buf = try gpa.alloc(i16, n);
    @memset(buf, value);
    return .{ .samples = buf, .channels = 1, .rate = SAMPLE_RATE };
}

test "advance and render reach the same completion" {
    const gpa = std.testing.allocator;
    var a = Mixer.init(gpa);
    defer a.deinit();
    var b = Mixer.init(gpa);
    defer b.deinit();
    try a.register(1, try testSource(gpa, 100, 1000));
    try b.register(1, try testSource(gpa, 100, 1000));
    _ = a.play(1, .{ .owner = 7 });
    _ = b.play(1, .{ .owner = 7 });

    var out: [64 * 2]i16 = undefined;
    var ticks: usize = 0;
    while (ticks < 4) : (ticks += 1) {
        a.advance(64);
        b.render(&out, 64);
    }
    // Both finished, both posted one notice for owner 7.
    const na = a.takeNotice();
    const nb = b.takeNotice();
    try std.testing.expect(na != null and nb != null);
    try std.testing.expectEqual(@as(u32, 7), na.?.owner);
    try std.testing.expectEqual(na.?.id, nb.?.id);
    try std.testing.expect(a.takeNotice() == null);
}

test "a stopped voice never completes" {
    const gpa = std.testing.allocator;
    var m = Mixer.init(gpa);
    defer m.deinit();
    try m.register(1, try testSource(gpa, 10, 1000));
    const id = m.play(1, .{});
    m.stop(id);
    m.advance(100);
    try std.testing.expect(m.takeNotice() == null);
    try std.testing.expect(!m.isPlaying(id));
}

test "loops play the source again before completing" {
    const gpa = std.testing.allocator;
    var m = Mixer.init(gpa);
    defer m.deinit();
    try m.register(1, try testSource(gpa, 10, 500));
    _ = m.play(1, .{ .loops = 2 });
    m.advance(25); // 2.5 plays
    try std.testing.expect(m.takeNotice() == null);
    m.advance(10); // past the third
    try std.testing.expect(m.takeNotice() != null);
}

test "a growing source stalls instead of finishing" {
    const gpa = std.testing.allocator;
    var m = Mixer.init(gpa);
    defer m.deinit();
    var src = try testSource(gpa, 8, 100);
    src.growing = true;
    try m.register(1, src);
    const id = m.play(1, .{});
    m.advance(50);
    try std.testing.expect(m.takeNotice() == null);
    try std.testing.expect(m.isPlaying(id));
    // Fed more, it plays on.
    try m.appendTo(1, &.{ 1, 2, 3, 4 });
    m.advance(2);
    try std.testing.expect(m.isPlaying(id));
}

test "pan attenuates one side and never boosts the other" {
    const t = Transform.fromVolumePan(1, 1); // hard right
    try std.testing.expectEqual(@as(f32, 0), t.ll);
    try std.testing.expectEqual(@as(f32, 1), t.rr);
}
