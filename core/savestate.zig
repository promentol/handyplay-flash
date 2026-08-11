//! Save-states: the whole mutable machine, framed by the container every
//! Handyplay core shares (`vendor/statefmt`, ADR D5).
//!
//! **A state carries only what cannot be RE-DERIVED from the movie.**
//! Restoring means building a fresh `Player` from the same SWF bytes and
//! applying the state over it, so the character library, decoded shapes,
//! glyph caches, decoded library sounds and the prototype objects the
//! globals installer builds are never written. What is left is the
//! mutable graph: the display tree, the AVM1 heap, and a pile of scalars.
//!
//! That rule is also the rewind budget. A libretro frontend implements
//! rewind by XOR-ing consecutive states, so the cost per frame is what
//! CHANGED, and the heavy immutable things (a loaded child movie, an
//! untouched bitmap) fall out of the delta entirely as long as they sit
//! at stable offsets. Hence the section order below, and hence D1-D4 in
//! `vendor/statefmt/statefmt.zig`, which are rules this module has to
//! obey rather than advice:
//!
//!   D1  fixed-size sections first, variable-size last
//!   D2  16-byte relative alignment (SectionWriter does it)
//!   D3  no indeterminate bytes — every field written explicitly, little
//!       endian, never a memcpy of a non-extern struct
//!   D4  `serialize_size` constant across a run
//!
//! One consequence of D3 that is easy to miss: anything serialized by
//! ITERATING A HASH MAP must be written in sorted key order. Hash order
//! depends on insertion history, so a restored map re-serializes in a
//! different order and two states of identical content stop matching.
//!
//! **SharedObject/LSO is excluded**, unchanged from ADR D5: rewinding
//! past a write must not un-write it.

const std = @import("std");
const statefmt = @import("statefmt");
const object_mod = @import("avm1/object.zig");
const value_mod = @import("avm1/value.zig");
const runtime = @import("avm1/runtime.zig");
const strings_mod = @import("avm1/string.zig");
const opcodes = @import("avm1/opcodes.zig");
const timers_mod = @import("avm1/timers.zig");
const natives = @import("avm1/natives.zig");

const Value = value_mod.Value;
const ObjectHandle = runtime.ObjectHandle;
const ScriptObject = object_mod.ScriptObject;

pub const MAGIC = statefmt.tag("HFSS");

/// One format, no migrations: a mismatch is refused outright rather than
/// half-read. There are no state files in the wild.
pub const CORE_VERSION: u32 = 1;

/// `flash_core`. Upstream reserves 7..15 for future cores and ADR D5
/// claims 7; done by value rather than by editing the vendored enum, so
/// the vendored file stays a verbatim copy.
pub const FORMAT: statefmt.Format = @enumFromInt(7);

pub const Error = error{
    BadMagic,
    BadVersion,
    Truncated,
    /// A section's payload failed its own reader.
    SectionCorrupt,
    /// The state was taken from a different movie.
    MovieMismatch,
    NoSpaceLeft,
    OutOfMemory,
};

/// Section tags, in the order they are written. Fixed-size first (D1);
/// everything that can change length trails behind it.
pub const Tag = enum(u32) {
    /// Player scalars — the frame clock, input, and the flags a frontend
    /// can see.
    plyr = statefmt.tag("PLYR"),
    /// The `Vm`'s own scalars and prototype handles.
    vmsc = statefmt.tag("VMSC"),
    /// setInterval/setTimeout.
    timr = statefmt.tag("TIMR"),
    /// The mixer's voice table.
    audi = statefmt.tag("AUDI"),
    /// The display tree.
    disp = statefmt.tag("DISP"),
    /// The AVM1 object table.
    heap = statefmt.tag("HEAP"),
    /// Every string the heap references, once.
    strs = statefmt.tag("STRS"),
    /// The AVM1 constant pools. Every `Push cpN` in every closure indexes
    /// into these, so a state without them restores a movie whose scripts
    /// all read `undefined`.
    pool = statefmt.tag("POOL"),
    /// Native payloads: bitmaps, XML, text formats, streams.
    natv = statefmt.tag("NATV"),
    /// Loaded child movies, verbatim.
    movs = statefmt.tag("MOVS"),
};

/// The tag a section magic names, or null for one this build predates.
/// Not `@enumFromInt`: that is undefined for a value outside the set.
pub fn tagOf(magic: u32) ?Tag {
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        if (f.value == magic) return @enumFromInt(f.value);
    }
    return null;
}

const ENVELOPE: statefmt.Expect = .{
    .magic = MAGIC,
    .version = CORE_VERSION,
    .format = FORMAT,
};

pub fn envelope() statefmt.Expect {
    return ENVELOPE;
}

pub fn section(t: Tag) statefmt.Expect {
    return .{ .magic = @intFromEnum(t), .version = CORE_VERSION, .format = FORMAT };
}

fn sec(t: Tag) statefmt.Expect {
    return section(t);
}

// --- primitives -----------------------------------------------------------
//
// Explicit, little-endian, one field at a time. Never `@memcpy` a
// non-extern struct: its padding is `undefined` and D3 forbids that.

