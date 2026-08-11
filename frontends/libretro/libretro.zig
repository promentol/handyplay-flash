//! Minimal libretro API surface, hand-declared in Zig (no libretro.h needed).
//! Only the structs/enums/callbacks our cores use. C ABI throughout, linked
//! into a native `.so`/`.dylib` for RetroArch and any other libretro host.
//!
//! Copied from `handyplay-oss/java-core/frontends/libretro/libretro.zig`, as
//! this file's contract said to: the ABI is the ABI, and two cores that
//! declare it differently is how one of them ends up subtly wrong.
const std = @import("std");

pub const API_VERSION: c_uint = 1;

// retro_environment commands we handle.
pub const ENVIRONMENT_SET_PIXEL_FORMAT: c_uint = 10;
pub const ENVIRONMENT_GET_SYSTEM_DIRECTORY: c_uint = 9;
pub const ENVIRONMENT_GET_SAVE_DIRECTORY: c_uint = 31;
pub const ENVIRONMENT_GET_VFS_INTERFACE: c_uint = 45 | 0x10000;
/// Core options: the libretro-native way to expose a setting a game needs.
pub const ENVIRONMENT_GET_VARIABLE: c_uint = 15;
pub const ENVIRONMENT_SET_VARIABLES: c_uint = 16;
pub const ENVIRONMENT_GET_VARIABLE_UPDATE: c_uint = 17;

pub const PIXEL_FORMAT_0RGB1555: c_uint = 0;
pub const PIXEL_FORMAT_XRGB8888: c_uint = 1;
pub const PIXEL_FORMAT_RGB565: c_uint = 2;

pub const REGION_NTSC: c_uint = 0;

/// What the frontend shows in its control menu. This core fills it in
/// AFTER load, from the key map it derived for that particular movie —
/// "A — Z" for one game and "A — Enter" for the next.
pub const ENVIRONMENT_SET_INPUT_DESCRIPTORS: c_uint = 11;

pub const InputDescriptor = extern struct {
    port: c_uint,
    device: c_uint,
    index: c_uint,
    id: c_uint,
    /// Null terminates the array.
    description: ?[*:0]const u8,
};

pub const DEVICE_JOYPAD: c_uint = 1;
pub const DEVICE_ANALOG: c_uint = 5;
/// Absolute, in [-0x7fff, 0x7fff] across the presented image — a
/// touchscreen or a mouse, which is what the pointer-driven movies want.
pub const DEVICE_POINTER: c_uint = 6;
pub const DEVICE_ID_JOYPAD_B: c_uint = 0;
pub const DEVICE_ID_JOYPAD_Y: c_uint = 1;
pub const DEVICE_ID_JOYPAD_SELECT: c_uint = 2;
pub const DEVICE_ID_JOYPAD_START: c_uint = 3;
pub const DEVICE_ID_JOYPAD_UP: c_uint = 4;
pub const DEVICE_ID_JOYPAD_DOWN: c_uint = 5;
pub const DEVICE_ID_JOYPAD_LEFT: c_uint = 6;
pub const DEVICE_ID_JOYPAD_RIGHT: c_uint = 7;
pub const DEVICE_ID_JOYPAD_A: c_uint = 8;
pub const DEVICE_ID_JOYPAD_X: c_uint = 9;
pub const DEVICE_ID_JOYPAD_L: c_uint = 10;
pub const DEVICE_ID_JOYPAD_R: c_uint = 11;
pub const DEVICE_ID_JOYPAD_L2: c_uint = 12;
pub const DEVICE_ID_JOYPAD_R2: c_uint = 13;
pub const DEVICE_ID_JOYPAD_L3: c_uint = 14;
pub const DEVICE_ID_JOYPAD_R3: c_uint = 15;

pub const INDEX_ANALOG_LEFT: c_uint = 0;
pub const INDEX_ANALOG_RIGHT: c_uint = 1;
pub const DEVICE_ID_ANALOG_X: c_uint = 0;
pub const DEVICE_ID_ANALOG_Y: c_uint = 1;

