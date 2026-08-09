//! Replaying a recorded input script into a running player.
//!
//! Ruffle's corpus records interaction as an `input.json` array of
//! events, with `Wait` marking the end of a tick's batch. Both harness
//! frontends read it — the trace runner for the text score, the SDL
//! frontend's headless mode for the image one — so the translation from
//! JSON to player calls lives here rather than twice.

const std = @import("std");
const flash = @import("flash");

/// Deliver events up to and including the next `Wait`, and return the new
/// cursor. Unknown event types are skipped — the corpus has plenty that
/// only mean something to a text field or a clipboard.
pub fn feedUntilWait(player: *flash.Player, events: []const std.json.Value, start: usize) usize {
    var i = start;
    while (i < events.len) : (i += 1) {
        const ev = events[i];
        if (ev != .object) continue;
        const kind = ev.object.get("type") orelse continue;
        if (kind != .string) continue;
        const name = kind.string;
        if (std.mem.eql(u8, name, "Wait")) return i + 1;
        if (std.mem.eql(u8, name, "MouseMove")) {
            const p = posOf(ev);
            player.mouseMove(p[0], p[1]) catch {};
        } else if (std.mem.eql(u8, name, "MouseDown")) {
            // The position rides along but is NOT a move event of its own.
            const p = posOf(ev);
            player.setMousePosition(p[0], p[1]);
            player.mouseButton(buttonOf(ev), true) catch {};
        } else if (std.mem.eql(u8, name, "MouseUp")) {
            const p = posOf(ev);
            player.setMousePosition(p[0], p[1]);
            player.mouseButton(buttonOf(ev), false) catch {};
        } else if (std.mem.eql(u8, name, "KeyDown")) {
            const k = keyOf(ev);
            player.keyDown(k[0], k[1]) catch {};
        } else if (std.mem.eql(u8, name, "KeyUp")) {
            const k = keyOf(ev);
            player.keyUp(k[0], k[1]) catch {};
        } else if (std.mem.eql(u8, name, "ImePreedit")) {
            const txt = ev.object.get("text");
            var buf: [64]u16 = undefined;
            var n: usize = 0;
            if (txt) |t| {
                if (t == .string) n = std.unicode.utf8ToUtf16Le(&buf, t.string) catch 0;
            }
            var cursor: ?[2]usize = null;
            if (ev.object.get("cursor")) |cv| {
                if (cv == .array and cv.array.items.len >= 2) {
                    cursor = .{
                        @intFromFloat(numOf(cv.array.items[0])),
                        @intFromFloat(numOf(cv.array.items[1])),
                    };
                }
            }
            player.imePreedit(buf[0..n], cursor) catch {};
        } else if (std.mem.eql(u8, name, "SetClipboardText")) {
            const txt = ev.object.get("text");
            if (txt) |t| {
                if (t == .string) player.setClipboard(t.string) catch {};
            }
        } else if (std.mem.eql(u8, name, "TextControl")) {
            if (controlOf(ev)) |c| player.textControl(c) catch {};
        } else if (std.mem.eql(u8, name, "TextInput")) {
            const codepoint = ev.object.get("codepoint");
            if (codepoint) |cp| {
                if (cp == .string and cp.string.len > 0) {
                    var buf: [8]u16 = undefined;
                    const n = std.unicode.utf8ToUtf16Le(&buf, cp.string) catch 0;
                    if (n > 0) player.textInput(buf[0..n]) catch {};
                }
            }
        } else if (std.mem.eql(u8, name, "FocusLost")) {
            player.windowFocus(false) catch {};
        } else if (std.mem.eql(u8, name, "FocusGained")) {
            player.windowFocus(true) catch {};
        }
    }
    return i;
}

/// The `--log-fetch` file reader. Every answer is kept alive for the whole
/// run: a loaded SWF is parsed IN PLACE, so its buffer has to outlive the
/// clip that holds it, and a conformance run is short enough that never
/// freeing is the simplest correct policy.
/// The simulated file dialogs ruffle's test UI backend provides. An OPEN
/// dialog succeeds only when the filter list carries the magic
/// "debug-select-success" description; a SAVE dialog only when the
/// suggested name is "debug-success.txt". Everything else is a
/// cancellation, which is how the corpus exercises both branches without
/// a real user.
fn posOf(ev: std.json.Value) [2]f64 {
    const pos = ev.object.get("pos") orelse return .{ 0, 0 };
    if (pos != .array or pos.array.items.len < 2) return .{ 0, 0 };
    return .{ numOf(pos.array.items[0]), numOf(pos.array.items[1]) };
}

fn numOf(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => 0,
    };
}

fn buttonOf(ev: std.json.Value) u8 {
    const btn = ev.object.get("btn") orelse return 0;
    if (btn != .string) return 0;
    if (std.mem.eql(u8, btn.string, "Middle")) return 1;
    if (std.mem.eql(u8, btn.string, "Right")) return 2;
    return 0;
}

