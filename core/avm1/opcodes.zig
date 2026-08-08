//! AVM1 action decoding — the full 0x00–0x9F catalog.
//!
//! Spec: reference/openflash/open-flash/content/documentation/avm1/actions/
//! (complete per-action pages incl. corrections) cross-checked against
//! reference/ruffle/swf/src/avm1/{opcode,types,read}.rs. Encoding rule:
//! code < 0x80 has no payload; code >= 0x80 is followed by u16le length.
//! Jump/If offsets are SIGNED and relative to the position AFTER the
//! action (they may legally land mid-action — the interpreter just seeks).
//! Push doubles use LE32_FLOAT64 (errata: byte order 45670123).
//!
//! Decoding is allocation-free: variable payloads (Push runs, function
//! bodies, Try blocks) come back as raw slices into the movie buffer.

const std = @import("std");
const rdr = @import("../swf/reader.zig");

pub const Error = rdr.Error;

pub const OpCode = enum(u8) {
    end = 0x00,
    next_frame = 0x04,
    previous_frame = 0x05,
    play = 0x06,
    stop = 0x07,
    toggle_quality = 0x08,
    stop_sounds = 0x09,
    add = 0x0a,
    subtract = 0x0b,
    multiply = 0x0c,
    divide = 0x0d,
    equals = 0x0e,
    less = 0x0f,
    and_op = 0x10,
    or_op = 0x11,
    not = 0x12,
    string_equals = 0x13,
    string_length = 0x14,
    string_extract = 0x15,
    pop = 0x17,
    to_integer = 0x18,
    get_variable = 0x1c,
    set_variable = 0x1d,
    set_target2 = 0x20,
    string_add = 0x21,
    get_property = 0x22,
    set_property = 0x23,
    clone_sprite = 0x24,
    remove_sprite = 0x25,
    trace = 0x26,
    start_drag = 0x27,
    end_drag = 0x28,
    string_less = 0x29,
    throw = 0x2a,
    cast_op = 0x2b,
    implements_op = 0x2c,
    fs_command2 = 0x2d,
    random_number = 0x30,
    mb_string_length = 0x31,
    char_to_ascii = 0x32,
    ascii_to_char = 0x33,
    get_time = 0x34,
    mb_string_extract = 0x35,
    mb_char_to_ascii = 0x36,
    mb_ascii_to_char = 0x37,
    delete = 0x3a,
    delete2 = 0x3b,
    define_local = 0x3c,
    call_function = 0x3d,
    return_op = 0x3e,
    modulo = 0x3f,
    new_object = 0x40,
    define_local2 = 0x41,
    init_array = 0x42,
    init_object = 0x43,
    type_of = 0x44,
    target_path = 0x45,
    enumerate = 0x46,
    add2 = 0x47,
    less2 = 0x48,
    equals2 = 0x49,
    to_number = 0x4a,
    to_string = 0x4b,
    push_duplicate = 0x4c,
    stack_swap = 0x4d,
    get_member = 0x4e,
    set_member = 0x4f,
    increment = 0x50,
    decrement = 0x51,
    call_method = 0x52,
    new_method = 0x53,
    instance_of = 0x54,
    enumerate2 = 0x55,
    bit_and = 0x60,
    bit_or = 0x61,
    bit_xor = 0x62,
    bit_lshift = 0x63,
    bit_rshift = 0x64,
    bit_urshift = 0x65,
    strict_equals = 0x66,
    greater = 0x67,
    string_greater = 0x68,
    extends_op = 0x69,
    goto_frame = 0x81,
    get_url = 0x83,
    store_register = 0x87,
    constant_pool = 0x88,
    strict_mode = 0x89,
    wait_for_frame = 0x8a,
    set_target = 0x8b,
    goto_label = 0x8c,
    wait_for_frame2 = 0x8d,
    define_function2 = 0x8e,
    try_op = 0x8f,
    with_op = 0x94,
    push = 0x96,
    jump = 0x99,
    get_url2 = 0x9a,
    define_function = 0x9b,
    if_op = 0x9d,
    call = 0x9e,
    goto_frame2 = 0x9f,
    _,
};

pub const FunctionParam = struct {
    name: []const u8,
    /// DefineFunction2: 0 = bind to a named local, else register index.
    register: u8 = 0,
};

/// DefineFunction2 preload/suppress flags (open-flash define-function2.md).
pub const Function2Flags = packed struct(u16) {
    preload_this: bool,
    suppress_this: bool,
    preload_arguments: bool,
    suppress_arguments: bool,
    preload_super: bool,
    suppress_super: bool,
    preload_root: bool,
    preload_parent: bool,
    preload_global: bool,
    _reserved: u7,
};

