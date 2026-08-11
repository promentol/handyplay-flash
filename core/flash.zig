//! Umbrella module root + the host seam (mirrors handyplay-oss exen.zig).
//! Frontend-agnostic, no I/O: frontends create a Player from SWF bytes,
//! feed it elapsed time, and present `framebuffer()` (XRGB8888).

const std = @import("std");

pub const swf = @import("swf/swf.zig");
pub const external = @import("external.zig");
pub const key_survey = @import("key_survey.zig");
pub const savestate = @import("savestate.zig");
const statefmt = @import("statefmt");

const codecs_pcm = @import("codecs/pcm.zig");
const codecs_adpcm = @import("codecs/adpcm.zig");
const codecs_mp3 = @import("codecs/mp3.zig");

pub const audio = struct {
    pub const mixer = @import("audio/mixer.zig");
    pub const stream = @import("audio/stream.zig");
};

pub const avm1 = struct {
    pub const opcodes = @import("avm1/opcodes.zig");
    pub const strings = @import("avm1/string.zig");
    pub const value = @import("avm1/value.zig");
    pub const object = @import("avm1/object.zig");
    pub const runtime = @import("avm1/runtime.zig");
    pub const activation = @import("avm1/activation.zig");
    pub const gc = @import("avm1/gc.zig");
    pub const amf = @import("avm1/amf.zig");
    pub const stage_object = @import("avm1/stage_object.zig");
    pub const singletons = @import("avm1/globals/singletons.zig");
    pub const loader = @import("avm1/globals/loader.zig");
    pub const style_sheet = @import("avm1/globals/style_sheet.zig");
    pub const local_connection = @import("avm1/globals/local_connection.zig");
    pub const net_connection = @import("avm1/globals/net_connection.zig");
    pub const net_stream = @import("avm1/globals/net_stream.zig");
    pub const sound = @import("avm1/globals/sound.zig");
    pub const file_reference = @import("avm1/globals/file_reference.zig");
    pub const text_binding = @import("avm1/text_binding.zig");
    pub const fscommand = @import("avm1/fscommand.zig");
    pub const xml_class = @import("avm1/globals/xml.zig");
    pub const text_format = @import("avm1/globals/text_format.zig");
    pub const bitmap_data = @import("avm1/globals/bitmap_data.zig");
};

pub const bitmap = struct {
    pub const pixels = @import("bitmap/pixels.zig");
    pub const data = @import("bitmap/data.zig");
    pub const operations = @import("bitmap/operations.zig");
    pub const decode = @import("bitmap/decode.zig");
    pub const turbulence = @import("bitmap/turbulence.zig");
};

pub const xml = struct {
    pub const parser = @import("xml/parser.zig");
};

pub const display = struct {
    pub const library = @import("display/library.zig");
    pub const display_object = @import("display/display_object.zig");
    pub const bounds = @import("display/bounds.zig");
    pub const movie_clip = @import("display/movie_clip.zig");
    pub const button = @import("display/button.zig");
    pub const text = @import("display/text.zig");
    pub const edit_text = @import("display/edit_text.zig");
    pub const device_font = @import("display/device_font.zig");
    pub const font = @import("display/font.zig");
    pub const text_layout = @import("display/text_layout.zig");
    pub const mouse = @import("display/mouse.zig");
    pub const drawing = @import("display/drawing.zig");
    pub const tab = @import("display/tab.zig");
    // M4: text.zig.
};

pub const text = struct {
    pub const format = @import("text/format.zig");
    pub const spans = @import("text/spans.zig");
    pub const html = @import("text/html.zig");
};

pub const render = struct {
    pub const canvas = @import("render/canvas.zig");
    pub const shape_utils = @import("render/shape_utils.zig");
    pub const renderer = @import("render/renderer.zig");
    // M4: bitmap fills; M7: masks.
};

pub const LoadError = swf.movie.Error || error{OutOfMemory};

const Vm = avm1.runtime.Vm;
const MovieClipT = display.movie_clip.MovieClip;

/// The player instance. Heap-pinned (`create`/`destroy`) because the
/// simdra surface↔canvas pair is self-referential once created.
/// Which KIND of player a frontend should be. It decides one thing only:
/// how the keyboard is mapped. Nothing here changes what is drawn or how
/// big it is — a Flash Lite movie is presented at its own stage size,
/// exactly like any other (docs/FLASH-LITE.md).
pub const Profile = enum {
    /// Desktop Flash: the keyboard is a keyboard.
    avm1,
    /// A handset. Two SOFT KEYS, a D-pad, and a numeric keypad, which is
    /// the entire input surface these games were written for.
    lite,
    /// Reserved. There is no AVM2 here; it maps a keyboard like `avm1`
    /// so that a frontend can accept the word without lying about it.
    avm2,

    pub fn fromName(name: []const u8) ?Profile {
        if (std.ascii.eqlIgnoreCase(name, "lite")) return .lite;
        if (std.ascii.eqlIgnoreCase(name, "avm1")) return .avm1;
        if (std.ascii.eqlIgnoreCase(name, "avm2")) return .avm2;
        return null;
    }
};

/// Is this a Flash Lite movie? The only reliable mark one leaves is a
/// call to `fscommand2`, which no desktop authoring tool emits. That
/// question is answered by the same walk that surveys the keyboard
/// (`core/key_survey.zig`), so asking it separately would parse every
/// action blob twice.
pub fn detectProfile(movie: *const swf.movie.Movie) Profile {
    return profileOf(key_survey.survey(movie));
}

fn profileOf(s: key_survey.Survey) Profile {
    return if (s.fs_command2) .lite else .avm1;
}

/// One DefineSound to PCM. The format nibble decides the decoder; the
/// two we do not have (Nellymoser, Speex) return null and play silent,
/// which is honest and costs nothing — neither appears in the corpus,
/// the games or the samples.
fn decodeSound(gpa: std.mem.Allocator, snd: swf.sound_tags.Sound) ?audio.mixer.Source {
    const f = snd.format;
    const samples: []i16 = switch (f.compression) {
        .uncompressed, .uncompressed_unknown_endian => codecs_pcm.decode(gpa, snd.data, f.is_16_bit) catch return null,
        .adpcm => codecs_adpcm.decode(gpa, snd.data, f.is_stereo, snd.num_samples) catch return null,
        .mp3 => {
            // A DefineSound MP3 begins with a 2-byte seek offset — the
            // number of samples the encoder's first frame runs ahead —
            // and minimp3 must not see it as audio.
            if (snd.data.len < 2) return null;
            const pcm = codecs_mp3.decodeAll(gpa, snd.data[2..]) orelse return null;
            return .{ .samples = pcm.samples, .channels = pcm.channels, .rate = pcm.rate };
        },
        else => return null,
    };
    return .{
        .samples = samples,
        .channels = if (f.is_stereo) 2 else 1,
        .rate = f.sample_rate,
    };
}