pub const Writer = struct {
    w: *statefmt.SectionWriter,

    pub fn u8v(self: Writer, v: u8) !void {
        try self.w.write(&[_]u8{v});
    }
    pub fn boolv(self: Writer, v: bool) !void {
        try self.u8v(@intFromBool(v));
    }
    pub fn u16v(self: Writer, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.w.write(&b);
    }
    pub fn u32v(self: Writer, v: u32) !void {
        try self.w.writeU32(v);
    }
    pub fn i32v(self: Writer, v: i32) !void {
        try self.u32v(@bitCast(v));
    }
    pub fn u64v(self: Writer, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try self.w.write(&b);
    }
    pub fn f64v(self: Writer, v: f64) !void {
        // A NaN's payload bits are not a function of state — canonicalise
        // it, or two identical machines can produce different bytes (D3).
        try self.u64v(@bitCast(if (std.math.isNan(v)) std.math.nan(f64) else v));
    }
    pub fn bytes(self: Writer, b: []const u8) !void {
        try self.u32v(@intCast(b.len));
        try self.w.write(b);
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn u8v(self: *Reader) Error!u8 {
        if (self.pos + 1 > self.buf.len) return Error.Truncated;
        defer self.pos += 1;
        return self.buf[self.pos];
    }
    pub fn boolv(self: *Reader) Error!bool {
        return (try self.u8v()) != 0;
    }
    pub fn u16v(self: *Reader) Error!u16 {
        if (self.pos + 2 > self.buf.len) return Error.Truncated;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.buf[self.pos..][0..2], .little);
    }
    pub fn u32v(self: *Reader) Error!u32 {
        if (self.pos + 4 > self.buf.len) return Error.Truncated;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
    }
    pub fn i32v(self: *Reader) Error!i32 {
        return @bitCast(try self.u32v());
    }
    pub fn u64v(self: *Reader) Error!u64 {
        if (self.pos + 8 > self.buf.len) return Error.Truncated;
        defer self.pos += 8;
        return std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
    }
    pub fn f64v(self: *Reader) Error!f64 {
        return @bitCast(try self.u64v());
    }
    pub fn bytes(self: *Reader) Error![]const u8 {
        const n = try self.u32v();
        if (self.pos + n > self.buf.len) return Error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }
};

// --- exhaustive scalar walking -------------------------------------------
//
// A hand-written field list rots: someone adds a field to `Vm` and the
// state silently stops covering it, which shows up months later as a
// restore that is subtly wrong. So the walk is COMPTIME and total —
// every field is either serialized by type or named in `skip`, and a new
// field that is neither fails the build.

/// Types this walker knows how to write. Everything else must be skipped
/// by name, which is a decision someone had to make on purpose.
fn writable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float => true,
        .@"enum" => true,
        .array => |a| writable(a.child),
        // An optional is a presence byte and, when present, the payload.
        // Worth supporting rather than skipping: `?i32`, `?bool` and
        // `?u16` are all over the display objects and every one of them
        // is real state.
        .optional => |o| writable(o.child),
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                if (!writable(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn skipped(comptime name: []const u8, comptime skip: []const []const u8) bool {
    // 131 fields against a 30-name list is a lot of comptime string
    // compares, and the default quota is 1000.
    @setEvalBranchQuota(200_000);
    inline for (skip) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

pub fn writeScalars(
    comptime T: type,
    value: *const T,
    w: Writer,
    comptime skip: []const []const u8,
) !void {
    @setEvalBranchQuota(200_000);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime skipped(f.name, skip)) continue;
        if (comptime !writable(f.type)) {
            @compileError("savestate: " ++ @typeName(T) ++ "." ++ f.name ++
                " is neither writable nor listed in the skip set — classify it");
        }
        try writeOne(f.type, @field(value, f.name), w);
    }
}

pub fn readScalars(
    comptime T: type,
    value: *T,
    r: *Reader,
    comptime skip: []const []const u8,
) Error!void {
    @setEvalBranchQuota(200_000);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime skipped(f.name, skip)) continue;
        @field(value, f.name) = try readOne(f.type, r);
    }
}

fn writeOne(comptime T: type, v: T, w: Writer) !void {
    switch (@typeInfo(T)) {
        .bool => try w.boolv(v),
        .int => |i| {
            // Widened by SIGNEDNESS, then written at a fixed width, so a
            // `u2` and an `i32` both come back as themselves.
            if (i.signedness == .unsigned) {
                const x: u64 = v;
                if (i.bits <= 8) try w.u8v(@intCast(x)) else if (i.bits <= 16) try w.u16v(@intCast(x)) else if (i.bits <= 32) try w.u32v(@intCast(x)) else try w.u64v(x);
            } else {
                const x: i64 = v;
                if (i.bits <= 8) try w.u8v(@bitCast(@as(i8, @intCast(x)))) else if (i.bits <= 16) try w.u16v(@bitCast(@as(i16, @intCast(x)))) else if (i.bits <= 32) try w.i32v(@intCast(x)) else try w.u64v(@bitCast(x));
            }
        },
        .float => try w.f64v(@floatCast(v)),
        .@"enum" => |e| try writeOne(e.tag_type, @intFromEnum(v), w),
        .array => for (v) |e| try writeOne(@TypeOf(e), e, w),
        .optional => |o| {
            try w.boolv(v != null);
            // The absent case still writes a payload, so an optional is
            // FIXED SIZE — a section whose length changed with a null
            // would shift every offset after it and wreck the delta (D1).
            try writeOne(o.child, v orelse std.mem.zeroes(o.child), w);
        },
        .@"struct" => |st| {
            inline for (st.fields) |f| try writeOne(f.type, @field(v, f.name), w);
        },
        else => @compileError("savestate: cannot write " ++ @typeName(T)),
    }
}