pub const Action = union(enum) {
    // No-payload stack/arith/etc. carry only their opcode.
    simple: OpCode,

    goto_frame: u16,
    goto_label: []const u8,
    get_url: struct { url: []const u8, target: []const u8 },
    store_register: u8,
    /// Raw pool payload: count u16 + NUL strings (parsed by the VM once).
    constant_pool: struct { count: u16, raw: []const u8 },
    strict_mode: bool,
    wait_for_frame: struct { frame: u16, skip_count: u8 },
    set_target: []const u8,
    wait_for_frame2: struct { skip_count: u8 },
    define_function2: struct {
        name: []const u8,
        register_count: u8,
        flags: Function2Flags,
        /// Raw params: register u8 + NUL name, × param_count.
        param_count: u16,
        params_raw: []const u8,
        body: []const u8,
    },
    try_op: struct {
        catch_in_register: bool,
        has_catch: bool,
        has_finally: bool,
        catch_name: []const u8,
        catch_register: u8,
        try_body: []const u8,
        catch_body: []const u8,
        finally_body: []const u8,
    },
    with_op: struct { body: []const u8 },
    /// Raw run of typed values; iterate with PushIterator.
    push: []const u8,
    jump: i16,
    get_url2: struct {
        /// Errata: SWF19 lists the flag order BACKWARDS. The real byte is
        /// bits 0-1 = send method, bit 6 = LoadTarget, bit 7 = LoadVariables
        /// (ruffle swf/src/avm1/types.rs `GetUrlFlags`) — and a real
        /// `loadVariables(url, clip)` sets 0xC0, both high bits, which the
        /// spec's layout would read as a nonexistent method 3.
        send_vars_method: u2, // 0=none, 1=GET, 2=POST
        is_target_sprite: bool,
        is_load_vars: bool,
    },
    define_function: struct {
        name: []const u8,
        param_count: u16,
        /// Raw params: NUL name × param_count.
        params_raw: []const u8,
        body: []const u8,
    },
    if_op: i16,
    goto_frame2: struct { set_playing: bool, scene_offset: u16 },
    /// Unknown/invalid opcode — skipped by length.
    unknown: struct { opcode: u8, payload: []const u8 },
};

