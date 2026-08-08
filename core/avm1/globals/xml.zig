//! `XMLNode` and `XML` — AVM1's XML DOM.
//!
//! The tree lives beside the script objects rather than inside them: a
//! node is a `Node` in the VM arena and its AVM1 object is created
//! LAZILY, on the first read that hands the node to script. That is
//! ruffle's shape and it is observable — `node.firstChild ==
//! node.firstChild` is true, because both reads find the same
//! already-made object.
//!
//! An `XML` document IS an `XMLNode`: its script object carries both
//! natives, and every node accessor works on it through the document's
//! ROOT node. The root is an element node with NO name, which is what
//! makes `doc.toString()` concatenate its children without wrapping them
//! in a tag.
//!
//! Reference: reference/ruffle/core/src/avm1/xml/tree.rs and
//! globals/{xml,xml_node}.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const decl = @import("decl.zig");
const parser = @import("../../xml/parser.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const AvmString = strings.AvmString;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const ver = decl.ver;

pub const ELEMENT_NODE: u8 = 1;
pub const TEXT_NODE: u8 = 3;

/// One node of the tree. Siblings are threaded so `nextSibling` is O(1),
/// which is how script walks a document.
pub const Node = struct {
    node_type: u8,
    /// The tag name for an element, the text for anything else. NULL for
    /// a document root, which has neither.
    node_value: ?AvmString,
    /// A bare object holding the attributes in DEFINITION order — the
    /// order a `for..in` and the serialiser both use.
    attributes: ObjectHandle,
    children: std.ArrayList(*Node) = .empty,
    parent: ?*Node = null,
    prev: ?*Node = null,
    next: ?*Node = null,
    /// Made on demand; once made, it is the node's identity for script.
    script_object: ObjectHandle = 0,
    /// The `childNodes` array, rebuilt in place whenever the child list
    /// changes so a reference script kept stays live.
    cached_child_nodes: ObjectHandle = 0,
};

/// The document-level state an `XML` adds on top of its root node.
pub const Document = struct {
    root: *Node,
    xml_decl: ?AvmString = null,
    doctype: ?AvmString = null,
    id_map: ObjectHandle,
    status: i32 = 0,
};

pub fn install(vm: *Vm, attrs: object_mod.Attributes) !void {
    // --- XMLNode ---
    const node_proto = try vm.objects.create();
    vm.objects.get(node_proto).proto = .{ .object = vm.object_proto };
    vm.xmlnode_proto = node_proto;

    const m = decl.hidden;
    try decl.method(vm, node_proto, "cloneNode", cloneNode, m);
    try decl.method(vm, node_proto, "removeNode", removeNode, m);
    try decl.method(vm, node_proto, "insertBefore", insertBefore, m);
    try decl.method(vm, node_proto, "appendChild", appendChild, m);
    try decl.method(vm, node_proto, "hasChildNodes", hasChildNodes, m);
    try decl.method(vm, node_proto, "toString", nodeToString, m);
    try decl.method(vm, node_proto, "getNamespaceForPrefix", getNamespaceForPrefix, m);
    try decl.method(vm, node_proto, "getPrefixForNamespace", getPrefixForNamespace, m);

    const p = decl.hidden;
    try decl.property(vm, node_proto, "attributes", getAttributes, null, p);
    try decl.property(vm, node_proto, "childNodes", getChildNodes, null, p);
    try decl.property(vm, node_proto, "firstChild", getFirstChild, null, p);
    try decl.property(vm, node_proto, "lastChild", getLastChild, null, p);
    try decl.property(vm, node_proto, "nextSibling", getNextSibling, null, p);
    // `nodeName` and `nodeValue` SHARE one setter — writing either
    // rewrites the same slot, whatever the node type.
    try decl.property(vm, node_proto, "nodeName", getNodeName, setNodeValue, p);
    try decl.property(vm, node_proto, "nodeType", getNodeType, null, p);
    try decl.property(vm, node_proto, "nodeValue", getNodeValue, setNodeValue, p);
    try decl.property(vm, node_proto, "parentNode", getParentNode, null, p);
    try decl.property(vm, node_proto, "previousSibling", getPrevSibling, null, p);
    try decl.property(vm, node_proto, "prefix", getPrefix, null, p);
    try decl.property(vm, node_proto, "localName", getLocalName, null, p);
    try decl.property(vm, node_proto, "namespaceURI", getNamespaceUri, null, p);

    vm.xmlnode_ctor = try decl.class(vm, "XMLNode", ctorXmlNode, node_proto, attrs);

    // --- XML, whose prototype INHERITS XMLNode's ---
    const xml_proto = try vm.objects.create();
    vm.objects.get(xml_proto).proto = .{ .object = node_proto };
    vm.xml_proto = xml_proto;

    try decl.method(vm, xml_proto, "createElement", createElement, m);
    try decl.method(vm, xml_proto, "createTextNode", createTextNode, m);
    try decl.method(vm, xml_proto, "parseXML", parseXml, m);
    try decl.method(vm, xml_proto, "getBytesLoaded", getBytesLoaded, m);
    try decl.method(vm, xml_proto, "getBytesTotal", getBytesTotal, m);
    try decl.method(vm, xml_proto, "load", load, m);
    try decl.method(vm, xml_proto, "sendAndLoad", sendAndLoad, m);
    try decl.method(vm, xml_proto, "onData", onData, m);
    try vm.objects.putWithAttrs(xml_proto, S("contentType"), .{
        .string = S("application/x-www-form-urlencoded"),
    }, .{ .read_only = true, .dont_enum = true }, false);
    try vm.objects.putWithAttrs(xml_proto, S("ignoreWhite"), .{ .boolean = false }, .{ .dont_enum = true }, false);
    try decl.property(vm, xml_proto, "docTypeDecl", getDocTypeDecl, null, ver(.{ .read_only = true, .dont_enum = true }, 0));
    try decl.property(vm, xml_proto, "status", getStatus, setStatus, p);
    try decl.property(vm, xml_proto, "xmlDecl", getXmlDecl, setXmlDecl, p);
    try decl.property(vm, xml_proto, "idMap", getIdMap, null, p);

    _ = try decl.class(vm, "XML", ctorXml, xml_proto, attrs);
}

// --- tree ---------------------------------------------------------------------

fn newNode(vm: *Vm, node_type: u8, node_value: ?AvmString) !*Node {
    const n = try vm.arena().create(Node);
    n.* = .{
        .node_type = node_type,
        .node_value = node_value,
        .attributes = try vm.objects.create(),
    };
    // Attributes hang off a BARE object: no prototype, so a `for..in`
    // over them lists exactly what the document declared.
    vm.objects.get(n.attributes).proto = .undefined_value;
    return n;
}

/// The node behind a value, whether it is an `XMLNode` or the `XML`
/// document whose root it is.
pub fn nodeOf(vm: *Vm, v: Value) ?*Node {
    if (v != .object) return null;
    return switch (vm.objects.get(v.object).native) {
        .xml_node => |ptr| @ptrCast(@alignCast(ptr)),
        .xml_doc => |ptr| blk: {
            const doc: *Document = @ptrCast(@alignCast(ptr));
            break :blk doc.root;
        },
        else => null,
    };
}

fn docOf(vm: *Vm, v: Value) ?*Document {
    if (v != .object) return null;
    return switch (vm.objects.get(v.object).native) {
        .xml_doc => |ptr| @ptrCast(@alignCast(ptr)),
        else => null,
    };
}

/// The node's script object, made on first use. Identity matters: two
/// reads of the same child must give the same object.
fn scriptObject(vm: *Vm, n: *Node) !Value {
    if (n.script_object != 0) return .{ .object = n.script_object };
    const h = try vm.objects.create();
    // `XMLNode.prototype` is read FRESH: content that reassigns it
    // changes what later nodes inherit, including nodes the parser
    // makes.
    const proto = vm.objects.getChained(vm.xmlnode_ctor, S("prototype"), vm.case_sensitive) orelse
        Value{ .object = vm.xmlnode_proto };
    vm.objects.get(h).proto = proto;
    vm.objects.get(h).native = .{ .xml_node = @ptrCast(n) };
    n.script_object = h;
    return .{ .object = h };
}

fn childIndex(p: *Node, child: *Node) ?usize {
    for (p.children.items, 0..) |c, i| {
        if (c == child) return i;
    }
    return null;
}

fn isAncestor(maybe: *Node, of: *Node) bool {
    var cur: ?*Node = of;
    while (cur) |c| : (cur = c.parent) {
        if (c == maybe) return true;
    }
    return false;
}

/// Insert `child` at `position`, ADOPTING it out of whatever tree it was
/// in. A cycle — inserting an ancestor into its own descendant — is
/// refused outright rather than corrupting the tree.
fn insertChild(vm: *Vm, self: *Node, position: usize, child: *Node) !void {
    if (isAncestor(child, self)) return;
    if (child.parent) |old| {
        if (old != self) orphan(old, child);
    }
    child.parent = self;
    try self.children.insert(vm.arena(), @min(position, self.children.items.len), child);

    const idx = childIndex(self, child).?;
    const new_prev: ?*Node = if (idx > 0) self.children.items[idx - 1] else null;
    const new_next: ?*Node = if (idx + 1 < self.children.items.len) self.children.items[idx + 1] else null;
    adoptSiblings(child, new_prev, new_next);
}

fn orphan(p: *Node, child: *Node) void {
    if (childIndex(p, child)) |i| {
        _ = p.children.orderedRemove(i);
        disownSiblings(child);
    }
}

fn adoptSiblings(child: *Node, new_prev: ?*Node, new_next: ?*Node) void {
    if (new_prev) |pv| pv.next = child;
    if (new_next) |nx| nx.prev = child;
    child.prev = new_prev;
    child.next = new_next;
}

fn disownSiblings(child: *Node) void {
    if (child.prev) |pv| pv.next = child.next;
    if (child.next) |nx| nx.prev = child.prev;
    child.prev = null;
    child.next = null;
}

fn removeFromParent(n: *Node) void {
    const p = n.parent orelse return;
    if (childIndex(p, n)) |i| _ = p.children.orderedRemove(i);
    disownSiblings(n);
    n.parent = null;
}

/// Rewrite the cached `childNodes` array IN PLACE. Script may be holding
/// the array it got from an earlier read, and Flash keeps that live.
fn refreshChildNodes(vm: *Vm, n: *Node) !void {
    if (n.cached_child_nodes == 0) return;
    const arr = n.cached_child_nodes;
    const old = vm.arrayLength(arr);
    for (n.children.items, 0..) |c, i| {
        try vm.objects.put(arr, try indexName(vm, i), try scriptObject(vm, c), false);
    }
    var i: usize = n.children.items.len;
    while (i < old) : (i += 1) {
        _ = vm.objects.deleteOwn(arr, try indexName(vm, i), false);
    }
    try vm.setArrayLength(arr, @intCast(n.children.items.len));
}

fn indexName(vm: *Vm, i: usize) !AvmString {
    var buf: [16]u8 = undefined;
    const ascii = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    const wide = try vm.arena().alloc(u16, ascii.len);
    for (ascii, wide) |c, *w| w.* = c;
    return wide;
}

// --- serialisation --------------------------------------------------------------

/// A node and its subtree as XML text. An element with NO name — the
/// document root — writes only its children, which is what makes an
/// `XML`'s own `toString` return the document rather than a wrapper.
fn writeNode(vm: *Vm, n: *Node, out: *std.ArrayList(u16)) !void {
    const a = vm.arena();
    if (n.node_type == ELEMENT_NODE) {
        const name = n.node_value orelse {
            for (n.children.items) |c| try writeNode(vm, c, out);
            return;
        };
        try out.append(a, '<');
        try out.appendSlice(a, name);
        // Backwards: attributes are STORED in reverse definition order
        // (see `elementFrom`), and a serialised element lists them the
        // way the document wrote them.
        var ai = vm.objects.get(n.attributes).props.items.len;
        while (ai > 0) {
            ai -= 1;
            const prop = vm.objects.get(n.attributes).props.items[ai];
            const v = try vm.toStringValue(prop.value);
            try out.append(a, ' ');
            try out.appendSlice(a, prop.key);
            try out.appendSlice(a, S("=\""));
            try out.appendSlice(a, try parser.escape(a, v));
            try out.append(a, '"');
        }
        if (n.children.items.len == 0) {
            try out.appendSlice(a, S(" />"));
        } else {
            try out.append(a, '>');
            for (n.children.items) |c| try writeNode(vm, c, out);
            try out.appendSlice(a, S("</"));
            try out.appendSlice(a, name);
            try out.append(a, '>');
        }
    } else {
        const v = n.node_value orelse return;
        try out.appendSlice(a, try parser.escape(a, v));
    }
}

// --- XMLNode ---------------------------------------------------------------------

/// `new XMLNode(type, value)`. With fewer than two arguments it is an
/// EMPTY TEXT node, not an element.
fn ctorXmlNode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const n = if (args.len >= 2) blk: {
        const t: u8 = @truncate(@as(u32, @bitCast(value_mod.toInt32(try vm.toNumber(args[0])))));
        break :blk try newNode(vm, t, try vm.toStringValue(args[1]));
    } else try newNode(vm, TEXT_NODE, S(""));
    n.script_object = this.object;
    vm.objects.get(this.object).native = .{ .xml_node = @ptrCast(n) };
    return this;
}