fn readOne(comptime T: type, r: *Reader) Error!T {
    return switch (@typeInfo(T)) {
        .bool => try r.boolv(),
        .int => |i| blk: {
            if (i.signedness == .unsigned) {
                const x: u64 = if (i.bits <= 8)
                    try r.u8v()
                else if (i.bits <= 16)
                    try r.u16v()
                else if (i.bits <= 32)
                    try r.u32v()
                else
                    try r.u64v();
                break :blk @intCast(x);
            }
            const x: i64 = if (i.bits <= 8)
                @as(i8, @bitCast(try r.u8v()))
            else if (i.bits <= 16)
                @as(i16, @bitCast(try r.u16v()))
            else if (i.bits <= 32)
                try r.i32v()
            else
                @bitCast(try r.u64v());
            break :blk @intCast(x);
        },
        .float => @floatCast(try r.f64v()),
        .@"enum" => |e| @enumFromInt(try readOne(e.tag_type, r)),
        .array => |a| blk: {
            var out: T = undefined;
            for (&out) |*e| e.* = try readOne(a.child, r);
            break :blk out;
        },
        .optional => |o| blk: {
            const present = try r.boolv();
            const v = try readOne(o.child, r);
            break :blk if (present) v else null;
        },
        .@"struct" => |st| blk: {
            var out: T = undefined;
            inline for (st.fields) |f| @field(out, f.name) = try readOne(f.type, r);
            break :blk out;
        },
        else => @compileError("savestate: cannot read " ++ @typeName(T)),
    };
}

const Mixed = struct {
    flag: bool,
    tiny: u2,
    small: i8,
    mid: u16,
    big: i32,
    huge: u64,
    real: f64,
    tag: enum(u8) { a, b, c },
    bits: [3]bool,
    nested: struct { x: i32, y: f64 },
};

test "the comptime walker round-trips every width and signedness" {
    var buf: [512]u8 = @splat(0);
    const exp: statefmt.Expect = .{ .magic = statefmt.tag("TEST"), .version = 1, .format = FORMAT };
    var sw = try statefmt.SectionWriter.begin(&buf, 0, exp, 0);
    const in: Mixed = .{
        .flag = true,
        .tiny = 3,
        .small = -7,
        .mid = 65535,
        .big = -2147483648,
        .huge = 0xDEAD_BEEF_CAFE_F00D,
        .real = -0.125,
        .tag = .c,
        .bits = .{ true, false, true },
        .nested = .{ .x = -1, .y = 2.5 },
    };
    try writeScalars(Mixed, &in, .{ .w = &sw }, &.{});
    const end = try sw.finish();

    const h = try statefmt.parse(buf[0..end], exp);
    var rd: Reader = .{ .buf = statefmt.payload(buf[0..end], h) };
    var out: Mixed = undefined;
    try readScalars(Mixed, &out, &rd, &.{});
    try std.testing.expectEqual(in, out);
}

test "a skipped field is neither written nor read" {
    var buf: [256]u8 = @splat(0);
    const exp: statefmt.Expect = .{ .magic = statefmt.tag("TES2"), .version = 1, .format = FORMAT };
    var sw = try statefmt.SectionWriter.begin(&buf, 0, exp, 0);
    const in: Mixed = std.mem.zeroInit(Mixed, .{ .big = 42 });
    try writeScalars(Mixed, &in, .{ .w = &sw }, &.{"huge"});
    const end = try sw.finish();
    const h = try statefmt.parse(buf[0..end], exp);
    var rd: Reader = .{ .buf = statefmt.payload(buf[0..end], h) };
    var out: Mixed = undefined;
    out.huge = 99;
    try readScalars(Mixed, &out, &rd, &.{"huge"});
    try std.testing.expectEqual(@as(i32, 42), out.big);
    try std.testing.expectEqual(@as(u64, 99), out.huge); // untouched
}

// --- the AVM1 heap ---------------------------------------------------------
//
// Handles are 1-based indices into `Objects.slots`, which makes them
// stable ids already — no mapping needed, unlike the display tree.
//
// The restore PATCHES the table a fresh boot built rather than replacing
// it. That is what keeps native function pointers alive: the globals
// installer is deterministic, so slot N holds the same built-in on every
// boot, and a slot the state calls a native function keeps whatever the
// live table has in it. Only script-defined objects are rebuilt.