/// One decoded action + where the NEXT action starts (for jump math the
/// interpreter uses reader positions directly).
pub fn readAction(r: *rdr.Reader) Error!?Action {
    if (r.atEnd()) return null;
    const raw_op = try r.readU8();
    const op: OpCode = @enumFromInt(raw_op);
    if (raw_op < 0x80) {
        if (raw_op == 0) return null; // End
        return .{ .simple = op };
    }
    const len = try r.readU16();
    const body = try r.readSlice(@min(len, r.remaining()));
    var br = rdr.Reader.init(body);
    return switch (op) {
        .goto_frame => .{ .goto_frame = try br.readU16() },
        .goto_label => .{ .goto_label = try br.readString() },
        .get_url => .{ .get_url = .{
            .url = try br.readString(),
            .target = try br.readString(),
        } },
        .store_register => .{ .store_register = try br.readU8() },
        .constant_pool => .{ .constant_pool = .{
            .count = try br.readU16(),
            .raw = br.readRest(),
        } },
        .strict_mode => .{ .strict_mode = (try br.readU8()) != 0 },
        .wait_for_frame => .{ .wait_for_frame = .{
            .frame = try br.readU16(),
            .skip_count = try br.readU8(),
        } },
        .set_target => .{ .set_target = try br.readString() },
        .wait_for_frame2 => .{ .wait_for_frame2 = .{ .skip_count = try br.readU8() } },
        .define_function2 => blk: {
            const name = try br.readString();
            const param_count = try br.readU16();
            const register_count = try br.readU8();
            const flags: Function2Flags = @bitCast(try br.readU16());
            const params_start = br.pos;
            var i: u16 = 0;
            while (i < param_count) : (i += 1) {
                _ = try br.readU8();
                _ = try br.readString();
            }
            const params_raw = body[params_start..br.pos];
            const body_len = try br.readU16();
            // Function body follows the action in the OUTER stream.
            const fn_body = try r.readSlice(@min(body_len, r.remaining()));
            break :blk .{ .define_function2 = .{
                .name = name,
                .register_count = register_count,
                .flags = flags,
                .param_count = param_count,
                .params_raw = params_raw,
                .body = fn_body,
            } };
        },
        .try_op => blk: {
            const flags = try br.readU8();
            const catch_in_register = (flags & 0b100) != 0;
            const has_finally = (flags & 0b010) != 0;
            const has_catch = (flags & 0b001) != 0;
            const try_size = try br.readU16();
            const catch_size = try br.readU16();
            const finally_size = try br.readU16();
            var catch_name: []const u8 = "";
            var catch_register: u8 = 0;
            if (catch_in_register) {
                catch_register = try br.readU8();
            } else {
                catch_name = try br.readString();
            }
            const try_body = try r.readSlice(@min(try_size, r.remaining()));
            const catch_body = try r.readSlice(@min(catch_size, r.remaining()));
            const finally_body = try r.readSlice(@min(finally_size, r.remaining()));
            break :blk .{ .try_op = .{
                .catch_in_register = catch_in_register,
                .has_catch = has_catch,
                .has_finally = has_finally,
                .catch_name = catch_name,
                .catch_register = catch_register,
                .try_body = try_body,
                .catch_body = catch_body,
                .finally_body = finally_body,
            } };
        },
        .with_op => blk: {
            const size = try br.readU16();
            const with_body = try r.readSlice(@min(size, r.remaining()));
            break :blk .{ .with_op = .{ .body = with_body } };
        },
        .push => .{ .push = body },
        .jump => .{ .jump = try br.readI16() },
        .get_url2 => blk: {
            const flags = try br.readU8();
            break :blk .{ .get_url2 = .{
                .send_vars_method = @intCast(flags & 0b11),
                .is_target_sprite = (flags & 0b0100_0000) != 0,
                .is_load_vars = (flags & 0b1000_0000) != 0,
            } };
        },
        .define_function => blk: {
            const name = try br.readString();
            const param_count = try br.readU16();
            const params_start = br.pos;
            var i: u16 = 0;
            while (i < param_count) : (i += 1) _ = try br.readString();
            const params_raw = body[params_start..br.pos];
            const body_len = try br.readU16();
            const fn_body = try r.readSlice(@min(body_len, r.remaining()));
            break :blk .{ .define_function = .{
                .name = name,
                .param_count = param_count,
                .params_raw = params_raw,
                .body = fn_body,
            } };
        },
        .if_op => .{ .if_op = try br.readI16() },
        .goto_frame2 => blk: {
            const flags = try br.readU8();
            const has_bias = (flags & 0b10) != 0;
            break :blk .{ .goto_frame2 = .{
                .set_playing = (flags & 0b01) != 0,
                .scene_offset = if (has_bias) try br.readU16() else 0,
            } };
        },
        // Call (0x9E) carries a length field like every other >= 0x80
        // opcode, but its body is EMPTY — the frame reference comes off
        // the stack. Without this it fell through to `.unknown` and its
        // dispatch arm was unreachable.
        .call => .{ .simple = .call },
        else => .{ .unknown = .{ .opcode = raw_op, .payload = body } },
    };
}

/// Push typed values — iterate a Push action's raw payload.
pub const PushValue = union(enum) {
    string: []const u8,
    float: f32,
    null_value,
    undefined_value,
    register: u8,
    boolean: bool,
    double: f64,
    /// ActionPush type 7 is SIGNED (ruffle read.rs:328 read_i32).
    int: i32,
    const8: u8,
    const16: u16,
};

pub const PushIterator = struct {
    r: rdr.Reader,

    pub fn init(raw: []const u8) PushIterator {
        return .{ .r = rdr.Reader.init(raw) };
    }

    pub fn next(self: *PushIterator) ?PushValue {
        if (self.r.atEnd()) return null;
        const t = self.r.readU8() catch return null;
        return switch (t) {
            0 => .{ .string = self.r.readString() catch return null },
            1 => .{ .float = self.r.readF32() catch return null },
            2 => .null_value,
            3 => .undefined_value,
            4 => .{ .register = self.r.readU8() catch return null },
            5 => .{ .boolean = (self.r.readU8() catch return null) != 0 },
            6 => .{ .double = self.r.readF64Swapped() catch return null },
            7 => .{ .int = self.r.readI32() catch return null },
            8 => .{ .const8 = self.r.readU8() catch return null },
            9 => .{ .const16 = self.r.readU16() catch return null },
            else => null, // invalid type kills the rest of the run
        };
    }
};

/// Iterate DefineFunction(2) params from their raw slice.
pub const ParamIterator = struct {
    r: rdr.Reader,
    with_registers: bool,

    pub fn init(raw: []const u8, with_registers: bool) ParamIterator {
        return .{ .r = rdr.Reader.init(raw), .with_registers = with_registers };
    }

    pub fn next(self: *ParamIterator) ?FunctionParam {
        if (self.r.atEnd()) return null;
        var p: FunctionParam = .{ .name = "" };
        if (self.with_registers) {
            p.register = self.r.readU8() catch return null;
        }
        p.name = self.r.readString() catch return null;
        return p;
    }
};

// --- Tests -----------------------------------------------------------------