fn appendChild(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    const child = nodeOf(vm, arg(args, 0)) orelse return .undefined_value;
    // Already a child of this node? Nothing happens — not even a move to
    // the end.
    if (childIndex(self, child) != null) return .undefined_value;
    const old_parent = child.parent;
    try insertChild(vm, self, self.children.items.len, child);
    try refreshChildNodes(vm, self);
    if (old_parent) |op| if (op != self) try refreshChildNodes(vm, op);
    return .undefined_value;
}

fn insertBefore(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    const child = nodeOf(vm, arg(args, 0)) orelse return .undefined_value;
    const point = nodeOf(vm, arg(args, 1)) orelse return .undefined_value;
    if (childIndex(self, child) != null) return .undefined_value;
    const position = childIndex(self, point) orelse return .undefined_value;
    const old_parent = child.parent;
    try insertChild(vm, self, position, child);
    try refreshChildNodes(vm, self);
    if (old_parent) |op| if (op != self) try refreshChildNodes(vm, op);
    return .undefined_value;
}

fn cloneNode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    const deep = args.len > 0 and value_mod.toBoolean(args[0], vm.swf_version);
    return scriptObject(vm, try duplicate(vm, self, deep));
}

/// A clone is DETACHED — no parent, no siblings — and carries the
/// attributes but never the script object: the copy is a new identity.
fn duplicate(vm: *Vm, self: *Node, deep: bool) !*Node {
    const out = try newNode(vm, self.node_type, self.node_value);
    for (vm.objects.get(self.attributes).props.items) |prop| {
        try vm.objects.put(out.attributes, prop.key, prop.value, false);
    }
    if (deep) {
        for (self.children.items, 0..) |c, i| {
            try insertChild(vm, out, i, try duplicate(vm, c, true));
        }
    }
    return out;
}

