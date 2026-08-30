//! DOM node tree for HTML/XML documents.
//!
//! Nodes are stored in a flat ArrayList and addressed by u32 index.
//! Memory is owned by a single ArenaAllocator inside `Document`, so
//! deallocation is O(1): just free the arena.

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

pub const Node = struct {
    kind: NodeKind,
    /// Element tag name (lower-cased for HTML). Empty for non-element nodes.
    tag: []const u8 = "",
    /// Attribute list for element nodes.
    attrs: []const Attribute = &.{},
    /// Raw text content for text/comment/cdata/doctype nodes.
    data: []const u8 = "",
    /// Tree links (all NO_NODE when unset).
    parent: u32 = NO_NODE,
    first_child: u32 = NO_NODE,
    last_child: u32 = NO_NODE,
    prev_sibling: u32 = NO_NODE,
    next_sibling: u32 = NO_NODE,

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
    pub fn appendChild(self: *Tree, parent_idx: u32, child_idx: u32) void {
        const parent = self.getMut(parent_idx);
        const prev_last = parent.last_child;
        parent.last_child = child_idx;
        if (parent.first_child == NO_NODE) parent.first_child = child_idx;

        const child = self.getMut(child_idx);
        child.parent = parent_idx;
        child.prev_sibling = prev_last;

        if (prev_last != NO_NODE) {
            self.getMut(prev_last).next_sibling = child_idx;
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
            var sib = node.last_child;
            while (sib != NO_NODE) {
                self.stack.append(self.allocator, sib) catch {};
                sib = self.tree.get(sib).prev_sibling;
            }
            return idx;
        }
    };

    /// Returns a depth-first walker starting at `root_idx`.
    pub fn walk(self: *const Tree, allocator: Allocator, root_idx: u32) !WalkState {
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(allocator, root_idx);
        return .{ .tree = self, .stack = stack, .allocator = allocator };
    }

    /// Collects all element nodes with `t` into `out`.
    pub fn getElementsByTag(
        self: *const Tree,
        allocator: Allocator,
        root_idx: u32,
        t: []const u8,
        out: *std.ArrayList(u32),
    ) !void {
        var w = try self.walk(allocator, root_idx);
        defer w.deinit();
        while (w.next()) |idx| {
            const node = self.get(idx);
            if (node.kind == .element and node.hasTag(t)) {
                try out.append(allocator, idx);
            }
        }
    }

    /// Returns the first element with `id` attribute matching `id_val`.
    pub fn getElementById(self: *const Tree, allocator: Allocator, root_idx: u32, id_val: []const u8) !?u32 {
        var w = try self.walk(allocator, root_idx);
        defer w.deinit();
        while (w.next()) |idx| {
            const node = self.get(idx);
            if (node.kind == .element) {
                if (node.attr("id")) |v| {
                    if (std.mem.eql(u8, v, id_val)) return idx;
                }
            }
        }
        return null;
    }

    /// Recursively concatenates all text node descendants of `root_idx`.
    pub fn innerText(self: *const Tree, allocator: Allocator, root_idx: u32) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = try self.walk(allocator, root_idx);
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
};

test "tree basic append and walk" {
    const a = std.testing.allocator;
    var tree: Tree = .{ .nodes = .empty };
    defer tree.deinit(a);

    const root = try tree.append(a, .{ .kind = .document });
    const elem = try tree.append(a, .{ .kind = .element, .tag = "div" });
    const txt = try tree.append(a, .{ .kind = .text, .data = "hello" });

    tree.appendChild(root, elem);
    tree.appendChild(elem, txt);

    try std.testing.expectEqual(@as(u32, NO_NODE), tree.get(root).parent);
    try std.testing.expectEqual(elem, tree.get(root).first_child);
    try std.testing.expectEqual(txt, tree.get(elem).first_child);
    try std.testing.expectEqual(elem, tree.get(txt).parent);
}