/// Strings are pooled: the heap references them by index, so the same
/// property name written a thousand times costs four bytes each time.
/// The strings a state references, once each.
///
/// It LIVES ACROSS SAVES, and that is the whole point. Rebuilding it per
/// save numbers the strings in first-encounter order, so one new string
/// early in the walk shifts every index after it — and since the heap
/// stores strings BY INDEX, a movie that interns one new string rewrites
/// nearly the entire state. Snake measured 4005 of 4024 STRS words and
/// 21919 of 29460 HEAP words changing in a single frame, which is a
/// ruinous thing to hand a rewind buffer.
///
/// Keeping the pool means an id, once handed out, keeps meaning the same
/// string for the life of the player. The cost is entries for strings
/// nothing references any more, and `compact` reclaims those when they
/// outnumber the live ones — one expensive frame, rarely.
pub const StringPool = struct {
    gpa: std.mem.Allocator,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// OWNED copies: the pool outlives any one save, so it cannot hold
    /// slices into whatever the interpreter happened to have live.
    list: std.ArrayList([]const u16) = .empty,
    /// Which entries this pass asked for — the input to `compact`.
    touched: std.ArrayList(bool) = .empty,

    pub fn deinit(self: *StringPool) void {
        var it = self.index.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.index.deinit(self.gpa);
        for (self.list.items) |s| self.gpa.free(@constCast(s));
        self.list.deinit(self.gpa);
        self.touched.deinit(self.gpa);
    }

    /// The index for `s`, adding it in FIRST-ENCOUNTER order — which is
    /// deterministic because the heap walk is.
    pub fn intern(self: *StringPool, s: []const u16) !u32 {
        const bytes = std.mem.sliceAsBytes(s);
        if (self.index.get(bytes)) |i| {
            if (i < self.touched.items.len) self.touched.items[i] = true;
            return i;
        }
        const owned_key = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned_key);
        const owned = try self.gpa.dupe(u16, s);
        const id: u32 = @intCast(self.list.items.len);
        try self.index.put(self.gpa, owned_key, id);
        try self.list.append(self.gpa, owned);
        try self.touched.append(self.gpa, true);
        return id;
    }

    /// Start a save: nothing is known to be live yet.
    pub fn beginPass(self: *StringPool) void {
        for (self.touched.items) |*t| t.* = false;
    }

    /// Worth renumbering? Only when the dead outnumber the live, and
    /// never for a pool small enough that the churn does not matter.
    pub fn shouldCompact(self: *const StringPool) bool {
        if (self.list.items.len < 256) return false;
        var live: usize = 0;
        for (self.touched.items) |t| {
            if (t) live += 1;
        }
        return self.list.items.len > live * 2;
    }

    /// Drop the untouched entries and renumber. Every index changes, so
    /// this is exactly the churn the pool exists to avoid — which is why
    /// it only runs when the pool has become mostly garbage.
    pub fn compact(self: *StringPool) !void {
        var kept: std.ArrayList([]const u16) = .empty;
        errdefer kept.deinit(self.gpa);
        for (self.list.items, 0..) |sv, i| {
            if (i < self.touched.items.len and self.touched.items[i]) {
                try kept.append(self.gpa, sv);
            } else {
                self.gpa.free(@constCast(sv));
            }
        }
        var it = self.index.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.index.clearRetainingCapacity();
        self.list.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
        for (kept.items) |sv| {
            const key = try self.gpa.dupe(u8, std.mem.sliceAsBytes(sv));
            try self.index.put(self.gpa, key, @intCast(self.list.items.len));
            try self.list.append(self.gpa, sv);
            try self.touched.append(self.gpa, true);
        }
        kept.deinit(self.gpa);
    }

    /// Adopt a restored state's numbering verbatim, so the next save
    /// reproduces the blob it came from.
    pub fn seed(self: *StringPool, strings: []const []const u16) !void {
        var it = self.index.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.index.clearRetainingCapacity();
        for (self.list.items) |sv| self.gpa.free(@constCast(sv));
        self.list.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
        for (strings) |sv| _ = try self.intern(sv);
    }
};

/// Everything the heap writer needs that is not the heap.
pub const SaveCtx = struct {
    pool: *StringPool,
    /// Display object pointer -> the id `DISP` gave it.
    disp_ids: *const std.AutoHashMapUnmanaged(usize, u32),
    /// Movie buffer -> its index in `MOVS` (the root movie is 0).
    movies: []const []const u8,
};

pub const LoadCtx = struct {
    strings: []const []const u16,
    disp: []const ?*anyopaque,
    movies: []const []const u8,
};

fn writeValue(w: Writer, v: Value, ctx: SaveCtx) !void {
    // Fixed width — tag plus eight bytes — so a value that changes KIND
    // does not change the section's length (D1).
    try w.u8v(@intFromEnum(std.meta.activeTag(v)));
    switch (v) {
        .undefined_value, .null_value => try w.u64v(0),
        .boolean => |b| try w.u64v(@intFromBool(b)),
        .number => |n| try w.f64v(n),
        .string => |s| try w.u64v(try ctx.pool.intern(s)),
        .object => |h| try w.u64v(h),
    }
}

fn readValue(r: *Reader, ctx: LoadCtx) Error!Value {
    const tag = try r.u8v();
    const raw = try r.u64v();
    return switch (tag) {
        0 => .undefined_value,
        1 => .null_value,
        2 => .{ .boolean = raw != 0 },
        3 => .{ .number = @bitCast(raw) },
        4 => blk: {
            if (raw >= ctx.strings.len) return Error.SectionCorrupt;
            break :blk .{ .string = ctx.strings[@intCast(raw)] };
        },
        5 => .{ .object = @intCast(raw) },
        else => Error.SectionCorrupt,
    };
}

/// Which strings the heap will need. Run before anything is written, so
/// `STRS` can be laid down ahead of `HEAP`.
pub fn collectStrings(vm: *const runtime.Vm, pool: *StringPool) !void {
    for (vm.class_registry.items) |e| _ = try pool.intern(e.name);
    for (vm.env_lo.class_registry.items) |e| _ = try pool.intern(e.name);
    for (vm.env_hi.class_registry.items) |e| _ = try pool.intern(e.name);
    for (vm.timers.list.items) |t| {
        if (t.callback == .method) _ = try pool.intern(t.callback.method.name);
        for (t.params) |v| {
            if (v == .string) _ = try pool.intern(v.string);
        }
    }
    for (vm.pools.items) |p| {
        for (p) |str| _ = try pool.intern(str);
    }
    for (vm.objects.slots.items) |*o| {
        for (o.props.items) |p| _ = try pool.intern(p.key);
        for (o.watchers) |wt| _ = try pool.intern(wt.key);
        try collectValueString(o.proto, pool);
        for (o.props.items) |p| try collectValueString(p.value, pool);
        for (o.watchers) |wt| try collectValueString(wt.user_data, pool);
        switch (o.native) {
            .boxed_string => |s| _ = try pool.intern(s),
            .function => |f| switch (f) {
                .avm1 => |a| _ = try pool.intern(a.base_clip_path),
                else => {},
            },
            else => {},
        }
    }
}