fn removeNode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    const old_parent = self.parent;
    removeFromParent(self);
    if (old_parent) |op| try refreshChildNodes(vm, op);
    return .undefined_value;
}

fn hasChildNodes(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    return .{ .boolean = self.children.items.len > 0 };
}

fn nodeToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .{ .string = S("") };
    var out: std.ArrayList(u16) = .empty;
    try writeNode(vm, self, &out);
    return .{ .string = try out.toOwnedSlice(vm.arena()) };
}

/// The URI a prefix resolves to, searching the node and then its
/// ANCESTORS and taking the FIRST declaration each carries.
///
/// An EMPTY prefix matches every attribute that starts with `xmlns`,
/// colon or no colon — which is why a node with no prefix of its own
/// still reports the nearest namespace as its `namespaceURI`.
fn lookupNamespaceUri(vm: *Vm, self: *Node, prefix: AvmString) ?Value {
    var cur: ?*Node = self;
    while (cur) |n| : (cur = n.parent) {
        const items = attrsInOrder(vm, n);
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const prop = items[i];
            if (!startsWithAscii(prop.key, "xmlns")) continue;
            const rest = prop.key[5..];
            if (prefix.len == 0) return prop.value;
            if (rest.len > 1 and rest[0] == ':' and strings.eql(rest[1..], prefix)) return prop.value;
        }
    }
    return null;
}

