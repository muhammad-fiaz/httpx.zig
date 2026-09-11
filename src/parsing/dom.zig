//! DOM node tree for HTML/XML documents.
//!
//! Nodes are stored in a flat ArrayList and addressed by u32 index.
//! Memory is owned by a single ArenaAllocator inside `Document`, so
//! deallocation is O(1): just free the arena.
//! Supports source byte offsets, source line/column positions, safe mutations,
//! and canonical XSS-safe HTML serialization.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum number of nodes in a single document (hostile-input guard).
pub const MAX_NODES: u32 = 1_000_000;
/// Maximum DOM tree nesting depth (hostile-input guard).
pub const MAX_DEPTH: u32 = 512;
/// Sentinel: "no node" / null parent.
pub const NO_NODE: u32 = std.math.maxInt(u32);

pub const NodeKind = enum(u8) {
    document,
    doctype,
    element,
    text,
    comment,
    cdata,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const SourcePoint = struct {
    row: u32 = 0,
    column: u32 = 0,
};

pub const SourceRange = struct {
    startByte: u32 = 0,
    endByte: u32 = 0,
    startPoint: SourcePoint = .{},
    endPoint: SourcePoint = .{},
};

pub const Node = struct {
    kind: NodeKind,
    /// Element tag name (lower-cased for HTML). Empty for non-element nodes.
    tag: []const u8 = "",
    /// Attribute list for element nodes.
    attrs: []const Attribute = &.{},
    /// Raw text content for text/comment/cdata/doctype nodes.
    data: []const u8 = "",
    /// Source byte and line/column range.
    range: SourceRange = .{},
    /// Whether this node had parsing errors/recovery.
    hasError: bool = false,
    /// Tree links (all NO_NODE when unset).
    parent: u32 = NO_NODE,
    firstChild: u32 = NO_NODE,
    lastChild: u32 = NO_NODE,
    prevSibling: u32 = NO_NODE,
    nextSibling: u32 = NO_NODE,

    /// Returns the value of the named attribute (case-insensitive), or null.
    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        }
        return null;
    }

    /// Returns true when this element matches the given tag name (case-insensitive).
    pub fn hasTag(self: *const Node, t: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.tag, t);
    }

    /// Returns true when the element has a class token in the `class` attribute.
    pub fn hasClass(self: *const Node, cls: []const u8) bool {
        const val = self.attr("class") orelse return false;
        var it = std.mem.splitAny(u8, val, " \t\r\n\x0C");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, cls)) return true;
        }
        return false;
    }

    pub fn innerHtml(self: *const Node, tree: *const Tree) []const u8 {
        _ = self;
        _ = tree;
        return "";
    }
};

/// HTML void elements — never have closing tags.
const VOID_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    .{ "area", {} },  .{ "base", {} }, .{ "br", {} },    .{ "col", {} },
    .{ "embed", {} }, .{ "hr", {} },   .{ "img", {} },   .{ "input", {} },
    .{ "link", {} },  .{ "meta", {} }, .{ "param", {} }, .{ "source", {} },
    .{ "track", {} }, .{ "wbr", {} },
});