test "decode simple ops, push runs, jumps" {
    // Push "hi", double 1.0, int 7; Add2; If +3; Trace; End.
    const code = [_]u8{ 0x96, 18, 0, 0x00 } ++ "hi\x00".* ++
        [_]u8{ 6, 0x00, 0x00, 0xF0, 0x3F, 0x00, 0x00, 0x00, 0x00 } ++
        [_]u8{ 7, 7, 0, 0, 0 } ++
        [_]u8{0x47} ++
        [_]u8{ 0x9D, 2, 0, 3, 0 } ++
        [_]u8{0x26} ++
        [_]u8{0x00};
    var r = rdr.Reader.init(&code);

    const a1 = (try readAction(&r)).?;
    var it = PushIterator.init(a1.push);
    try std.testing.expectEqualStrings("hi", it.next().?.string);
    try std.testing.expectEqual(@as(f64, 1.0), it.next().?.double);
    try std.testing.expectEqual(@as(i32, 7), it.next().?.int);
    try std.testing.expectEqual(@as(?PushValue, null), it.next());

    try std.testing.expectEqual(OpCode.add2, (try readAction(&r)).?.simple);
    try std.testing.expectEqual(@as(i16, 3), (try readAction(&r)).?.if_op);
    try std.testing.expectEqual(OpCode.trace, (try readAction(&r)).?.simple);
    try std.testing.expectEqual(@as(?Action, null), try readAction(&r));
}

test "decode DefineFunction2 with registers and body in outer stream" {
    // name "f", 2 params (r1 "a", r0 "b"), 3 registers, flags preload_this,
    // body = Return; End marker after.
    const code = [_]u8{ 0x8E, 13, 0 } ++ "f\x00".* ++
        [_]u8{ 2, 0 } ++ // param count
        [_]u8{3} ++ // register count
        [_]u8{ 0x01, 0x00 } ++ // flags: preload_this
        [_]u8{1} ++ "a\x00".* ++ [_]u8{0} ++ "b\x00".* ++
        [_]u8{ 1, 0 } ++ // body len = 1
        [_]u8{0x3E} ++ // body: Return
        [_]u8{0x00};
    // Wait: params (1+2)+(1+2)=6 bytes; header = 2+2+1+2+6+2 = 15. Fix len:
    var fixed = code;
    fixed[1] = 15;
    var r = rdr.Reader.init(&fixed);
    const a = (try readAction(&r)).?;
    const f = a.define_function2;
    try std.testing.expectEqualStrings("f", f.name);
    try std.testing.expectEqual(@as(u8, 3), f.register_count);
    try std.testing.expect(f.flags.preload_this);
    try std.testing.expect(!f.flags.preload_global);
    var params = ParamIterator.init(f.params_raw, true);
    const p1 = params.next().?;
    try std.testing.expectEqual(@as(u8, 1), p1.register);
    try std.testing.expectEqualStrings("a", p1.name);
    try std.testing.expectEqualStrings("b", params.next().?.name);
    try std.testing.expectEqual(@as(usize, 1), f.body.len);
    try std.testing.expectEqual(@as(u8, 0x3E), f.body[0]);
    // Next action after the body is End → null.
    try std.testing.expectEqual(@as(?Action, null), try readAction(&r));
}

test "decode GetURL2 errata flag order and GotoFrame2 bias" {
    // SWF19 lists these bits backwards. Real bytes: 0x41 = LoadTarget
    // (bit 6) plus method 1 (GET), and 0xC0 — the byte the Flash compiler
    // actually emits for `loadVariables(url, clip)` — is BOTH high flags
    // with no method, which the spec's layout would decode as method 3.
    const code = [_]u8{ 0x9A, 1, 0, 0b0100_0001 } ++
        [_]u8{ 0x9A, 1, 0, 0b1100_0000 } ++
        [_]u8{ 0x9F, 3, 0, 0b11, 4, 0 } ++ // goto2: bias present, play, scene 4
        [_]u8{0x00};
    var r = rdr.Reader.init(&code);
    const u = (try readAction(&r)).?.get_url2;
    try std.testing.expectEqual(@as(u2, 1), u.send_vars_method);
    try std.testing.expect(u.is_target_sprite);
    try std.testing.expect(!u.is_load_vars);
    const lv = (try readAction(&r)).?.get_url2;
    try std.testing.expectEqual(@as(u2, 0), lv.send_vars_method);
    try std.testing.expect(lv.is_target_sprite);
    try std.testing.expect(lv.is_load_vars);
    const g = (try readAction(&r)).?.goto_frame2;
    try std.testing.expect(g.set_playing);
    try std.testing.expectEqual(@as(u16, 4), g.scene_offset);
}