/// Walks the node and its ANCESTORS, so a prefix declared on an outer
/// element resolves from within.
fn getNamespaceForPrefix(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (args.len == 0) return .undefined_value;
    const prefix = try vm.toStringValue(args[0]);
    return lookupNamespaceUri(vm, self, prefix) orelse .null_value;
}

fn getPrefixForNamespace(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (args.len == 0) return .undefined_value;
    const uri = try vm.toStringValue(args[0]);
    var cur: ?*Node = self;
    while (cur) |n| : (cur = n.parent) {
        const items = attrsInOrder(vm, n);
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const prop = items[i];
            const v = try vm.toStringValue(prop.value);
            if (!strings.eql(v, uri)) continue;
            if (!startsWithAscii(prop.key, "xmlns")) continue;
            const rest = prop.key[5..];
            if (rest.len > 1 and rest[0] == ':') return .{ .string = rest[1..] };
            return .{ .string = S("") };
        }
    }
    return .null_value;
}

/// Attributes in DEFINITION order. Storage is reversed (see
/// `elementFrom`), and every namespace lookup wants the FIRST one the
/// document declared, so each walks back out of storage.
fn attrsInOrder(vm: *Vm, n: *Node) []const object_mod.Property {
    return vm.objects.get(n.attributes).props.items;
}

