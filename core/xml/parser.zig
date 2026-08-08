//! A pull parser for AVM1's `XML.parseXML`.
//!
//! A leaf module: `std` plus the AVM1 string type, which is what the
//! parser reads and writes. Working in UTF-16 throughout means a
//! document round-trips without a lossy detour through UTF-8, which
//! matters because a SWF string can hold unpaired surrogates.
//!
//! Flash's parser is LENIENT in ways a conforming one is not, and the
//! corpus checks each of them: an unrecognised entity is left alone
//! rather than being an error, a bare `&` is not an entity at all, and a
//! `<!DOCTYPE>` or `<?xml?>` is captured verbatim rather than
//! interpreted. The error codes it does report are the `XML.status`
//! numbers, so they are part of the observable behaviour.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/xml.rs (its
//! quick-xml event loop) and core/common/src/xml.rs (`avm1_unescape`).

const std = @import("std");
const strings = @import("../avm1/string.zig");

const AvmString = strings.AvmString;

/// `XML.status`. Zero is success; every failure is negative and the exact
/// number is script-visible.
pub const Status = enum(i32) {
    ok = 0,
    cdata_not_terminated = -2,
    decl_not_terminated = -3,
    doctype_not_terminated = -4,
    comment_not_terminated = -5,
    element_malformed = -6,
    out_of_memory = -7,
    attribute_not_terminated = -8,
    mismatched_start = -9,
    mismatched_end = -10,
};

pub const Attribute = struct { name: AvmString, value: AvmString };

pub const Event = union(enum) {
    /// `<tag …>` — pushes a level.
    start: Element,
    /// `<tag … />` — a level of its own that closes immediately.
    empty: Element,
    end: AvmString,
    /// Already unescaped.
    text: AvmString,
    /// Never unescaped: a CDATA section is literal by definition.
    cdata: AvmString,
    /// The whole `<?xml … ?>`, angle brackets included.
    decl: AvmString,
    /// The whole `<!DOCTYPE …>`, angle brackets included.
    doctype: AvmString,
    comment,

    pub const Element = struct { name: AvmString, attributes: []const Attribute };
};