/// `{"key": "Tab"}` or `{"key": {"Char": "a"}}` → (Flash key code, ASCII).
///
/// Flash's key codes are the Windows virtual-key numbering, in which a
/// letter's code is its UPPERCASE ASCII value while `Key.getAscii` reports
/// the character as typed.
fn keyOf(ev: std.json.Value) [2]i32 {
    const key = ev.object.get("key") orelse return .{ 0, 0 };
    switch (key) {
        .string => |name| return .{ namedKeyCode(name), 0 },
        .object => |o| {
            const ch = o.get("Char") orelse o.get("Numpad") orelse return .{ 0, 0 };
            if (ch != .string or ch.string.len == 0) return .{ 0, 0 };
            const c: i32 = ch.string[0];
            // A PUNCTUATION key reports the US-layout virtual key code,
            // not the character's own — `"` is the quote key, 222, and
            // its ASCII stays 34 (corpus input_dead_keys_windows).
            const punct = [_][2]i32{
                .{ '-', 189 }, .{ '_', 189 }, .{ '=', 187 }, .{ '+', 187 },
                .{ '[', 219 }, .{ '{', 219 }, .{ ']', 221 }, .{ '}', 221 },
                .{ '\\', 220 }, .{ '|', 220 }, .{ ';', 186 }, .{ ':', 186 },
                .{ '\'', 222 }, .{ '"', 222 }, .{ ',', 188 }, .{ '<', 188 },
                .{ '.', 190 }, .{ '>', 190 }, .{ '/', 191 }, .{ '?', 191 },
                .{ '`', 192 }, .{ '~', 192 },
            };
            for (punct) |pair| {
                if (pair[0] == c) return .{ pair[1], c };
            }
            const upper: i32 = if (c >= 'a' and c <= 'z') c - 32 else c;
            return .{ upper, c };
        },
        else => return .{ 0, 0 },
    }
}

/// `{"type":"TextControl","code":"MoveRight"}` — ruffle's
/// `TextControlCode` variant names, verbatim.
fn controlOf(ev: std.json.Value) ?flash.display.edit_text.Control {
    const code = ev.object.get("code") orelse return null;
    if (code != .string) return null;
    const table = .{
        .{ "MoveLeft", .move_left },
        .{ "MoveLeftWord", .move_left_word },
        .{ "MoveLeftLine", .move_left_line },
        .{ "MoveLeftDocument", .move_left_document },
        .{ "MoveRight", .move_right },
        .{ "MoveRightWord", .move_right_word },
        .{ "MoveRightLine", .move_right_line },
        .{ "MoveRightDocument", .move_right_document },
        .{ "SelectLeft", .select_left },
        .{ "SelectLeftWord", .select_left_word },
        .{ "SelectLeftLine", .select_left_line },
        .{ "SelectLeftDocument", .select_left_document },
        .{ "SelectRight", .select_right },
        .{ "SelectRightWord", .select_right_word },
        .{ "SelectRightLine", .select_right_line },
        .{ "SelectRightDocument", .select_right_document },
        .{ "SelectAll", .select_all },
        .{ "Copy", .copy },
        .{ "Paste", .paste },
        .{ "Cut", .cut },
        .{ "Backspace", .backspace },
        .{ "BackspaceWord", .backspace_word },
        .{ "Enter", .enter },
        .{ "Delete", .delete },
        .{ "DeleteWord", .delete_word },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, code.string, e[0])) return e[1];
    }
    return null;
}

fn namedKeyCode(name: []const u8) i32 {
    const table = .{
        .{ "Backspace", 8 },  .{ "Tab", 9 },       .{ "Enter", 13 },
        .{ "LeftShift", 16 }, .{ "RightShift", 16 }, .{ "LeftControl", 17 },
        .{ "RightControl", 17 }, .{ "LeftAlt", 18 }, .{ "RightAlt", 18 },
        .{ "CapsLock", 20 },  .{ "Escape", 27 },   .{ "Space", 32 },
        .{ "PageUp", 33 },    .{ "PageDown", 34 }, .{ "End", 35 },
        .{ "Home", 36 },      .{ "ArrowLeft", 37 }, .{ "ArrowUp", 38 },
        .{ "ArrowRight", 39 }, .{ "ArrowDown", 40 }, .{ "Insert", 45 },
        .{ "Delete", 46 },    .{ "F1", 112 },      .{ "F2", 113 },
        .{ "F3", 114 },       .{ "F4", 115 },      .{ "F5", 116 },
        .{ "F6", 117 },       .{ "F7", 118 },      .{ "F8", 119 },
        .{ "F9", 120 },       .{ "F10", 121 },     .{ "F11", 122 },
        .{ "F12", 123 },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return 0;
}