fn startsWithAscii(s: AvmString, comptime lit: []const u8) bool {
    if (s.len < lit.len) return false;
    inline for (lit, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return true;
}

fn getAttributes(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    return .{ .object = self.attributes };
}

fn getChildNodes(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.cached_child_nodes == 0) {
        self.cached_child_nodes = try vm.newArray();
        try vm.setArrayLength(self.cached_child_nodes, 0);
        try refreshChildNodes(vm, self);
    }
    return .{ .object = self.cached_child_nodes };
}

fn getFirstChild(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.children.items.len == 0) return .null_value;
    return scriptObject(vm, self.children.items[0]);
}

fn getLastChild(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.children.items.len == 0) return .null_value;
    return scriptObject(vm, self.children.items[self.children.items.len - 1]);
}

fn getNextSibling(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    return if (self.next) |n| scriptObject(vm, n) else .null_value;
}

fn getPrevSibling(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    return if (self.prev) |n| scriptObject(vm, n) else .null_value;
}

fn getParentNode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    return if (self.parent) |n| scriptObject(vm, n) else .null_value;
}

/// Only an ELEMENT has a node name; anything else reports null even
/// though the same slot holds its text.
fn getNodeName(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.node_type != ELEMENT_NODE) return .null_value;
    return if (self.node_value) |v| .{ .string = v } else .null_value;
}

/// And the mirror image: only a NON-element has a node value.
fn getNodeValue(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.node_type == ELEMENT_NODE) return .null_value;
    return if (self.node_value) |v| .{ .string = v } else .null_value;
}

fn setNodeValue(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len == 0 or args[0] == .undefined_value) return .undefined_value;
    const self = nodeOf(vm, this) orelse return .undefined_value;
    self.node_value = try vm.toStringValue(args[0]);
    return .undefined_value;
}

fn getNodeType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(self.node_type) };
}

/// `a:b` splits at the FIRST colon; a name with no colon is all local
/// name and an empty prefix.
fn getLocalName(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.node_type != ELEMENT_NODE) return .null_value;
    const name = self.node_value orelse return .null_value;
    if (std.mem.indexOfScalar(u16, name, ':')) |i| {
        if (i + 1 < name.len) return .{ .string = name[i + 1 ..] };
    }
    return .{ .string = name };
}

fn getPrefix(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.node_type != ELEMENT_NODE) return .null_value;
    const name = self.node_value orelse return .null_value;
    if (std.mem.indexOfScalar(u16, name, ':')) |i| {
        if (i + 1 < name.len) return .{ .string = name[0..i] };
    }
    return .{ .string = S("") };
}

/// The URI for the node's OWN prefix, through the same lookup
/// `getNamespaceForPrefix` uses — including its empty-prefix rule, so a
/// node with a bare name still reports the nearest namespace.
fn getNamespaceUri(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const self = nodeOf(vm, this) orelse return .undefined_value;
    if (self.node_type != ELEMENT_NODE) return .null_value;
    const name = self.node_value orelse return .null_value;
    var prefix: AvmString = S("");
    if (std.mem.indexOfScalar(u16, name, ':')) |i| {
        if (i + 1 < name.len) prefix = name[0..i];
    }
    return lookupNamespaceUri(vm, self, prefix) orelse .{ .string = S("") };
}

// --- XML -------------------------------------------------------------------------