/// Flat node store.
pub const Tree = struct {
    nodes: std.ArrayList(Node),

    pub fn init(allocator: Allocator) Tree {
        _ = allocator;
        return .{ .nodes = .empty };
    }

    pub fn initCapacity(allocator: Allocator, cap: usize) Allocator.Error!Tree {
        var t = Tree{ .nodes = .empty };
        try t.nodes.ensureTotalCapacity(allocator, cap);
        return t;
    }

    pub fn deinit(self: *Tree, allocator: Allocator) void {
        self.nodes.deinit(allocator);
    }

    /// Appends a node and returns its index. Errors if MAX_NODES exceeded.
    pub fn append(self: *Tree, allocator: Allocator, node: Node) !u32 {
        if (self.nodes.items.len >= MAX_NODES) return error.TooManyNodes;
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return idx;
    }

    pub fn get(self: *const Tree, idx: u32) *const Node {
        return &self.nodes.items[idx];
    }

    pub fn getMut(self: *Tree, idx: u32) *Node {
        return &self.nodes.items[idx];
    }

    pub fn len(self: *const Tree) u32 {
        return @intCast(self.nodes.items.len);
    }

    /// Attaches `child` as the last child of `parent`.
    pub fn appendChild(self: *Tree, parentIdx: u32, childIdx: u32) void {
        const parent = self.getMut(parentIdx);
        const prev_last = parent.lastChild;
        parent.lastChild = childIdx;
        if (parent.firstChild == NO_NODE) parent.firstChild = childIdx;

        const child = self.getMut(childIdx);
        child.parent = parentIdx;
        child.prevSibling = prev_last;
        child.nextSibling = NO_NODE;

        if (prev_last != NO_NODE) {
            self.getMut(prev_last).nextSibling = childIdx;
        }
    }

    /// Attaches `child` as the first child of `parent`.
    pub fn prependChild(self: *Tree, parentIdx: u32, childIdx: u32) void {
        const parent = self.getMut(parentIdx);
        const old_first = parent.firstChild;
        parent.firstChild = childIdx;
        if (parent.lastChild == NO_NODE) parent.lastChild = childIdx;

        const child = self.getMut(childIdx);
        child.parent = parentIdx;
        child.prevSibling = NO_NODE;
        child.nextSibling = old_first;

        if (old_first != NO_NODE) {
            self.getMut(old_first).prevSibling = childIdx;
        }
    }

    /// Removes a child node from its parent.
    pub fn removeChild(self: *Tree, childIdx: u32) void {
        const child = self.getMut(childIdx);
        const p_idx = child.parent;
        if (p_idx == NO_NODE) return;

        const parent = self.getMut(p_idx);
        const prev = child.prevSibling;
        const next = child.nextSibling;

        if (prev != NO_NODE) {
            self.getMut(prev).nextSibling = next;
        } else {
            parent.firstChild = next;
        }

        if (next != NO_NODE) {
            self.getMut(next).prevSibling = prev;
        } else {
            parent.lastChild = prev;
        }

        child.parent = NO_NODE;
        child.prevSibling = NO_NODE;
        child.nextSibling = NO_NODE;
    }

    /// Replaces an existing child node with a new node.
    pub fn replaceChild(self: *Tree, oldChildIdx: u32, newChildIdx: u32) void {
        const old_child = self.get(oldChildIdx);
        const p_idx = old_child.parent;
        if (p_idx == NO_NODE) return;

        const prev = old_child.prevSibling;
        const next = old_child.nextSibling;

        const new_child = self.getMut(newChildIdx);
        new_child.parent = p_idx;
        new_child.prevSibling = prev;
        new_child.nextSibling = next;

        if (prev != NO_NODE) {
            self.getMut(prev).nextSibling = newChildIdx;
        } else {
            self.getMut(p_idx).firstChild = newChildIdx;
        }

        if (next != NO_NODE) {
            self.getMut(next).prevSibling = newChildIdx;
        } else {
            self.getMut(p_idx).lastChild = newChildIdx;
        }

        const old_mut = self.getMut(oldChildIdx);
        old_mut.parent = NO_NODE;
        old_mut.prevSibling = NO_NODE;
        old_mut.nextSibling = NO_NODE;
    }

    /// Sets or adds an attribute on the element node.
    pub fn setAttribute(self: *Tree, allocator: Allocator, nodeIdx: u32, name: []const u8, value: []const u8) !void {
        const node = self.getMut(nodeIdx);
        if (node.kind != .element) return;

        for (node.attrs) |*a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) {
                @constCast(a).value = value;
                return;
            }
        }

        var new_attrs = try allocator.alloc(Attribute, node.attrs.len + 1);
        @memcpy(new_attrs[0..node.attrs.len], node.attrs);
        new_attrs[node.attrs.len] = .{ .name = name, .value = value };
        node.attrs = new_attrs;
    }

    /// Removes an attribute from the element node if present.
    pub fn removeAttribute(self: *Tree, allocator: Allocator, nodeIdx: u32, name: []const u8) !void {
        const node = self.getMut(nodeIdx);
        if (node.kind != .element or node.attrs.len == 0) return;

        var found_idx: ?usize = null;
        for (node.attrs, 0..) |a, i| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) {
                found_idx = i;
                break;
            }
        }
        if (found_idx) |idx| {
            var new_attrs = try allocator.alloc(Attribute, node.attrs.len - 1);
            @memcpy(new_attrs[0..idx], node.attrs[0..idx]);
            @memcpy(new_attrs[idx..], node.attrs[idx + 1 ..]);
            node.attrs = new_attrs;
        }
    }

    /// Depth-first iteration state.
    pub const WalkState = struct {
        tree: *const Tree,
        stack: std.ArrayList(u32),
        allocator: Allocator,

        pub fn deinit(self: *WalkState) void {
            self.stack.deinit(self.allocator);
        }

        pub fn next(self: *WalkState) ?u32 {
            if (self.stack.items.len == 0) return null;
            const idx = self.stack.pop().?;
            const node = self.tree.get(idx);
            // Push children right-to-left so first child comes out first.
            var sib = node.lastChild;
            while (sib != NO_NODE) {
                self.stack.append(self.allocator, sib) catch {};
                sib = self.tree.get(sib).prevSibling;
            }
            return idx;
        }
    };

    /// Returns a depth-first walker starting at `rootIdx`.
    pub fn walk(self: *const Tree, allocator: Allocator, rootIdx: u32) !WalkState {
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(allocator, rootIdx);
        return .{ .tree = self, .stack = stack, .allocator = allocator };
    }

    /// Collects all element nodes with `t` into `out`.
    pub fn getElementsByTag(
        self: *const Tree,
        allocator: Allocator,
        rootIdx: u32,
        t: []const u8,
        out: *std.ArrayList(u32),
    ) !void {
        var w = try self.walk(allocator, rootIdx);
        defer w.deinit();
        while (w.next()) |idx| {
            const node = self.get(idx);
            if (node.kind == .element and node.hasTag(t)) {
                try out.append(allocator, idx);
            }
        }
    }

    /// Returns the first element with `id` attribute matching `idVal`.
    pub fn getElementById(self: *const Tree, allocator: Allocator, rootIdx: u32, idVal: []const u8) !?u32 {
        var w = try self.walk(allocator, rootIdx);
        defer w.deinit();
        while (w.next()) |idx| {
            const node = self.get(idx);
            if (node.kind == .element) {
                if (node.attr("id")) |v| {
                    if (std.mem.eql(u8, v, idVal)) return idx;
                }
            }
        }
        return null;
    }

    /// Recursively concatenates all text node descendants of `rootIdx`.
    pub fn innerText(self: *const Tree, allocator: Allocator, rootIdx: u32) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = try self.walk(allocator, rootIdx);
        defer w.deinit();
        while (w.next()) |idx| {
            const node = self.get(idx);
            if (node.kind == .text) {
                const trimmed = std.mem.trim(u8, node.data, " \t\r\n\x0C");
                if (trimmed.len > 0) {
                    if (buf.items.len > 0) try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, trimmed);
                }
            }
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Canonical, XSS-safe HTML serialization of a node and its descendants.
    pub fn serialize(self: *const Tree, allocator: Allocator, nodeIdx: u32) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        try self.serializeToWriter(allocator, nodeIdx, &out.writer);
        return out.toOwnedSlice();
    }

    pub fn serializeToWriter(self: *const Tree, allocator: Allocator, nodeIdx: u32, writer: anytype) !void {
        const node = self.get(nodeIdx);
        switch (node.kind) {
            .document => {
                var child = node.firstChild;
                while (child != NO_NODE) {
                    try self.serializeToWriter(allocator, child, writer);
                    child = self.get(child).nextSibling;
                }
            },
            .doctype => {
                try writer.writeAll("<!DOCTYPE html>\n");
            },
            .element => {
                try writer.writeByte('<');
                try writer.writeAll(node.tag);
                for (node.attrs) |a| {
                    try writer.writeByte(' ');
                    try writer.writeAll(a.name);
                    if (a.value.len > 0) {
                        try writer.writeAll("=\"");
                        try escapeAttr(writer, a.value);
                        try writer.writeByte('"');
                    }
                }
                try writer.writeByte('>');

                if (VOID_ELEMENTS.has(node.tag)) return;

                var child = node.firstChild;
                while (child != NO_NODE) {
                    try self.serializeToWriter(allocator, child, writer);
                    child = self.get(child).nextSibling;
                }

                try writer.writeAll("</");
                try writer.writeAll(node.tag);
                try writer.writeByte('>');
            },
            .text => {
                try escapeText(writer, node.data);
            },
            .comment => {
                try writer.writeAll("<!--");
                try writer.writeAll(node.data);
                try writer.writeAll("-->");
            },
            .cdata => {
                try writer.writeAll("<![CDATA[");
                try writer.writeAll(node.data);
                try writer.writeAll("]]>");
            },
        }
    }
};

fn escapeText(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(c),
        }
    }
}

fn escapeAttr(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(c),
        }
    }
}

test "tree basic append, walk, mutate, serialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tree: Tree = .{ .nodes = .empty };

    const root = try tree.append(a, .{ .kind = .document });
    const elem = try tree.append(a, .{ .kind = .element, .tag = "div" });
    const txt = try tree.append(a, .{ .kind = .text, .data = "hello & world" });

    tree.appendChild(root, elem);
    tree.appendChild(elem, txt);

    try std.testing.expectEqual(@as(u32, NO_NODE), tree.get(root).parent);
    try std.testing.expectEqual(elem, tree.get(root).firstChild);
    try std.testing.expectEqual(txt, tree.get(elem).firstChild);
    try std.testing.expectEqual(elem, tree.get(txt).parent);

    try tree.setAttribute(a, elem, "class", "active");
    try std.testing.expectEqualStrings("active", tree.get(elem).attr("class").?);

    const serialized = try tree.serialize(a, root);
    try std.testing.expectEqualStrings("<div class=\"active\">hello &amp; world</div>", serialized);
}