fn collectValueString(v: Value, pool: *StringPool) !void {
    if (v == .string) _ = try pool.intern(v.string);
}

/// `Object.registerClass` bindings: a linkage name and the constructor
/// it was bound to. Real script state — a movie that registers a class
/// and then attaches a clip gets the wrong object without it.
pub fn writeClasses(w: Writer, vm: *const runtime.Vm, pool: *StringPool) !void {
    try writeRegistry(w, vm.class_registry.items, pool);
    // AND the two dormant environments. `Object.registerClass` is
    // per-case-sensitivity: `useVersion` swaps the whole environment when
    // the running SWF crosses version 7, so a state that carried only the
    // active registry lost every binding the moment a SWF6 movie was
    // loaded — which is what corpus register_class does, two ticks after
    // the save (the constructor never runs, and the prototype check
    // fails).
    try writeRegistry(w, vm.env_lo.class_registry.items, pool);
    try writeRegistry(w, vm.env_hi.class_registry.items, pool);
}

fn writeRegistry(w: Writer, entries: []const runtime.ClassEntry, pool: *StringPool) !void {
    try w.u32v(@intCast(entries.len));
    for (entries) |e| {
        try w.u32v(try pool.intern(e.name));
        try w.u32v(e.ctor);
    }
}

pub fn readClasses(r: *Reader, vm: *runtime.Vm, ctx: LoadCtx) Error!void {
    try readRegistry(r, vm, ctx, &vm.class_registry);
    try readRegistry(r, vm, ctx, &vm.env_lo.class_registry);
    try readRegistry(r, vm, ctx, &vm.env_hi.class_registry);
}

fn readRegistry(
    r: *Reader,
    vm: *runtime.Vm,
    ctx: LoadCtx,
    list: *std.ArrayList(runtime.ClassEntry),
) Error!void {
    const n = try r.u32v();
    list.clearRetainingCapacity();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const name_i = try r.u32v();
        const ctor = try r.u32v();
        if (name_i >= ctx.strings.len) return Error.SectionCorrupt;
        // The VM ARENA, which is what `registerClass` appends with. Mixing
        // the two allocators on one list is the bug that cost the
        // constant pools a day.
        list.append(vm.arena(), .{
            .name = ctx.strings[name_i],
            .ctor = ctor,
        }) catch return Error.OutOfMemory;
    }
}

/// The constant pools, as indices into `STRS`.
/// The timer table. `setInterval`/`setTimeout` are the one place AVM1
/// runs outside the timeline, so a state without them silently drops
/// whatever the content had scheduled — corpus loadmovie_var_persistence
/// loses a whole `loadClip` that a `setTimeout` was going to start.
///
/// It sits after `STRS` because a timer's arguments are VALUES, and a
/// string value is an index into the pool.
pub fn writeTimers(w: Writer, vm: *const runtime.Vm, ctx: SaveCtx) !void {
    try w.i32v(vm.timers.counter);
    try w.u64v(vm.timers.cur_time);
    try w.u32v(@intCast(vm.timers.list.items.len));
    for (vm.timers.list.items) |t| {
        try w.i32v(t.id);
        try w.u64v(t.tick_time);
        try w.u64v(t.interval);
        try w.boolv(t.is_timeout);
        switch (t.callback) {
            .func => |h| {
                try w.u8v(0);
                try w.u32v(h);
                try w.u32v(0);
            },
            .method => |m| {
                try w.u8v(1);
                try w.u32v(m.this);
                try w.u32v(@intCast(try ctx.pool.intern(m.name)));
            },
        }
        try w.u32v(@intCast(t.params.len));
        for (t.params) |v| try writeValue(w, v, ctx);
    }
}

pub fn readTimers(r: *Reader, vm: *runtime.Vm, ctx: LoadCtx) !void {
    vm.timers.counter = try r.i32v();
    vm.timers.cur_time = try r.u64v();
    vm.timers.list.clearRetainingCapacity();
    const n = try r.u32v();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const id = try r.i32v();
        const tick_time = try r.u64v();
        const interval = try r.u64v();
        const is_timeout = try r.boolv();
        const kind = try r.u8v();
        const a = try r.u32v();
        const b = try r.u32v();
        const callback: timers_mod.Callback = switch (kind) {
            0 => .{ .func = a },
            1 => .{ .method = .{
                .this = a,
                .name = if (b < ctx.strings.len) ctx.strings[b] else return Error.SectionCorrupt,
            } },
            else => return Error.SectionCorrupt,
        };
        const n_params = try r.u32v();
        const params = try vm.arena().alloc(Value, n_params);
        for (params) |*v| v.* = try readValue(r, ctx);
        try vm.timers.list.append(vm.gpa, .{
            .id = id,
            .callback = callback,
            .params = params,
            .tick_time = tick_time,
            .interval = interval,
            .is_timeout = is_timeout,
        });
    }
}