pub const Parser = struct {
    src: AvmString,
    pos: usize = 0,
    gpa: std.mem.Allocator,
    status: Status = .ok,

    pub fn init(gpa: std.mem.Allocator, src: AvmString) Parser {
        return .{ .src = src, .gpa = gpa };
    }

    /// The next event, or null at the end of the document. A parse error
    /// also ends the document, with `status` set.
    pub fn next(self: *Parser) !?Event {
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] != '<') return .{ .text = try self.readText() };

        // `<` at the very end is not a tag and not an error — it is text.
        if (self.pos + 1 >= self.src.len) return .{ .text = try self.readText() };
        const c = self.src[self.pos + 1];
        if (c == '!') return self.readBang();
        if (c == '?') return self.readDecl();
        if (c == '/') return self.readEnd();
        return self.readStart();
    }

    fn fail(self: *Parser, s: Status) ?Event {
        self.status = s;
        self.pos = self.src.len;
        return null;
    }

    /// Everything up to the next `<`, entities resolved.
    fn readText(self: *Parser) !AvmString {
        const start = self.pos;
        // Step past a leading `<` that turned out not to open a tag, so
        // the scan cannot stall on it.
        if (self.src[self.pos] == '<') self.pos += 1;
        while (self.pos < self.src.len and self.src[self.pos] != '<') self.pos += 1;
        return unescape(self.gpa, self.src[start..self.pos]);
    }

    /// `<!…`: a comment, a CDATA section, or a doctype.
    fn readBang(self: *Parser) !?Event {
        if (startsWith(self.src[self.pos..], "<!--")) {
            const end = indexOfSeq(self.src, self.pos + 4, "-->") orelse
                return self.fail(.comment_not_terminated);
            self.pos = end + 3;
            return .comment;
        }
        if (startsWith(self.src[self.pos..], "<![CDATA[")) {
            const body = self.pos + 9;
            const end = indexOfSeq(self.src, body, "]]>") orelse
                return self.fail(.cdata_not_terminated);
            self.pos = end + 3;
            return .{ .cdata = self.src[body..end] };
        }
        // A doctype may nest `<…>` in its internal subset, so the scan
        // has to balance rather than stop at the first `>`.
        var depth: usize = 0;
        var i = self.pos;
        while (i < self.src.len) : (i += 1) {
            if (self.src[i] == '<') depth += 1;
            if (self.src[i] == '>') {
                depth -= 1;
                if (depth == 0) {
                    const whole = self.src[self.pos .. i + 1];
                    self.pos = i + 1;
                    return .{ .doctype = whole };
                }
            }
        }
        return self.fail(.doctype_not_terminated);
    }

    fn readDecl(self: *Parser) !?Event {
        const end = indexOfSeq(self.src, self.pos + 2, "?>") orelse
            return self.fail(.decl_not_terminated);
        const whole = self.src[self.pos .. end + 2];
        self.pos = end + 2;
        return .{ .decl = whole };
    }

    fn readEnd(self: *Parser) !?Event {
        const name_start = self.pos + 2;
        var i = name_start;
        while (i < self.src.len and self.src[i] != '>') i += 1;
        if (i >= self.src.len) return self.fail(.element_malformed);
        self.pos = i + 1;
        return .{ .end = trim(self.src[name_start..i]) };
    }

    fn readStart(self: *Parser) !?Event {
        var i = self.pos + 1;
        const name_start = i;
        while (i < self.src.len and !isNameEnd(self.src[i])) i += 1;
        const name = self.src[name_start..i];
        if (name.len == 0) return self.fail(.element_malformed);

        var attrs: std.ArrayList(Attribute) = .empty;
        errdefer attrs.deinit(self.gpa);

        while (true) {
            while (i < self.src.len and isSpace(self.src[i])) i += 1;
            if (i >= self.src.len) return self.fail(.element_malformed);
            if (self.src[i] == '>') {
                self.pos = i + 1;
                return .{ .start = .{ .name = name, .attributes = try attrs.toOwnedSlice(self.gpa) } };
            }
            if (self.src[i] == '/') {
                if (i + 1 >= self.src.len or self.src[i + 1] != '>') return self.fail(.element_malformed);
                self.pos = i + 2;
                return .{ .empty = .{ .name = name, .attributes = try attrs.toOwnedSlice(self.gpa) } };
            }

            const key_start = i;
            while (i < self.src.len and !isSpace(self.src[i]) and self.src[i] != '=' and
                self.src[i] != '>' and self.src[i] != '/') i += 1;
            const key = self.src[key_start..i];
            if (key.len == 0) return self.fail(.element_malformed);

            while (i < self.src.len and isSpace(self.src[i])) i += 1;
            if (i >= self.src.len or self.src[i] != '=') return self.fail(.element_malformed);
            i += 1;
            while (i < self.src.len and isSpace(self.src[i])) i += 1;
            if (i >= self.src.len) return self.fail(.attribute_not_terminated);

            // An UNQUOTED value is its own error code, not a generic
            // malformed element.
            const quote = self.src[i];
            if (quote != '"' and quote != '\'') return self.fail(.attribute_not_terminated);
            i += 1;
            const val_start = i;
            while (i < self.src.len and self.src[i] != quote) i += 1;
            if (i >= self.src.len) return self.fail(.attribute_not_terminated);
            const raw = self.src[val_start..i];
            i += 1;

            try attrs.append(self.gpa, .{ .name = key, .value = try unescape(self.gpa, raw) });
        }
    }
};

fn isSpace(c: u16) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameEnd(c: u16) bool {
    return isSpace(c) or c == '>' or c == '/';
}

fn trim(s: AvmString) AvmString {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isSpace(s[a])) a += 1;
    while (b > a and isSpace(s[b - 1])) b -= 1;
    return s[a..b];
}