pub const Player = struct {
    gpa: std.mem.Allocator,
    movie: swf.movie.Movie,
    root: display.movie_clip.MovieClip,
    /// The root clip has no parent to hold its placement, but AVM1 can
    /// still write `_root._x`/`_alpha`/`_visible`, so the Player owns one.
    /// `owns_kind` is false — `root` is a field, not a heap allocation.
    root_placement: display.display_object.DisplayObject,
    canvas: render.canvas.Canvas,
    renderer: render.renderer.Renderer,
    background: swf.reader.Color,
    vm: *Vm,
    /// The tick's display context, live only while runOneFrame is on the
    /// stack. Gotos need it to replay IMMEDIATELY, the way ruffle's
    /// goto_frame does, rather than being deferred to the end of the
    /// action — a script can observe the removal its own goto caused.
    cur_ctx: ?*display.movie_clip.Context = null,
    /// What the pointer is over, and what it was pressed on. Both survive
    /// across events — the whole rollOver/dragOut machine is the delta
    /// between the old pair and the new pick.
    hovered: ?*display.display_object.DisplayObject = null,
    pressed: ?*display.display_object.DisplayObject = null,
    /// Flash's `instanceN` counter. Monotonic for the life of the movie;
    /// ruffle resets it only when the root movie is replaced.
    instance_counter: u32 = 0,
    /// DoInitAction runs once, before frame 1 (see `runInitActions`).
    init_actions_done: bool = false,
    /// The host clipboard, as far as a text field is concerned. Owned by
    /// the player because Cut and Paste must see the same one.
    clipboard: std.ArrayList(u16) = .empty,
    /// The parsed device face, owned here and pointed at by the library.
    device_face: ?*display.device_font.DeviceFont = null,
    /// Fixed timestep (ms/frame) from the SWF header, clamped 0.01–120 fps.
    frame_ms: f64,
    acc_ms: f64 = 0,
    /// Milliseconds of wall time since the movie started. Only the
    /// caret's blink reads it, so it need not be precise — just monotone.
    elapsed_ms: f64 = 0,
    /// Loads the movie has asked for and not yet been answered. They are
    /// resolved at the END of the tick, mirroring ruffle's test harness,
    /// which runs its future executor after `run_frame` and the timers.
    pending_loads: std.ArrayList(avm1.runtime.FetchRequest) = .empty,
    /// The frontend's file reader, and whether requests are traced.
    load_file: ?*const fn (user: ?*anyopaque, url: []const u8, status: *FetchStatus) ?[]const u8 = null,
    load_user: ?*anyopaque = null,
    log_fetch: bool = false,
    /// Movies loaded at runtime, owned here. Every parsed struct in the
    /// clips below them slices into these buffers, so they must outlive
    /// any clip that ever pointed at one — including after an
    /// `unloadMovie`, since a queued action can still be holding a child.
    loaded_movies: std.ArrayList(*swf.movie.Movie) = .empty,
    /// External sounds (`Sound.loadSound`) by mixer handle, and where
    /// each came from. Same rule as the movies: the state carries the URL
    /// and a restore re-fetches, rather than shipping the MP3.
    external_sounds: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// The URL of the `loadSound` currently completing, so the register
    /// callback — which only sees bytes — can file it.
    loading_sound_url: ?[]const u8 = null,
    /// Where each of those came from, parallel to `loaded_movies`. A save
    /// writes the URL and a restore RE-FETCHES: the bytes are the host's
    /// and immutable, so carrying them in the state would be paying a
    /// rewind cost for something already on disk.
    movie_urls: std.ArrayList([]const u8) = .empty,
    /// `_level1` and up, NEWEST FIRST. That order is the execution order:
    /// ruffle prepends every new clip to one global list, so a level
    /// created later takes its frame before the root does (corpus
    /// unloadmovienum, where the loaded level traces before the parent's
    /// next frame). Level 0 is `root` and is not in here.
    levels: std.ArrayList(*display.display_object.DisplayObject) = .empty,
    /// Loads whose `onLoadInit` is still owed — see `fireLoadInits`.
    pending_init: std.ArrayList(avm1.runtime.FetchRequest.Movie) = .empty,
    /// Clips whose `unloadMovie` lands at the start of the next frame.
    pending_unloads: std.ArrayList(*MovieClipT) = .empty,
    /// Ruffle's `clip_exec_list`, NEWEST FIRST. Every clip is prepended
    /// when it joins a timeline, which is why a child takes its frame
    /// before the parent that placed it and why a level loaded later runs
    /// ahead of the root. Removed clips are dropped as the walk meets
    /// them, exactly as ruffle's does.
    exec_list: std.ArrayList(*MovieClipT) = .empty,
    /// Sounds started this tick. With no audio device a sound is over the
    /// moment it starts, but `onSoundComplete` must still arrive on a
    /// LATER tick — firing it inside `start()` would run the handler
    /// before the call returned.
    pending_sound_done: std.ArrayList(u32) = .empty,
    /// M6. The mixer is the only thing that knows how far a sound has
    /// got; the Player only decides WHEN it moves — exactly one frame's
    /// worth of samples per frame run, so a headless run and a played
    /// one agree to the tick (see audio/mixer.zig).
    mixer: audio.mixer.Mixer = undefined,
    /// Samples already mixed and waiting for a sink. Only filled when a
    /// frontend said it would pull; a trace run advances instead.
    audio_out: std.ArrayList(i16) = .empty,
    audio_on: bool = false,
    /// Fractional carry, because 44100 rarely divides by a frame rate.
    audio_acc: f64 = 0,
    /// Character id -> whether its PCM has been decoded into the mixer
    /// yet. Sounds decode on FIRST PLAY: a movie with two hundred of them
    /// should not pay for the ones it never reaches.
    sound_decoded: std.AutoHashMapUnmanaged(u16, bool) = .empty,
    /// One stream per timeline that has one, keyed by the clip's address
    /// — a sprite may stream its own music over the root's.
    streams: std.AutoHashMapUnmanaged(usize, audio.stream.Stream) = .empty,
    /// Text fields a restore rebuilt that are still waiting for their
    /// `variable` to be re-bound — the binding needs the AVM1 heap, which
    /// is read after the display tree.
    pending_binds: std.ArrayList(*display.display_object.DisplayObject) = .empty,
    /// Attached bitmaps waiting for `NATV` to hand over their pixels.
    pending_bitmaps: std.ArrayList(struct {
        obj: *display.display_object.DisplayObject,
        owner: u32,
    }) = .empty,
    /// Playback speed, 1.0 = the movie's own frame rate. It is a
    /// FRONTEND setting, not movie state: a save-state does not carry it,
    /// the same way it does not carry the quality flag.
    speed: f64 = 1.0,
    /// The string pool, kept between saves so ids stay stable.
    state_pool: savestate.StringPool = undefined,
    /// Slot count at which the next collection runs (avm1/gc.zig).
    // (gc_log is a debug knob, below.)
    gc_threshold: usize = 8192,
    /// The latched `serialize_size`, measured on the first ask.
    state_bound: usize = 0,
    /// Scratch for `movieBuffers`, kept so a save does not allocate.
    movie_bufs: std.ArrayList([]const u8) = .empty,
    /// Display objects by save-state id, rebuilt by `DISP` on load and
    /// read by `HEAP` to re-point every `native.clip`.
    disp_by_id: std.ArrayList(?*anyopaque) = .empty,
    /// A clip id also names its placement object; both can appear in a
    /// `native.display`.
    disp_alt: std.AutoHashMapUnmanaged(u32, *anyopaque) = .empty,
    /// Counter behind the handles `loadSound` bytes get.
    external_sound_next: u32 = 0,
    /// Diagnostics, not state: how many StartSound tags the playhead
    /// reached and how many of them found a sound we could decode. The
    /// difference is the interesting number.
    sounds_seen: u32 = 0,
    sounds_played: u32 = 0,
    /// One MP3 decoder per NetStream that carries audio; the bit
    /// reservoir has to survive between packets.
    flv_audio: std.AutoHashMapUnmanaged(u32, codecs_mp3.Streamer) = .empty,
    /// The one open `XMLSocket`, its script object, and whatever of a
    /// message has arrived so far. Flash frames on NUL and nothing else,
    /// so a partial message simply waits here for the rest.
    socket_obj: avm1.runtime.ObjectHandle = 0,
    socket_buf: std.ArrayList(u8) = .empty,
    socket_connect: ?*const fn (user: ?*anyopaque, host: []const u8, port: u16) void = null,
    socket_send: ?*const fn (user: ?*anyopaque, data: []const u8) void = null,
    socket_close_fn: ?*const fn (user: ?*anyopaque) void = null,
    socket_poll: ?*const fn (user: ?*anyopaque) ?SocketEvent = null,
    socket_user: ?*anyopaque = null,
    open_dialog: ?*const fn (user: ?*anyopaque, filters: []const avm1.runtime.FileFilter) ?[]const DialogFile = null,
    open_multi_dialog: ?*const fn (user: ?*anyopaque, filters: []const avm1.runtime.FileFilter) ?[]const DialogFile = null,
    save_dialog: ?*const fn (user: ?*anyopaque, name: []const u8) ?DialogFile = null,
    dialog_user: ?*anyopaque = null,
    /// FileReference dialogs awaiting the end of the tick.
    pending_dialogs: std.ArrayList(avm1.runtime.FileDialogRequest) = .empty,
    /// The host's `ExternalInterface` end, reached through a thunk that
    /// hands the Player back (see `externalThunk`).
    external_call: ?ExternalCallFn = null,
    external_user: ?*anyopaque = null,
    /// Stage quality, as a rasteriser switch (see `Options.antialias`).
    antialias: bool = true,
    /// What `SetSoftKeys` last named, in the order the strip shows them:
    /// left, right. Copied rather than aliased — a label lives as long as
    /// the movie does, and the arena slice it came from does not.
    soft_key_buf: [2][MAX_SOFT_KEY]u8 = @splat(@splat(0)),
    soft_key_len: [2]usize = .{ 0, 0 },
    /// What kind of player this is, for the frontend's key map. Set by
    /// `Options.profile` or, when that is null, detected from the movie.
    profile: Profile = .avm1,
    /// Which keys this movie actually reads, surveyed at load. A frontend
    /// binds ACTIONS (`up`, `select`, `soft_left`) and asks
    /// `key_survey.resolve` what code to send for each — so a phone game
    /// that only knows the keypad and a desktop game that only knows the
    /// arrows are both playable from the same physical keys, with no
    /// per-movie table anywhere.
    keys: key_survey.Survey = .{},
    /// `FullScreen`. RECORDED, never acted on: the movie is always shown
    /// at its own size (docs/FLASH-LITE.md says why).
    full_screen: bool = false,
    /// `Quit` — the one command whose whole implementation is a flag the
    /// frontend may read. `trace_runner` never does, which is what keeps
    /// the 679 corpus dirs from stopping on their own last line.
    quit_requested: bool = false,
    /// Where the record of every command goes. NOT `trace()`: 679 movies
    /// call `fscommand("quit")` and a traced line would appear in each.
    fscommand_log: ?*const fn (user: ?*anyopaque, call: avm1.fscommand.Call) void = null,
    fscommand_user: ?*anyopaque = null,
    /// The bytes behind each picked FileReference, for `upload`. Keyed by
    /// the script object, so a reference that is browsed twice replaces
    /// its own contents.
    file_data: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    /// Safety valve: max timeline frames advanced per tick call.
    /// What a restored `attachBitmap` points at until `NATV` hands over the
/// real pixels — a zero-sized bitmap, so anything that reads it before
/// the patch sees nothing rather than garbage.
var empty_bitmap: bitmap.data.BitmapData = .{ .width = 0, .height = 0, .transparency = true };

/// `HANDYPLAY_FLASH_GC_LOG=1` prints one line per collection.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
var gc_log: ?bool = null;

fn gcLog() bool {
    if (gc_log) |v| return v;
    const v = getenv("HANDYPLAY_FLASH_GC_LOG") != null;
    gc_log = v;
    return v;
}

const MAX_FRAMES_PER_TICK = 5;

    /// Longest soft-key label kept. The strip on a handset fitted about
    /// eight characters; the games stay well under this.
    pub const MAX_SOFT_KEY = 32;

    /// Host facts the movie can observe but `core/` cannot discover for
    /// itself. Everything defaults to the deterministic value the
    /// conformance runner wants, so `create` stays a two-argument call.
    pub const Options = struct {
        /// What `_url` reports. Flash uses the path the movie was loaded
        /// from; the corpus expects the local form "/test.swf".
        url: []const u8 = "",
        /// Wall clock at movie start (Unix epoch ms) and the local zone's
        /// offset in minutes, for `Date`. The defaults are the
        /// deterministic mock the conformance runner needs; a real frontend
        /// passes the real clock.
        epoch_ms: f64 = avm1.runtime.MOCK_EPOCH_MS,
        tz_offset_min: i32 = 345,
        /// The presentation area in DEVICE pixels, and the HiDPI factor.
        /// Zero means "the movie's own stage box at 1:1", which is what a
        /// windowed frontend wants; `test.toml`'s `viewport_dimensions`
        /// overrides it.
        viewport_width: u32 = 0,
        viewport_height: u32 = 0,
        scale_factor: f64 = 1.0,
        /// A TTF for every face the movie did NOT embed. `core/` does no
        /// I/O, so the host reads the file and hands the bytes over; with
        /// none, an unembedded face measures zero and draws nothing,
        /// which is what a machine without the font installed does.
        device_font: ?[]const u8 = null,
        /// Answer a `loadVariables`/`loadMovie`/`XML.load` for a URL. The
        /// same rule as `device_font`: `core/` does no I/O, so the host
        /// resolves the URL (relative to the movie) and reads the bytes.
        /// The returned slice must stay valid for the Player's lifetime —
        /// a loaded SWF is parsed in place, not copied. `null` = the load
        /// failed, which scripts observe as an unsuccessful `onData`.
        load_file: ?*const fn (user: ?*anyopaque, url: []const u8, status: *FetchStatus) ?[]const u8 = null,
        load_user: ?*anyopaque = null,
        /// `test.toml`'s `log_fetch`: trace every request and navigation
        /// the way ruffle's test navigator does. Off for a real frontend.
        log_fetch: bool = false,
        /// `XMLSocket`. One socket at a time — the whole corpus opens one
        /// and no frontend has needed two. `connect` and `send` are
        /// fire-and-forget; every reply comes back through `poll`, which
        /// the Player drains once per tick.
        socket_connect: ?*const fn (user: ?*anyopaque, host: []const u8, port: u16) void = null,
        socket_send: ?*const fn (user: ?*anyopaque, data: []const u8) void = null,
        socket_close: ?*const fn (user: ?*anyopaque) void = null,
        socket_poll: ?*const fn (user: ?*anyopaque) ?SocketEvent = null,
        socket_user: ?*anyopaque = null,
        /// `flash.net.FileReference`'s dialogs. Answered synchronously —
        /// the delay the script sees comes from the request being drained
        /// at the end of the tick, not from the frontend. `null` means the
        /// user cancelled.
        open_dialog: ?*const fn (user: ?*anyopaque, filters: []const avm1.runtime.FileFilter) ?[]const DialogFile = null,
        open_multi_dialog: ?*const fn (user: ?*anyopaque, filters: []const avm1.runtime.FileFilter) ?[]const DialogFile = null,
        save_dialog: ?*const fn (user: ?*anyopaque, name: []const u8) ?DialogFile = null,
        dialog_user: ?*anyopaque = null,
        /// Flash's stage QUALITY. "low" renders one sample per pixel —
        /// no antialiasing at all — and a recorded image taken that way
        /// has hard edges that a soft renderer cannot match.
        antialias: bool = true,
        /// What the handset answers about itself when a movie asks
        /// through `fscommand2` — battery, signal, device name and the
        /// rest. All fiction, all deterministic.
        device: avm1.fscommand.DeviceInfo = .{},
        /// `null` means DETECT — a movie that calls `fscommand2` is
        /// Flash Lite, anything else is desktop AVM1. An explicit value
        /// always wins, including over a movie that disagrees.
        profile: ?Profile = null,
        /// Called for every `fscommand`/`fscommand2`, recognised or not,
        /// so a frontend can show what a movie asked for. A DEBUG
        /// channel: it must never reach `trace()`.
        fscommand_log: ?*const fn (user: ?*anyopaque, call: avm1.fscommand.Call) void = null,
        fscommand_user: ?*anyopaque = null,
        /// Do NOT run frame 1 during `create`. A restore wants an empty
        /// display tree to rebuild into: the state IS the tree, and a
        /// frame 1 that ran first would leave its objects behind and its
        /// scripts' side effects with them.
        skip_first_frame: bool = false,
        /// The other end of `ExternalInterface`. Wiring one up is what
        /// makes `ExternalInterface.available` true, so a frontend with
        /// nothing to expose leaves it null and the class stays inert.
        /// The Player is handed back because a host that calls out is
        /// usually about to call back IN, and frame 1 runs before
        /// `createWith` has returned a pointer to hold on to.
        external_call: ?ExternalCallFn = null,
        external_user: ?*anyopaque = null,
    };

    /// A file the host's dialog picked.
    pub const DialogFile = struct {
        name: []const u8,
        file_type: ?[]const u8 = null,
        contents: []const u8 = &.{},
    };

    /// Why a fetch produced no bytes. Only `FileReference` distinguishes
    /// them, and it has to: a name that does not resolve never reports
    /// `onOpen`, while a live server answering 404 does.
    pub const FetchStatus = enum { ok, dns_error, http_error };

    /// What a socket can tell the movie. `data` is raw bytes, unframed:
    /// splitting them into NUL-terminated messages is the Player's job,
    /// because a message can be split across two of these and two
    /// messages can arrive in one.
    pub const SocketEvent = union(enum) {
        connect: bool,
        data: []const u8,
        close,
    };

    pub fn create(gpa: std.mem.Allocator, file_bytes: []const u8) anyerror!*Player {
        return createWith(gpa, file_bytes, .{});
    }

    /// `anyerror` rather than `LoadError`: frame 1 runs here, and a
    /// script on it can fail in any of the ways a later frame can.
    pub fn createWith(gpa: std.mem.Allocator, file_bytes: []const u8, opts: Options) anyerror!*Player {
        const self = try gpa.create(Player);
        errdefer gpa.destroy(self);
        var movie = try swf.movie.load(gpa, file_bytes);
        errdefer movie.deinit();
        const fps_clamped = std.math.clamp(movie.header.frame_rate, 0.01, 120.0);
        const w = @max(movie.header.widthPx(), 1);
        const h = @max(movie.header.heightPx(), 1);
        self.* = .{
            .gpa = gpa,
            .movie = movie,
            .root = display.movie_clip.MovieClip.init(movie.frames),
            .root_placement = undefined,
            .canvas = try render.canvas.Canvas.init(gpa, w, h),
            .renderer = render.renderer.Renderer.init(self.movie.allocator()),
            .background = (movie.background_color orelse 0x00FFFFFF) | 0xFF000000,
            .vm = try Vm.create(gpa, movie.swf_version),
            .frame_ms = 1000.0 / @as(f64, fps_clamped),
            .state_pool = .{ .gpa = gpa },
            .mixer = audio.mixer.Mixer.init(gpa),
        };
        // After the literal: both halves need `self` to be at its final
        // address, and frame 1 below can already touch `_root._x`.
        self.root_placement = .{
            .character_id = 0,
            .depth = 0,
            .kind = .{ .clip = &self.root },
            .owns_kind = false,
        };
        self.root.placement = &self.root_placement;
        self.load_file = opts.load_file;
        self.load_user = opts.load_user;
        self.log_fetch = opts.log_fetch;
        self.socket_connect = opts.socket_connect;
        self.socket_send = opts.socket_send;
        self.socket_close_fn = opts.socket_close;
        self.socket_poll = opts.socket_poll;
        self.socket_user = opts.socket_user;
        self.open_dialog = opts.open_dialog;
        self.open_multi_dialog = opts.open_multi_dialog;
        self.save_dialog = opts.save_dialog;
        self.dialog_user = opts.dialog_user;
        self.antialias = opts.antialias;
        self.vm.device = opts.device;
        self.keys = key_survey.survey(&self.movie);
        self.profile = opts.profile orelse profileOf(self.keys);
        self.fscommand_log = opts.fscommand_log;
        self.fscommand_user = opts.fscommand_user;
        self.external_call = opts.external_call;
        self.external_user = opts.external_user;
        if (opts.external_call != null) {
            self.vm.external_call = externalThunk;
            self.vm.external_user = @ptrCast(self);
        }
        // The ROOT consumes instance0 without keeping it: ruffle runs
        // post_instantiation (which names it) and only then
        // set_default_root_name, which blanks the name again for AVM1
        // (context.rs:404-405). That is why children start at instance1
        // and why `_root._name` is "" — corpus default_names.
        self.instance_counter = 1;
        self.installHost();
        // Host facts the VM needs BEFORE frame 1: a frame-1 script can read
        // `_url` or call `getBounds` (whose invalid-value latch consults the
        // root movie's version).
        // AFTER the struct literal above: `Renderer.init` runs inside it,
        // where `&self.movie` is not yet a valid pointer (same reason the
        // root placement is fixed up separately).
        if (opts.device_font) |ttf| {
            const face = try gpa.create(display.device_font.DeviceFont);
            face.* = display.device_font.DeviceFont.init(gpa, ttf) catch {
                gpa.destroy(face);
                return error.InvalidFont;
            };
            self.device_face = face;
            self.movie.lib.device_font = face;
        }
        self.renderer.lib = &self.movie.lib;
        self.renderer.swf_version = self.movie.swf_version;
        self.renderer.display_gpa = gpa;
        self.renderer.jpeg_tables = self.movie.jpeg_tables;
        self.vm.renderer = @ptrCast(&self.renderer);
        self.vm.root_swf_version = self.movie.swf_version;
        self.vm.max_call_depth = self.movie.max_recursion_depth;
        self.vm.movie_url = avm1.strings.fromSwf(self.vm.arena(), opts.url, 8) catch &.{};
        self.vm.epoch_ms = opts.epoch_ms;
        const inv_tw = 1.0 / @as(f64, swf.reader.TWIPS_PER_PX);
        self.vm.stage_origin_x = @as(f64, @floatFromInt(movie.header.xmin)) * inv_tw;
        self.vm.stage_origin_y = @as(f64, @floatFromInt(movie.header.ymin)) * inv_tw;
        self.vm.stage_width = w;
        self.vm.stage_height = h;
        self.vm.movie_width = @floatFromInt(w);
        self.vm.movie_height = @floatFromInt(h);
        self.vm.viewport_width = if (opts.viewport_width != 0) opts.viewport_width else w;
        self.vm.viewport_height = if (opts.viewport_height != 0) opts.viewport_height else h;
        self.vm.viewport_scale = if (opts.scale_factor > 0) opts.scale_factor else 1.0;
        // The screen the capabilities report is the viewport corrected for
        // HiDPI (ruffle's test harness feeds them from the same option).
        self.vm.screen_width = @intFromFloat(@round(@as(f64, @floatFromInt(self.vm.viewport_width)) / self.vm.viewport_scale));
        self.vm.screen_height = @intFromFloat(@round(@as(f64, @floatFromInt(self.vm.viewport_height)) / self.vm.viewport_scale));
        _ = avm1.stage_object.recomputeView(self.vm);
        self.vm.use_network_sandbox = self.movie.use_network_sandbox;
        self.vm.tz_offset_min = opts.tz_offset_min;
        // Bind `_root` BEFORE frame 1. Lazily creating it in the action
        // drain was a trap: a root frame that places a child before its own
        // DoAction drains the CHILD first, so every `_root`-anchored path
        // resolved against Vm.create's placeholder object instead of the
        // real clip — and a movie with no DoAction at all never bound it.
        // The root is the FIRST entry in the execution list, so it ends
        // up LAST: everything placed after it runs before it.
        try self.exec_list.append(gpa, &self.root);
        const root_obj = try self.clipObject(&self.root);
        // `$version` is an ordinary, ENUMERABLE variable on the root
        // timeline — which is why a POST `getURL` sends it along with the
        // movie's own variables (corpus geturl). The platform tag and
        // player version are the ones the corpus was recorded with.
        try self.vm.objects.putWithAttrs(
            root_obj,
            avm1.strings.ascii("$version"),
            .{ .string = avm1.strings.ascii("LNX 32,0,0,0") },
            .{},
            false,
        );
        // Frame 1 executes immediately so the first present isn't blank.
        if (!opts.skip_first_frame) try self.runOneFrame();
        // …and frame 1 IS a tick, so a load it started resolves here. Half
        // the loader corpus runs with `num_frames = 1` and would otherwise
        // never see its own data.
        _ = try self.finishTick();
        try self.renderNow();
        return self;
    }

    pub fn destroy(self: *Player) void {
        const gpa = self.gpa;
        if (self.device_face) |f| {
            f.deinit();
            gpa.destroy(f);
        }
        self.pending_loads.deinit(gpa);
        self.pending_init.deinit(gpa);
        self.pending_sound_done.deinit(gpa);
        self.mixer.deinit();
        self.audio_out.deinit(gpa);
        self.sound_decoded.deinit(gpa);
        var sit = self.streams.valueIterator();
        while (sit.next()) |st| st.deinit(gpa);
        self.streams.deinit(gpa);
        self.movie_bufs.deinit(gpa);
        self.disp_by_id.deinit(gpa);
        self.pending_binds.deinit(gpa);
        self.state_pool.deinit();
        self.pending_bitmaps.deinit(gpa);
        self.disp_alt.deinit(gpa);
        var fit = self.flv_audio.valueIterator();
        while (fit.next()) |st| st.deinit(gpa);
        self.flv_audio.deinit(gpa);
        self.exec_list.deinit(gpa);
        self.socket_buf.deinit(gpa);
        self.pending_dialogs.deinit(gpa);
        self.file_data.deinit(gpa);
        for (self.levels.items) |lv| {
            lv.deinit(gpa);
            gpa.destroy(lv);
        }
        self.levels.deinit(gpa);
        self.clipboard.deinit(gpa);
        self.vm.destroy();
        self.root.deinit(gpa);
        self.canvas.deinit();
        self.movie.deinit();
        for (self.loaded_movies.items) |m| {
            m.deinit();
            gpa.destroy(m);
        }
        self.loaded_movies.deinit(gpa);
        for (self.movie_urls.items) |u| gpa.free(u);
        self.movie_urls.deinit(gpa);
        var esit = self.external_sounds.valueIterator();
        while (esit.next()) |u| gpa.free(u.*);
        self.external_sounds.deinit(gpa);
        gpa.destroy(self);
    }

    /// Advance the fixed-timestep clock; returns how many timeline frames
    /// ran (0 = nothing new to present).
    pub fn tick(self: *Player, elapsed_ms: f64) !u32 {
        self.acc_ms += elapsed_ms;
        self.elapsed_ms += elapsed_ms;
        var frames: u32 = 0;
        while (self.acc_ms >= self.frame_ms and frames < MAX_FRAMES_PER_TICK) {
            try self.runOneFrame();
            self.acc_ms -= self.frame_ms;
            frames += 1;
        }
        // Cap backlog after pauses/hiccups.
        if (self.acc_ms > self.frame_ms * MAX_FRAMES_PER_TICK) {
            self.acc_ms = self.frame_ms;
        }
        const loaded = try self.finishTick();
        // Streams run LAST, after the frame, the timers and the loads —
        // ruffle's `StreamManager::tick` sits at the tail of its own tick
        // for the same reason: a stream that just got its bytes should
        // play them on this tick, not the next.
        try self.tickStreams(elapsed_ms);
        // The tick is over: no activation is live and the operand stack
        // is clear, which is the only point where a sweep is safe.
        if (frames > 0) self.maybeCollect();
        if (frames > 0 or loaded) try self.renderNow();
        return frames;
    }

    // --- save-states ------------------------------------------------------
    //
    // Serialization happens BETWEEN FRAMES, which is not a limitation but
    // a simplification worth naming: at a frame boundary the AVM1 operand
    // stack is cleared, the four global registers are reset and no
    // activation is live (`runOneFrame`'s tail does all three, matching
    // ruffle's "the stack is cleared between frames"). So none of that
    // transient state has to be written at all — it is empty by
    // construction, and a state taken anywhere else would be wrong for
    // reasons far worse than a missing field.

    /// Fields of `Vm` that are NOT scalar state. Everything not listed
    /// here is written automatically by the comptime walker, so a new
    /// field either serializes itself or fails the build — which is the
    /// point: a hand-maintained list is exactly what rots.
    const VM_SKIP = [_][]const u8{
        // Allocators and the object arena — rebuilt, not restored.
        "gpa",           "arena_state",  "objects",
        // Empty at a frame boundary (see above).
        "stack",         "registers",    "pending_throw",
        "current_activation",            "property_call_stack",
        // Host wiring: function pointers the frontend supplies afresh.
        "host",          "external_call", "external_user",
        "display_ctx",   "renderer",      "device",
        // Owned elsewhere or re-derived from the movie.
        "pools",         "unbound_text_fields",           "external_callbacks",
        "net_streams",   "levels",        "timers",
        "trace_buf",     "movie_url",     "root_object",
        // Their own sections, or a later phase of this work.
        "drag",          "drop_target",
        // `Object.registerClass` bindings travel in POOL, next to the
        // strings they name.
        "class_registry",
        // A cache keyed by ADDRESS, so it cannot be restored — and does
        // not need to be: it refills as the pools are re-decoded, and
        // POOL carries the decoded result either way.
        "pool_cache",
        // Network and LocalConnection traffic in flight. A state that
        // resumed a half-finished request would be inventing a reply the
        // server never sent; a restored movie re-issues instead.
        "net_inflight",  "net_headers",  "net_messages",
        "local_connections",             "pending_local_sends",
        // `System.exactSettings` scratch buffers — derived, and refilled
        // on the next read.
        "env_lo",        "env_hi",       "env_scratch",
    };

    /// Fields of `DisplayObject` that are not scalar state: pointers into
    /// the tree (rebuilt from the record's parent id), the kind union
    /// (rebuilt from the character id), and the slices that come from the
    /// movie and never change.
    const DO_SKIP = [_][]const u8{
        "kind",          "parent",       "placement",
        "mask",          "maskee",       "video_source",
        "name",          "origin_name",  "text_bindings",
        "tag_filters",   "clip_actions", "owner_button",
        // OWNERSHIP is a fact about how THIS instance was built, not
        // about the movie's state: the restore created these objects, so
        // the restore's answer is the true one. Taking the saved value
        // instead double-frees or leaks at teardown, which is how this
        // was found — an abort in `destroy`, with an identical trace.
        "owns_kind",
    };

    /// Likewise for `MovieClip`: the frame list and the movie are the
    /// library's, the children are rebuilt from their own records, and the
    /// drawing gets its own writer.
    const MC_SKIP = [_][]const u8{
        "frames",        "children",     "placement",
        "parent",        "drawing",      "movie",
        "loaded",        "owner_button", "stream_head",
    };




    // --- NATV: the arena-owned native payloads -----------------------------
    //
    // Five of `NativeInfo`'s variants point at a struct the interpreter
    // allocated rather than at anything the movie contains: a
    // `BitmapData`'s pixels, a `TextFormat`, an XML tree, and a
    // `NetStream`'s buffered FLV. `HEAP` writes them as `deferred` and
    // this section fills them in — it runs LAST, because every one of
    // them hangs off an object the heap has to have restored first.

    const NatvKind = enum(u8) { bitmap_data, text_format, xml_node, xml_doc, net_stream };

    /// A pointer-keyed index over every XML node reachable from the heap,
    /// so parent/child/sibling links can travel as numbers.
    const XmlIndex = struct {
        ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
        list: std.ArrayList(*avm1.xml_class.Node) = .empty,

        fn deinit(self: *XmlIndex, gpa: std.mem.Allocator) void {
            self.ids.deinit(gpa);
            self.list.deinit(gpa);
        }

        fn add(self: *XmlIndex, gpa: std.mem.Allocator, n: *avm1.xml_class.Node) !void {
            if (self.ids.contains(@intFromPtr(n))) return;
            try self.ids.put(gpa, @intFromPtr(n), @intCast(self.list.items.len));
            try self.list.append(gpa, n);
            // The whole tree, from the topmost parent down, so a node
            // reached through a child still brings its family.
            for (n.children.items) |c| try self.add(gpa, c);
        }

        fn rootOf(n: *avm1.xml_class.Node) *avm1.xml_class.Node {
            var cur = n;
            while (cur.parent) |p| cur = p;
            return cur;
        }

        fn idOf(self: *const XmlIndex, n: ?*avm1.xml_class.Node) u32 {
            const node = n orelse return 0xFFFF_FFFF;
            return self.ids.get(@intFromPtr(node)) orelse 0xFFFF_FFFF;
        }
    };

    fn writeNatives(self: *Player, w: savestate.Writer) !void {
        var index: XmlIndex = .{};
        defer index.deinit(self.gpa);
        for (self.vm.objects.slots.items) |*slot| {
            switch (slot.native) {
                .xml_node => |p| try index.add(self.gpa, XmlIndex.rootOf(@ptrCast(@alignCast(p)))),
                .xml_doc => |p| {
                    const doc: *avm1.xml_class.Document = @ptrCast(@alignCast(p));
                    try index.add(self.gpa, XmlIndex.rootOf(doc.root));
                },
                else => {},
            }
        }

        // The node table first: the records below reference it by number.
        try w.u32v(@intCast(index.list.items.len));
        for (index.list.items) |n| {
            try w.u8v(n.node_type);
            try writeOptU16s(w, n.node_value);
            try w.u32v(n.attributes);
            try w.u32v(index.idOf(n.parent));
            try w.u32v(index.idOf(n.prev));
            try w.u32v(index.idOf(n.next));
            try w.u32v(n.script_object);
            try w.u32v(n.cached_child_nodes);
            try w.u32v(@intCast(n.children.items.len));
            for (n.children.items) |c| try w.u32v(index.idOf(c));
        }

        // Then one record per object, in SLOT ORDER — deterministic, so
        // two states of the same content agree byte for byte (D3).
        var count: u32 = 0;
        for (self.vm.objects.slots.items) |*slot| {
            switch (slot.native) {
                .bitmap_data, .text_format, .xml_node, .xml_doc, .net_stream => count += 1,
                else => {},
            }
        }
        try w.u32v(count);
        for (self.vm.objects.slots.items, 0..) |*slot, i| {
            const handle: u32 = @intCast(i + 1);
            switch (slot.native) {
                .bitmap_data => |p| {
                    const bd: *bitmap.data.BitmapData = @ptrCast(@alignCast(p));
                    try w.u32v(handle);
                    try w.u8v(@intFromEnum(NatvKind.bitmap_data));
                    try w.u32v(bd.width);
                    try w.u32v(bd.height);
                    try w.boolv(bd.transparency);
                    try w.boolv(bd.disposed);
                    try w.u32v(@intCast(bd.data.len));
                    for (bd.data) |px| try w.u32v(@bitCast(px));
                },
                .text_format => |p| {
                    const tf: *text.format.TextFormat = @ptrCast(@alignCast(p));
                    try w.u32v(handle);
                    try w.u8v(@intFromEnum(NatvKind.text_format));
                    try self.writeFormat(w, tf.*);
                },
                .xml_node => |p| {
                    try w.u32v(handle);
                    try w.u8v(@intFromEnum(NatvKind.xml_node));
                    try w.u32v(index.idOf(@ptrCast(@alignCast(p))));
                },
                .xml_doc => |p| {
                    const doc: *avm1.xml_class.Document = @ptrCast(@alignCast(p));
                    try w.u32v(handle);
                    try w.u8v(@intFromEnum(NatvKind.xml_doc));
                    try w.u32v(index.idOf(doc.root));
                    try writeOptU16s(w, doc.xml_decl);
                    try writeOptU16s(w, doc.doctype);
                    try w.u32v(doc.id_map);
                    try w.i32v(doc.status);
                },
                .net_stream => |p| {
                    const st: *avm1.net_stream.Stream = @ptrCast(@alignCast(p));
                    try w.u32v(handle);
                    try w.u8v(@intFromEnum(NatvKind.net_stream));
                    try w.u32v(st.obj);
                    try writeBytes(w, st.buffer);
                    try w.boolv(st.downloading);
                    try w.boolv(st.playing);
                    try w.u64v(st.offset);
                    try w.boolv(st.header_read);
                    try w.f64v(st.stream_time);
                    try w.boolv(st.queued_seek != null);
                    try w.f64v(st.queued_seek orelse 0);
                    try w.f64v(st.buffer_time);
                    try w.u32v(st.audio_handle);
                },
                else => {},
            }
        }
    }

    fn readNatives(self: *Player, r: *savestate.Reader) !void {
        const a = self.vm.arena();
        const n_nodes = try r.u32v();
        const nodes = try self.gpa.alloc(*avm1.xml_class.Node, n_nodes);
        defer self.gpa.free(nodes);
        for (nodes) |*slot| {
            slot.* = try a.create(avm1.xml_class.Node);
            slot.*.* = .{ .node_type = 0, .node_value = null, .attributes = 0 };
        }
        // Two passes: every node exists before any link is followed.
        for (nodes) |node| {
            node.node_type = try r.u8v();
            node.node_value = try self.readOptU16s(r, a);
            node.attributes = try r.u32v();
            const parent = try r.u32v();
            const prev = try r.u32v();
            const next = try r.u32v();
            node.script_object = try r.u32v();
            node.cached_child_nodes = try r.u32v();
            const n_kids = try r.u32v();
            node.parent = if (parent < n_nodes) nodes[parent] else null;
            node.prev = if (prev < n_nodes) nodes[prev] else null;
            node.next = if (next < n_nodes) nodes[next] else null;
            node.children = .empty;
            var k: u32 = 0;
            while (k < n_kids) : (k += 1) {
                const id = try r.u32v();
                if (id < n_nodes) try node.children.append(self.vm.gpa, nodes[id]);
            }
        }

        const count = try r.u32v();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const handle = try r.u32v();
            const kind: NatvKind = @enumFromInt(try r.u8v());
            const slot: ?*avm1.object.ScriptObject =
                if (handle >= 1 and handle <= self.vm.objects.slots.items.len)
                    &self.vm.objects.slots.items[handle - 1]
                else
                    null;
            switch (kind) {
                .bitmap_data => {
                    const bd = try a.create(bitmap.data.BitmapData);
                    bd.* = .{
                        .width = try r.u32v(),
                        .height = try r.u32v(),
                        .transparency = try r.boolv(),
                        .disposed = try r.boolv(),
                    };
                    const n_px = try r.u32v();
                    const px = try self.gpa.alloc(bitmap.pixels.Color, n_px);
                    for (px) |*c| c.* = @bitCast(try r.u32v());
                    bd.data = px;
                    if (slot) |sl| sl.native = .{ .bitmap_data = @ptrCast(bd) };
                },
                .text_format => {
                    const tf = try a.create(text.format.TextFormat);
                    tf.* = try self.readFormat(r, a);
                    if (slot) |sl| sl.native = .{ .text_format = @ptrCast(tf) };
                },
                .xml_node => {
                    const id = try r.u32v();
                    if (id < n_nodes) {
                        if (slot) |sl| sl.native = .{ .xml_node = @ptrCast(nodes[id]) };
                    }
                },
                .xml_doc => {
                    const root = try r.u32v();
                    const doc = try a.create(avm1.xml_class.Document);
                    doc.* = .{
                        .root = if (root < n_nodes) nodes[root] else try a.create(avm1.xml_class.Node),
                        .xml_decl = try self.readOptU16s(r, a),
                        .doctype = try self.readOptU16s(r, a),
                        .id_map = try r.u32v(),
                        .status = try r.i32v(),
                    };
                    if (slot) |sl| sl.native = .{ .xml_doc = @ptrCast(doc) };
                },
                .net_stream => {
                    const st = try a.create(avm1.net_stream.Stream);
                    st.* = .{ .obj = try r.u32v() };
                    st.buffer = try self.readBytes(r);
                    st.downloading = try r.boolv();
                    st.playing = try r.boolv();
                    st.offset = @intCast(try r.u64v());
                    st.header_read = try r.boolv();
                    st.stream_time = try r.f64v();
                    const has_seek = try r.boolv();
                    const seek = try r.f64v();
                    st.queued_seek = if (has_seek) seek else null;
                    st.buffer_time = try r.f64v();
                    st.audio_handle = try r.u32v();
                    if (slot) |sl| sl.native = .{ .net_stream = @ptrCast(st) };
                    // The VM ticks streams through its own list.
                    try self.vm.net_streams.append(self.vm.arena(), st);
                },
            }
        }
    }

    // --- text fields -------------------------------------------------------
    //
    // An `EditText` is the one display object with real MUTABLE state of
    // its own: the typed text, the runs of formatting over it, the
    // selection, the variable it mirrors. None of that is in the movie.

    /// Everything the comptime walker cannot take: owned strings, the
    /// arena-backed spans, the lazily rebuilt layout, and the tag the
    /// field was born from (re-derived from the character).
    const ET_SKIP = [_][]const u8{
        "def",       "text",       "spans",     "font_name",
        "variable",  "restrict",   "layout",    "ime",
        "bound_to",  "filters",    "styles",    "original_html",
        "default_format",
        // Derived: the restore always relays out, so writing the flag
        // would make a re-save differ from the save it came from.
        "dirty",
    };

    fn writeU16s(w: savestate.Writer, v: []const u16) !void {
        try w.u32v(@intCast(v.len));
        for (v) |c| try w.u16v(c);
    }

    fn writeOptU16s(w: savestate.Writer, v: ?[]const u16) !void {
        try w.boolv(v != null);
        try writeU16s(w, v orelse &.{});
    }

    fn readU16s(self: *Player, r: *savestate.Reader, a: std.mem.Allocator) ![]u16 {
        _ = self;
        const n = try r.u32v();
        const out = try a.alloc(u16, n);
        for (out) |*c| c.* = try r.u16v();
        return out;
    }

    fn readOptU16s(self: *Player, r: *savestate.Reader, a: std.mem.Allocator) !?[]u16 {
        const present = try r.boolv();
        const v = try self.readU16s(r, a);
        if (present) return v;
        a.free(v);
        return null;
    }

    fn writeFormat(self: *Player, w: savestate.Writer, tf: text.format.TextFormat) !void {
        _ = self;
        // Every field is an OPTIONAL — "not set" is a distinct state that
        // `getTextFormat` reports as null — so each writes a presence flag
        // and then its value.
        try writeOptU16s(w, tf.font);
        try writeOptF64(w, tf.size);
        try w.boolv(tf.color != null);
        try w.u32v(tf.color orelse 0);
        try writeOptU16s(w, tf.url);
        try writeOptU16s(w, tf.target);
        try writeOptBool(w, tf.bold);
        try writeOptBool(w, tf.italic);
        try writeOptBool(w, tf.underline);
        try w.boolv(tf.text_align != null);
        try w.u8v(if (tf.text_align) |v| @intFromEnum(v) else 0);
        try writeOptF64(w, tf.left_margin);
        try writeOptF64(w, tf.right_margin);
        try writeOptF64(w, tf.indent);
        try writeOptF64(w, tf.leading);
        try writeOptF64(w, tf.block_indent);
        const stops: []const f64 = tf.tab_stops orelse &.{};
        try w.boolv(tf.tab_stops != null);
        try w.u32v(@intCast(stops.len));
        for (stops) |v| try w.f64v(v);
        try writeOptBool(w, tf.bullet);
        try w.boolv(tf.display != null);
        try w.u8v(if (tf.display) |v| @intFromEnum(v) else 0);
        try writeOptBool(w, tf.kerning);
        try writeOptF64(w, tf.letter_spacing);
    }

    fn writeOptF64(w: savestate.Writer, v: ?f64) !void {
        try w.boolv(v != null);
        try w.f64v(v orelse 0);
    }

    fn writeOptBool(w: savestate.Writer, v: ?bool) !void {
        try w.boolv(v != null);
        try w.boolv(v orelse false);
    }

    fn readOptF64(r: *savestate.Reader) !?f64 {
        const present = try r.boolv();
        const v = try r.f64v();
        return if (present) v else null;
    }

    fn readOptBool(r: *savestate.Reader) !?bool {
        const present = try r.boolv();
        const v = try r.boolv();
        return if (present) v else null;
    }

    fn readFormat(self: *Player, r: *savestate.Reader, a: std.mem.Allocator) !text.format.TextFormat {
        var tf: text.format.TextFormat = .{};
        tf.font = try self.readOptU16s(r, a);
        tf.size = try readOptF64(r);
        {
            const present = try r.boolv();
            const v = try r.u32v();
            tf.color = if (present) v else null;
        }
        tf.url = try self.readOptU16s(r, a);
        tf.target = try self.readOptU16s(r, a);
        tf.bold = try readOptBool(r);
        tf.italic = try readOptBool(r);
        tf.underline = try readOptBool(r);
        {
            const present = try r.boolv();
            const v = try r.u8v();
            tf.text_align = if (present) @enumFromInt(v) else null;
        }
        tf.left_margin = try readOptF64(r);
        tf.right_margin = try readOptF64(r);
        tf.indent = try readOptF64(r);
        tf.leading = try readOptF64(r);
        tf.block_indent = try readOptF64(r);
        {
            const present = try r.boolv();
            const n = try r.u32v();
            const stops = try a.alloc(f64, n);
            for (stops) |*v| v.* = try r.f64v();
            tf.tab_stops = if (present) stops else null;
        }
        tf.bullet = try readOptBool(r);
        {
            const present = try r.boolv();
            const v = try r.u8v();
            tf.display = if (present) @enumFromInt(v) else null;
        }
        tf.kerning = try readOptBool(r);
        tf.letter_spacing = try readOptF64(r);
        return tf;
    }

    fn writeSpan(w: savestate.Writer, sp: text.spans.TextSpan) !void {
        try w.u64v(sp.len);
        try writeU16s(w, sp.font.face);
        try w.f64v(sp.font.size);
        try w.u32v(sp.font.color);
        try w.f64v(sp.font.letter_spacing);
        try w.boolv(sp.font.kerning);
        try w.boolv(sp.style.bold);
        try w.boolv(sp.style.italic);
        try w.boolv(sp.style.underline);
        try w.u8v(@intFromEnum(sp.text_align));
        try w.f64v(sp.left_margin);
        try w.f64v(sp.right_margin);
        try w.f64v(sp.indent);
        try w.f64v(sp.block_indent);
        try w.f64v(sp.leading);
        try w.u32v(@intCast(sp.tab_stops.len));
        for (sp.tab_stops) |v| try w.f64v(v);
        try w.boolv(sp.bullet);
        try writeU16s(w, sp.url);
        try writeU16s(w, sp.target);
        try w.u8v(@intFromEnum(sp.display));
    }

    fn readSpan(self: *Player, r: *savestate.Reader, a: std.mem.Allocator) !text.spans.TextSpan {
        var sp: text.spans.TextSpan = .{};
        sp.len = @intCast(try r.u64v());
        sp.font.face = try self.readU16s(r, a);
        sp.font.size = try r.f64v();
        sp.font.color = try r.u32v();
        sp.font.letter_spacing = try r.f64v();
        sp.font.kerning = try r.boolv();
        sp.style.bold = try r.boolv();
        sp.style.italic = try r.boolv();
        sp.style.underline = try r.boolv();
        sp.text_align = @enumFromInt(try r.u8v());
        sp.left_margin = try r.f64v();
        sp.right_margin = try r.f64v();
        sp.indent = try r.f64v();
        sp.block_indent = try r.f64v();
        sp.leading = try r.f64v();
        {
            const n = try r.u32v();
            const stops = try a.alloc(f64, n);
            for (stops) |*v| v.* = try r.f64v();
            sp.tab_stops = stops;
        }
        sp.bullet = try r.boolv();
        sp.url = try self.readU16s(r, a);
        sp.target = try self.readU16s(r, a);
        sp.display = @enumFromInt(try r.u8v());
        return sp;
    }

    fn writeEditText(self: *Player, w: savestate.Writer, et: *display.edit_text.EditText) !void {
        try savestate.writeScalars(display.edit_text.EditText, et, w, &ET_SKIP);
        try writeU16s(w, et.text.items);
        try writeOptU16s(w, et.variable);
        try writeOptU16s(w, et.restrict);
        try writeOptU16s(w, et.original_html);
        try w.boolv(et.ime != null);
        try w.u64v(if (et.ime) |i| i.start else 0);
        try w.u64v(if (et.ime) |i| i.end else 0);
        try writeU16s(w, if (et.ime) |i| i.text else &.{});
        try w.u32v(@intCast(et.filters.items.len));
        for (et.filters.items) |h| try w.u32v(h);
        try self.writeFormat(w, et.default_format);
        try w.u32v(@intCast(et.spans.list.items.len));
        for (et.spans.list.items) |sp| try writeSpan(w, sp);
    }

    fn readEditText(self: *Player, r: *savestate.Reader, et: *display.edit_text.EditText) !void {
        const gpa = self.gpa;
        try savestate.readScalars(display.edit_text.EditText, et, r, &ET_SKIP);

        et.text.clearRetainingCapacity();
        const txt = try self.readU16s(r, gpa);
        defer gpa.free(txt);
        try et.text.appendSlice(gpa, txt);

        if (et.variable) |v| gpa.free(v);
        et.variable = try self.readOptU16s(r, gpa);
        if (et.restrict) |v| gpa.free(v);
        et.restrict = try self.readOptU16s(r, gpa);
        if (et.original_html) |v| gpa.free(v);
        et.original_html = try self.readOptU16s(r, gpa);

        {
            const present = try r.boolv();
            const start: usize = @intCast(try r.u64v());
            const end: usize = @intCast(try r.u64v());
            const t = try self.readU16s(r, gpa);
            if (et.ime) |old| gpa.free(old.text);
            if (present) {
                et.ime = .{ .start = start, .end = end, .text = t };
            } else {
                gpa.free(t);
                et.ime = null;
            }
        }

        et.filters.clearRetainingCapacity();
        const n_filters = try r.u32v();
        var i: u32 = 0;
        while (i < n_filters) : (i += 1) try et.filters.append(gpa, try r.u32v());

        // Span strings live in the spans arena, which owns them for the
        // life of the field — the same place `dupeFormat` puts them.
        const a = et.spans.alloc();
        et.default_format = try self.readFormat(r, a);
        et.spans.list.clearRetainingCapacity();
        const n_spans = try r.u32v();
        var k: u32 = 0;
        while (k < n_spans) : (k += 1) {
            try et.spans.list.append(gpa, try self.readSpan(r, a));
        }
        // The layout is derived; make it rebuild on the next read.
        et.dirty = true;

        // A field with a variable is re-bound the way a fresh one is —
        // but only once the heap exists, since the object it mirrors is
        // in it. `loadState` drains this at the end.
        et.bound_to = null;
    }

    // --- the script drawing API's geometry ---------------------------------
    //
    // `beginFill`/`lineTo` output is the ONLY part of a clip that is not
    // in the movie, so it cannot be re-derived — and a clip whose drawing
    // is missing has no bounds at all, which makes it invisible to the
    // mouse (corpus root_button_mode loses a press on a clip it drew).

    fn writeMatrix(w: savestate.Writer, m: swf.reader.Matrix) !void {
        try w.f64v(m.a);
        try w.f64v(m.b);
        try w.f64v(m.c);
        try w.f64v(m.d);
        try w.i32v(m.tx);
        try w.i32v(m.ty);
    }

    fn readMatrix(r: *savestate.Reader) !swf.reader.Matrix {
        return .{
            .a = @floatCast(try r.f64v()),
            .b = @floatCast(try r.f64v()),
            .c = @floatCast(try r.f64v()),
            .d = @floatCast(try r.f64v()),
            .tx = try r.i32v(),
            .ty = try r.i32v(),
        };
    }

    fn writeGradient(self: *Player, w: savestate.Writer, g: swf.shape.Gradient) !void {
        _ = self;
        try writeMatrix(w, g.matrix);
        try w.u8v(@intFromEnum(g.spread));
        try w.u8v(@intFromEnum(g.interpolation));
        try w.u32v(@intCast(g.records.len));
        for (g.records) |rec| {
            try w.u8v(rec.ratio);
            try w.u32v(rec.color);
        }
    }

    fn readGradient(self: *Player, r: *savestate.Reader) !swf.shape.Gradient {
        const matrix = try readMatrix(r);
        const spread: swf.shape.GradientSpread = @enumFromInt(try r.u8v());
        const interpolation: swf.shape.GradientInterpolation = @enumFromInt(try r.u8v());
        const n = try r.u32v();
        const recs = try self.gpa.alloc(swf.shape.GradientRecord, n);
        for (recs) |*rec| {
            rec.ratio = try r.u8v();
            rec.color = try r.u32v();
        }
        return .{
            .matrix = matrix,
            .spread = spread,
            .interpolation = interpolation,
            .records = recs,
        };
    }

    fn writeFillStyle(self: *Player, w: savestate.Writer, f: swf.shape.FillStyle) !void {
        try w.u8v(@intFromEnum(std.meta.activeTag(f)));
        switch (f) {
            .solid => |c| try w.u32v(c),
            .linear_gradient, .radial_gradient => |g| try self.writeGradient(w, g),
            .focal_gradient => |fg| {
                try self.writeGradient(w, fg.gradient);
                try w.f64v(fg.focal_point);
            },
            .bitmap => |b| {
                try w.u16v(b.id);
                try writeMatrix(w, b.matrix);
                try w.boolv(b.is_smoothed);
                try w.boolv(b.is_repeating);
                // `live` is a pointer into a BitmapData; it belongs to
                // NATV and is re-attached there, not here.
            },
        }
    }

    fn readFillStyle(self: *Player, r: *savestate.Reader) !swf.shape.FillStyle {
        return switch (try r.u8v()) {
            0 => .{ .solid = try r.u32v() },
            1 => .{ .linear_gradient = try self.readGradient(r) },
            2 => .{ .radial_gradient = try self.readGradient(r) },
            3 => .{ .focal_gradient = .{
                .gradient = try self.readGradient(r),
                .focal_point = @floatCast(try r.f64v()),
            } },
            4 => .{ .bitmap = .{
                .id = try r.u16v(),
                .matrix = try readMatrix(r),
                .is_smoothed = try r.boolv(),
                .is_repeating = try r.boolv(),
            } },
            else => savestate.Error.SectionCorrupt,
        };
    }

    fn writeLineStyle(self: *Player, w: savestate.Writer, l: swf.shape.LineStyle) !void {
        try w.u16v(l.width);
        try self.writeFillStyle(w, l.fill);
        try w.u8v(@intFromEnum(l.start_cap));
        try w.u8v(@intFromEnum(l.end_cap));
        try w.u8v(@intFromEnum(l.join));
        try w.f64v(l.miter_limit);
        try w.boolv(l.no_h_scale);
        try w.boolv(l.no_v_scale);
        try w.boolv(l.no_close);
        try w.boolv(l.pixel_hinting);
    }

    fn readLineStyle(self: *Player, r: *savestate.Reader) !swf.shape.LineStyle {
        return .{
            .width = try r.u16v(),
            .fill = try self.readFillStyle(r),
            .start_cap = @enumFromInt(try r.u8v()),
            .end_cap = @enumFromInt(try r.u8v()),
            .join = @enumFromInt(try r.u8v()),
            .miter_limit = @floatCast(try r.f64v()),
            .no_h_scale = try r.boolv(),
            .no_v_scale = try r.boolv(),
            .no_close = try r.boolv(),
            .pixel_hinting = try r.boolv(),
        };
    }

    fn writeCommands(w: savestate.Writer, cmds: []const render.shape_utils.DrawCommand) !void {
        try w.u32v(@intCast(cmds.len));
        for (cmds) |c| {
            try w.u8v(@intFromEnum(std.meta.activeTag(c)));
            switch (c) {
                inline .move_to, .line_to => |p| {
                    try w.i32v(p.x);
                    try w.i32v(p.y);
                    try w.i32v(0);
                    try w.i32v(0);
                },
                .quad_to => |q| {
                    try w.i32v(q.cx);
                    try w.i32v(q.cy);
                    try w.i32v(q.ax);
                    try w.i32v(q.ay);
                },
            }
        }
    }

    fn readCommands(self: *Player, r: *savestate.Reader) ![]render.shape_utils.DrawCommand {
        const n = try r.u32v();
        const out = try self.gpa.alloc(render.shape_utils.DrawCommand, n);
        for (out) |*c| {
            const tag = try r.u8v();
            const a = try r.i32v();
            const b = try r.i32v();
            const cc = try r.i32v();
            const d = try r.i32v();
            c.* = switch (tag) {
                0 => .{ .move_to = .{ .x = a, .y = b } },
                1 => .{ .line_to = .{ .x = a, .y = b } },
                2 => .{ .quad_to = .{ .cx = a, .cy = b, .ax = cc, .ay = d } },
                else => return savestate.Error.SectionCorrupt,
            };
        }
        return out;
    }

    fn writeDrawing(self: *Player, w: savestate.Writer, mc: *MovieClipT) !void {
        const d: *const display.drawing.Drawing = if (mc.drawing) |*dd| dd else {
            try w.boolv(false);
            return;
        };
        try w.boolv(true);
        try w.boolv(d.bounds != null);
        const b = d.bounds orelse swf.reader.Rectangle{};
        try w.i32v(b.xmin);
        try w.i32v(b.xmax);
        try w.i32v(b.ymin);
        try w.i32v(b.ymax);
        try w.i32v(d.cursor.x);
        try w.i32v(d.cursor.y);
        try w.i32v(d.fill_start.x);
        try w.i32v(d.fill_start.y);

        try w.u32v(@intCast(d.paths.items.len));
        for (d.paths.items) |p| {
            try w.u8v(@intFromEnum(std.meta.activeTag(p)));
            switch (p) {
                .fill => |f| {
                    try self.writeFillStyle(w, f.style.*);
                    try w.u8v(@intFromEnum(f.winding));
                    try writeCommands(w, f.commands);
                },
                .stroke => |st| {
                    try self.writeLineStyle(w, st.style.*);
                    try w.boolv(st.is_closed);
                    try writeCommands(w, st.commands);
                },
            }
        }
        // The two subpaths still open.
        try w.boolv(d.fill != null);
        if (d.fill) |f| {
            try self.writeFillStyle(w, f.style.*);
            try writeCommands(w, f.commands.items);
        }
        try w.boolv(d.line != null);
        if (d.line) |l| {
            try self.writeLineStyle(w, l.style.*);
            try writeCommands(w, l.commands.items);
        }
    }

    fn readDrawing(self: *Player, r: *savestate.Reader, mc: *MovieClipT) !void {
        if (!try r.boolv()) return;
        const d = mc.drawingMut(self.gpa);
        const has_bounds = try r.boolv();
        const box: swf.reader.Rectangle = .{
            .xmin = try r.i32v(),
            .xmax = try r.i32v(),
            .ymin = try r.i32v(),
            .ymax = try r.i32v(),
        };
        d.bounds = if (has_bounds) box else null;
        d.cursor = .{ .x = try r.i32v(), .y = try r.i32v() };
        d.fill_start = .{ .x = try r.i32v(), .y = try r.i32v() };

        const n = try r.u32v();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            switch (try r.u8v()) {
                0 => {
                    const style = try self.gpa.create(swf.shape.FillStyle);
                    style.* = try self.readFillStyle(r);
                    const winding: render.shape_utils.Winding = @enumFromInt(try r.u8v());
                    try d.paths.append(self.gpa, .{ .fill = .{
                        .style = style,
                        .winding = winding,
                        .commands = try self.readCommands(r),
                    } });
                },
                1 => {
                    const style = try self.gpa.create(swf.shape.LineStyle);
                    style.* = try self.readLineStyle(r);
                    const is_closed = try r.boolv();
                    try d.paths.append(self.gpa, .{ .stroke = .{
                        .style = style,
                        .is_closed = is_closed,
                        .commands = try self.readCommands(r),
                    } });
                },
                else => return savestate.Error.SectionCorrupt,
            }
        }
        if (try r.boolv()) {
            const style = try self.gpa.create(swf.shape.FillStyle);
            style.* = try self.readFillStyle(r);
            const cmds = try self.readCommands(r);
            defer self.gpa.free(cmds);
            d.fill = .{ .style = style };
            try d.fill.?.commands.appendSlice(self.gpa, cmds);
        }
        if (try r.boolv()) {
            const style = try self.gpa.create(swf.shape.LineStyle);
            style.* = try self.readLineStyle(r);
            const cmds = try self.readCommands(r);
            defer self.gpa.free(cmds);
            d.line = .{ .style = style };
            try d.line.?.commands.appendSlice(self.gpa, cmds);
        }
    }

    /// One display object, flattened. Written in pre-order so a parent is
    /// always restored before the children that name it.
    const DispRecord = struct {
        parent: u32,
        character_id: u16,
        depth: i32,
        kind: u8,
    };

    /// Collect when the table has grown enough to be worth a pass. The
    /// threshold rises with the live set, so a movie with a big heap is
    /// not swept every frame while one that churns is.
    fn maybeCollect(self: *Player) void {
        if (self.vm.objects.slots.items.len < self.gc_threshold) return;
        var roots: std.ArrayList(u32) = .empty;
        defer roots.deinit(self.gpa);
        // Everything the Player can still reach that the VM cannot see:
        // the display tree, the clips queued for a frame or an unload,
        // the fields waiting for a variable, and the hover/press targets.
        treeRoots(&self.root, &roots, self.gpa);
        for (self.levels.items) |lv| {
            roots.append(self.gpa, lv.avm_object) catch {};
            if (lv.kind == .clip) treeRoots(lv.kind.clip, &roots, self.gpa);
        }
        for (self.exec_list.items) |mc| {
            if (mc.placement) |o| roots.append(self.gpa, o.avm_object) catch {};
            roots.append(self.gpa, mc.avm_object) catch {};
        }
        for (self.pending_unloads.items) |mc| roots.append(self.gpa, mc.avm_object) catch {};
        for (self.vm.unbound_text_fields.items) |o| roots.append(self.gpa, o.avm_object) catch {};
        if (self.hovered) |o| roots.append(self.gpa, o.avm_object) catch {};
        if (self.pressed) |o| roots.append(self.gpa, o.avm_object) catch {};

        const stats = avm1.gc.collect(self.vm, roots.items);
        if (gcLog()) std.debug.print("[gc] {d} slots -> {d} live, {d} freed\n", .{ stats.slots, stats.live, stats.freed });
        // Next pass when the table has grown by half again over what is
        // live, and never more often than every 4096 slots.
        self.gc_threshold = @max(4096, stats.live + stats.live / 2 + 1024);
    }

    fn treeRoots(mc: *MovieClipT, out: *std.ArrayList(u32), gpa: std.mem.Allocator) void {
        out.append(gpa, mc.avm_object) catch {};
        if (mc.placement) |o| out.append(gpa, o.avm_object) catch {};
        for (mc.children.items) |child| {
            out.append(gpa, child.avm_object) catch {};
            if (child.kind == .clip) treeRoots(child.kind.clip, out, gpa);
            if (child.kind == .button) {
                // A button's own child lists are display objects too, and
                // each may carry a script object.
                for (child.kind.button.children()) |b| out.append(gpa, b.avm_object) catch {};
            }
        }
    }

    /// An upper bound on the state's size, MEASURED once and then
    /// latched. `serialize_size` may not move across a run (D4), so the
    /// answer has to cover the biggest this movie can get — and a flat
    /// guess does not: AntiMosquito's state does not fit in a megabyte
    /// and could not be saved at all.
    ///
    /// Four times the measured size, with a floor. A movie that outgrows
    /// even that (a script creating bitmaps for minutes) fails to save
    /// and the frontend says so, which is the honest outcome; a
    /// truncated blob that restores wrong is not.
    pub fn stateUpperBound(self: *Player) usize {
        if (self.state_bound != 0) return self.state_bound;
        var cap: usize = 1 << 20;
        // Up to half a gigabyte: a movie with a maximum-size `BitmapData`
        // really does carry 268 MB of pixels (corpus
        // bitmap_data_max_size_swf10), and refusing to save at all is
        // worse than a big buffer.
        while (cap <= 512 << 20) : (cap *= 2) {
            const buf = self.gpa.alloc(u8, cap) catch break;
            defer self.gpa.free(buf);
            const used = self.saveState(buf) catch continue; // too small: grow
            // Headroom, but not FOUR TIMES it: a rewind layer allocates
            // this per slot, so the difference between 2x and 4x on a
            // 200 MB state is a gigabyte of RAM.
            self.state_bound = @max(used * 2 + (1 << 20), 1 << 20);
            return self.state_bound;
        }
        self.state_bound = 1 << 20;
        return self.state_bound;
    }

    /// Write the whole mutable machine into `buf`. Answers how many bytes
    /// were used; the caller zeroes the rest (D3).
    pub fn saveState(self: *Player, buf: []u8) !usize {

        var env = try statefmt.SectionWriter.begin(buf, 0, savestate.envelope(), 0);
        var at = env.pos;

        // The display ids the heap will refer to, assigned by the same
        // pre-order walk `DISP` writes in.
        var ids: std.AutoHashMapUnmanaged(usize, u32) = .empty;
        defer ids.deinit(self.gpa);
        var n: u32 = 0;
        try self.mapTree(&self.root, &ids, &n);
        for (self.levels.items) |lv| try self.mapTree(lv.kind.clip, &ids, &n);

        // Strings are pooled BEFORE anything is written, so `STRS` can be
        // laid down ahead of the section that indexes into it. The pool
        // is the PLAYER's, not this save's: stable ids are what keeps a
        // rewind delta small (core/savestate.zig StringPool).
        const pool = &self.state_pool;
        pool.beginPass();
        try savestate.collectStrings(self.vm, pool);
        if (pool.shouldCompact()) try pool.compact();

        const ctx: savestate.SaveCtx = .{
            .pool = pool,
            .disp_ids = &ids,
            .movies = self.movieBuffers(),
        };

        at = try self.writeSection(buf, at, .plyr, writePlayerScalars);
        at = try self.writeSection(buf, at, .vmsc, writeVmScalars);
        // MOVS before DISP, because the tree's records name the movie a
        // clip's characters come from — and before AUDI, because a voice
        // whose source has not been registered yet is dropped.
        at = try self.writeSection(buf, at, .movs, writeMovies);
        at = try self.writeSection(buf, at, .audi, writeAudio);
        at = try self.writeSection(buf, at, .disp, writeDisplayTree);
        {
            var w = try statefmt.SectionWriter.begin(buf, at, savestate.section(.strs), 0);
            try savestate.writeStrings(.{ .w = &w }, pool);
            at = try w.finish();
        }
        {
            // After `STRS`: a timer's arguments are Values, and a string
            // Value is an index into the pool.
            var w = try statefmt.SectionWriter.begin(buf, at, savestate.section(.timr), 0);
            try savestate.writeTimers(.{ .w = &w }, self.vm, ctx);
            at = try w.finish();
        }
        {
            var w = try statefmt.SectionWriter.begin(buf, at, savestate.section(.pool), 0);
            try savestate.writePools(.{ .w = &w }, self.vm, pool);
            try savestate.writeClasses(.{ .w = &w }, self.vm, pool);
            at = try w.finish();
        }
        {
            var w = try statefmt.SectionWriter.begin(buf, at, savestate.section(.heap), 0);
            try savestate.writeHeap(.{ .w = &w }, self.vm, ctx);
            at = try w.finish();
        }
        // LAST: every payload here hangs off an object `HEAP` restores.
        at = try self.writeSection(buf, at, .natv, writeNatives);

        env.pos = at;
        return try env.finish();
    }

    /// Every movie buffer a closure's bytecode could point into. The root
    /// is index 0 and loaded children follow, which is the numbering
    /// `MOVS` will use.
    fn movieBuffers(self: *Player) []const []const u8 {
        self.movie_bufs.clearRetainingCapacity();
        self.movie_bufs.append(self.gpa, self.movie.body) catch {};
        for (self.loaded_movies.items) |m| self.movie_bufs.append(self.gpa, m.body) catch {};
        return self.movie_bufs.items;
    }

    /// Assign display ids in the same pre-order the tree is written in.
    fn mapTree(
        self: *Player,
        mc: *MovieClipT,
        ids: *std.AutoHashMapUnmanaged(usize, u32),
        n: *u32,
    ) !void {
        try ids.put(self.gpa, @intFromPtr(mc), n.*);
        if (mc.placement) |o| try ids.put(self.gpa, @intFromPtr(o), n.*);
        n.* += 1;
        for (mc.children.items) |child| {
            if (child.kind == .clip) {
                try self.mapTree(child.kind.clip, ids, n);
            } else {
                try ids.put(self.gpa, @intFromPtr(child), n.*);
                n.* += 1;
                if (child.kind == .button) {
                    var m: IdMap = .{ .self = self, .ids = ids, .n = n };
                    walkButtonKids(child.kind.button, &m, mapKid);
                }
            }
        }
    }

    fn writeSection(
        self: *Player,
        buf: []u8,
        at: usize,
        comptime tag: savestate.Tag,
        comptime body: fn (*Player, savestate.Writer) anyerror!void,
    ) !usize {
        var w = try statefmt.SectionWriter.begin(buf, at, savestate.section(tag), 0);
        try body(self, .{ .w = &w });
        const end = try w.finish();
        if (gcLog()) std.debug.print("[sec] {s} {d}\n", .{ @tagName(tag), end - at });
        return end;
    }

    fn writePlayerScalars(self: *Player, w: savestate.Writer) !void {
        try w.f64v(self.acc_ms);
        try w.f64v(self.elapsed_ms);
        try w.f64v(self.audio_acc);
        try w.u32v(self.instance_counter);
        try w.boolv(self.init_actions_done);
        try w.u32v(self.background);
        try w.boolv(self.antialias);
        try w.boolv(self.full_screen);
        try w.boolv(self.quit_requested);
        try w.u32v(self.external_sound_next);
        try w.u32v(self.sounds_seen);
        try w.u32v(self.sounds_played);
    }

    fn readPlayerScalars(self: *Player, r: *savestate.Reader) !void {
        self.acc_ms = try r.f64v();
        self.elapsed_ms = try r.f64v();
        self.audio_acc = try r.f64v();
        self.instance_counter = try r.u32v();
        self.init_actions_done = try r.boolv();
        self.background = try r.u32v();
        self.antialias = try r.boolv();
        self.full_screen = try r.boolv();
        self.quit_requested = try r.boolv();
        self.external_sound_next = try r.u32v();
        self.sounds_seen = try r.u32v();
        self.sounds_played = try r.u32v();
    }

    fn writeVmScalars(self: *Player, w: savestate.Writer) !void {
        try savestate.writeScalars(Vm, self.vm, w, &VM_SKIP);
    }

    /// The display tree, pre-order. Ids are positional: the root is 0 and
    /// every child's parent is an index already written, which is what
    /// lets the reader rebuild top-down in one pass.
    /// Runtime-loaded movies and the levels they live on. The SWFs
    /// themselves are NOT in the state — only the URL each came from,
    /// re-fetched through the same host reader on restore. That keeps a
    /// rewind frame free of megabytes that never change, and it is the
    /// same "re-derive what the movie already knows" rule the character
    /// library follows.
    fn writeMovies(self: *Player, w: savestate.Writer) !void {
        try w.u32v(@intCast(self.loaded_movies.items.len));
        for (self.movie_urls.items) |url| {
            try w.u32v(@intCast(url.len));
            for (url) |c| try w.u8v(c);
        }
        // A url per movie is required; if the two ever drift, pad so the
        // reader still knows how many movies to expect.
        var pad = self.loaded_movies.items.len;
        while (pad > self.movie_urls.items.len) : (pad -= 1) try w.u32v(0);

        try w.u32v(@intCast(self.levels.items.len));
        for (self.levels.items) |lv| try w.i32v(lv.kind.clip.level_id);

        // Loads still IN FLIGHT. A `loadMovie` issued on the frame the
        // state was taken completes a tick later, and without this the
        // restored run simply never hears about it — corpus
        // loadmovie_var_persistence loses the second clip entirely.
        try w.u32v(@intCast(self.pending_loads.items.len));
        for (self.pending_loads.items) |req| {
            try writeBytes(w, req.url);
            try w.u8v(@intFromEnum(req.method));
            try writeBytes(w, req.body);
            try writeBytes(w, req.mime);
            try w.u8v(@intFromEnum(std.meta.activeTag(req.target)));
            switch (req.target) {
                .movie => |m| {
                    try w.u32v(m.clip);
                    try w.u32v(m.broadcaster);
                },
                inline else => |h| {
                    try w.u32v(h);
                    try w.u32v(0);
                },
            }
        }
        // Sounds fetched from outside the movie, by mixer handle. SORTED,
        // because a hash map's order depends on insertion history and two
        // states of identical content have to match byte for byte (D3).
        try w.u32v(self.external_sounds.count());
        {
            var handles: std.ArrayList(u32) = .empty;
            defer handles.deinit(self.gpa);
            var it = self.external_sounds.keyIterator();
            while (it.next()) |h| try handles.append(self.gpa, h.*);
            std.mem.sort(u32, handles.items, {}, std.sort.asc(u32));
            for (handles.items) |h| {
                try w.u32v(h);
                try writeBytes(w, self.external_sounds.get(h).?);
            }
        }
        try w.u32v(self.external_sound_next);

        // And the `onLoadInit`s already owed.
        try w.u32v(@intCast(self.pending_init.items.len));
        for (self.pending_init.items) |m| {
            try w.u32v(m.clip);
            try w.u32v(m.broadcaster);
        }
    }

    fn writeBytes(w: savestate.Writer, b: []const u8) !void {
        try w.u32v(@intCast(b.len));
        for (b) |c| try w.u8v(c);
    }

    fn readBytes(self: *Player, r: *savestate.Reader) ![]const u8 {
        const n = try r.u32v();
        // The VM arena, which is where a script's own strings live and
        // what the fetch path already assumes it can hold on to.
        const out = try self.vm.arena().alloc(u8, n);
        for (out) |*c| c.* = try r.u8v();
        return out;
    }

    fn readMovies(self: *Player, r: *savestate.Reader) !void {
        const n = try r.u32v();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const len = try r.u32v();
            const url = try self.gpa.alloc(u8, len);
            errdefer self.gpa.free(url);
            for (url) |*c| c.* = try r.u8v();
            var status: FetchStatus = .dns_error;
            const bytes = (if (self.load_file) |f| f(self.load_user, url, &status) else null) orelse {
                // The state names a movie the host can no longer produce.
                // Fail loudly: every later index would be off by one and
                // the tree would attach the wrong characters.
                if (gcLog()) std.debug.print("[movs] refetch failed: {s}\n", .{url});
                self.gpa.free(url);
                return savestate.Error.SectionCorrupt;
            };
            const m = try self.gpa.create(swf.movie.Movie);
            m.* = swf.movie.load(self.gpa, bytes) catch {
                self.gpa.destroy(m);
                self.gpa.free(url);
                return savestate.Error.SectionCorrupt;
            };
            try self.loaded_movies.append(self.gpa, m);
            try self.movie_urls.append(self.gpa, url);
        }
        // Levels are created here so `DISP` can fill them; `getOrCreateLevel`
        // builds the clip, its placement, its AVM1 object and the exec-list
        // entry exactly as `loadMovieNum` did the first time. They are made
        // in REVERSE so the newest-first order comes out the same.
        const n_levels = try r.u32v();
        const ids = try self.gpa.alloc(i32, n_levels);
        defer self.gpa.free(ids);
        for (ids) |*id| id.* = try r.i32v();
        var k: usize = n_levels;
        while (k > 0) {
            k -= 1;
            _ = try self.getOrCreateLevel(ids[k]);
        }

        const n_loads = try r.u32v();
        var j: u32 = 0;
        while (j < n_loads) : (j += 1) {
            const url = try self.readBytes(r);
            const method: avm1.runtime.FetchRequest.Method = @enumFromInt(try r.u8v());
            const body = try self.readBytes(r);
            const mime = try self.readBytes(r);
            const tag = try r.u8v();
            const a = try r.u32v();
            const b = try r.u32v();
            const target: avm1.runtime.FetchRequest.Target = switch (tag) {
                0 => .{ .form = a },
                1 => .{ .sound = a },
                2 => .{ .load_vars = a },
                3 => .{ .movie = .{ .clip = a, .broadcaster = b } },
                4 => .{ .stylesheet = a },
                5 => .{ .net_stream = a },
                6 => .{ .net_connection = a },
                else => return savestate.Error.SectionCorrupt,
            };
            try self.pending_loads.append(self.gpa, .{
                .url = url,
                .method = method,
                .body = body,
                .mime = mime,
                .target = target,
            });
        }

        const n_sounds = try r.u32v();
        var t: u32 = 0;
        while (t < n_sounds) : (t += 1) {
            const handle = try r.u32v();
            const url = try self.readBytes(r);
            var status: FetchStatus = .dns_error;
            const bytes = (if (self.load_file) |f| f(self.load_user, url, &status) else null) orelse continue;
            const pcm = codecs_mp3.decodeAll(self.gpa, bytes) orelse continue;
            self.mixer.register(handle, .{
                .samples = pcm.samples,
                .channels = pcm.channels,
                .rate = pcm.rate,
            }) catch {
                self.gpa.free(pcm.samples);
                continue;
            };
            const copy = try self.gpa.dupe(u8, url);
            self.external_sounds.put(self.gpa, handle, copy) catch self.gpa.free(copy);
        }
        self.external_sound_next = try r.u32v();

        const n_init = try r.u32v();
        var q: u32 = 0;
        while (q < n_init) : (q += 1) {
            const clip = try r.u32v();
            const bc = try r.u32v();
            try self.pending_init.append(self.gpa, .{ .clip = clip, .broadcaster = bc });
        }
    }

    /// Which movie a clip's characters come from, as a save writes it.
    /// `inherited` is by far the common case — an ordinary sprite has no
    /// movie of its own and walks up to find one.
    fn movieRef(self: *Player, mc: *MovieClipT) u32 {
        const m = mc.movie orelse return if (mc.emptied_by_load) 1 else 0;
        if (m == &self.movie) return 0;
        for (self.loaded_movies.items, 0..) |lm, i| {
            if (lm == m) return @intCast(i + 2);
        }
        return 0;
    }

    fn applyMovieRef(self: *Player, mc: *MovieClipT, ref: u32) void {
        switch (ref) {
            0 => {}, // as instantiated
            1 => {
                mc.movie = null;
                mc.frames = &.{};
            },
            else => {
                const i = ref - 2;
                if (i >= self.loaded_movies.items.len) return;
                const m = self.loaded_movies.items[i];
                mc.movie = m;
                mc.frames = m.frames;
            },
        }
    }

    fn writeLoadInfo(w: savestate.Writer, info: ?display.movie_clip.MovieClip.LoadInfo) !void {
        const li = info orelse {
            try w.boolv(false);
            try writeName(w, null);
            try w.u32v(0);
            try w.u8v(0);
            try w.boolv(false);
            return;
        };
        try w.boolv(true);
        try writeName(w, li.url);
        try w.u32v(li.bytes);
        try w.u8v(li.version);
        try w.boolv(li.failed);
    }

    fn readLoadInfo(self: *Player, r: *savestate.Reader) !?display.movie_clip.MovieClip.LoadInfo {
        const present = try r.boolv();
        const n = try r.u32v();
        var url: []const u16 = &.{};
        if (n != 0xFFFF_FFFF) {
            // The VM arena, which is where `absoluteUrl` puts it.
            const out = try self.vm.arena().alloc(u16, n);
            for (out) |*c| c.* = try r.u16v();
            url = out;
        }
        const bytes = try r.u32v();
        const version = try r.u8v();
        const failed = try r.boolv();
        if (!present) return null;
        return .{ .url = url, .bytes = bytes, .version = version, .failed = failed };
    }

    fn writeDisplayTree(self: *Player, w: savestate.Writer) !void {
        var count: u32 = 0;
        try countTree(&self.root, &count);
        for (self.levels.items) |lv| try countTree(lv.kind.clip, &count);
        try w.u32v(count);
        var next: u32 = 0;
        try self.writeClipRecord(&self.root, 0, w, &next);
        // Every `_levelN` is a parentless tree of its own, written after
        // the root in the SAME id space — the heap points at their clips
        // by the same ids.
        for (self.levels.items) |lv| try self.writeClipRecord(lv.kind.clip, 0, w, &next);

        // The EXECUTION LIST's order is script-visible (corpus
        // execution_order4) and it is insertion order, which no walk of
        // the finished tree can recover — so it travels as ids.
        var ids: std.AutoHashMapUnmanaged(usize, u32) = .empty;
        defer ids.deinit(self.gpa);
        var n2: u32 = 0;
        try self.mapTree(&self.root, &ids, &n2);
        for (self.levels.items) |lv| try self.mapTree(lv.kind.clip, &ids, &n2);
        try w.u32v(@intCast(self.exec_list.items.len));
        for (self.exec_list.items) |mc| {
            try w.u32v(ids.get(@intFromPtr(mc)) orelse 0xFFFF_FFFF);
        }

        // The MOUSE's two anchors. Every rollOver/rollOut/dragOut is the
        // delta between the old pair and the new pick, so a restore that
        // forgets them re-announces a hover the content already had
        // (corpus hittest_morph_input) or loses the press that a later
        // release belongs to (mouse_events).
        try w.u32v(if (self.hovered) |o| ids.get(@intFromPtr(o)) orelse 0xFFFF_FFFF else 0xFFFF_FFFF);
        try w.u32v(if (self.pressed) |o| ids.get(@intFromPtr(o)) orelse 0xFFFF_FFFF else 0xFFFF_FFFF);
    }

    /// A BUTTON's own children — the state containers and the hit area —
    /// walked in one fixed order by everything that numbers the tree.
    ///
    /// They get ids but NOT records: the button rebuilds them from its
    /// definition on restore (`ensureInit`), so their geometry is already
    /// re-derived. The ids are what the EXECUTION LIST needs — an
    /// animated clip inside a button is on it, and without a number for
    /// it a restore silently dropped 121 of Trap Sweeper's 163 entries.
    fn walkButtonKids(
        b: *display.button.Button,
        ctxp: anytype,
        comptime visit: fn (@TypeOf(ctxp), *display.display_object.DisplayObject) void,
    ) void {
        for (b.children()) |c| walkKid(c, ctxp, visit);
        for (b.hitChildren()) |c| walkKid(c, ctxp, visit);
    }

    fn walkKid(
        o: *display.display_object.DisplayObject,
        ctxp: anytype,
        comptime visit: fn (@TypeOf(ctxp), *display.display_object.DisplayObject) void,
    ) void {
        visit(ctxp, o);
        switch (o.kind) {
            .clip => |mc| for (mc.children.items) |c| walkKid(c, ctxp, visit),
            .button => |bb| walkButtonKids(bb, ctxp, visit),
            else => {},
        }
    }

    fn bumpCount(n: *u32, o: *display.display_object.DisplayObject) void {
        _ = o;
        n.* += 1;
    }

    const IdMap = struct {
        self: *Player,
        ids: *std.AutoHashMapUnmanaged(usize, u32),
        n: *u32,
    };

    fn mapKid(m: *IdMap, o: *display.display_object.DisplayObject) void {
        m.ids.put(m.self.gpa, @intFromPtr(o), m.n.*) catch {};
        if (o.kind == .clip) m.ids.put(m.self.gpa, @intFromPtr(o.kind.clip), m.n.*) catch {};
        m.n.* += 1;
    }

    const IdNote = struct { self: *Player, next: *u32 };

    fn noteKid(k: *IdNote, o: *display.display_object.DisplayObject) void {
        if (o.kind == .clip) {
            k.self.noteDisplayId(k.next, @ptrCast(o.kind.clip), @ptrCast(o));
        } else {
            k.self.noteDisplayId(k.next, @ptrCast(o), null);
        }
    }

    fn countTree(mc: *MovieClipT, n: *u32) !void {
        n.* += 1;
        for (mc.children.items) |child| {
            if (child.kind == .clip) {
                try countTree(child.kind.clip, n);
            } else {
                n.* += 1;
                if (child.kind == .button) walkButtonKids(child.kind.button, n, bumpCount);
            }
        }
    }

    fn writeClipRecord(self: *Player, mc: *MovieClipT, parent: u32, w: savestate.Writer, next: *u32) !void {
        const me = next.*;
        next.* += 1;
        const obj = mc.placement;
        try w.u32v(parent);
        try w.u16v(if (obj) |o| o.character_id else 0);
        try w.i32v(if (obj) |o| o.depth else 0);
        try w.u8v(@intFromEnum(DispKind.clip));
        if (obj) |o| {
            try w.boolv(true);
            try savestate.writeScalars(display.display_object.DisplayObject, o, w, &DO_SKIP);
            try writeName(w, o.name);
        } else try w.boolv(false);
        try savestate.writeScalars(MovieClipT, mc, w, &MC_SKIP);
        try w.u32v(self.movieRef(mc));
        try writeLoadInfo(w, mc.loaded);
        try self.writeDrawing(w, mc);

        try w.u32v(@intCast(mc.children.items.len));
        for (mc.children.items) |child| {
            if (child.kind == .clip) {
                try self.writeClipRecord(child.kind.clip, me, w, next);
            } else {
                next.* += 1;
                try w.u32v(me);
                try w.u16v(child.character_id);
                try w.i32v(child.depth);
                try w.u8v(@intFromEnum(kindTag(child.kind)));
                try w.boolv(true);
                try savestate.writeScalars(display.display_object.DisplayObject, child, w, &DO_SKIP);
                try writeName(w, child.name);
                // A button's own state, which decides which records it
                // shows AND which ones it is hit through.
                if (child.kind == .button) try w.u8v(@intFromEnum(child.kind.button.state));
                if (child.kind == .edit_text) try self.writeEditText(w, child.kind.edit_text);
                // An `attachBitmap` borrows an AVM1 object's pixels, so
                // the record names the OBJECT; `NATV` restores the buffer
                // and the pointer is patched afterwards.
                if (child.kind == .attached_bitmap) {
                    try w.u32v(self.ownerOfBitmap(child.kind.attached_bitmap.data));
                    try w.boolv(child.kind.attached_bitmap.smoothing);
                }
                if (child.kind == .button) walkButtonKids(child.kind.button, next, bumpCount);
                try w.u32v(0); // no children of its own
            }
        }
    }

    fn writeName(w: savestate.Writer, name: ?[]const u16) !void {
        const n = name orelse {
            try w.u32v(0xFFFF_FFFF);
            return;
        };
        try w.u32v(@intCast(n.len));
        for (n) |c| try w.u16v(c);
    }

    const DispKind = enum(u8) {
        shape,
        morph_shape,
        text,
        edit_text,
        button,
        bitmap,
        attached_bitmap,
        clip,
        video,
    };

    fn kindTag(k: display.display_object.DisplayObject.Kind) DispKind {
        return switch (k) {
            .shape => .shape,
            .morph_shape => .morph_shape,
            .text => .text,
            .edit_text => .edit_text,
            .button => .button,
            .bitmap => .bitmap,
            .attached_bitmap => .attached_bitmap,
            .clip => .clip,
            .video => .video,
        };
    }

    /// The mixer's voices, plus which library sounds were decoded — the
    /// samples themselves are NOT written: a DefineSound re-decodes from
    /// the movie, deterministically, for nothing.
    fn writeAudio(self: *Player, w: savestate.Writer) !void {
        var saved: [audio.mixer.MAX_VOICES]audio.mixer.SavedVoice = undefined;
        audio.mixer.savedVoices(&self.mixer, &saved);
        for (saved) |v| {
            try w.u8v(v.active);
            try w.u32v(v.handle);
            try w.f64v(v.pos);
            try w.u32v(v.in_point);
            try w.u32v(v.out_point);
            try w.u8v(v.has_out);
            try w.u16v(v.loops);
            try w.u32v(v.owner);
            try w.f64v(v.ll);
            try w.f64v(v.lr);
            try w.f64v(v.rl);
            try w.f64v(v.rr);
            try w.u32v(v.id);
        }
        try w.u32v(self.mixer.next_id);
        // Which library sounds to have ready before the voices land. In
        // SORTED order — hash order depends on insertion history and two
        // states of identical content have to match byte for byte (D3).
        var ids: [512]u16 = undefined;
        var n: usize = 0;
        var it = self.sound_decoded.keyIterator();
        while (it.next()) |k| {
            if (n == ids.len) break;
            ids[n] = k.*;
            n += 1;
        }
        std.mem.sort(u16, ids[0..n], {}, std.sort.asc(u16));
        try w.u32v(@intCast(n));
        for (ids[0..n]) |id| try w.u16v(id);
    }

    fn readAudio(self: *Player, r: *savestate.Reader) !void {
        var saved: [audio.mixer.MAX_VOICES]audio.mixer.SavedVoice = undefined;
        for (&saved) |*v| {
            v.* = .{
                .active = try r.u8v(),
                .handle = try r.u32v(),
                .pos = try r.f64v(),
                .in_point = try r.u32v(),
                .out_point = try r.u32v(),
                .has_out = try r.u8v(),
                .loops = try r.u16v(),
                .owner = try r.u32v(),
                .ll = @floatCast(try r.f64v()),
                .lr = @floatCast(try r.f64v()),
                .rl = @floatCast(try r.f64v()),
                .rr = @floatCast(try r.f64v()),
                .id = try r.u32v(),
            };
        }
        const next_id = try r.u32v();
        // Re-decode first: a voice whose source is missing is dropped.
        const n = try r.u32v();
        var i: u32 = 0;
        while (i < n) : (i += 1) _ = self.soundHandle(try r.u16v());
        audio.mixer.restoreVoices(&self.mixer, &saved, next_id);
    }

    /// Rebuild the display tree from its records. The player this runs
    /// against has NOT run frame 1 (`Options.skip_first_frame`), so the
    /// tree is empty and every object here is created rather than
    /// reconciled — no timeline replay, no scripts, no naming pass.
    fn readDisplayTree(self: *Player, r: *savestate.Reader) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const count = try r.u32v();
        self.pending_binds.clearRetainingCapacity();
        self.pending_bitmaps.clearRetainingCapacity();
        self.disp_by_id.clearRetainingCapacity();
        try self.disp_by_id.appendNTimes(self.gpa, null, count);
        var next: u32 = 0;
        try self.readClipRecord(&self.root, r, &ctx, &next);
        // `MOVS` already created the levels, in the same order.
        for (self.levels.items) |lv| try self.readClipRecord(lv.kind.clip, r, &ctx, &next);

        const n_exec = try r.u32v();
        self.exec_list.clearRetainingCapacity();
        var e: u32 = 0;
        while (e < n_exec) : (e += 1) {
            const id = try r.u32v();
            if (id < self.disp_by_id.items.len) {
                if (self.disp_by_id.items[id]) |ptr| {
                    try self.exec_list.append(self.gpa, @ptrCast(@alignCast(ptr)));
                }
            }
        }
        self.hovered = self.objectOfId(try r.u32v());
        self.pressed = self.objectOfId(try r.u32v());
    }

    /// The DISPLAY OBJECT a save id names — the placement, not the clip:
    /// an id maps to both, and `hovered`/`pressed` are picks off the
    /// render list.
    fn objectOfId(self: *Player, id: u32) ?*display.display_object.DisplayObject {
        if (id >= self.disp_by_id.items.len) return null;
        if (self.disp_alt.get(id)) |alt| return @ptrCast(@alignCast(alt));
        const ptr = self.disp_by_id.items[id] orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn readClipRecord(
        self: *Player,
        mc: *MovieClipT,
        r: *savestate.Reader,
        ctx: *display.movie_clip.Context,
        next: *u32,
    ) !void {
        self.noteDisplayId(next, @ptrCast(mc), if (mc.placement) |o| @ptrCast(o) else null);
        _ = try r.u32v(); // parent index — implied by the recursion
        _ = try r.u16v(); // character id — the object already exists
        _ = try r.i32v();
        _ = try r.u8v();
        try self.readObjectBody(mc.placement, r);
        try savestate.readScalars(MovieClipT, mc, r, &MC_SKIP);
        // The movie BEFORE the children: `instantiateAt` looks each one
        // up in this clip's library, which a load may have replaced.
        self.applyMovieRef(mc, try r.u32v());
        mc.loaded = try self.readLoadInfo(r);
        try self.readDrawing(r, mc);

        // `instantiateAt` resolves character ids through `ctx.movie`, so a
        // clip holding a LOADED movie has to lend it to the context for
        // the whole subtree — the same swap playback does when it runs a
        // loaded timeline's frames.
        const outer_movie = ctx.movie;
        defer ctx.movie = outer_movie;
        if (mc.movie) |m| ctx.movie = m;

        const n = try r.u32v();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            _ = try r.u32v(); // parent index
            const cid = try r.u16v();
            const depth = try r.i32v();
            const kind: DispKind = @enumFromInt(try r.u8v());
            const child = try self.instantiateForRecord(mc, ctx, cid, depth, kind) orelse {
                // The character is gone — skip the record rather than
                // desynchronise the reader.
                if (gcLog()) std.debug.print("[disp] no character {d} at depth {d}\n", .{ cid, depth });
                _ = try r.boolv();
                return savestate.Error.SectionCorrupt;
            };
            child.parent = mc;
            if (child.kind == .clip) {
                child.kind.clip.placement = child;
                child.kind.clip.parent = mc;
            }
            try insertByDepth(mc, child, ctx);
            reattachPlaceData(mc, child);
            if (kind == .clip and child.kind == .clip) {
                self.noteDisplayId(next, @ptrCast(child.kind.clip), @ptrCast(child));
                // A clip's own body is written recursively, headerless —
                // the four header words were consumed above.
                try self.readObjectBody(child, r);
                try savestate.readScalars(MovieClipT, child.kind.clip, r, &MC_SKIP);
                self.applyMovieRef(child.kind.clip, try r.u32v());
                child.kind.clip.loaded = try self.readLoadInfo(r);
                try self.readDrawing(r, child.kind.clip);
                const grand = try r.u32v();
                var g: u32 = 0;
                const inner = ctx.movie;
                defer ctx.movie = inner;
                if (child.kind.clip.movie) |m| ctx.movie = m;
                while (g < grand) : (g += 1) try self.readChildInto(child.kind.clip, r, ctx, next);
            } else {
                self.noteDisplayId(next, @ptrCast(child), null);
                try self.readObjectBody(child, r);
                try self.readLeafExtras(child, kind, r, ctx, next);
                _ = try r.u32v(); // leaf: no children
            }
        }
    }

    /// A restored button has to be BUILT: `ensureInit` is what fills the
    /// hit area and the visible state, and it normally runs on the frame
    /// the button is placed — a frame the restore never replays. Without
    /// it the button is invisible to `mouse.pick`, which is how corpus
    /// mouse_events lost every press after the state was reloaded.
    /// The AVM1 object whose `BitmapData` this is, or 0.
    fn ownerOfBitmap(self: *Player, data: *const bitmap.data.BitmapData) u32 {
        for (self.vm.objects.slots.items, 0..) |*slot, i| {
            if (slot.native == .bitmap_data and
                @intFromPtr(slot.native.bitmap_data) == @intFromPtr(data))
            {
                return @intCast(i + 1);
            }
        }
        return 0;
    }

    fn readLeafExtras(
        self: *Player,
        child: *display.display_object.DisplayObject,
        kind: DispKind,
        r: *savestate.Reader,
        ctx: *display.movie_clip.Context,
        next: *u32,
    ) !void {
        // Driven by the RECORD's kind, not the rebuilt object's: if the
        // two ever disagree the bytes still have to be consumed, or every
        // offset after this point is wrong.
        if (kind == .attached_bitmap) {
            const owner = try r.u32v();
            const smoothing = try r.boolv();
            if (child.kind == .attached_bitmap) {
                child.kind.attached_bitmap.smoothing = smoothing;
                if (owner != 0) try self.pending_bitmaps.append(self.gpa, .{ .obj = child, .owner = owner });
            }
            return;
        }
        if (kind == .edit_text) {
            if (child.kind == .edit_text) {
                try self.readEditText(r, child.kind.edit_text);
                if (child.kind.edit_text.variable != null) {
                    try self.pending_binds.append(self.gpa, child);
                }
            } else {
                var scratch = try display.edit_text.EditText.dynamic(self.gpa, 0, 0);
                defer scratch.deinit(self.gpa);
                try self.readEditText(r, &scratch);
            }
            return;
        }
        if (kind != .button) return;
        const state = try r.u8v();
        if (child.kind != .button) return;
        const b = child.kind.button;
        b.state = @enumFromInt(state);
        try b.ensureInit(ctx, child);
        var k: IdNote = .{ .self = self, .next = next };
        walkButtonKids(b, &k, noteKid);
    }

    /// `instantiateAt` for a record. A character id of 0 means the object
    /// was made by SCRIPT — `createEmptyMovieClip` or `createTextField` —
    /// and there is no library entry to look up, so the kind the record
    /// carries is the only thing that says which to build.
    fn instantiateForRecord(
        self: *Player,
        mc: *MovieClipT,
        ctx: *display.movie_clip.Context,
        cid: u16,
        depth: i32,
        kind: DispKind,
    ) !?*display.display_object.DisplayObject {
        _ = self;
        if (cid == 0 and kind == .edit_text) {
            const obj = try mc.instantiateTextField(ctx, depth, 0, 0);
            obj.owns_kind = true;
            return obj;
        }
        if (cid == 0 and kind == .attached_bitmap) {
            // The pixels are BORROWED from an AVM1 object, so this starts
            // empty and `NATV` supplies the buffer.
            return try mc.instantiateAttachedBitmap(ctx, depth, &empty_bitmap, false);
        }
        return mc.instantiateAt(ctx, cid, depth, 0);
    }

    /// One child record whose header has NOT yet been read.
    /// Record which display object a save id names, both ways round: an
    /// AVM1 object may hold the clip OR its placement.
    fn noteDisplayId(self: *Player, next: *u32, a: ?*anyopaque, b: ?*anyopaque) void {
        const id = next.*;
        next.* += 1;
        if (id < self.disp_by_id.items.len) {
            self.disp_by_id.items[id] = a orelse b;
            if (a != null and b != null) self.disp_alt.put(self.gpa, id, b.?) catch {};
        }
    }

    fn readChildInto(
        self: *Player,
        mc: *MovieClipT,
        r: *savestate.Reader,
        ctx: *display.movie_clip.Context,
        next: *u32,
    ) !void {
        _ = try r.u32v();
        const cid = try r.u16v();
        const depth = try r.i32v();
        const kind: DispKind = @enumFromInt(try r.u8v());
        const child = try self.instantiateForRecord(mc, ctx, cid, depth, kind) orelse {
            if (gcLog()) std.debug.print("[disp] child: no character {d} at depth {d}\n", .{ cid, depth });
            return savestate.Error.SectionCorrupt;
        };
        child.parent = mc;
        if (child.kind == .clip) {
            child.kind.clip.placement = child;
            child.kind.clip.parent = mc;
            self.noteDisplayId(next, @ptrCast(child.kind.clip), @ptrCast(child));
        } else self.noteDisplayId(next, @ptrCast(child), null);
        try insertByDepth(mc, child, ctx);
        reattachPlaceData(mc, child);
        try self.readObjectBody(child, r);
        if (kind == .clip and child.kind == .clip) {
            try savestate.readScalars(MovieClipT, child.kind.clip, r, &MC_SKIP);
            self.applyMovieRef(child.kind.clip, try r.u32v());
            child.kind.clip.loaded = try self.readLoadInfo(r);
            try self.readDrawing(r, child.kind.clip);
            const grand = try r.u32v();
            var g: u32 = 0;
            const inner = ctx.movie;
            defer ctx.movie = inner;
            if (child.kind.clip.movie) |m| ctx.movie = m;
            while (g < grand) : (g += 1) try self.readChildInto(child.kind.clip, r, ctx, next);
        } else {
            try self.readLeafExtras(child, kind, r, ctx, next);
            _ = try r.u32v();
        }
    }

    /// Clip event handlers, filters and the original name come from the
    /// PlaceObject tag that first put this object on the list — the
    /// restore does not replay tags, so it looks the tag up instead.
    /// Pure re-derivation: the data is the movie's and never changes.
    fn reattachPlaceData(parent: *MovieClipT, obj: *display.display_object.DisplayObject) void {
        const frames = parent.frames;
        for (frames) |frame| {
            for (frame.controls) |c| {
                const po = switch (c) {
                    .place => |p| p,
                    else => continue,
                };
                if (po.depth != obj.depth) continue;
                const cid = switch (po.action) {
                    .place, .replace => |placed| placed,
                    .modify => continue,
                };
                if (cid != obj.character_id) continue;
                if (po.clip_actions.len != 0) obj.clip_actions = po.clip_actions;
                return;
            }
        }
    }

    fn readObjectBody(self: *Player, obj: ?*display.display_object.DisplayObject, r: *savestate.Reader) !void {
        const present = try r.boolv();
        if (!present) return;
        if (obj) |o| {
            try savestate.readScalars(display.display_object.DisplayObject, o, r, &DO_SKIP);
            o.name = try self.readName(r);
        } else {
            // No object to write into — the record still has to be
            // consumed or every offset after it is wrong.
            var scratch: display.display_object.DisplayObject = undefined;
            try savestate.readScalars(display.display_object.DisplayObject, &scratch, r, &DO_SKIP);
            _ = try self.readName(r);
        }
    }

    fn readName(self: *Player, r: *savestate.Reader) !?[]const u16 {
        const n = try r.u32v();
        if (n == 0xFFFF_FFFF) return null;
        // The GPA, not the movie arena: `DisplayObject.deinit` frees a
        // name with the general-purpose allocator, and an arena slice
        // handed to it is an invalid free at teardown.
        const out = try self.gpa.alloc(u16, n);
        for (out) |*c| c.* = try r.u16v();
        return out;
    }

    /// Depth order is what the renderer walks, so a rebuilt list has to
    /// keep it — `finishInstantiate` would, but it also names, constructs
    /// and runs frames, none of which a restore may do.
    fn insertByDepth(
        mc: *MovieClipT,
        obj: *display.display_object.DisplayObject,
        ctx: *display.movie_clip.Context,
    ) !void {
        var at: usize = mc.children.items.len;
        for (mc.children.items, 0..) |child, i| {
            if (child.depth > obj.depth) {
                at = i;
                break;
            }
        }
        try mc.children.insert(ctx.gpa, at, obj);
    }

    /// Apply a state to a player that was freshly built from the same
    /// movie. Anything the state does not carry is whatever a fresh load
    /// produced, which is the point of the re-derivation rule.
    pub fn loadState(self: *Player, data: []const u8) !void {
        const h = try statefmt.parse(data, savestate.envelope());
        var sr: statefmt.SectionReader = .{ .buf = statefmt.payload(data, h) };
        // `STRS` is written before `HEAP` precisely so this is in hand by
        // the time the heap needs it.
        var pending_strings: []const []const u16 = &.{};
        // Rebuilding the tree instantiates objects, and instantiating
        // names them — which moves Flash's global `instanceN` counter.
        // The saved value is the true one; the restore's own bookkeeping
        // must not show up in the next save (four games' re-save differed
        // by exactly one here).
        var saved_instance: ?u32 = null;
        while (try sr.next()) |s| {
            var r: savestate.Reader = .{ .buf = s.payload };
            // A section this build does not know is SKIPPED, not
            // coerced: `@enumFromInt` on an unknown magic is undefined.
            const which = savestate.tagOf(s.magic) orelse continue;
            errdefer if (gcLog()) std.debug.print("[load] section {s} failed at +{d} of {d}\n", .{ @tagName(which), r.pos, s.payload.len });
            switch (which) {
                .plyr => {
                    try self.readPlayerScalars(&r);
                    saved_instance = self.instance_counter;
                },
                .vmsc => try savestate.readScalars(Vm, self.vm, &r, &VM_SKIP),
                .timr => try savestate.readTimers(&r, self.vm, .{
                    .strings = pending_strings,
                    .disp = self.disp_by_id.items,
                    .movies = &.{},
                }),
                .audi => try self.readAudio(&r),
                .movs => try self.readMovies(&r),
                .disp => try self.readDisplayTree(&r),
                .strs => {
                    pending_strings = try savestate.readStrings(&r, self.movie.allocator());
                    // Adopt the numbering, so a re-save reproduces it.
                    try self.state_pool.seed(pending_strings);
                },
                .pool => {
                    const ctx: savestate.LoadCtx = .{
                        .strings = pending_strings,
                        .disp = self.disp_by_id.items,
                        .movies = &.{},
                    };
                    try savestate.readPools(&r, self.vm, ctx);
                    try savestate.readClasses(&r, self.vm, ctx);
                },
                .heap => {
                    const ctx: savestate.LoadCtx = .{
                        .strings = pending_strings,
                        .disp = self.disp_by_id.items,
                        .movies = self.movieBuffers(),
                    };
                    try savestate.readHeap(&r, self.vm, ctx);
                },
                .natv => try self.readNatives(&r),
            }
        }

        // Now that the heap is in, every restored field can look up the
        // variable it mirrors — the same path `createTextField` takes.
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        for (self.pending_bitmaps.items) |p| {
            if (p.owner == 0 or p.owner > self.vm.objects.slots.items.len) continue;
            const slot = &self.vm.objects.slots.items[p.owner - 1];
            if (slot.native != .bitmap_data) continue;
            if (p.obj.kind != .attached_bitmap) continue;
            p.obj.kind.attached_bitmap.data = @ptrCast(@alignCast(slot.native.bitmap_data));
        }
        self.pending_bitmaps.clearRetainingCapacity();

        for (self.pending_binds.items) |obj| {
            // `set_initial = false`: the field and the variable were BOTH
            // saved, and they agreed. Re-running the creation path would
            // let the variable overwrite the text (IQ test's field lost a
            // character that way) — this only re-links them.
            const bound = avm1.text_binding.bind(self.vm, obj, false) catch false;
            if (!bound) {
                self.vm.unbound_text_fields.append(self.vm.arena(), obj) catch {};
            }
        }
        self.pending_binds.clearRetainingCapacity();
        if (saved_instance) |n| self.instance_counter = n;
    }


    // --- sounds ---------------------------------------------------------
    //
    // A library sound decodes on FIRST PLAY and stays decoded: `games/`
    // carries up to 245 of them in one movie and most are never reached,
    // so decoding at load would be paying for silence.

    /// The mixer handle for a character id, decoding it if this is the
    /// first time anyone asked. Null when the format is one we do not
    /// decode — Nellymoser and Speex, neither of which appears in any
    /// content this project has (docs/AUDIO.md).
    pub fn soundHandle(self: *Player, id: u16) ?u32 {
        if (self.mixer.has(id)) return id;
        if (self.sound_decoded.get(id)) |_| return null; // tried, failed
        const ch = self.movie.lib.get(id) orelse return null;
        const snd = switch (ch) {
            .sound => |s| s,
            else => return null,
        };
        self.sound_decoded.put(self.gpa, id, true) catch {};
        const pcm = decodeSound(self.gpa, snd) orelse return null;
        self.mixer.register(id, pcm) catch {
            self.gpa.free(pcm.samples);
            return null;
        };
        return id;
    }

    /// A timeline StartSound: the tag says which sound and how, and the
    /// SoundInfo's `stop` flag means it is a request to be QUIET rather
    /// than to play.
    pub fn startTimelineSound(self: *Player, tag: swf.sound_tags.StartSound) void {
        self.sounds_seen += 1;
        const handle = self.soundHandle(tag.id) orelse return;
        self.sounds_played += 1;
        if (tag.info.sync_stop) {
            self.mixer.stopHandle(handle);
            return;
        }
        if (tag.info.sync_no_multiple and self.mixer.playingHandle(handle)) return;
        // In and out points are in the sound's OWN samples, which is
        // what the mixer counts in too — no conversion.
        _ = self.mixer.play(handle, .{
            .in_point = tag.info.in_sample orelse 0,
            .out_point = tag.info.out_sample,
            // SWF counts TOTAL plays; the mixer counts repeats.
            .loops = if (tag.info.num_loops > 0) tag.info.num_loops - 1 else 0,
            .envelope = self.envelopeFor(tag.info.envelope),
            .owner = 0, // a timeline sound has no script to notify
        });
    }

    /// A SoundStreamBlock reached the playhead on `clip`. The stream is
    /// created on the first block and fed on every one after it.
    pub fn feedStreamBlock(self: *Player, clip: *MovieClipT, block: []const u8) void {
        const head = self.streamHeadFor(clip) orelse return;
        const key: usize = @intFromPtr(clip);
        const gop = self.streams.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) {
            // The STREAM format, not the playback one: the second is
            // advisory and players ignore it (SWF19).
            gop.value_ptr.* = .{
                .handle = audio.stream.handleFor(self.streams.count()),
                .format = head.stream,
            };
            self.mixer.register(gop.value_ptr.handle, .{
                .samples = &.{},
                .channels = if (head.stream.is_stereo) 2 else 1,
                .rate = head.stream.sample_rate,
                // The defining property of a stream: running out of
                // samples is "not fed yet", not "finished".
                .growing = true,
            }) catch return;
        }
        const st = gop.value_ptr;

        // A playhead that went BACKWARDS is a loop or a goto, and the
        // music has to go back with it rather than run on.
        const frame = clip.current_frame;
        if (st.started and frame <= st.last_frame) {
            self.mixer.stopHandle(st.handle);
            if (self.mixer.source(st.handle)) |src| {
                self.gpa.free(src.samples);
                src.samples = &.{};
            }
            st.started = false;
            if (st.mp3_state) |*m| {
                m.deinit(self.gpa);
                st.mp3_state = null;
            }
        }
        st.last_frame = frame;

        const pcm = st.decodeBlock(self.gpa, block) orelse return;
        defer self.gpa.free(pcm);
        self.mixer.appendTo(st.handle, pcm) catch return;
        if (!st.started) {
            st.voice = self.mixer.play(st.handle, .{ .owner = 0 });
            st.started = true;
        }
    }

    /// The stream head that governs `clip` — its own if it has one, the
    /// root movie's otherwise.
    fn streamHeadFor(self: *Player, clip: *MovieClipT) ?swf.sound_tags.StreamHead {
        if (clip.stream_head) |h| return h;
        return self.movie.stream_head;
    }

    /// SoundInfo's envelope in the mixer's terms. The points live in the
    /// movie's arena, so the converted copy does too — it outlives every
    /// voice that could be pointing at it.
    fn envelopeFor(self: *Player, points: []const swf.sound_tags.SoundEnvelopePoint) []const audio.mixer.EnvelopePoint {
        if (points.len == 0) return &.{};
        const out = self.movie.allocator().alloc(audio.mixer.EnvelopePoint, points.len) catch return &.{};
        for (out, points) |*o, p| {
            o.* = .{
                .at = p.sample,
                // 0..32768 in the tag, a plain gain here.
                .left = @as(f32, @floatFromInt(p.left)) / 32768.0,
                .right = @as(f32, @floatFromInt(p.right)) / 32768.0,
            };
        }
        return out;
    }

    /// How many output frames one movie frame is worth. Fractional, so
    /// the carry matters: 44100 / 12 is 3675 exactly, but 44100 / 16 is
    /// not, and dropping the remainder would drift a stream out of sync
    /// over a few minutes.
    fn audioFramesPerFrame(self: *Player) usize {
        self.audio_acc += @as(f64, @floatFromInt(audio.mixer.SAMPLE_RATE)) *
            self.frame_ms / 1000.0 / self.speed;
        const whole: usize = @intFromFloat(@floor(self.audio_acc));
        self.audio_acc -= @floatFromInt(whole);
        return whole;
    }

    /// Move the audio clock on by one movie frame — mixing if a sink is
    /// going to pull, and otherwise just moving. The two reach identical
    /// positions and completions; that is the whole point.
    fn tickAudio(self: *Player) void {
        const frames = self.audioFramesPerFrame();
        if (frames == 0) return;
        if (self.audio_on) {
            const at = self.audio_out.items.len;
            // A sink that stops pulling must not grow this without
            // bound; half a second is more cushion than any frontend
            // needs and less than anyone can hear.
            const cap = audio.mixer.SAMPLE_RATE;
            if (at > cap) {
                self.audio_out.clearRetainingCapacity();
                self.mixer.advance(frames);
                return;
            }
            self.audio_out.resize(self.gpa, at + frames * 2) catch {
                self.mixer.advance(frames);
                return;
            };
            self.mixer.render(self.audio_out.items[at..], frames);
        } else {
            self.mixer.advance(frames);
        }
        while (self.mixer.takeNotice()) |n| {
            if (n.owner != 0) self.pending_sound_done.append(self.gpa, n.owner) catch {};
        }
    }

    /// How many samples are mixed and waiting. A sink uses it to decide
    /// whether pulling again would fetch anything but silence.
    pub fn audioPending(self: *const Player) usize {
        return self.audio_out.items.len;
    }

    /// A frontend's window onto the mixed audio: interleaved stereo at
    /// 44100. Whatever has not been mixed yet comes back as silence
    /// rather than as a stall — the clock belongs to the frame loop, not
    /// to the sound card.
    pub fn renderAudio(self: *Player, out: []i16, frames: usize) void {
        self.audio_on = true;
        const want = frames * 2;
        const have = @min(want, self.audio_out.items.len);
        @memcpy(out[0..have], self.audio_out.items[0..have]);
        if (have < want) @memset(out[have..@min(want, out.len)], 0);
        if (have > 0) {
            const left = self.audio_out.items.len - have;
            std.mem.copyForwards(i16, self.audio_out.items[0..left], self.audio_out.items[have..]);
            self.audio_out.shrinkRetainingCapacity(left);
        }
    }

    /// One tick of every `NetStream`. They need a display context like
    /// any other script entry point, since a status handler can touch the
    /// stage.
    fn tickStreams(self: *Player, dt_ms: f64) !void {
        if (self.vm.net_streams.items.len == 0) return;
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        avm1.net_stream.tickAll(self.vm, dt_ms) catch |e| self.reportUncaught(e);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// Ruffle's `executor.run()`: everything asynchronous that came due
    /// during this tick lands now, after the frame and after the timers.
    /// Returns whether anything actually completed.
    ///
    /// A load queued BY a completion handler is deliberately left for the
    /// next tick — ruffle polls a snapshot of its future set, so a chain of
    /// loads advances one link per tick rather than running to exhaustion.
    fn finishTick(self: *Player) !bool {
        const sockets = self.socket_poll != null and self.socket_obj != 0;
        if (self.pending_loads.items.len == 0 and self.pending_dialogs.items.len == 0 and
            self.vm.pending_local_sends.items.len == 0 and
            self.vm.net_messages.items.len == 0 and !sockets)
        {
            return false;
        }
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        self.drainSocket() catch |e| self.reportUncaught(e);
        // A LocalConnection message is delivered from the executor too,
        // a tick after `send` — the receiver never runs inside the
        // sender's frame.
        avm1.local_connection.deliver(self.vm) catch |e| self.reportUncaught(e);
        // Flash Remoting flushes its queue from the executor too: every
        // call made this tick leaves in ONE packet.
        avm1.net_connection.flush(self.vm) catch |e| self.reportUncaught(e);
        try self.drainActions(&ctx);
        // Loads run to EXHAUSTION, like the dialogs below: ruffle's
        // executor keeps polling until its task list is empty, so a load
        // started from inside an `onLoad` handler still completes on this
        // tick. `sound_id3` chains eight of them and runs for ONE.
        var load_rounds: u32 = 0;
        while (self.pending_loads.items.len > 0 and load_rounds < 64) : (load_rounds += 1) {
            const batch = try self.pending_loads.toOwnedSlice(self.gpa);
            defer self.gpa.free(batch);
            for (batch) |req| {
                self.completeLoad(req) catch |e| self.reportUncaught(e);
                try self.drainActions(&ctx);
            }
        }
        // Dialogs run to EXHAUSTION, unlike loads: ruffle's executor keeps
        // polling until its task list is empty, so an `upload` started
        // from inside an `onSelect` handler still completes on this tick —
        // which the upload dirs need, since they only run one.
        var rounds: u32 = 0;
        while (self.pending_dialogs.items.len > 0 and rounds < 16) : (rounds += 1) {
            const dialogs = try self.pending_dialogs.toOwnedSlice(self.gpa);
            defer self.gpa.free(dialogs);
            for (dialogs) |req| {
                self.runFileDialog(req) catch |e| self.reportUncaught(e);
                try self.drainActions(&ctx);
            }
        }
        self.retireDead(&ctx);
        return true;
    }

    fn hostFileDialog(ctx: *anyopaque, req: avm1.runtime.FileDialogRequest) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        self.pending_dialogs.append(self.gpa, req) catch {};
    }

    /// The three FileReference sequences. Each one is exactly ruffle's,
    /// and the differences between them are the point: a DNS failure never
    /// reports `onOpen`, an HTTP failure does and then still reports
    /// `onProgress` after the error, and an upload's `onProgress` counts
    /// the bytes it SENT rather than any it received.
    fn runFileDialog(self: *Player, req: avm1.runtime.FileDialogRequest) !void {
        const fr = avm1.file_reference;
        const vm = self.vm;
        switch (req.what) {
            .browse => |filters| {
                const picked = if (self.open_dialog) |f| f(self.dialog_user, filters) else null;
                const files = picked orelse {
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onCancel"), &.{});
                    return;
                };
                if (files.len == 0) {
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onCancel"), &.{});
                    return;
                }
                try self.adoptFile(req.obj, files[0]);
                try fr.fire(vm, req.obj, avm1.strings.ascii("onSelect"), &.{});
            },
            .browse_multi => |filters| {
                const picked = if (self.open_multi_dialog) |f| f(self.dialog_user, filters) else null;
                const files = picked orelse {
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onCancel"), &.{});
                    return;
                };
                // `fileList` is a read-only array of fresh FileReferences.
                const list = try vm.newArray();
                for (files, 0..) |file, i| {
                    const child = try vm.objects.create();
                    // A FileReference, not another List: the entries answer
                    // `name`/`type`/`size`, which only that prototype has.
                    vm.objects.get(child).proto = .{ .object = vm.filereference_proto };
                    try self.adoptFile(child, file);
                    try vm.arraySet(list, @intCast(i), .{ .object = child });
                }
                try vm.setArrayLength(list, @intCast(files.len));
                try vm.objects.putWithAttrs(
                    req.obj,
                    avm1.strings.ascii("fileList"),
                    .{ .object = list },
                    .{ .dont_enum = true, .dont_delete = true, .read_only = true },
                    false,
                );
                try fr.fire(vm, req.obj, avm1.strings.ascii("onSelect"), &.{});
            },
            .download => |d| {
                const picked = if (self.save_dialog) |f| f(self.dialog_user, d.name) else null;
                const dest = picked orelse {
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onCancel"), &.{});
                    return;
                };
                // onSelect reports the DESTINATION, before a byte moves.
                try self.adoptFile(req.obj, dest);
                try fr.fire(vm, req.obj, avm1.strings.ascii("onSelect"), &.{});
                var status: FetchStatus = .dns_error;
                const body = if (self.load_file) |f| f(self.load_user, d.url, &status) else null;
                if (body) |bytes| {
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onOpen"), &.{});
                    // The file now holds what was downloaded, and both
                    // callbacks below must see that, not the empty stub.
                    try self.adoptFile(req.obj, .{
                        .name = dest.name,
                        .file_type = dest.file_type,
                        .contents = bytes,
                    });
                    const n: f64 = @floatFromInt(bytes.len);
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onProgress"), &.{
                        .{ .number = n },
                        .{ .number = n },
                    });
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onComplete"), &.{});
                    return;
                }
                switch (status) {
                    // A domain that does not resolve never opened.
                    .dns_error => {
                        try self.traceFmt("Error opening URL '{s}'", .{d.url});
                        try fr.fire(vm, req.obj, avm1.strings.ascii("onIOError"), &.{});
                    },
                    // A bad status code arrived over a live connection, so
                    // onOpen fires — and onProgress STILL fires after the
                    // error, which is Flash's, not a mistake.
                    .http_error, .ok => {
                        try fr.fire(vm, req.obj, avm1.strings.ascii("onOpen"), &.{});
                        try self.traceFmt("Error opening URL '{s}'", .{d.url});
                        try fr.fire(vm, req.obj, avm1.strings.ascii("onIOError"), &.{});
                        try fr.fire(vm, req.obj, avm1.strings.ascii("onProgress"), &.{
                            .{ .number = 0 },
                            .{ .number = 0 },
                        });
                    },
                }
            },
            .upload => |url| {
                const data = self.file_data.get(req.obj) orelse "";
                var status: FetchStatus = .dns_error;
                const body = if (self.load_file) |f| f(self.load_user, url, &status) else null;
                try fr.fire(vm, req.obj, avm1.strings.ascii("onOpen"), &.{});
                const n: f64 = @floatFromInt(data.len);
                if (body != null) {
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onProgress"), &.{
                        .{ .number = n },
                        .{ .number = n },
                    });
                    try fr.fire(vm, req.obj, avm1.strings.ascii("onComplete"), &.{});
                    return;
                }
                switch (status) {
                    .dns_error => try fr.fire(vm, req.obj, avm1.strings.ascii("onIOError"), &.{}),
                    .http_error, .ok => {
                        try fr.fire(vm, req.obj, avm1.strings.ascii("onProgress"), &.{
                            .{ .number = n },
                            .{ .number = n },
                        });
                        try fr.fire(vm, req.obj, avm1.strings.ascii("onHTTPError"), &.{});
                    },
                }
            },
        }
    }

    /// A relative load URL, as `_url` reports it: resolved against the
    /// movie's own, because that is what Flash stores on the clip.
    fn absoluteUrl(self: *Player, url: []const u8) !avm1.strings.AvmString {
        const a = self.vm.arena();
        if (std.mem.indexOf(u8, url, "://") != null or url.len == 0) {
            return avm1.strings.fromSwf(a, url, 8);
        }
        const base = try avm1.strings.toUtf8(a, self.vm.movie_url);
        const cut = std.mem.lastIndexOfScalar(u8, base, '/') orelse
            return avm1.strings.fromSwf(a, url, 8);
        const joined = try std.mem.concat(a, u8, &.{ base[0 .. cut + 1], url });
        return avm1.strings.fromSwf(a, joined, 8);
    }

    fn adoptFile(self: *Player, obj: u32, file: DialogFile) !void {
        try avm1.file_reference.applySelection(
            self.vm,
            obj,
            file.name,
            file.file_type,
            file.contents.len,
        );
        try self.file_data.put(self.gpa, obj, file.contents);
    }

    /// Ruffle's `update_sockets`, minus the handle table: deliver whatever
    /// the frontend has for us, framing the byte stream on NUL. A message
    /// split across two deliveries is one message; two messages in one
    /// delivery are two.
    fn drainSocket(self: *Player) !void {
        const poll = self.socket_poll orelse return;
        while (poll(self.socket_user)) |ev| {
            const target = self.socket_obj;
            if (target == 0) continue;
            switch (ev) {
                .connect => |ok| try avm1.loader.callMethod(
                    self.vm,
                    target,
                    avm1.strings.ascii("onConnect"),
                    &.{.{ .boolean = ok }},
                ),
                .data => |bytes| {
                    try self.socket_buf.appendSlice(self.gpa, bytes);
                    while (std.mem.indexOfScalar(u8, self.socket_buf.items, 0)) |nul| {
                        const msg = try self.vm.arena().dupe(u8, self.socket_buf.items[0..nul]);
                        self.socket_buf.replaceRange(self.gpa, 0, nul + 1, &.{}) catch {};
                        const s = try avm1.strings.fromSwf(self.vm.arena(), msg, 8);
                        try avm1.loader.callMethod(
                            self.vm,
                            target,
                            avm1.strings.ascii("onData"),
                            &.{.{ .string = s }},
                        );
                    }
                },
                .close => {
                    self.socket_buf.clearRetainingCapacity();
                    self.socket_obj = 0;
                    try avm1.loader.callMethod(
                        self.vm,
                        target,
                        avm1.strings.ascii("onClose"),
                        &.{},
                    );
                },
            }
        }
    }

    fn hostSocketConnect(ctx: *anyopaque, sock: u32, host: []const u8, port: u16) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        if (self.log_fetch) {
            self.traceFmt("Navigator::connect_socket", .{}) catch {};
            self.traceFmt("    Host: {s}; Port: {d}", .{ host, port }) catch {};
        }
        self.socket_obj = sock;
        self.socket_buf.clearRetainingCapacity();
        if (self.socket_connect) |f| f(self.socket_user, host, port);
    }

    fn hostSocketSend(ctx: *anyopaque, sock: u32, data: []const u8) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        // A send before the socket is open is silently dropped — the
        // corpus opens with exactly that and expects no complaint.
        if (self.socket_obj != sock) return;
        if (self.socket_send) |f| f(self.socket_user, data);
    }

    fn hostSocketClose(ctx: *anyopaque, sock: u32) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        if (self.socket_obj != sock) return;
        self.socket_obj = 0;
        self.socket_buf.clearRetainingCapacity();
        if (self.socket_close_fn) |f| f(self.socket_user);
    }

    /// Ask the host for the bytes and hand them to whichever completion
    /// protocol the request named. A host with no reader at all fails
    /// every load, which is the honest answer for a frontend that cannot
    /// read files.
    fn completeLoad(self: *Player, req: avm1.runtime.FetchRequest) !void {
        if (self.log_fetch) try self.traceFetch(req);
        var status: FetchStatus = .dns_error;
        const body: ?[]const u8 = if (self.load_file) |f| f(self.load_user, req.url, &status) else null;
        switch (req.target) {
            .form => |h| try avm1.loader.completeForm(self.vm, h, body),
            .load_vars => |h| try avm1.loader.completeLoadVars(self.vm, h, body),
            .sound => |h| {
                self.loading_sound_url = req.url;
                defer self.loading_sound_url = null;
                try avm1.sound.completeLoad(self.vm, h, body);
            },
            .movie => |m| try self.completeMovieLoad(m, req.url, body),
            .net_connection => |h| try avm1.net_connection.completeCall(self.vm, h, body),
            .net_stream => |h| try avm1.net_stream.completeLoad(self.vm, h, body),
            .stylesheet => |h| try avm1.style_sheet.completeLoad(self.vm, h, body),
        }
    }

    /// A SWF came back (or did not). Parsing it can fail on garbage, on a
    /// non-SWF payload, or on a missing file; all three land in the same
    /// place, because `loadMovie` has no error channel of its own — only a
    /// MovieClipLoader's `onLoadError` hears about it.
    fn completeMovieLoad(
        self: *Player,
        target: avm1.runtime.FetchRequest.Movie,
        url: []const u8,
        body: ?[]const u8,
    ) !void {
        const ctx = self.cur_ctx orelse return;
        const mc = avm1.stage_object.clipOfHandle(self.vm, target.clip) orelse return;
        // A fetch that succeeded but did not bring a SWF is still a
        // SUCCESS: ruffle sniffs the content type and substitutes an
        // "error movie" — an empty timeline — for anything it cannot
        // recognise. Only a fetch FAILURE reaches `onLoadError`
        // (corpus mcl_loadclip loads invalid.txt and hears the full
        // success sequence).
        const bytes = body orelse {
            try mc.unloadContents(ctx);
            self.vm.objects.clearDeletable(target.clip);
            mc.replaceWithMovie(null);
            // A FAILED load still sets `_url` to what was attempted.
            mc.loaded = .{
                .url = try self.absoluteUrl(url),
                .bytes = 0,
                .version = 0,
                .failed = true,
            };
            try avm1.loader.movieLoadEvents(self.vm, target, null);
            return;
        };
        const loaded: ?*swf.movie.Movie = blk: {
            if (!isSwf(bytes)) break :blk null;
            const m = try self.gpa.create(swf.movie.Movie);
            m.* = swf.movie.load(self.gpa, bytes) catch {
                self.gpa.destroy(m);
                break :blk null;
            };
            try self.loaded_movies.append(self.gpa, m);
            try self.movie_urls.append(self.gpa, try self.gpa.dupe(u8, url));
            break :blk m;
        };
        // Ruffle unloads and wipes the target BEFORE the fetch resolves, so
        // a failed load still leaves the clip empty and its variables gone.
        try mc.unloadContents(ctx);
        self.vm.objects.clearDeletable(target.clip);
        mc.replaceWithMovie(loaded);
        // An image becomes the clip's only child, at depth 1. Unrecognised
        // bytes leave the clip empty but still count as loaded.
        const is_image = loaded == null and try self.attachLoadedImage(ctx, mc, bytes);
        const img_len: usize = if (is_image) bytes.len else 0;
        // An image gives the clip a frame — and that frame is CURRENT,
        // because Flash wraps the bitmap in a one-frame movie and plays
        // it. Only an empty or unreadable result leaves the clip with
        // no frames at all.
        if (is_image) {
            mc.emptied_by_load = false;
            mc.current_frame = 1;
        }
        // What the clip now reports for `_url`, `getBytesTotal` and
        // `getSWFVersion`. An image has no SWF version at all, and 0 is
        // what script reads back as -1.
        mc.loaded = .{
            .url = try self.absoluteUrl(url),
            .bytes = if (loaded) |m| m.compressed_len else @intCast(bytes.len),
            .version = if (loaded) |m| m.swf_version else 0,
            // Bytes that are neither a SWF nor an image leave the clip in
            // the ERROR state, even though the LOAD itself succeeded and
            // reports success events (corpus movieclip_state_values
            // loads a text file).
            .failed = loaded == null and !is_image,
        };
        // The clip's script object now belongs to the LOADED movie's
        // environment: a SWF8 movie in `_level2` gets the SWF7+ side's
        // `MovieClip.prototype`, whatever version loaded it (corpus
        // loadmovienum_cross_version_prototype).
        if (loaded) |m| {
            const env = if (m.swf_version >= 7) &self.vm.env_hi else &self.vm.env_lo;
            const active = self.vm.env_hi_active == (m.swf_version >= 7);
            const proto = if (active) self.vm.movieclip_proto else env.movieclip_proto;
            if (proto != 0) {
                self.vm.objects.get(target.clip).proto = .{ .object = proto };
            }
        }
        // Loading into _level0 REPLACES the root movie, and the stage
        // takes the new movie's size — `Stage.width` reports the
        // incoming header, not the one the player started with
        // (corpus loadmovie_replace_root).
        if (loaded) |m| {
            if (mc.level_id == 0 and mc.parent == null) {
                const w = m.header.widthPx();
                const h = m.header.heightPx();
                self.vm.stage_width = w;
                self.vm.stage_height = h;
                self.vm.movie_width = @floatFromInt(w);
                self.vm.movie_height = @floatFromInt(h);
                _ = avm1.stage_object.recomputeView(self.vm);
            }
        }
        // A loaded movie's `#initclip` blocks run at PRELOAD, before its
        // own frame 1 — which is what lets it `Object.registerClass` the
        // symbols its own timeline is about to place.
        if (loaded) |m| try self.runMovieInitActions(ctx, mc, m);
        // FLASHVARS: the loaded URL's query string lands on the clip as
        // plain, enumerable variables — visible to the incoming movie's
        // own frame 1, and to nobody else (corpus loadmovie_flashvars
        // checks `_root` did NOT get them).
        if (std.mem.indexOfScalar(u8, url, '?')) |q| {
            try avm1.loader.decodeInto(self.vm, target.clip, url[q + 1 ..]);
        }
        try avm1.loader.movieLoadEvents(
            self.vm,
            target,
            if (loaded) |m| m.compressed_len else img_len,
        );
        // `onLoadInit` waits for the loaded movie's OWN first frame,
        // a whole tick behind the rest of the sequence.
        try self.pending_init.append(self.gpa, target);
    }

    /// SWF containers: uncompressed, zlib, or LZMA.
    fn isSwf(b: []const u8) bool {
        return b.len >= 3 and b[1] == 'W' and b[2] == 'S' and
            (b[0] == 'F' or b[0] == 'C' or b[0] == 'Z');
    }

    /// `loadMovie` of a GIF/JPEG/PNG: Flash wraps the image in a one-frame
    /// movie whose only content is the bitmap, placed at depth 1. Returns
    /// false for bytes that are not an image at all.
    fn attachLoadedImage(
        self: *Player,
        ctx: *display.movie_clip.Context,
        mc: *MovieClipT,
        bytes: []const u8,
    ) !bool {
        var img = (bitmap.decode.decodeStandalone(self.gpa, bytes) catch return false) orelse return false;
        defer img.deinit(self.gpa);
        const bd = try self.gpa.create(bitmap.data.BitmapData);
        errdefer self.gpa.destroy(bd);
        bd.* = try bitmap.data.BitmapData.init(self.gpa, img.width, img.height, true, 0);
        // A file's alpha is STRAIGHT; the buffer stores it premultiplied
        // — TRUNCATING, because this one is a texture on its way to the
        // screen rather than a script's own pixel buffer.
        for (bd.data, 0..) |*px, i| {
            const s = img.rgba[i * 4 ..][0..4];
            px.* = bitmap.pixels.Color.fromArgb(
                (@as(u32, s[3]) << 24) | (@as(u32, s[0]) << 16) | (@as(u32, s[1]) << 8) | s[2],
            ).toPremultipliedTruncating();
        }
        const obj = try mc.instantiateAttachedBitmap(ctx, 1, bd, false);
        try mc.finishInstantiate(ctx, obj, false);
        return true;
    }

    /// Fire the `onLoadInit`s owed from the previous tick. Called after the
    /// action drain, so the loaded movie's frame-1 trace lands first.
    /// The `onSoundComplete`s owed from the previous tick.
    fn fireSoundCompletes(self: *Player) !void {
        if (self.pending_sound_done.items.len == 0) return;
        const batch = try self.pending_sound_done.toOwnedSlice(self.gpa);
        defer self.gpa.free(batch);
        for (batch) |h| avm1.sound.finishPlay(self.vm, h) catch |e| self.reportUncaught(e);
    }

    fn fireLoadInits(self: *Player) !void {
        if (self.pending_init.items.len == 0) return;
        const batch = try self.pending_init.toOwnedSlice(self.gpa);
        defer self.gpa.free(batch);
        // REVERSE order: ruffle collects the loader handles and reverses
        // them before firing (loader.rs `movie_clip_on_load`), so the last
        // load started is the first to report itself initialised.
        var i = batch.len;
        while (i > 0) {
            i -= 1;
            avm1.loader.movieLoadInit(self.vm, batch[i]) catch |e| self.reportUncaught(e);
        }
    }

    fn hostSoundComplete(ctx: *anyopaque, sound: u32) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        self.pending_sound_done.append(self.gpa, sound) catch {};
    }

    /// `Sound.start()`. The owner is the script object, so a completion
    /// can find its way back to the right `onSoundComplete` and a later
    /// `stop()` knows what to silence.
    fn hostSoundPlay(ctx: *anyopaque, req: avm1.runtime.SoundPlay) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const handle: u32 = if (req.handle <= std.math.maxInt(u16))
            (self.soundHandle(@intCast(req.handle)) orelse return)
        else
            req.handle;
        const rate = if (self.mixer.source(handle)) |s| s.rate else audio.mixer.SAMPLE_RATE;
        const in_point: u32 = @intFromFloat(@max(0, req.offset_secs) * @as(f64, @floatFromInt(rate)));
        _ = self.mixer.play(handle, .{
            .in_point = in_point,
            .loops = req.loops,
            .transform = audio.mixer.Transform.fromVolumePan(
                @floatCast(req.volume / 100.0),
                @floatCast(req.pan / 100.0),
            ),
            .owner = req.owner,
        });
    }

    fn hostSoundStop(ctx: *anyopaque, owner: u32) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        self.mixer.stopOwner(owner);
    }

    fn hostSoundPosition(ctx: *anyopaque, owner: u32) f64 {
        const self: *Player = @ptrCast(@alignCast(ctx));
        return self.mixer.positionMsOfOwner(owner) orelse -1;
    }

    fn hostSoundTransform(ctx: *anyopaque, owner: u32, volume: f64, pan: f64) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        self.mixer.setOwnerTransform(owner, audio.mixer.Transform.fromVolumePan(
            @floatCast(volume / 100.0),
            @floatCast(pan / 100.0),
        ));
    }

    /// Bytes from outside the movie — a `loadSound` MP3. Registered under
    /// a handle above the character-id space so it cannot be mistaken for
    /// a library sound.
    fn hostSoundRegister(ctx: *anyopaque, data: []const u8) u32 {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const pcm = codecs_mp3.decodeAll(self.gpa, data) orelse return 0;
        self.external_sound_next += 1;
        const handle = audio.stream.HANDLE_BASE * 2 + self.external_sound_next;
        self.mixer.register(handle, .{
            .samples = pcm.samples,
            .channels = pcm.channels,
            .rate = pcm.rate,
        }) catch {
            self.gpa.free(pcm.samples);
            return 0;
        };
        if (self.loading_sound_url) |url| {
            const copy = self.gpa.dupe(u8, url) catch return handle;
            self.external_sounds.put(self.gpa, handle, copy) catch self.gpa.free(copy);
        }
        return handle;
    }

    /// FLV audio: one MP3 packet from a NetStream, decoded incrementally
    /// and appended to a growing source that is already playing.
    fn hostStreamAudio(ctx: *anyopaque, handle_in: u32, frame: []const u8) u32 {
        const self: *Player = @ptrCast(@alignCast(ctx));
        var handle = handle_in;
        if (handle == 0) {
            self.external_sound_next += 1;
            handle = audio.stream.HANDLE_BASE * 3 + self.external_sound_next;
            self.mixer.register(handle, .{
                .samples = &.{},
                .channels = 2,
                .rate = audio.mixer.SAMPLE_RATE,
                .growing = true,
            }) catch return 0;
            const st = self.flv_audio.getOrPut(self.gpa, handle) catch return 0;
            st.value_ptr.* = codecs_mp3.Streamer.init(self.gpa) orelse return 0;
            _ = self.mixer.play(handle, .{ .owner = 0 });
        }
        const st = self.flv_audio.getPtr(handle) orelse return handle;
        var out: std.ArrayList(i16) = .empty;
        defer out.deinit(self.gpa);
        st.feed(self.gpa, frame, &out) catch return handle;
        if (out.items.len == 0) return handle;
        // The first packet also tells us the real rate and channel count.
        if (self.mixer.source(handle)) |src| {
            src.rate = st.rate;
            src.channels = st.channels;
        }
        self.mixer.appendTo(handle, out.items) catch {};
        return handle;
    }

    /// `MovieClipLoader.getProgress`: how big the clip's movie is.
    fn hostMovieBytes(ctx: *anyopaque, clip: u32) u32 {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc = avm1.stage_object.clipOfHandle(self.vm, clip) orelse return 0;
        if (mc.movie) |m| return m.compressed_len;
        // A clip with no movie of its own reports the root movie's size,
        // which is what `_level0` and an untouched timeline both are.
        return self.movie.compressed_len;
    }

    /// `_levelN`, made on demand. A level is a parentless clip that ticks
    /// and renders after the root; once created it is never destroyed,
    /// because `unloadMovieNum` leaves the level itself in place and only
    /// empties it (corpus unloadmovienum still resolves `_level1`).
    pub fn getOrCreateLevel(self: *Player, id: i32) !?*MovieClipT {
        if (id == 0) return &self.root;
        if (id < 0) return null;
        for (self.levels.items) |lv| {
            if (lv.kind.clip.level_id == id) return lv.kind.clip;
        }
        const mc = try self.gpa.create(MovieClipT);
        errdefer self.gpa.destroy(mc);
        mc.* = MovieClipT.init(&.{});
        mc.level_id = id;
        const obj = try self.gpa.create(display.display_object.DisplayObject);
        obj.* = .{
            .character_id = 0,
            .depth = id,
            .kind = .{ .clip = mc },
            .owns_kind = true,
        };
        mc.placement = obj;
        // Highest level first for RENDERING; the execution order comes
        // from the shared list, where a level prepended later runs first.
        try self.levels.insert(self.gpa, 0, obj);
        try self.exec_list.insert(self.gpa, 0, mc);
        const handle = try self.clipObject(mc);
        try self.vm.levels.append(self.vm.arena(), .{ .id = id, .obj = handle });
        return mc;
    }

    /// `_levelN` for the VM, made on demand. Returns 0 for a level that
    /// cannot exist.
    fn hostLevel(ctx: *anyopaque, id: i32) u32 {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc = (self.getOrCreateLevel(id) catch return 0) orelse return 0;
        return self.clipObject(mc) catch 0;
    }

    /// `unloadMovie` / a `loadMovie` with an empty URL. Immediate, unlike
    /// a load: the timeline is gone before the calling script continues.
    /// `unloadMovie` takes effect on the NEXT frame: the script that
    /// called it still sees the old state, and only the following tick
    /// reports the unloaded one (corpus movieclip_state_values, whose
    /// header spells the rule out).
    fn hostUnloadMovie(ctx: *anyopaque, clip: u32) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc = avm1.stage_object.clipOfHandle(self.vm, clip) orelse return;
        self.pending_unloads.append(self.gpa, mc) catch return;
    }

    fn runPendingUnloads(self: *Player, c: *display.movie_clip.Context) void {
        const batch = self.pending_unloads.toOwnedSlice(self.gpa) catch return;
        defer self.gpa.free(batch);
        for (batch) |mc| self.unloadNow(c, mc);
    }

    fn unloadNow(self: *Player, c: *display.movie_clip.Context, mc: *MovieClipT) void {
        _ = self;
        mc.unloadContents(c) catch return;
        mc.replaceWithMovie(null);
        // The load is FORGOTTEN, not zeroed: an unloaded clip answers
        // `_url` and `getSWFVersion` from the movie it sits in again.
        mc.loaded = null;

    }

    /// `log_fetch`: ruffle's test navigator logs each request through the
    /// SAME sink as `trace`, so the lines interleave with the movie's own
    /// output and the corpus pins the interleaving.
    fn traceFetch(self: *Player, req: avm1.runtime.FetchRequest) !void {
        try self.traceFmt("Navigator::fetch:", .{});
        try self.traceFmt("  URL: {s}", .{req.url});
        try self.traceFmt("  Method: {s}", .{if (req.method == .none) "GET" else req.method.name()});
        if (req.method == .post) {
            const mime = if (req.mime.len == 0) "application/x-www-form-urlencoded" else req.mime;
            try self.traceFmt("  Mime-Type: {s}", .{mime});
            if (req.mime.len == 0) {
                try self.traceFmt("  Body: {s}", .{req.body});
            } else {
                // Rust's `{:02X?}` over a byte slice, which is what
                // ruffle's test navigator logs for a binary body.
                var line: std.ArrayList(u8) = .empty;
                const a = self.vm.arena();
                try line.append(a, '[');
                for (req.body, 0..) |b, i| {
                    if (i != 0) try line.appendSlice(a, ", ");
                    var hb: [2]u8 = undefined;
                    _ = std.fmt.bufPrint(&hb, "{X:0>2}", .{b}) catch unreachable;
                    try line.appendSlice(a, &hb);
                }
                try line.append(a, ']');
                try self.traceFmt("  Body: {s}", .{line.items});
            }
        }
    }

    fn traceFmt(self: *Player, comptime fmt: []const u8, args: anytype) !void {
        const a = self.vm.arena();
        const line = try std.fmt.allocPrint(a, fmt, args);
        try self.vm.traceLine(try avm1.strings.fromSwf(a, line, 8));
    }

    /// `getURL` and `LoadVars.send`. There is no browser, so the request
    /// is only ever logged.
    fn hostNavigate(ctx: *anyopaque, req: avm1.runtime.NavigateRequest) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        if (!self.log_fetch) return;
        self.traceFmt("Navigator::navigate_to_url:", .{}) catch return;
        self.traceFmt("  URL: {s}", .{req.url}) catch return;
        self.traceFmt("  Target: {s}", .{req.target}) catch return;
        if (req.method == .none) return;
        self.traceFmt("  Method: {s}", .{req.method.name()}) catch return;
        for (req.vars) |kv| {
            self.traceFmt("  Param: {s}={s}", .{ kv.key, kv.value }) catch return;
        }
    }

    /// The only place a command ACTS. `core/` recognised it and answered
    /// the script already; what is left is the part that belongs to a
    /// player — the quality switch, the soft-key strip, and the two flags
    /// a frontend may read. Everything else is recorded and no more.
    fn hostFsCommand(ctx: *anyopaque, call: avm1.fscommand.Call) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const eq = std.ascii.eqlIgnoreCase;
        const arg0 = if (call.args.len > 0) call.args[0] else "";
        if (eq(call.name, "SetQuality")) {
            // Only LOW turns antialiasing off; medium, high and best all
            // get the soft rasteriser, since that is the only other
            // sampling this renderer has.
            self.antialias = !eq(arg0, "low");
        } else if (eq(call.name, "SetSoftKeys")) {
            self.setSoftKey(0, arg0);
            self.setSoftKey(1, if (call.args.len > 1) call.args[1] else "");
        } else if (eq(call.name, "ResetSoftKeys")) {
            self.soft_key_len = .{ 0, 0 };
        } else if (eq(call.name, "FullScreen")) {
            self.full_screen = !eq(arg0, "false") and !eq(arg0, "0");
        } else if (eq(call.name, "Quit")) {
            self.quit_requested = true;
        }
        if (self.fscommand_log) |f| f(self.fscommand_user, call);
    }

    fn setSoftKey(self: *Player, which: usize, label: []const u8) void {
        const n = @min(label.len, MAX_SOFT_KEY);
        @memcpy(self.soft_key_buf[which][0..n], label[0..n]);
        self.soft_key_len[which] = n;
    }

    /// The label the strip shows on that side, "" when unset.
    pub fn softKey(self: *const Player, which: usize) []const u8 {
        return self.soft_key_buf[which][0..self.soft_key_len[which]];
    }

    fn hostFetch(ctx: *anyopaque, req: avm1.runtime.FetchRequest) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        self.pending_loads.append(self.gpa, req) catch {};
    }

    /// One tick's display Context. Every entry point builds the same one.
    fn makeContext(self: *Player) display.movie_clip.Context {
        return .{
            .gpa = self.gpa,
            .movie = &self.movie,
            .root_movie = &self.movie,
            .instance_counter = &self.instance_counter,
            .class_lookup = hostRegisteredClass,
            .class_lookup_user = @ptrCast(self),
            .run_inline = hostRunInline,
            .has_button_handler = hostHasButtonHandler,
            .has_property = hostHasProperty,
            .mouse_enabled = hostMouseEnabled,
            .lost_display_object = hostLostDisplayObject,
            .bool_property = hostBoolProperty,
            .key_focus = hostKeyFocus,
            .object_instantiated = hostObjectInstantiated,
            .clip_created = hostClipCreated,
            .warn_fn = hostWarn,
            .start_sound = hostStartSound,
            .stream_block = hostStreamBlock,
            .audio_user = @ptrCast(self),
        };
    }

    fn hostStartSound(user: *anyopaque, tag: swf.sound_tags.StartSound) void {
        const self: *Player = @ptrCast(@alignCast(user));
        self.startTimelineSound(tag);
    }

    fn hostStreamBlock(user: *anyopaque, clip: *MovieClipT, block: []const u8) void {
        const self: *Player = @ptrCast(@alignCast(user));
        self.feedStreamBlock(clip, block);
    }

    fn hostClipCreated(user: *anyopaque, clip: *MovieClipT) void {
        const self: *Player = @ptrCast(@alignCast(user));
        self.exec_list.insert(self.gpa, 0, clip) catch {};
    }

    /// A player warning, on the same sink as `trace` and with Flash's own
    /// prefix (ruffle's TestLogBackend, whose `log_warnings` defaults on).
    fn hostWarn(user: *anyopaque, msg: []const u8) void {
        const self: *Player = @ptrCast(@alignCast(user));
        self.traceFmt("Warning: {s}", .{msg}) catch {};
    }

    /// Removed clips leave the execution list the first time the walk
    /// notices them, which is where ruffle unlinks them too.
    fn dropDeadFromExecList(self: *Player) void {
        var i: usize = 0;
        while (i < self.exec_list.items.len) {
            if (self.exec_list.items[i].removed) {
                _ = self.exec_list.orderedRemove(i);
            } else i += 1;
        }
    }

    fn runOneFrame(self: *Player) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        // Everything queued for removal LAST tick goes now, before any
        // script runs — ruffle's `Avm1::remove_pending` at the head of
        // `run_frame`.
        self.runPendingUnloads(&ctx);
        try self.root.removePending(&ctx);
        for (self.levels.items) |lv| {
            if (lv.kind == .clip) try lv.kind.clip.removePending(&ctx);
        }
        self.dropDeadFromExecList();
        try self.runInitActions(&ctx);
        // ONE list, newest first — no tree walk. A clip prepended during
        // this pass is not visited by it, which is ruffle's rule too
        // ("adding while iterating is safe, as this does not modify any
        // active nodes"): a clip placed this tick already ran its first
        // frame inside `finishInstantiate`.
        const snapshot = try self.gpa.dupe(*MovieClipT, self.exec_list.items);
        defer self.gpa.free(snapshot);
        for (snapshot) |mc| {
            if (mc.removed) continue;
            if (mc.ran_this_tick) continue;
            try mc.runFrame(&ctx);
        }
        self.dropDeadFromExecList();
        for (self.levels.items) |lv| {
            if (lv.kind == .clip) try lv.kind.clip.applyPendingGoto(&ctx);
        }
        try self.root.applyPendingGoto(&ctx);
        try self.drainActions(&ctx);
        try self.fireLoadInits();
        // The audio clock moves HERE, once per frame, so a sound that
        // ends during this frame fires its handler in this frame —
        // ruffle ticks its mixer inside `run_frame` for the same reason.
        self.tickAudio();
        try self.fireSoundCompletes();
        try self.drainActions(&ctx);
        try self.updateTimers(&ctx);
        // "Looks like the stack is cleared between frames" (ruffle
        // avm1/runtime.rs). AVM1's operand stack and its four global
        // registers are shared by every DoAction in the movie, so a block
        // that leaves a value behind hands it to the NEXT block to run —
        // across clips, even across levels. The one boundary that wipes it
        // is the frame (corpus shared_stack).
        self.vm.stack.clearRetainingCapacity();
        self.vm.registers = @splat(.undefined_value);
        self.root.clearRanThisTick();
        for (self.levels.items) |lv| {
            if (lv.kind == .clip) lv.kind.clip.clearRanThisTick();
        }
        self.retireDead(&ctx);
        // Ruffle re-picks at the end of EVERY update, not just on pointer
        // events (player.rs:2386) — a clip that moves, hides or is removed
        // under a stationary pointer changes the hover all by itself.
        try self.updateMouseState(false, false);
        self.vm.now_ms += self.frame_ms;
        self.vm.budget = 5_000_000;
        self.vm.halted = false;
        if (ctx.background_color) |c| self.background = c | 0xFF000000;
    }

    /// Drain the action queue (actions can queue more via gotos — pending
    /// gotos apply between drains; new DoActions from replays stay
    /// suppressed per Ruffle's run_goto rule). A goto here can remove a clip
    /// whose own DoAction is still queued behind us; such clips are marked
    /// `removed` and stay alive until `retireDead`, so the pointer is safe
    /// and scripts see undefined.
    fn drainActions(self: *Player, ctx: *display.movie_clip.Context) !void {
        while (ctx.popAction()) |qa| {
            // A clip that has been removed — or is only QUEUED for
            // removal — runs nothing but its own unload
            // (ruffle player.rs `run_actions`).
            const pending = if (qa.clip.placement) |pl| pl.pending_removal else false;
            if ((qa.clip.removed or pending) and !qa.on_removed) continue;
            // A button's handler runs on the BUTTON's script object; the
            // queued `clip` is only its parent, for the removal check.
            if (qa.display) |d| {
                if (d.removed) continue;
                const h = try avm1.stage_object.displayObject(self.vm, d);
                switch (qa.what) {
                    .method => |name| self.callClipHandler(h, name),
                    else => {},
                }
                try self.root.applyPendingGoto(ctx);
                continue;
            }
            const clip_obj = try self.clipObject(qa.clip);
            switch (qa.what) {
                .code => |code| self.runBytecode(clip_obj, code),
                .method => |name| self.callClipHandler(clip_obj, name),
                .construct => |c| {
                    // Order is load-bearing: the prototype must be in place
                    // before the construct handlers run, and the constructor
                    // itself runs last (ruffle player.rs:2169-2196).
                    if (c.ctor != 0) {
                        const proto = self.vm.objects.getChained(
                            c.ctor,
                            avm1.strings.ascii("prototype"),
                            self.vm.case_sensitive,
                        ) orelse avm1.value.Value.undefined_value;
                        self.vm.objects.get(clip_obj).proto = proto;
                    }
                    for (c.events) |code| self.runBytecode(clip_obj, code);
                    if (c.ctor != 0) {
                        _ = self.vm.constructOnExisting(c.ctor, clip_obj) catch |e|
                            self.reportUncaught(e);
                    }
                },
            }
            try self.root.applyPendingGoto(ctx);
        }
    }

    /// Fire whatever timers came due this frame. Ruffle updates timers in
    /// `Player::tick` AFTER `run_frame`, and drains the action queue between
    /// callbacks, so a timer that gotos sees the effect before the next one
    /// fires. Callbacks run with the ROOT as base clip.
    fn updateTimers(self: *Player, ctx: *display.movie_clip.Context) !void {
        const timers = &self.vm.timers;
        timers.advance(self.frame_ms);
        if (timers.list.items.len == 0) return;
        const root_obj = try self.clipObject(&self.root);
        var fired: u32 = 0;
        while (timers.due()) |timer| {
            fired += 1;
            if (fired > @TypeOf(timers.*).MAX_TICKS) {
                // Too many at once: rewind the clock to just before this
                // one rather than starving the frame.
                timers.backOff(timer);
                break;
            }
            const id = timer.id;
            const callback = timer.callback;
            const params = timer.params;
            const result = switch (callback) {
                .func => |f| self.vm.callFunction(
                    .{ .object = f },
                    .{ .object = root_obj },
                    params,
                ),
                // Resolved at FIRE time, so reassigning the method between
                // ticks changes what runs — and a missing one just no-ops.
                // A timer bound to a clip stops firing once that clip is
                // removed, WITHOUT being cancelled (ruffle timer.rs:97-114).
                .method => |m| blk: {
                    if (avm1.stage_object.isRemovedClip(self.vm, m.this)) {
                        break :blk avm1.value.Value.undefined_value;
                    }
                    const f = self.vm.getProperty(m.this, m.name, .{ .object = m.this }) catch
                        avm1.value.Value.undefined_value;
                    break :blk self.vm.callFunction(f, .{ .object = m.this }, params);
                },
            };
            // A truthy return value cancels the interval (ruffle timer.rs
            // `cancel_timer`).
            const cancelled = if (result) |v|
                avm1.value.toBoolean(v, self.vm.swf_version)
            else |e| blk: {
                self.reportUncaught(e);
                break :blk false;
            };
            timers.reschedule(id, cancelled);
            try self.drainActions(ctx);
        }
    }

    /// Every `DoInitAction` in the main timeline, run once before the first
    /// frame. Ruffle executes these during PRELOAD rather than on the
    /// timeline, so a class registered by `#initclip` is available to
    /// PlaceObject tags that appear before it in the tag stream.
    ///
    /// Init actions nested inside a DefineSprite are skipped: the SWF spec
    /// forbids them and ruffle notes its own handling there is nonsense.
    fn runInitActions(self: *Player, ctx: *display.movie_clip.Context) !void {
        if (self.init_actions_done) return;
        self.init_actions_done = true;
        const root_obj = try self.clipObject(&self.root);
        for (self.movie.frames) |frame| {
            for (frame.controls) |control| {
                if (control != .init_action) continue;
                self.runBytecode(root_obj, control.init_action.code);
                try self.root.applyPendingGoto(ctx);
            }
        }
    }

    /// The `DoInitAction` blocks of a movie loaded at runtime, run once
    /// with the target clip as the base — the loaded movie's own preload
    /// phase, which is where `#initclip` lives.
    fn runMovieInitActions(
        self: *Player,
        ctx: *display.movie_clip.Context,
        mc: *MovieClipT,
        movie: *const swf.movie.Movie,
    ) !void {
        const clip_obj = try self.clipObject(mc);
        const outer = ctx.movie;
        ctx.movie = movie;
        defer ctx.movie = outer;
        // In TAG ORDER, because an import's init actions interleave with
        // this movie's own. An import copies the exporting movie's
        // characters in under OUR ids and then runs ALL of its init
        // actions — not just the ones behind an imported symbol — with
        // the IMPORTING clip as `this` (corpus do_init_action_child).
        for (movie.frames) |frame| {
            for (frame.controls) |control| {
                switch (control) {
                    .init_action => |ia| self.runBytecode(clip_obj, ia.code),
                    .import => |i| {
                        if (i < movie.imports.len) {
                            try self.runImport(ctx, mc, movie, movie.imports[i]);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn runImport(
        self: *Player,
        ctx: *display.movie_clip.Context,
        mc: *MovieClipT,
        importer: *const swf.movie.Movie,
        imp: swf.movie.Import,
    ) !void {
        const url = try avm1.strings.toUtf8(self.vm.arena(), try self.absoluteUrl(imp.url));
        var st: FetchStatus = .dns_error;
        const bytes = (if (self.load_file) |f| f(self.load_user, url, &st) else null) orelse return;
        if (!isSwf(bytes)) return;
        const m = try self.gpa.create(swf.movie.Movie);
        m.* = swf.movie.load(self.gpa, bytes) catch {
            self.gpa.destroy(m);
            return;
        };
        try self.loaded_movies.append(self.gpa, m);
        try self.movie_urls.append(self.gpa, try self.gpa.dupe(u8, url));
        // Each requested name is looked up in the source's exports and
        // filed under the id the IMPORTER uses for it.
        const lib = @constCast(&importer.lib);
        for (imp.assets) |asset| {
            const src_id = m.lib.exports.get(asset.name) orelse continue;
            const ch = m.lib.get(src_id) orelse continue;
            try lib.put(importer.allocator(), asset.id, ch);
        }
        const clip_obj = try self.clipObject(mc);
        const outer = ctx.movie;
        ctx.movie = m;
        defer ctx.movie = outer;
        for (m.frames) |frame| {
            for (frame.controls) |control| {
                if (control != .init_action) continue;
                self.runBytecode(clip_obj, control.init_action.code);
            }
        }
    }

    /// Point the walk context at the movie the base clip belongs to, for
    /// the duration of one script. Everything a script does that touches
    /// a LIBRARY — `attachMovie`, `loadBitmap`, a text field resolving a
    /// font — has to look in the clip's own movie, and inside a loaded
    /// SWF that is not the root's. Returns the movie to put back.
    fn enterClipMovie(self: *Player, clip_obj: avm1.runtime.ObjectHandle) ?Scope {
        const ctx = self.cur_ctx orelse return null;
        const mc = avm1.stage_object.clipOfHandle(self.vm, clip_obj) orelse return null;
        const prev: Scope = .{ .movie = ctx.movie, .version = self.vm.swf_version };
        const movie = mc.movieOf(ctx);
        ctx.movie = movie;
        // The VERSION follows the movie too. A SWF5 file loaded into a
        // SWF8 one coerces, gates properties and folds case like a SWF5
        // file — corpus mcl_events_swf_version detects its own version
        // through the ASSetPropFlags gate bits and prints it.
        if (movie.swf_version != 0) {
            // …and so does the ENVIRONMENT: a SWF6 movie loaded into a
            // SWF8 one gets the SWF6 `_global` and prototypes, which are
            // a different set of objects (corpus global_swf6_7_8).
            self.vm.useVersion(movie.swf_version);
            self.vm.swf_version = movie.swf_version;
            // The object table keeps its own copy for the property
            // version gate, which is the half `ASSetPropFlags` observes.
            self.vm.objects.swf_version = movie.swf_version;
        }
        return prev;
    }

    const Scope = struct { movie: *const swf.movie.Movie, version: u8 };

    fn leaveClipMovie(self: *Player, prev: ?Scope) void {
        const p = prev orelse return;
        self.vm.swf_version = p.version;
        self.vm.objects.swf_version = p.version;
        const ctx = self.cur_ctx orelse return;
        ctx.movie = p.movie;
    }

    fn runBytecode(self: *Player, clip_obj: avm1.runtime.ObjectHandle, code: []const u8) void {
        const prev = self.enterClipMovie(clip_obj);
        defer self.leaveClipMovie(prev);
        var act = avm1.activation.Activation.init(
            self.vm,
            code,
            .{ .object = clip_obj },
            clip_obj,
            self.vm.active_pool,
        );
        _ = act.run() catch |e| self.reportUncaught(e);
    }

    /// Invoke a script-assigned event handler (`clip.onEnterFrame = f`)
    /// if one is present. Absent handlers are the common case, so this
    /// must stay a cheap lookup miss.
    fn callClipHandler(self: *Player, clip_obj: avm1.runtime.ObjectHandle, name: []const u8) void {
        const prev = self.enterClipMovie(clip_obj);
        defer self.leaveClipMovie(prev);
        var buf: [24]u16 = undefined;
        for (name, 0..) |c, i| buf[i] = c;
        const wide = buf[0..name.len];
        const f = self.vm.objects.getChained(clip_obj, wide, self.vm.case_sensitive) orelse return;
        if (!self.vm.isCallable(f)) return;
        _ = self.vm.callFunction(f, .{ .object = clip_obj }, &.{}) catch |e| self.reportUncaught(e);
    }

    /// A throw that escapes the outermost action is reported and execution
    /// continues — Flash does not stop the movie (ruffle
    /// avm1/runtime.rs:668-684). The message goes to the trace sink,
    /// which is where the corpus expects to see it.
    fn reportUncaught(self: *Player, e: anyerror) void {
        if (e != error.Avm1Thrown) return;
        const S = avm1.strings.ascii;
        const msg = self.vm.toStringValue(self.vm.pending_throw) catch S("[type Object]");
        const prefix = S("Warning: Uncaught exception, ");
        const line = avm1.strings.concat(self.vm.arena(), prefix, msg) catch return;
        self.vm.traceLine(line) catch {};
        self.vm.pending_throw = .undefined_value;
    }

    /// Free the clips removed during this tick, now that no queued action
    /// can still reference them. Their AVM1 objects may outlive them (a
    /// script can hold the reference), so sever the native link first —
    /// otherwise every later property read is a use-after-free.
    fn retireDead(self: *Player, ctx: *display.movie_clip.Context) void {
        for (ctx.graveyard.items) |obj| {
            self.severClipObjects(obj);
            self.rebindMouseTargets(ctx, obj);
            // The execution list holds raw pointers, so a clip about to
            // be FREED has to leave it here — noticing it on the next
            // walk would already be a use-after-free.
            self.unlistSubtree(obj);
        }
        ctx.drainGraveyard(self.gpa);
    }

    fn unlistSubtree(self: *Player, obj: *display.display_object.DisplayObject) void {
        switch (obj.kind) {
            .clip => |mc| {
                self.unlistClip(mc);
                for (mc.children.items) |c| self.unlistSubtree(c);
            },
            .button => |b| for (b.container.children.items) |c| self.unlistSubtree(c),
            else => {},
        }
    }

    fn unlistClip(self: *Player, mc: *MovieClipT) void {
        var i: usize = 0;
        while (i < self.exec_list.items.len) {
            if (self.exec_list.items[i] == mc) {
                _ = self.exec_list.orderedRemove(i);
            } else i += 1;
        }
    }

    /// A goto can destroy the very object the pointer is on. Ruffle keeps
    /// the old one alive and re-acquires at the top of the next
    /// `update_mouse_state`; our display objects are freed at the end of
    /// the tick, so the hand-off has to happen HERE, while both the dead
    /// object and its replacement exist.
    ///
    /// "Replacement" is ruffle's `check_display_object_equality`: same
    /// depth, same character. The button state carries across, which is
    /// what lets a press survive the goto it triggered (corpus
    /// button_goto).
    fn rebindMouseTargets(
        self: *Player,
        ctx: *display.movie_clip.Context,
        dead: *display.display_object.DisplayObject,
    ) void {
        const DO = display.display_object.DisplayObject;
        const inSubtree = struct {
            fn f(root: *DO, needle: *DO) bool {
                if (root == needle) return true;
                for (display.bounds.childrenOf(root)) |child| {
                    if (f(child, needle)) return true;
                }
                if (root.kind == .button) {
                    for (root.kind.button.hit_area.children.items) |child| {
                        if (f(child, needle)) return true;
                    }
                }
                return false;
            }
        }.f;
        for ([_]*?*DO{ &self.hovered, &self.pressed }) |slot| {
            const cur = slot.* orelse continue;
            if (!inSubtree(dead, cur)) continue;
            slot.* = self.findReplacement(&self.root_placement, cur);
            if (slot.*) |fresh| {
                if (fresh.kind == .button and cur.kind == .button) {
                    fresh.kind.button.setState(ctx, fresh, cur.kind.button.state) catch {};
                }
            }
        }
    }

    fn findReplacement(
        self: *Player,
        root: *display.display_object.DisplayObject,
        old: *display.display_object.DisplayObject,
    ) ?*display.display_object.DisplayObject {
        for (display.bounds.childrenOf(root)) |child| {
            if (child.depth == old.depth and child.character_id == old.character_id and
                child.kind != .shape) return child;
            if (self.findReplacement(child, old)) |hit| return hit;
        }
        return null;
    }

    fn severClipObjects(self: *Player, obj: *display.display_object.DisplayObject) void {
        // Buttons and text fields carry their handle on the DisplayObject
        // itself; clips carry theirs on the MovieClip. Both must be cut
        // loose or a retained script reference outlives the memory.
        if (obj.avm_object != 0) self.vm.objects.get(obj.avm_object).native = .removed_display;
        if (obj.kind != .clip) return;
        const mc = obj.kind.clip;
        if (mc.avm_object != 0) self.vm.objects.get(mc.avm_object).native = .removed_display;
        for (mc.children.items) |child| self.severClipObjects(child);
    }

    /// Fetch (creating once) the AVM1 object for a clip. Object creation
    /// itself lives in `stage_object.clipObject` — this wrapper only adds
    /// the root's global bindings, which nothing below the Player knows
    /// about.
    fn clipObject(self: *Player, mc: *MovieClipT) !avm1.runtime.ObjectHandle {
        const existed = mc.avm_object != 0;
        const h = try avm1.stage_object.clipObject(self.vm, mc);
        if (!existed and mc == &self.root) {
            self.vm.root_scope = h;
            self.vm.root_object = .{ .object = h };
            // NOT registered as _global properties: `_root`/`_levelN` are
            // resolved through the display tree (stage_object's path
            // properties), which correctly yields undefined below SWF5
            // where they do not exist. A _global entry would leak them
            // into SWF4 — corpus target_paths/swf4.
            const S = avm1.strings.ascii;
            // BOTH environments — a movie on the other side of the SWF7
            // line has its own `_global` and would still find them.
            for ([_]avm1.runtime.ObjectHandle{
                self.vm.globals,
                self.vm.env_lo.globals,
                self.vm.env_hi.globals,
            }) |g| {
                if (g == 0) continue;
                _ = self.vm.objects.deleteOwn(g, S("_root"), self.vm.case_sensitive);
                _ = self.vm.objects.deleteOwn(g, S("_level0"), self.vm.case_sensitive);
            }
        }
        return h;
    }

    fn hostKeyFocus(user: *anyopaque, obj: *display.display_object.DisplayObject) bool {
        const self: *Player = @ptrCast(@alignCast(user));
        return avm1.stage_object.hasKeyFocus(self.vm, obj);
    }

    /// A display object just joined the list. A field gets its broadcaster
    /// object and binds its `variable`; anything else just gives the
    /// parked fields another chance (M4-D7).
    fn hostObjectInstantiated(user: *anyopaque, obj: *display.display_object.DisplayObject) void {
        const self: *Player = @ptrCast(@alignCast(user));
        if (obj.kind == .edit_text) {
            _ = avm1.stage_object.displayObject(self.vm, obj) catch return;
            avm1.text_binding.onFieldCreated(self.vm, obj) catch {};
            return;
        }
        avm1.text_binding.retryUnbound(self.vm) catch {};
    }

    fn hostBoolProperty(
        user: *anyopaque,
        obj: *display.display_object.DisplayObject,
        name: []const u8,
    ) ?bool {
        const self: *Player = @ptrCast(@alignCast(user));
        const handle = switch (obj.kind) {
            .clip => |mc| mc.avm_object,
            else => obj.avm_object,
        };
        if (handle == 0) return null;
        var buf: [24]u16 = undefined;
        for (name, 0..) |c, i| buf[i] = c;
        const v = self.vm.objects.getChained(handle, buf[0..name.len], self.vm.case_sensitive) orelse
            return null;
        if (v == .undefined_value or v == .null_value) return null;
        return avm1.value.toBoolean(v, self.vm.swf_version);
    }

    fn hostLostDisplayObject(user: *anyopaque, obj: *display.display_object.DisplayObject) void {
        const self: *Player = @ptrCast(@alignCast(user));
        avm1.stage_object.dropFocusIf(self.vm, obj) catch {};
        // Fields bound to a variable ON this object go back to waiting
        // rather than pointing at a corpse (ruffle unregister_bindings).
        avm1.text_binding.unregister(self.vm, obj) catch {};
    }

    /// The script-property half of "button mode": does the clip's object
    /// carry any of onPress/onRelease/…? Looked up through the prototype
    /// chain, so a class that defines onRelease makes every instance
    /// pickable (ruffle movie_clip.rs is_button_mode).
    fn hostHasButtonHandler(user: *anyopaque, clip: *display.movie_clip.MovieClip) bool {
        const self: *Player = @ptrCast(@alignCast(user));
        if (clip.avm_object == 0) return false;
        for (display.mouse.BUTTON_EVENT_METHODS) |name| {
            var buf: [24]u16 = undefined;
            for (name, 0..) |c, i| buf[i] = c;
            if (self.vm.objects.hasChained(clip.avm_object, buf[0..name.len], self.vm.case_sensitive)) {
                return true;
            }
        }
        return false;
    }

    fn hostHasProperty(user: *anyopaque, clip: *display.movie_clip.MovieClip, name: []const u8) bool {
        const self: *Player = @ptrCast(@alignCast(user));
        if (clip.avm_object == 0) return false;
        var buf: [32]u16 = undefined;
        if (name.len > buf.len) return false;
        for (name, 0..) |c, i| buf[i] = c;
        return self.vm.objects.hasChained(clip.avm_object, buf[0..name.len], self.vm.case_sensitive);
    }

    /// `obj.enabled`, the AVM1 property. Absent means enabled — only an
    /// explicit false takes a button or clip out of the pick.
    fn hostMouseEnabled(user: *anyopaque, obj: *display.display_object.DisplayObject) bool {
        const self: *Player = @ptrCast(@alignCast(user));
        const handle = switch (obj.kind) {
            .clip => |mc| mc.avm_object,
            else => obj.avm_object,
        };
        if (handle == 0) return true;
        const v = self.vm.objects.getChained(
            handle,
            avm1.strings.ascii("enabled"),
            self.vm.case_sensitive,
        ) orelse return true;
        if (v == .undefined_value or v == .null_value) return true;
        return avm1.value.toBoolean(v, self.vm.swf_version);
    }

    /// `Object.registerClass` maps an ExportAssets SYMBOL to a constructor,
    /// while the display list only knows character ids — so the lookup has
    /// to go back through the export table.
    fn hostRegisteredClass(user: *anyopaque, char_id: u16) u32 {
        const self: *Player = @ptrCast(@alignCast(user));
        if (char_id == 0 or self.vm.class_registry.items.len == 0) return 0;
        // The CURRENT walk's movie, not the root's: a character id only
        // means anything inside the library it came from, and a loaded
        // movie registers classes for its OWN exports.
        const movie = if (self.cur_ctx) |c| c.movie else &self.movie;
        var it = movie.lib.exports.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != char_id) continue;
            const wide = avm1.strings.fromSwf(self.vm.arena(), e.key_ptr.*, movie.swf_version) catch
                return 0;
            if (self.vm.registeredClass(wide)) |ctor| return ctor;
        }
        return 0;
    }

    fn hostRunInline(user: *anyopaque, clip: *MovieClipT, code: []const u8) void {
        const self: *Player = @ptrCast(@alignCast(user));
        const clip_obj = self.clipObject(clip) catch return;
        self.runBytecode(clip_obj, code);
    }

    fn installHost(self: *Player) void {
        self.vm.host = .{
            .ctx = @ptrCast(self),
            .goto_frame = hostGotoFrame,
            .goto_label = hostGotoLabel,
            .set_playing = hostSetPlaying,
            .next_prev = hostNextPrev,
            .focus_roll = hostFocusRoll,
            .fetch = hostFetch,
            .navigate = hostNavigate,
            .fscommand = hostFsCommand,
            .level = hostLevel,
            .unload_movie = hostUnloadMovie,
            .movie_bytes = hostMovieBytes,
            .sound_complete = hostSoundComplete,
            .sound_play = hostSoundPlay,
            .sound_stop = hostSoundStop,
            .sound_position = hostSoundPosition,
            .sound_transform = hostSoundTransform,
            .sound_register = hostSoundRegister,
            .stream_audio = hostStreamAudio,
            .socket_connect = hostSocketConnect,
            .socket_send = hostSocketSend,
            .socket_close = hostSocketClose,
            .file_dialog = hostFileDialog,
        };
    }

    /// The focus moved, so the hover moves with it. The roll events are
    /// queued like any other, which is why a programmatic `setFocus`
    /// shows them only after the calling script finishes.
    fn hostFocusRoll(ctx: *anyopaque, obj: ?*anyopaque, run_now: bool) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const c = self.cur_ctx orelse return;
        const target: ?*display.display_object.DisplayObject =
            if (obj) |o| @ptrCast(@alignCast(o)) else null;
        const old = self.hovered;
        self.hovered = target;
        if (old) |o| display.mouse.dispatch(c, o, .roll_out) catch {};
        if (target) |t| display.mouse.dispatch(c, t, .roll_over) catch {};
        if (run_now) self.drainActions(c) catch {};
    }

    fn hostGotoFrame(ctx: *anyopaque, clip: *anyopaque, frame: u16, play: bool) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        mc.gotoFrame(frame);
        mc.playing = play;
        self.applyGotoNow(mc);
    }

    fn hostGotoLabel(ctx: *anyopaque, clip: *anyopaque, label: []const u16, play: bool) bool {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        for (label) |c| {
            if (n >= buf.len or c > 0x7F) break;
            buf[n] = @intCast(c);
            n += 1;
        }
        const target = mc.labelToNumber(buf[0..n]) orelse return false;
        mc.gotoFrame(target);
        mc.playing = play;
        self.applyGotoNow(mc);
        return true;
    }

    /// Replay a pending goto right now, if we are inside a tick.
    fn applyGotoNow(self: *Player, mc: *MovieClipT) void {
        const ctx = self.cur_ctx orelse return;
        mc.applyPendingGoto(ctx) catch {};
    }

    fn hostSetPlaying(ctx: *anyopaque, clip: *anyopaque, playing: bool) void {
        _ = ctx;
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        mc.playing = playing;
    }

    fn hostNextPrev(ctx: *anyopaque, clip: *anyopaque, delta: i2) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        const cur = mc.current_frame;
        if (delta > 0) {
            mc.gotoFrame(cur + 1);
        } else if (cur > 1) {
            mc.gotoFrame(cur - 1);
        }
        mc.playing = false;
        self.applyGotoNow(mc);
    }

    // --- input seam ---------------------------------------------------------
    //
    // Frontends call these; `core/` never polls anything. Each one updates
    // the VM's input state, re-applies any drag, broadcasts to the clips and
    // then to the Key/Mouse listeners, and drains whatever that queued —
    // input events run script OUTSIDE the frame loop, like timers do.

    pub fn mouseMove(self: *Player, x: f64, y: f64) !void {
        if (self.movie.swf_version < 9) self.resetHighlight();
        const before = [2]f64{ self.vm.mouse_x, self.vm.mouse_y };
        self.setMousePosition(x, y);
        try self.dispatchInput(swf.place.ClipEvent.MOUSE_MOVE, "onMouseMove", self.vm.mouse_object);
        // A move to where the pointer already IS does not count as one:
        // ruffle compares the mapped position with the previous
        // (player.rs:1384), and an unmoved pointer leaves the hover — a
        // Tab may own it — untouched. The broadcast above still fires.
        const moved = self.vm.mouse_x != before[0] or self.vm.mouse_y != before[1];
        // Dragging inside a pressed text field extends its selection.
        if (self.pressed) |p| {
            if (!p.removed) avm1.stage_object.dragSelect(self.vm, p);
        }
        try self.updateMouseState(moved, false);
    }

    /// Re-pick and fire whatever the delta implies. Ruffle's
    /// `update_mouse_state` (player.rs:1523-1850) in the same order: the
    /// roll/drag pair for a changed hover first, then press or release.
    ///
    /// The pick runs on every pointer event AND once per frame, because a
    /// clip can move out from under a stationary pointer.
    /// The player window lost or gained the OS focus. Losing it drops the
    /// AVM1 focus entirely (ruffle `handle_focus_event`); gaining it back
    /// restores nothing.
    pub fn windowFocus(self: *Player, gained: bool) !void {
        if (gained) return;
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        // `reset_focus`, not a plain `set`: the roll events it queues run
        // BEFORE the focus handlers (focus_tracker.rs:95-97).
        try avm1.stage_object.setFocusEx(self.vm, 0, true);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// Any left press clears the focus highlight, and below SWF9 so does
    /// every other mouse event (ruffle `should_reset_highlight`).
    fn resetHighlight(self: *Player) void {
        self.vm.focus_highlight = false;
    }

    pub fn updateMouseState(self: *Player, moved: bool, changed_left: bool) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        try self.deriveMouseEvents(&ctx, moved, changed_left);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// Deliver one event, and forget a DISABLED button afterwards: ruffle
    /// drops it from `hovered`/`pressed` inside `event_dispatch`
    /// (avm1_button.rs:517-524) so that re-enabling it re-fires the roll
    /// from scratch instead of resuming mid-gesture.
    fn sendMouse(
        self: *Player,
        ctx: *display.movie_clip.Context,
        obj: *display.display_object.DisplayObject,
        event: display.mouse.Event,
    ) !void {
        // The check comes FIRST: ruffle reads `enabled` at the top of
        // `event_dispatch`, so a handler that disables the button only
        // takes effect from the NEXT event on.
        const disabled_button = obj.kind == .button and !ctx.mouseEnabled(obj);
        try display.mouse.dispatch(ctx, obj, event);
        if (!disabled_button) return;
        if (self.hovered == obj) self.hovered = null;
        if (self.pressed == obj) self.pressed = null;
    }

    fn deriveMouseEvents(
        self: *Player,
        ctx: *display.movie_clip.Context,
        moved: bool,
        changed_left: bool,
    ) !void {
        const M = display.mouse;
        const DO = display.display_object.DisplayObject;
        const twips = swf.reader.TWIPS_PER_PX;
        const point: [2]i32 = .{
            @intFromFloat(@round(self.vm.mouse_x * twips)),
            @intFromFloat(@round(self.vm.mouse_y * twips)),
        };
        const new_over = M.pick(ctx, &self.root_placement, .identity, point);
        const left_down = (self.vm.mouse_buttons & 1) != 0;

        // Ruffle COLLECTS the events first, updates hovered/pressed, and
        // only then fires them (player.rs:1547 `events`) — the order
        // matters because a handler can invalidate the very state that
        // produced it.
        var events: [6]struct { obj: *DO, ev: M.Event } = undefined;
        var n: usize = 0;

        // An object that has been removed stops being hovered or pressed.
        if (self.hovered) |h| {
            if (h.removed) self.hovered = null;
        }
        if (self.pressed) |p| {
            if (p.removed) self.pressed = null;
        }

        // Nothing moved, no button changed, and something is already
        // hovered: leave it alone. Tab sets the hover too, and an idle
        // pick must not roll straight back out of it (ruffle
        // player.rs:1538 `skip_mouse_hover`). An object that has gone
        // INVISIBLE is the exception — that hover is cancelled even when
        // the pointer never moved.
        var skip_hover = !moved and !changed_left and self.hovered != null;
        if (self.hovered) |h| {
            if (!h.visible) skip_hover = false;
        }

        const cur_over = self.hovered;
        if (!skip_hover and cur_over != new_over) {
            if (left_down) {
                // Dragging: only the DRAG pair fires, and not at all while
                // an AVM1 `startDrag` is in progress.
                if (self.vm.drag == null) {
                    if (self.pressed) |down| {
                        if (cur_over == down) {
                            events[n] = .{ .obj = down, .ev = .drag_out };
                            n += 1;
                        } else if (new_over == down) {
                            events[n] = .{ .obj = down, .ev = .drag_over };
                            n += 1;
                        }
                    }
                    if (cur_over) |c| {
                        if (self.pressed != c) {
                            events[n] = .{ .obj = c, .ev = .drag_out };
                            n += 1;
                        }
                    }
                    if (new_over) |o| {
                        if (self.pressed != o) {
                            events[n] = .{ .obj = o, .ev = .drag_over };
                            n += 1;
                        }
                    }
                }
            } else {
                if (cur_over) |c| {
                    events[n] = .{ .obj = c, .ev = .roll_out };
                    n += 1;
                }
                if (new_over) |o| {
                    events[n] = .{ .obj = o, .ev = .roll_over };
                    n += 1;
                }
            }
        }
        if (!skip_hover) self.hovered = new_over;

        if (changed_left) {
            if (left_down) {
                if (self.hovered) |over| {
                    events[n] = .{ .obj = over, .ev = .press };
                    n += 1;
                    self.pressed = over;
                } else {
                    // A press on NOTHING still moves the focus: it goes
                    // to the stage, which cannot hold it, so a focused
                    // text field loses it.
                    try avm1.stage_object.focusByMousePress(self.vm, null);
                }
            } else {
                const down = self.pressed;
                self.pressed = null;
                if (down) |d| {
                    if (d == self.hovered) {
                        events[n] = .{ .obj = d, .ev = .release };
                        n += 1;
                    } else {
                        events[n] = .{ .obj = d, .ev = .release_outside };
                        n += 1;
                        // Whatever is under the pointer NOW is rolled over
                        // immediately (ruffle player.rs:1835-1845).
                        if (self.hovered) |over| {
                            events[n] = .{ .obj = over, .ev = .roll_over };
                            n += 1;
                        }
                    }
                }
            }
        }

        for (events[0..n]) |e| {
            try self.sendMouse(ctx, e.obj, e.ev);
            // A PRESS moves the focus: onto the pressed object if it can
            // take focus by mouse, off whatever had it otherwise (ruffle
            // `update_focus_on_mouse_press`, fired per press event).
            if (e.ev == .press and !e.obj.removed) {
                try avm1.stage_object.focusByMousePress(self.vm, e.obj);
            }
        }
    }


    /// Move the pointer WITHOUT raising a move event. A button event
    /// carries a position too, and delivering it as a move as well would
    /// double every `onMouseMove` handler.
    pub fn setMousePosition(self: *Player, x_view: f64, y_view: f64) void {
        // The caller speaks VIEWPORT pixels; the stage may be scaled or
        // letterboxed inside it.
        const p = avm1.stage_object.viewportToStage(self.vm, x_view, y_view);
        self.vm.mouse_x = p[0];
        self.vm.mouse_y = p[1];
        avm1.stage_object.applyDrag(self.vm);
    }

    pub fn mouseButton(self: *Player, button: u8, down: bool) !void {
        if (button == 0 and down) {
            self.resetHighlight();
        } else if (self.movie.swf_version < 9 and button != 1) {
            self.resetHighlight();
        }
        const bit = @as(u8, 1) << @intCast(@min(button, 7));
        if (down) {
            self.vm.mouse_buttons |= bit;
        } else {
            self.vm.mouse_buttons &= ~bit;
        }
        // Every mouse button is also a KEY as far as `Key` is concerned:
        // left is 1, right 2, middle 4. They participate in the toggle
        // state too — corpus key_isToggled reads `Key.isToggled(1)`
        // between clicks, and mouse_events_visible_enabled asks
        // `Key.isDown(4)` for the middle one.
        const key: usize = switch (button) {
            0 => 1,
            1 => 4,
            2 => 2,
            else => 0,
        };
        if (key != 0) {
            if (down and !self.vm.keys_down[key]) self.vm.keys_toggled[key] = !self.vm.keys_toggled[key];
            self.vm.keys_down[key] = down;
        }
        // Only the PRIMARY button drives the press/release machine; AVM1
        // has no handler for the other two (ruffle's MiddlePress and
        // RightPress arms are AVM2-only).
        if (button != 0) return;
        if (down) {
            try self.dispatchInput(swf.place.ClipEvent.MOUSE_DOWN, "onMouseDown", self.vm.mouse_object);
        } else {
            try self.dispatchInput(swf.place.ClipEvent.MOUSE_UP, "onMouseUp", self.vm.mouse_object);
        }
        try self.updateMouseState(false, true);
    }

    /// Seed the clipboard the way a host paste-buffer would.
    pub fn setClipboard(self: *Player, utf8: []const u8) !void {
        self.clipboard.clearRetainingCapacity();
        const needed = std.unicode.calcUtf16LeLen(utf8) catch return;
        try self.clipboard.resize(self.gpa, needed);
        _ = std.unicode.utf8ToUtf16Le(self.clipboard.items, utf8) catch {
            self.clipboard.clearRetainingCapacity();
        };
    }

    /// Text typed by the user. This is also where printable ASCII raises
    /// its button `keyPress`, and a handler that CLAIMS the key stops the
    /// character reaching the focused field.
    pub fn textInput(self: *Player, typed: []const u16) !void {
        for (typed) |cp| try self.textInputOne(cp);
    }

    fn textInputOne(self: *Player, cp: u16) !void {
        var handled = false;
        if (display.button.buttonKeyFromChar(cp)) |bk| handled = try self.dispatchKeyPress(bk);
        if (handled) return;
        // Space activates the highlighted focus, and it does so from the
        // TEXT INPUT rather than the key-down (ruffle player.rs:1348).
        if (cp == ' ') try self.activateFocus();

        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const t = self.focusedFieldTarget() orelse return;
        const changed = try t.obj.kind.edit_text.textInput(self.gpa, &.{cp});
        if (changed) try self.afterFieldEdit(t.obj);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// An IME preedit update for the focused field. An empty string ends
    /// the composition.
    pub fn imePreedit(self: *Player, preedit: []const u16, cursor: ?[2]usize) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const t = self.focusedFieldTarget() orelse return;
        try t.obj.kind.edit_text.imePreedit(self.gpa, preedit, cursor);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// One editing command (arrow keys, backspace, cut/paste …).
    pub fn textControl(self: *Player, code: display.edit_text.Control) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const t = self.focusedFieldTarget() orelse return;
        const changed = try t.obj.kind.edit_text.textControl(self.gpa, code, &self.clipboard);
        if (changed) try self.afterFieldEdit(t.obj);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// The box Flash outlines in yellow around the focused object, in
    /// stage TWIPS — or null when there is nothing to outline.
    ///
    /// Three conditions, all ruffle's (focus_tracker.rs
    /// `calculate_highlight`): the highlight has to be ACTIVE, which only
    /// a key press makes it and any mouse activity ends; `_focusrect` has
    /// to allow it, which below SWF6 only the stage's flag decides; and
    /// the object has to have bounds worth outlining — a clip with
    /// nothing in it is focusable but invisible.
    fn focusHighlightBox(self: *Player) ?swf.reader.Rectangle {
        if (!self.vm.focus_highlight or self.vm.focus == 0) return null;
        const t = avm1.stage_object.targetOf(self.vm, self.vm.focus) orelse return null;
        const enabled = if (self.movie.swf_version >= 6)
            t.obj.focus_rect orelse self.vm.stage_focus_rect
        else
            self.vm.stage_focus_rect;
        if (!enabled) return null;
        const parent_to_global = avm1.stage_object.parentToGlobalMatrix(t);
        const box = display.bounds.engineBoundsWithTransform(
            t.obj,
            parent_to_global.mul(t.obj.matrix),
            &self.movie.lib,
        ) orelse return null;
        if (box.xmin == box.xmax and box.ymin == box.ymax) return null;
        return box;
    }

    fn focusedFieldTarget(self: *Player) ?avm1.stage_object.Target {
        if (self.vm.focus == 0) return null;
        const t = avm1.stage_object.targetOf(self.vm, self.vm.focus) orelse return null;
        if (t.obj.kind != .edit_text) return null;
        return t;
    }

    /// An edit made by the USER pushes the variable binding and then
    /// broadcasts `onChanged` from the field itself.
    fn afterFieldEdit(self: *Player, obj: *display.display_object.DisplayObject) !void {
        try avm1.text_binding.propagate(self.vm, obj);
        const h = try avm1.stage_object.handleOf(self.vm, obj);
        _ = avm1.singletons.broadcast(
            self.vm,
            .{ .object = h },
            avm1.strings.ascii("onChanged"),
            &.{.{ .object = h }},
        ) catch {};
    }

    /// `code` is a Flash key code (the Windows virtual-key numbering);
    /// `char` is the ASCII/UTF-16 code unit `Key.getAscii` reports, or 0.
    pub fn keyDown(self: *Player, code: i32, char: i32) !void {
        if (code >= 0 and code < 256) {
            const i: usize = @intCast(code);
            // Toggle keys flip on the PRESS, and only on a fresh press —
            // auto-repeat must not flicker Caps Lock back off.
            if (!self.vm.keys_down[i]) self.vm.keys_toggled[i] = !self.vm.keys_toggled[i];
            self.vm.keys_down[i] = true;
        }
        self.vm.last_key_code = code;
        self.vm.last_key_char = char;
        try self.dispatchInput(swf.place.ClipEvent.KEY_DOWN, "onKeyDown", self.vm.key_object);
        // keyPress comes after keyDown, always (ruffle player.rs:1302).
        var handled = false;
        if (display.button.buttonKeyFromKeyCode(code)) |bk| handled = try self.dispatchKeyPress(bk);
        // Tab cycles the focus — but only when no keyPress claimed the
        // key first (ruffle player.rs:1328-1340).
        if (!handled and code == 9) {
            try self.cycleFocus(self.vm.keys_down[16]);
        } else if (!handled and code == 13) {
            try self.activateFocus();
        }
        try self.updateMouseState(false, false);
    }

    /// Enter or Space on a highlighted focused object presses AND
    /// releases it, without waiting for the key to come up (ruffle
    /// player.rs:1340-1357).
    fn activateFocus(self: *Player) !void {
        if (!avm1.stage_object.highlightVisible(self.vm)) return;
        const t = avm1.stage_object.targetOf(self.vm, self.vm.focus) orelse return;
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        try display.mouse.dispatch(&ctx, t.obj, .press);
        try display.mouse.dispatch(&ctx, t.obj, .release);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// Move the focus to the next (or previous) tabbable object. Ruffle's
    /// `set_by_key` path: the roll events fire SYNCHRONOUSLY here, unlike
    /// a programmatic `Selection.setFocus`, and the actions they queue are
    /// drained before the focus itself moves (focus_tracker.rs:144-157).
    fn cycleFocus(self: *Player, reverse: bool) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        var order = try display.tab.build(&ctx, &self.root_placement, self.gpa);
        defer order.deinit(self.gpa);
        const current = if (self.vm.focus != 0)
            (avm1.stage_object.targetOf(self.vm, self.vm.focus) orelse null)
        else
            null;
        const cur_obj: ?*display.display_object.DisplayObject =
            if (current) |t| t.obj else null;
        const target = display.tab.next(&order, cur_obj, reverse) orelse return;

        // `setFocus` moves the hover and queues the roll events; a KEY
        // move runs them before the focus handlers, unlike a programmatic
        // one (focus_tracker.rs:150-157).
        const handle = try avm1.stage_object.handleOf(self.vm, target);
        try avm1.stage_object.setFocusEx(self.vm, handle, true);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    fn dispatchKeyPress(self: *Player, code: u8) !bool {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const handled = try self.root.broadcastKeyPress(&ctx, code);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
        return handled;
    }

    pub fn keyUp(self: *Player, code: i32, char: i32) !void {
        if (code >= 0 and code < 256) self.vm.keys_down[@intCast(code)] = false;
        self.vm.last_key_code = code;
        self.vm.last_key_char = char;
        try self.dispatchInput(swf.place.ClipEvent.KEY_UP, "onKeyUp", self.vm.key_object);
        try self.updateMouseState(false, false);
    }

    fn dispatchInput(
        self: *Player,
        flag: u32,
        comptime method: []const u8,
        listener_target: avm1.runtime.ObjectHandle,
    ) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        try self.root.broadcastClipEvent(&ctx, flag, method);
        try self.drainActions(&ctx);
        // The Key/Mouse listener lists come AFTER the clips.
        if (listener_target != 0) {
            _ = avm1.singletons.broadcast(
                self.vm,
                .{ .object = listener_target },
                avm1.strings.ascii(method),
                &.{},
            ) catch {};
            try self.drainActions(&ctx);
        }
        self.retireDead(&ctx);
    }

    /// Take accumulated trace() output (UTF-8; caller-owned view valid
    /// until the next VM activity).
    pub fn takeTrace(self: *Player) []const u8 {
        return self.vm.trace_buf.items;
    }

    fn renderNow(self: *Player) !void {
        const inv_twips = 1.0 / @as(f64, swf.reader.TWIPS_PER_PX);
        const stage: render.renderer.Transform = .{
            .a = inv_twips,
            .d = inv_twips,
            // Stages with non-zero origins translate here.
            .tx = -@as(f64, @floatFromInt(self.movie.header.xmin)) * inv_twips,
            .ty = -@as(f64, @floatFromInt(self.movie.header.ymin)) * inv_twips,
        };
        self.renderer.focused_field = blk: {
            const t = self.focusedFieldTarget() orelse break :blk null;
            break :blk t.obj.kind.edit_text;
        };
        self.renderer.focus_highlight = self.focusHighlightBox();
        self.renderer.now_ms = self.elapsed_ms;
        (try self.canvas.ctx()).antialias = self.antialias;
        try self.renderer.renderFrame(
            &self.canvas,
            &self.root,
            &self.root_placement,
            self.levels.items,
            self.background,
            stage,
        );
    }

    /// XRGB8888 little-endian, width()*height().
    pub fn framebuffer(self: *const Player) []const u32 {
        return self.canvas.pixels();
    }
    pub fn width(self: *const Player) u32 {
        return self.canvas.width();
    }
    pub fn height(self: *const Player) u32 {
        return self.canvas.height();
    }
    pub fn fps(self: *const Player) f64 {
        return 1000.0 / self.frame_ms;
    }

    /// Run the movie faster or slower than it was authored. The frame
    /// clock is NOT touched — `tick` is simply handed more (or less) than
    /// one frame period, so the timeline, `getTimer`, timers and streamed
    /// sound all move together — and the mixer is told to walk its voices
    /// at the same multiple, which pitches the audio to match instead of
    /// letting it drift a whole speed behind.
    ///
    /// Clamped to what the tick loop can honour: `MAX_FRAMES_PER_TICK`
    /// caps a single call at five frames.
    pub fn setSpeed(self: *Player, s: f64) void {
        self.speed = std.math.clamp(s, 0.25, @as(f64, MAX_FRAMES_PER_TICK));
        self.mixer.speed = self.speed;
    }
    pub fn currentFrame(self: *const Player) u16 {
        return self.root.current_frame;
    }

    /// A host's answer to `ExternalInterface.call`, with the Player in
    /// hand so the answer can trace or call straight back in.
    pub const ExternalCallFn = *const fn (
        user: ?*anyopaque,
        player: *Player,
        name: []const u8,
        args: []const external.Value,
    ) external.Value;

    fn externalThunk(user: ?*anyopaque, name: []const u8, args: []const external.Value) external.Value {
        const self: *Player = @ptrCast(@alignCast(user orelse return .null_value));
        const f = self.external_call orelse return .null_value;
        return f(self.external_user, self, name, args);
    }

    /// The host calling IN through `ExternalInterface`: run whatever the
    /// movie registered under `name`. Null when nothing did, when the
    /// callback throws, or when the marshalling gives up.
    pub fn callExternalInterface(
        self: *Player,
        name: []const u8,
        args: []const external.Value,
    ) external.Value {
        return @import("avm1/globals/external.zig").callRegistered(self.vm, name, args) catch .null_value;
    }

    /// Trace a line the way the movie's own `trace()` does — the bridge's
    /// host end shares the sink, which is how the corpus records both
    /// sides of a call in one stream.
    pub fn traceUtf8(self: *Player, line: []const u8) void {
        const wide = avm1.strings.fromSwf(self.vm.arena(), line, 8) catch return;
        self.vm.traceLine(wide) catch {};
    }
    pub fn totalFrames(self: *const Player) u16 {
        return self.root.totalFrames();
    }
};

test {
    // Explicit imports: test blocks are only collected from files that a
    // test-context import reaches (refAllDecls alone proved unreliable —
    // display/render/avm1 tests silently dropped out of the binary).
    @import("std").testing.refAllDecls(@This());
    _ = @import("display/library.zig");
    _ = @import("display/display_object.zig");
    _ = @import("display/bounds.zig");
    _ = @import("display/movie_clip.zig");
    _ = @import("display/button.zig");
    _ = @import("display/mouse.zig");
    _ = @import("display/tab.zig");
    _ = @import("display/text.zig");
    _ = @import("display/edit_text.zig");
    _ = @import("display/font.zig");
    _ = @import("display/device_font.zig");
    _ = @import("display/text_layout.zig");
    _ = @import("render/canvas.zig");
    _ = @import("render/shape_utils.zig");
    _ = @import("render/renderer.zig");
    _ = @import("avm1/opcodes.zig");
    _ = @import("avm1/string.zig");
    _ = @import("avm1/value.zig");
    _ = @import("avm1/object.zig");
    _ = @import("avm1/runtime.zig");
    _ = @import("avm1/activation.zig");
    _ = @import("avm1/stage_object.zig");
    _ = @import("avm1/timers.zig");
    _ = @import("avm1/globals/decl.zig");
    _ = @import("avm1/globals/geom.zig");
    _ = @import("avm1/globals/date.zig");
    _ = @import("avm1/globals/singletons.zig");
    _ = @import("avm1/globals/selection.zig");
    _ = @import("avm1/globals/text_format.zig");
    _ = @import("avm1/globals/text_snapshot.zig");
    _ = @import("avm1/globals/text_field.zig");
    _ = @import("avm1/globals/style_sheet.zig");
    _ = @import("avm1/globals/filters.zig");
    _ = @import("avm1/globals/bitmap_data.zig");
    _ = @import("avm1/globals/loader.zig");
    _ = @import("avm1/globals/socket.zig");
    _ = @import("avm1/globals/file_reference.zig");
    _ = @import("avm1/globals/external.zig");
    _ = @import("avm1/globals/sound.zig");
    _ = @import("avm1/text_binding.zig");
    _ = @import("bitmap/pixels.zig");
    _ = @import("bitmap/data.zig");
    _ = @import("bitmap/operations.zig");
    _ = @import("bitmap/decode.zig");
    _ = @import("bitmap/turbulence.zig");
    _ = @import("xml/parser.zig");
    _ = @import("avm1/case_tables.zig");
    _ = @import("text/format.zig");
    _ = @import("text/spans.zig");
    _ = @import("text/html.zig");
    _ = @import("avm1/globals/movie_clip.zig");
    _ = @import("avm1/globals/globals.zig");
    _ = @import("codecs/screen_video.zig");
    _ = @import("codecs/h263.zig");
    _ = @import("codecs/pcm.zig");
    _ = @import("codecs/adpcm.zig");
    _ = @import("codecs/mp3.zig");
    _ = @import("audio/mixer.zig");
    _ = @import("audio/stream.zig");
    _ = @import("savestate.zig");
    _ = @import("avm1/gc.zig");
    _ = @import("avm1/natives.zig");
}