pub fn writePools(w: Writer, vm: *const runtime.Vm, pool: *StringPool) !void {
    try w.u32v(vm.active_pool);
    try w.u32v(@intCast(vm.pools.items.len));
    for (vm.pools.items) |p| {
        try w.u32v(@intCast(p.len));
        for (p) |str| try w.u32v(try pool.intern(str));
    }
}

pub fn readPools(r: *Reader, vm: *runtime.Vm, ctx: LoadCtx) Error!void {
    // The LIST is the gpa's (`Vm.destroy` frees it with the gpa); only the
    // pools it points at live in the arena. Appending with the arena is an
    // invalid free at teardown — which is exactly what it was.
    const arena = vm.objects.arena;
    const gpa = vm.gpa;
    vm.active_pool = try r.u32v();
    const n = try r.u32v();
    vm.pools.clearRetainingCapacity();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const len = try r.u32v();
        const p = arena.alloc(strings_mod.AvmString, len) catch return Error.OutOfMemory;
        for (p) |*str| {
            const idx = try r.u32v();
            if (idx >= ctx.strings.len) return Error.SectionCorrupt;
            str.* = ctx.strings[idx];
        }
        vm.pools.append(gpa, p) catch return Error.OutOfMemory;
    }
}

pub fn writeStrings(w: Writer, pool: *const StringPool) !void {
    try w.u32v(@intCast(pool.list.items.len));
    for (pool.list.items) |s| {
        try w.u32v(@intCast(s.len));
        for (s) |c| try w.u16v(c);
    }
}

pub fn readStrings(r: *Reader, arena: std.mem.Allocator) Error![][]const u16 {
    const n = try r.u32v();
    const out = arena.alloc([]const u16, n) catch return Error.OutOfMemory;
    for (out) |*slot| {
        const len = try r.u32v();
        const s = arena.alloc(u16, len) catch return Error.OutOfMemory;
        for (s) |*c| c.* = try r.u16v();
        slot.* = s;
    }
    return out;
}

/// The object table. Slots are written in index order, so a handle IS
/// its position and nothing needs remapping.
pub fn writeHeap(w: Writer, vm: *const runtime.Vm, ctx: SaveCtx) !void {
    try w.u32v(@intCast(vm.objects.slots.items.len));
    for (vm.objects.slots.items) |*o| {
        try writeValue(w, o.proto, ctx);
        try writeAttrs(w, o.proto_attrs);
        try w.u32v(@intCast(o.props.items.len));
        for (o.props.items) |p| {
            try w.u32v(try ctx.pool.intern(p.key));
            try writeValue(w, p.value, ctx);
            try writeAttrs(w, p.attrs);
            try w.u32v(p.getter);
            try w.u32v(p.setter);
            try w.u32v(p.gen);
        }
        try writeNative(w, o.native, ctx);
        try w.boolv(o.is_with_scope);
        try w.u32v(o.scope_values);
        try w.u32v(@intCast(o.interfaces.len));
        for (o.interfaces) |h| try w.u32v(h);
        try w.boolv(o.interfaces_set);
        try w.boolv(o.ctor_propagates);
        try w.u32v(o.scope_parent);
        try w.u32v(@intCast(o.watchers.len));
        for (o.watchers) |wt| {
            try w.u32v(try ctx.pool.intern(wt.key));
            try w.u32v(wt.callback);
            try writeValue(w, wt.user_data, ctx);
        }
    }
}

fn writeAttrs(w: Writer, a: object_mod.Attributes) !void {
    try w.u8v((@as(u8, @intFromBool(a.dont_enum)) << 0) |
        (@as(u8, @intFromBool(a.dont_delete)) << 1) |
        (@as(u8, @intFromBool(a.read_only)) << 2));
}

fn readAttrs(r: *Reader) Error!object_mod.Attributes {
    const b = try r.u8v();
    return .{
        .dont_enum = b & 1 != 0,
        .dont_delete = b & 2 != 0,
        .read_only = b & 4 != 0,
    };
}

/// Native tags. Written as a byte so the union's own ordering can change
/// without silently reinterpreting old blobs.
const NativeTag = enum(u8) {
    none,
    fn_native,
    fn_table,
    fn_avm1,
    array,
    boxed_bool,
    boxed_number,
    boxed_string,
    clip,
    display,
    super_obj,
    removed_display,
    date,
    transform,
    /// Arena-owned payloads — `NATV`'s business, not this section's.
    deferred,
};