fn ctorXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const doc = try emptyDoc(vm, this.object);
    if (args.len > 0) {
        const text = try vm.toStringValue(args[0]);
        try parseInto(vm, doc, this.object, text);
    }
    return this;
}

fn emptyDoc(vm: *Vm, obj: ObjectHandle) !*Document {
    // The ROOT is an element with no name — the one node that serialises
    // as just its children.
    const root = try newNode(vm, ELEMENT_NODE, null);
    root.script_object = obj;
    const doc = try vm.arena().create(Document);
    const id_map = try vm.objects.create();
    vm.objects.get(id_map).proto = .undefined_value;
    doc.* = .{ .root = root, .id_map = id_map };
    vm.objects.get(obj).native = .{ .xml_doc = @ptrCast(doc) };
    return doc;
}

fn parseXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const doc = docOf(vm, this) orelse return .undefined_value;
    // Every existing child goes first, whatever the new text turns out
    // to be — even a parse that fails leaves the document empty.
    while (doc.root.children.items.len > 0) {
        removeFromParent(doc.root.children.items[doc.root.children.items.len - 1]);
    }
    if (args.len > 0) {
        const text = try vm.toStringValue(args[0]);
        try parseInto(vm, doc, this.object, text);
    }
    try refreshChildNodes(vm, doc.root);
    return .undefined_value;
}

fn parseInto(vm: *Vm, doc: *Document, obj: ObjectHandle, text: AvmString) !void {
    const ignore_white = blk: {
        const v = vm.objects.getChained(obj, S("ignoreWhite"), vm.case_sensitive) orelse
            break :blk false;
        break :blk value_mod.toBoolean(v, vm.swf_version);
    };

    var open: std.ArrayList(*Node) = .empty;
    defer open.deinit(vm.arena());
    try open.append(vm.arena(), doc.root);

    var ps = parser.Parser.init(vm.arena(), text);
    doc.status = 0;
    while (try ps.next()) |ev| {
        const top = open.items[open.items.len - 1];
        switch (ev) {
            .start, .empty => |el| {
                const node = try elementFrom(vm, doc, el);
                try insertChild(vm, top, top.children.items.len, node);
                if (ev == .start) try open.append(vm.arena(), node);
            },
            .end => {
                // An end tag with nothing open is a MISMATCH, and the
                // parse stops there.
                if (open.items.len <= 1) {
                    doc.status = @intFromEnum(parser.Status.mismatched_end);
                    break;
                }
                _ = open.pop();
            },
            .text => |t| try addText(vm, top, t, ignore_white),
            // CDATA is never whitespace-collapsed and never unescaped.
            .cdata => |t| try addText(vm, top, t, false),
            .decl => |d| doc.xml_decl = d,
            .doctype => |d| doc.doctype = d,
            .comment => {},
        }
    }
    if (ps.status != .ok) doc.status = @intFromEnum(ps.status);
    try refreshChildNodes(vm, doc.root);
}

fn elementFrom(vm: *Vm, doc: *Document, el: parser.Event.Element) !*Node {
    const node = try newNode(vm, ELEMENT_NODE, el.name);
    // Stored in REVERSE definition order. A `for..in` pushes properties
    // in storage order and the script pops them, so reversing here is
    // what makes script see the attributes in the order the document
    // wrote them; the serialiser walks back the other way to match.
    var ri = el.attributes.len;
    while (ri > 0) {
        ri -= 1;
        const a = el.attributes[ri];
        try vm.objects.put(node.attributes, a.name, .{ .string = a.value }, false);
        // An `id` attribute also registers the node in the document's
        // `idMap`, which is how content finds a node without walking.
        if (strings.eql(a.name, S("id"))) {
            try vm.objects.put(doc.id_map, a.value, try scriptObject(vm, node), false);
        }
    }
    return node;
}

fn addText(vm: *Vm, parent: *Node, text: AvmString, ignore_white: bool) !void {
    if (text.len == 0) return;
    if (ignore_white) {
        var all_space = true;
        for (text) |c| {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') all_space = false;
        }
        if (all_space) return;
    }
    const node = try newNode(vm, TEXT_NODE, text);
    try insertChild(vm, parent, parent.children.items.len, node);
}

fn createElement(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    _ = docOf(vm, this) orelse return .undefined_value;
    const name = try vm.toStringValue(arg(args, 0));
    return scriptObject(vm, try newNode(vm, ELEMENT_NODE, name));
}

