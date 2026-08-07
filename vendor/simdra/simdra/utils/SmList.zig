//! SmList(T) — minimal generic growable list, allocator-unmanaged style.
//!
//! Three plain scalar fields (`ptr`, `len`, `cap`); node-zigar's type scanner
//! handles them as a single struct without recursing into
//! `std.ArrayListUnmanaged`'s namespace (which historically blew zigar's
//! comptime-branch quota — see commit history of `PathBuf` in `SmPath.zig`).
//!
//! Allocator is passed explicitly to every method that allocates / frees
//! (the `std.ArrayListUnmanaged` pattern). The list itself stores no
//! allocator — keeps the layout zigar-safe (4-field structs with embedded
//! `std.mem.Allocator` would otherwise pull in vtable function-pointer
//! types). Owning structs (`SmPath`, `SmGradient`, `SmSurface`, etc.) hold
//! the canonical allocator and thread it down.
//!
//! Methods exposed:
//!   - `append(allocator, value)` / `appendSlice(allocator, values)` — push.
//!   - `ensureUnusedCapacity(allocator, n)` — reserve room.
//!   - `clearRetainingCapacity()` — `len = 0`, keeps the buffer.
//!   - `deinit(allocator)` — free the buffer.
//!   - `items()` — `[]T` slice over the populated range.
//!
//! Field layout (stable; relied on by the few sites that pre-grow then bulk
//! assign via `ptr[i]`): `ptr: [*]T`, `len: usize`, `cap: usize`.

const std = @import("std");

pub fn SmList(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: [*]T = undefined,
        len: usize = 0,
        cap: usize = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.cap > 0) {
                allocator.free(self.ptr[0..self.cap]);
                self.ptr = undefined;
                self.len = 0;
                self.cap = 0;
            }
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, n: usize) !void {
            const needed = self.len + n;
            if (needed <= self.cap) return;
            const new_cap = @max(needed, self.cap * 2 + 8);
            if (self.cap == 0) {
                const slice = try allocator.alloc(T, new_cap);
                self.ptr = slice.ptr;
            } else {
                const slice = try allocator.realloc(self.ptr[0..self.cap], new_cap);
                self.ptr = slice.ptr;
            }
            self.cap = new_cap;
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            try self.ensureUnusedCapacity(allocator, 1);
            self.ptr[self.len] = value;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, allocator: std.mem.Allocator, values: []const T) !void {
            try self.ensureUnusedCapacity(allocator, values.len);
            @memcpy(self.ptr[self.len..][0..values.len], values);
            self.len += values.len;
        }

        pub fn items(self: *const Self) []T {
            return self.ptr[0..self.len];
        }
    };
}