pub const DEVICE_ID_POINTER_X: c_uint = 0;
pub const DEVICE_ID_POINTER_Y: c_uint = 1;
pub const DEVICE_ID_POINTER_PRESSED: c_uint = 2;

/// The CORE OPTIONS v2 interface. The old `SET_VARIABLES` is declared
/// once, before any content exists, and RetroArch ignores a second call —
/// measured, not assumed: it logs both calls and keeps the first list. v2
/// can be re-declared after load, which is the only way an option's
/// values can be "the keys THIS movie reads".
pub const ENVIRONMENT_GET_CORE_OPTIONS_VERSION: c_uint = 52;
pub const ENVIRONMENT_SET_CORE_OPTIONS_V2: c_uint = 67;

/// libretro.h's own cap, and the array is INLINE in the definition.
pub const NUM_CORE_OPTION_VALUES_MAX: usize = 128;

pub const CoreOptionValue = extern struct {
    value: ?[*:0]const u8 = null,
    label: ?[*:0]const u8 = null,
};

pub const CoreOptionV2Category = extern struct {
    key: ?[*:0]const u8 = null,
    desc: ?[*:0]const u8 = null,
    info: ?[*:0]const u8 = null,
};

pub const CoreOptionV2Definition = extern struct {
    key: ?[*:0]const u8 = null,
    desc: ?[*:0]const u8 = null,
    desc_categorized: ?[*:0]const u8 = null,
    info: ?[*:0]const u8 = null,
    info_categorized: ?[*:0]const u8 = null,
    category_key: ?[*:0]const u8 = null,
    values: [NUM_CORE_OPTION_VALUES_MAX]CoreOptionValue = @splat(.{}),
    default_value: ?[*:0]const u8 = null,
};

pub const CoreOptionsV2 = extern struct {
    categories: ?[*]CoreOptionV2Category,
    definitions: ?[*]CoreOptionV2Definition,
};

/// The frontend's logger. Worth having: a core that prints to stderr is
/// invisible inside RetroArch, and the input map this core DERIVES from
/// the movie is exactly the thing you want to read back.
pub const ENVIRONMENT_GET_LOG_INTERFACE: c_uint = 27;

pub const LOG_INFO: c_uint = 1;
pub const LOG_WARN: c_uint = 2;

pub const LogCallback = extern struct {
    log: ?*const fn (c_uint, [*:0]const u8, ...) callconv(.c) void,
};

pub const MEMORY_SAVE_RAM: c_uint = 0;
pub const MEMORY_SYSTEM_RAM: c_uint = 2;

pub const SystemInfo = extern struct {
    library_name: [*:0]const u8,
    library_version: [*:0]const u8,
    valid_extensions: [*:0]const u8,
    need_fullpath: bool,
    block_extract: bool,
};

pub const GameGeometry = extern struct {
    base_width: c_uint,
    base_height: c_uint,
    max_width: c_uint,
    max_height: c_uint,
    aspect_ratio: f32,
};

pub const SystemTiming = extern struct {
    fps: f64,
    sample_rate: f64,
};

pub const SystemAvInfo = extern struct {
    geometry: GameGeometry,
    timing: SystemTiming,
};

/// One `key`/`value` core-option row; `value` is "Description; opt1|opt2|...".
/// A `Variable` array is terminated by an all-null entry.
pub const Variable = extern struct {
    key: ?[*:0]const u8,
    value: ?[*:0]const u8,
};

pub const GameInfo = extern struct {
    path: ?[*:0]const u8,
    data: ?*const anyopaque,
    size: usize,
    meta: ?[*:0]const u8,
};

pub const EnvironmentFn = ?*const fn (c_uint, ?*anyopaque) callconv(.c) bool;
pub const VideoRefreshFn = ?*const fn (?*const anyopaque, c_uint, c_uint, usize) callconv(.c) void;
pub const AudioSampleFn = ?*const fn (i16, i16) callconv(.c) void;
pub const AudioSampleBatchFn = ?*const fn (?[*]const i16, usize) callconv(.c) usize;
pub const InputPollFn = ?*const fn () callconv(.c) void;
pub const InputStateFn = ?*const fn (c_uint, c_uint, c_uint, c_uint) callconv(.c) i16;