fn createTextNode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    _ = docOf(vm, this) orelse return .undefined_value;
    const text = try vm.toStringValue(arg(args, 0));
    return scriptObject(vm, try newNode(vm, TEXT_NODE, text));
}

fn getDocTypeDecl(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const doc = docOf(vm, this) orelse return .undefined_value;
    return if (doc.doctype) |d| .{ .string = d } else .undefined_value;
}

fn getXmlDecl(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const doc = docOf(vm, this) orelse return .undefined_value;
    return if (doc.xml_decl) |d| .{ .string = d } else .undefined_value;
}

fn setXmlDecl(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const doc = docOf(vm, this) orelse return .undefined_value;
    doc.xml_decl = try vm.toStringValue(arg(args, 0));
    return .undefined_value;
}

fn getStatus(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const doc = docOf(vm, this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(doc.status) };
}

fn setStatus(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const doc = docOf(vm, this) orelse return .undefined_value;
    doc.status = value_mod.toInt32(try vm.toNumber(arg(args, 0)));
    return .undefined_value;
}

fn getIdMap(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const doc = docOf(vm, this) orelse return .undefined_value;
    return .{ .object = doc.id_map };
}

/// Both are just readers for the undocumented `_bytesLoaded` and
/// `_bytesTotal` properties, which the LOADER writes. Nothing here ever
/// loads (`core/` does no I/O), so they read undefined — which is also
/// what a real player reports before a request is made.
fn getBytesLoaded(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return vm.objects.getChained(this.object, S("_bytesLoaded"), vm.case_sensitive) orelse .undefined_value;
}

fn getBytesTotal(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return vm.objects.getChained(this.object, S("_bytesTotal"), vm.case_sensitive) orelse .undefined_value;
}

/// `XML.load(url)`. A NULL url is rejected outright — undefined is not,
/// and fetches the string "undefined". Only a real XML document can load;
/// an XMLNode with the method borrowed onto it returns false.
fn load(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const url_val = decl.arg(args, 0);
    if (url_val == .null_value) return .{ .boolean = false };
    if (docOf(vm, this) == null) return .{ .boolean = false };
    const url = try vm.toStringValue(url_val);
    const l = @import("loader.zig");
    // The progress properties are reset on THIS, while the data lands on
    // the loader object — the same object here, but not in `sendAndLoad`.
    try l.resetProgress(vm, this.object);
    l.spawn(vm, try l.buildRequest(vm, url, null, .none, .{ .load_vars = this.object }));
    return .{ .boolean = true };
}

/// `XML.sendAndLoad(url, target)`. The body is THIS document serialised —
/// not form-encoded variables, which is where it parts company with
/// `LoadVars.sendAndLoad`. It is always a POST, and it returns undefined
/// rather than a success flag.
fn sendAndLoad(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const url_val = decl.arg(args, 0);
    if (url_val == .null_value) return .undefined_value;
    const target = decl.arg(args, 1);
    if (target != .object) return .undefined_value;
    const doc = docOf(vm, this) orelse return .undefined_value;
    const url = try vm.toStringValue(url_val);
    const l = @import("loader.zig");
    var body: std.ArrayList(u16) = .empty;
    try writeNode(vm, doc.root, &body);
    try l.resetProgress(vm, this.object);
    l.spawn(vm, .{
        .url = try strings.toUtf8(vm.arena(), url),
        .method = .post,
        .body = try strings.toUtf8(vm.arena(), body.items),
        .target = .{ .load_vars = target.object },
    });
    return .undefined_value;
}

/// `XML.prototype.onData`: parse and report. Undefined data means the load
/// failed, and `onLoad` hears about it without `parseXML` ever running.
fn onData(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const src = decl.arg(args, 0);
    const l = @import("loader.zig");
    if (src == .undefined_value) {
        try l.callMethod(vm, this.object, S("onLoad"), &.{.{ .boolean = false }});
        return .undefined_value;
    }
    try l.callMethod(vm, this.object, S("parseXML"), &.{.{ .string = try vm.toStringValue(src) }});
    try vm.setProperty(this.object, S("loaded"), .{ .boolean = true }, this);
    try l.callMethod(vm, this.object, S("onLoad"), &.{.{ .boolean = true }});
    return .undefined_value;
}