fn writeNative(w: Writer, n: object_mod.NativeInfo, ctx: SaveCtx) !void {
    switch (n) {
        .none => try w.u8v(@intFromEnum(NativeTag.none)),
        .array => try w.u8v(@intFromEnum(NativeTag.array)),
        .removed_display => try w.u8v(@intFromEnum(NativeTag.removed_display)),
        .boxed_bool => |b| {
            try w.u8v(@intFromEnum(NativeTag.boxed_bool));
            try w.boolv(b);
        },
        .boxed_number => |x| {
            try w.u8v(@intFromEnum(NativeTag.boxed_number));
            try w.f64v(x);
        },
        .boxed_string => |s| {
            try w.u8v(@intFromEnum(NativeTag.boxed_string));
            try w.u32v(try ctx.pool.intern(s));
        },
        .date => |d| {
            try w.u8v(@intFromEnum(NativeTag.date));
            try w.f64v(d);
        },
        .transform => |h| {
            try w.u8v(@intFromEnum(NativeTag.transform));
            try w.u32v(h);
        },
        .super_obj => |sup| {
            try w.u8v(@intFromEnum(NativeTag.super_obj));
            try w.u32v(sup.this);
            try w.u8v(sup.depth);
        },
        // A display pointer becomes the id `DISP` gave it. An object
        // whose display object is gone writes the "removed" marker
        // instead, which is what a retained reference to a dead clip
        // already means.
        .clip => |ptr| try writeDisplayRef(w, .clip, ptr, ctx),
        .display => |ptr| try writeDisplayRef(w, .display, ptr, ctx),
        .function => |f| switch (f) {
            // The POINTER is not written: a fresh boot puts the same
            // built-in in the same slot, so the live one is the right
            // one. The exception is a native installed on an INSTANCE
            // after boot — there is no such slot — and those carry an id
            // from `avm1/natives.zig`.
            .native => |nf| {
                try w.u8v(@intFromEnum(NativeTag.fn_native));
                try w.u16v(natives.idOf(nf));
            },
            .table_native => |t| {
                try w.u8v(@intFromEnum(NativeTag.fn_table));
                try w.u16v(t.index);
                // `ASnative(cat, i)` makes one of these at RUNTIME, so
                // there may be no live slot to take the dispatcher from.
                try w.u32v(natives.categoryOf(t.f));
            },
            .avm1 => |a| {
                try w.u8v(@intFromEnum(NativeTag.fn_avm1));
                try writeCode(w, a.body, ctx);
                try writeCode(w, a.params_raw, ctx);
                try w.u16v(a.param_count);
                try w.boolv(a.with_registers);
                try w.u8v(a.register_count);
                try w.u16v(@bitCast(a.flags));
                try w.u32v(a.scope);
                try w.u32v(a.constant_pool);
                try w.u8v(a.swf_version);
                try w.u32v(a.base_clip);
                try w.u32v(try ctx.pool.intern(a.base_clip_path));
            },
        },
        // text_format, net_stream, bitmap_data, xml_node, xml_doc.
        // Their payloads travel in `NATV`, which is written after this
        // section because every one of them hangs off an object here.
        else => try w.u8v(@intFromEnum(NativeTag.deferred)),
    }
}

fn writeDisplayRef(w: Writer, comptime tag: NativeTag, ptr: *anyopaque, ctx: SaveCtx) !void {
    if (ctx.disp_ids.get(@intFromPtr(ptr))) |id| {
        try w.u8v(@intFromEnum(tag));
        try w.u32v(id);
    } else {
        try w.u8v(@intFromEnum(NativeTag.removed_display));
    }
}

/// A closure's bytecode is a slice into a movie buffer; it travels as
/// (which movie, where in it, how long) and is re-sliced on restore.
fn writeCode(w: Writer, code: []const u8, ctx: SaveCtx) !void {
    for (ctx.movies, 0..) |m, i| {
        if (@intFromPtr(code.ptr) >= @intFromPtr(m.ptr) and
            @intFromPtr(code.ptr) + code.len <= @intFromPtr(m.ptr) + m.len)
        {
            try w.u32v(@intCast(i));
            try w.u32v(@intCast(@intFromPtr(code.ptr) - @intFromPtr(m.ptr)));
            try w.u32v(@intCast(code.len));
            return;
        }
    }
    // Not inside any movie we know: an empty body is safer than a
    // dangling slice, and it cannot happen for content we can load.
    try w.u32v(0xFFFF_FFFF);
    try w.u32v(0);
    try w.u32v(0);
}

fn readCode(r: *Reader, ctx: LoadCtx) Error![]const u8 {
    const which = try r.u32v();
    const off = try r.u32v();
    const len = try r.u32v();
    if (which == 0xFFFF_FFFF or which >= ctx.movies.len) return &.{};
    const m = ctx.movies[which];
    if (off + len > m.len) return Error.SectionCorrupt;
    return m[off..][0..len];
}

/// Apply a heap onto the table a fresh boot built.
///
/// Slots below the live count are PATCHED so built-in function pointers
/// survive; slots above it are created. Nothing is ever removed: a boot
/// that made more objects than the state did would leave the extras
/// unreferenced, which is what garbage is for.
pub fn readHeap(r: *Reader, vm: *runtime.Vm, ctx: LoadCtx) Error!void {
    const arena = vm.objects.arena;
    const count = try r.u32v();
    while (vm.objects.slots.items.len < count) {
        _ = vm.objects.create() catch return Error.OutOfMemory;
    }
    // And TRUNCATE: rebuilding the display tree makes AVM1 objects of its
    // own (a clip gets one the moment it is instantiated), and any beyond
    // the state's count are the restore's own litter. Leaving them makes
    // the next save a different SIZE, which is how this was found — the
    // envelope's `total_size` word differing between a save and the
    // re-save right after loading it.
    if (vm.objects.slots.items.len > count) {
        vm.objects.slots.shrinkRetainingCapacity(count);
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const o = &vm.objects.slots.items[i];
        o.proto = try readValue(r, ctx);
        o.proto_attrs = try readAttrs(r);

        const n_props = try r.u32v();
        o.props.clearRetainingCapacity();
        o.props.ensureTotalCapacity(arena, n_props) catch return Error.OutOfMemory;
        var p: u32 = 0;
        while (p < n_props) : (p += 1) {
            const key_i = try r.u32v();
            if (key_i >= ctx.strings.len) return Error.SectionCorrupt;
            o.props.appendAssumeCapacity(.{
                .key = ctx.strings[key_i],
                .value = try readValue(r, ctx),
                .attrs = try readAttrs(r),
                .getter = try r.u32v(),
                .setter = try r.u32v(),
                .gen = try r.u32v(),
            });
        }

        try readNative(r, o, ctx, arena);
        o.is_with_scope = try r.boolv();
        o.scope_values = try r.u32v();

        const n_if = try r.u32v();
        const ifs = arena.alloc(ObjectHandle, n_if) catch return Error.OutOfMemory;
        for (ifs) |*h| h.* = try r.u32v();
        o.interfaces = ifs;
        o.interfaces_set = try r.boolv();
        o.ctor_propagates = try r.boolv();
        o.scope_parent = try r.u32v();

        const n_w = try r.u32v();
        const ws = arena.alloc(object_mod.Watcher, n_w) catch return Error.OutOfMemory;
        for (ws) |*wt| {
            const k = try r.u32v();
            if (k >= ctx.strings.len) return Error.SectionCorrupt;
            wt.* = .{
                .key = ctx.strings[k],
                .callback = try r.u32v(),
                .user_data = try readValue(r, ctx),
            };
        }
        o.watchers = ws;
    }
}