fn startsWith(s: AvmString, comptime lit: []const u8) bool {
    if (s.len < lit.len) return false;
    inline for (lit, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return true;
}

fn indexOfSeq(s: AvmString, from: usize, comptime lit: []const u8) ?usize {
    if (s.len < lit.len) return null;
    var i = from;
    while (i + lit.len <= s.len) : (i += 1) {
        if (startsWith(s[i..], lit)) return i;
    }
    return null;
}

/// XML entities, Flash's way: an entity runs from `&` to the next `;`
/// with NO intervening `&`, so a bare ampersand is left alone instead of
/// swallowing the text after it. An entity that is not recognised —
/// including a numeric reference that will not parse — is copied through
/// verbatim rather than being an error.
pub fn unescape(gpa: std.mem.Allocator, s: AvmString) !AvmString {
    if (std.mem.indexOfScalar(u16, s, '&') == null) return s;

    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        // Find the terminator, giving up at another `&`.
        var j = i + 1;
        while (j < s.len and s[j] != ';' and s[j] != '&') j += 1;
        if (j >= s.len or s[j] != ';') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        if (decodeEntity(s[i + 1 .. j])) |decoded| {
            switch (decoded) {
                .unit => |u| try out.append(gpa, u),
                .pair => |p| try out.appendSlice(gpa, &p),
            }
            i = j + 1;
        } else {
            try out.appendSlice(gpa, s[i .. j + 1]);
            i = j + 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

const Decoded = union(enum) { unit: u16, pair: [2]u16 };

fn decodeEntity(body: AvmString) ?Decoded {
    if (body.len == 0) return null;
    if (eqAscii(body, "amp")) return .{ .unit = '&' };
    if (eqAscii(body, "lt")) return .{ .unit = '<' };
    if (eqAscii(body, "gt")) return .{ .unit = '>' };
    if (eqAscii(body, "quot")) return .{ .unit = '"' };
    if (eqAscii(body, "apos")) return .{ .unit = '\'' };
    if (body[0] != '#') return null;

    const hex = body.len > 1 and (body[1] == 'x' or body[1] == 'X');
    const digits = body[(if (hex) @as(usize, 2) else 1)..];
    if (digits.len == 0) return null;
    var cp: u32 = 0;
    for (digits) |d| {
        const v: u32 = switch (d) {
            '0'...'9' => d - '0',
            'a'...'f' => if (hex) d - 'a' + 10 else return null,
            'A'...'F' => if (hex) d - 'A' + 10 else return null,
            else => return null,
        };
        cp = cp *% (if (hex) @as(u32, 16) else 10) +% v;
        if (cp > 0x10FFFF) return null;
    }
    if (cp < 0x10000) return .{ .unit = @intCast(cp) };
    const v = cp - 0x10000;
    return .{ .pair = .{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) } };
}

fn eqAscii(s: AvmString, comptime lit: []const u8) bool {
    if (s.len != lit.len) return false;
    inline for (lit, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return true;
}

/// The five predefined entities, on the way back out.
pub fn escape(gpa: std.mem.Allocator, s: AvmString) !AvmString {
    var needed = false;
    for (s) |c| {
        if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'') needed = true;
    }
    if (!needed) return s;

    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(gpa, strings.ascii("&amp;")),
        '<' => try out.appendSlice(gpa, strings.ascii("&lt;")),
        '>' => try out.appendSlice(gpa, strings.ascii("&gt;")),
        '"' => try out.appendSlice(gpa, strings.ascii("&quot;")),
        '\'' => try out.appendSlice(gpa, strings.ascii("&apos;")),
        else => try out.append(gpa, c),
    };
    return out.toOwnedSlice(gpa);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn u16s(comptime s: []const u8) AvmString {
    return strings.ascii(s);
}

test "a bare ampersand is not an entity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The `&` before the space has no `;` of its own, and the scan for
    // one stops at the next `&` rather than running into `&amp;`.
    const got = try unescape(a, u16s("a & b &amp; c"));
    try testing.expectEqualSlices(u16, u16s("a & b & c"), got);
}

test "an unknown entity survives verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try unescape(arena.allocator(), u16s("&nope; &#xZZ; &#65;"));
    try testing.expectEqualSlices(u16, u16s("&nope; &#xZZ; A"), got);
}

test "elements, attributes and an empty tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), u16s("<a x='1' y=\"2\"><b/>hi</a>"));

    const e1 = (try p.next()).?;
    try testing.expectEqualSlices(u16, u16s("a"), e1.start.name);
    try testing.expectEqual(@as(usize, 2), e1.start.attributes.len);
    try testing.expectEqualSlices(u16, u16s("y"), e1.start.attributes[1].name);
    try testing.expectEqualSlices(u16, u16s("2"), e1.start.attributes[1].value);

    try testing.expectEqualSlices(u16, u16s("b"), (try p.next()).?.empty.name);
    try testing.expectEqualSlices(u16, u16s("hi"), (try p.next()).?.text);
    try testing.expectEqualSlices(u16, u16s("a"), (try p.next()).?.end);
    try testing.expect((try p.next()) == null);
    try testing.expectEqual(Status.ok, p.status);
}

test "CDATA is literal and comments vanish" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), u16s("<![CDATA[a&amp;<b>]]><!-- x -->"));
    try testing.expectEqualSlices(u16, u16s("a&amp;<b>"), (try p.next()).?.cdata);
    try testing.expect((try p.next()).? == .comment);
}

test "an unquoted attribute has its own status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), u16s("<a x=1>"));
    try testing.expect((try p.next()) == null);
    try testing.expectEqual(Status.attribute_not_terminated, p.status);
}

test "a doctype balances its internal subset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), u16s("<!DOCTYPE a [<!ENTITY x \"y\">]><a/>"));
    try testing.expectEqualSlices(u16, u16s("<!DOCTYPE a [<!ENTITY x \"y\">]>"), (try p.next()).?.doctype);
    try testing.expectEqualSlices(u16, u16s("a"), (try p.next()).?.empty.name);
}
