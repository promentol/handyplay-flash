//! The value model the ExternalInterface bridge speaks.
//!
//! Two worlds meet here — AVM1 on one side, whatever embeds the player on
//! the other — and neither can hold the other's values. Everything that
//! crosses is flattened into this: no prototypes, no identity, no cycles,
//! and strings in UTF-8 rather than the player's UTF-16.
//!
//! An object is a SORTED list of pairs, not a hash: ruffle marshals
//! through a `BTreeMap` (core/src/external.rs), so the order a host sees
//! is the keys' own, whatever order the script defined them in.
//!
//! Nothing here allocates. Values built by the player live in the VM
//! arena; values built by a host live as long as the host says.

const std = @import("std");

pub const Pair = struct { key: []const u8, value: Value };

pub const Value = union(enum) {
    undefined_value,
    null_value,
    boolean: bool,
    number: f64,
    string: []const u8,
    /// Sorted by key.
    object: []const Pair,
    list: []const Value,
};

/// A host's answer to `ExternalInterface.call`. `user` is whatever the
/// host handed the player; `args` are the call's arguments minus the
/// method name.
pub const CallFn = *const fn (user: ?*anyopaque, name: []const u8, args: []const Value) Value;

pub fn lessThanKey(_: void, a: Pair, b: Pair) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}