fn readNative(
    r: *Reader,
    o: *ScriptObject,
    ctx: LoadCtx,
    arena: std.mem.Allocator,
) Error!void {
    _ = arena;
    const tag: NativeTag = @enumFromInt(try r.u8v());
    switch (tag) {
        .none => o.native = .none,
        .array => o.native = .array,
        .removed_display => o.native = .removed_display,
        .boxed_bool => o.native = .{ .boxed_bool = try r.boolv() },
        .boxed_number => o.native = .{ .boxed_number = try r.f64v() },
        .boxed_string => {
            const i = try r.u32v();
            if (i >= ctx.strings.len) return Error.SectionCorrupt;
            o.native = .{ .boxed_string = ctx.strings[i] };
        },
        .date => o.native = .{ .date = try r.f64v() },
        .transform => o.native = .{ .transform = try r.u32v() },
        .super_obj => o.native = .{ .super_obj = .{
            .this = try r.u32v(),
            .depth = try r.u8v(),
        } },
        .clip, .display => {
            const id = try r.u32v();
            const ptr: ?*anyopaque = if (id < ctx.disp.len) ctx.disp[id] else null;
            // A display object the tree no longer has is exactly what
            // `removed_display` means, and content can tell the two apart.
            o.native = if (ptr) |pt|
                (if (tag == .clip) .{ .clip = pt } else .{ .display = pt })
            else
                .removed_display;
        },
        // The live slot already holds the right function pointer: a fresh
        // boot installs the same built-in at the same handle. An id names
        // one that no boot would have installed here.
        .fn_native => {
            if (natives.get(try r.u16v())) |nf| {
                o.native = .{ .function = .{ .native = nf } };
            }
        },
        .fn_table => {
            const idx = try r.u16v();
            const cat = try r.u32v();
            if (natives.tableFn(cat)) |f| {
                o.native = .{ .function = .{ .table_native = .{ .f = f, .index = idx } } };
            } else if (o.native == .function and o.native.function == .table_native) {
                o.native.function.table_native.index = idx;
            }
        },
        .fn_avm1 => {
            const body = try readCode(r, ctx);
            const params = try readCode(r, ctx);
            const param_count = try r.u16v();
            const with_registers = try r.boolv();
            const register_count = try r.u8v();
            const flags: opcodes.Function2Flags = @bitCast(try r.u16v());
            const scope = try r.u32v();
            const pool = try r.u32v();
            const swf_version = try r.u8v();
            const base_clip = try r.u32v();
            const path_i = try r.u32v();
            if (path_i >= ctx.strings.len) return Error.SectionCorrupt;
            o.native = .{ .function = .{ .avm1 = .{
                .body = body,
                .param_count = param_count,
                .params_raw = params,
                .with_registers = with_registers,
                .register_count = register_count,
                .flags = flags,
                .scope = scope,
                .constant_pool = pool,
                .swf_version = swf_version,
                .base_clip = base_clip,
                .base_clip_path = ctx.strings[path_i],
            } } };
        },
        // A payload `NATV` owns. Until that section exists the live value
        // stands, which for a fresh boot means "nothing".
        .deferred => {},
    }
}

test "a NaN round-trips as one canonical pattern" {
    // Two NaNs with different payloads must serialize identically, or a
    // rewind delta of unchanged state is not zero (D3).
    const a: f64 = @bitCast(@as(u64, 0x7FF8_0000_0000_0001));
    const b: f64 = @bitCast(@as(u64, 0x7FF8_0000_DEAD_BEEF));
    try std.testing.expect(std.math.isNan(a) and std.math.isNan(b));
    const ca: u64 = @bitCast(if (std.math.isNan(a)) std.math.nan(f64) else a);
    const cb: u64 = @bitCast(if (std.math.isNan(b)) std.math.nan(f64) else b);
    try std.testing.expectEqual(ca, cb);
}

test "the envelope and its sections agree on format and version" {
    try std.testing.expectEqual(ENVELOPE.format, sec(.plyr).format);
    try std.testing.expectEqual(ENVELOPE.version, sec(.heap).version);
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(FORMAT));
}
