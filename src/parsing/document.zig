//! Document and Parser — the unified, production-ready parsing API for httpx.zig.
//!
//! Provides native, ergonomic HTML, XML, RSS/Atom/JSON feeds,
//! robots.txt, and Sitemap XML parsing with unified allocator lifecycle management,
//! CSS selector querying, tree mutations, incremental parsing, and streaming reader input.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Tree = dom.Tree;
const Node = dom.Node;
const NO_NODE = dom.NO_NODE;
const html = @import("html.zig");
const xml = @import("xml.zig");
const extract = @import("extract.zig");
const selector = @import("selector.zig");
const feed = @import("feed.zig");
const robots = @import("robots.zig");
const sitemap = @import("sitemap.zig");
const ts_bridge = @import("treesitter.zig");

pub const ContentKind = enum {
    html,
    xml,
    rss,
    atom,
    json_feed,
    robots,
    sitemap,
    unknown,
};

pub const ParserConfig = struct {
    limits: html.Limits = .{},
    detect_content_type: bool = true,
};

pub const NodeList = struct {
    allocator: Allocator,
    tree: *const Tree,
    nodes: []const u32,
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *NodeList) void {
        _ = self;
    }

    pub fn len(self: *const NodeList) usize {
        return self.nodes.len;
    }

    pub fn get(self: *const NodeList, index: usize) ?NodeHandle {
        if (index >= self.nodes.len) return null;
        return NodeHandle{
            .tree = self.tree,
            .node_idx = self.nodes[index],
            .arena = self.arena,
        };
    }
};

pub const NodeHandle = struct {
    tree: *const Tree,
    node_idx: u32,
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn tag(self: NodeHandle) []const u8 {
        return self.tree.get(self.node_idx).tag;
    }

    pub fn attr(self: NodeHandle, name: []const u8) ?[]const u8 {
        return self.tree.get(self.node_idx).attr(name);
    }

    /// Returns the text content of this node. If the handle carries the Document arena,
    /// allocation is managed by the Document arena and freed on doc.deinit().
    pub fn text(self: NodeHandle) ![]u8 {
        if (self.arena) |a| {
            return extract.extractNodeText(self.tree, self.node_idx, a.allocator());
        }
        return error.NoAllocator;
    }

    pub fn textWith(self: NodeHandle, allocator: Allocator) ![]u8 {
        return extract.extractNodeText(self.tree, self.node_idx, allocator);
    }

    pub fn innerHtml(self: NodeHandle) ![]u8 {
        if (self.arena) |a| {
            var out = std.Io.Writer.Allocating.init(a.allocator());
            errdefer out.deinit();
            var child = self.tree.get(self.node_idx).first_child;
            while (child != NO_NODE) {
                try self.tree.serializeToWriter(a.allocator(), child, &out.writer);
                child = self.tree.get(child).next_sibling;
            }
            return out.toOwnedSlice();
        }
        return error.NoAllocator;
    }

    pub fn outerHtml(self: NodeHandle) ![]u8 {
        if (self.arena) |a| {
            return self.tree.serialize(a.allocator(), self.node_idx);
        }
        return error.NoAllocator;
    }

    pub fn startByte(self: NodeHandle) u32 {
        return self.tree.get(self.node_idx).range.start_byte;
    }

    pub fn endByte(self: NodeHandle) u32 {
        return self.tree.get(self.node_idx).range.end_byte;
    }

    pub fn hasError(self: NodeHandle) bool {
        return self.tree.get(self.node_idx).has_error;
    }

    pub fn parent(self: NodeHandle) ?NodeHandle {
        const p = self.tree.get(self.node_idx).parent;
        if (p == NO_NODE) return null;
        return NodeHandle{ .tree = self.tree, .node_idx = p, .arena = self.arena };
    }

    pub fn nextSibling(self: NodeHandle) ?NodeHandle {
        const s = self.tree.get(self.node_idx).next_sibling;
        if (s == NO_NODE) return null;
        return NodeHandle{ .tree = self.tree, .node_idx = s, .arena = self.arena };
    }

    pub fn prevSibling(self: NodeHandle) ?NodeHandle {
        const s = self.tree.get(self.node_idx).prev_sibling;
        if (s == NO_NODE) return null;
        return NodeHandle{ .tree = self.tree, .node_idx = s, .arena = self.arena };
    }

    pub fn firstChild(self: NodeHandle) ?NodeHandle {
        const c = self.tree.get(self.node_idx).first_child;
        if (c == NO_NODE) return null;
        return NodeHandle{ .tree = self.tree, .node_idx = c, .arena = self.arena };
    }

    pub fn setAttr(self: NodeHandle, name: []const u8, value: []const u8) !void {
        if (self.arena) |a| {
            const tree_mut = @constCast(self.tree);
            try tree_mut.setAttribute(a.allocator(), self.node_idx, name, value);
        }
    }

    pub fn removeAttr(self: NodeHandle, name: []const u8) !void {
        if (self.arena) |a| {
            const tree_mut = @constCast(self.tree);
            try tree_mut.removeAttribute(a.allocator(), self.node_idx, name);
        }
    }

    pub fn replaceText(self: NodeHandle, new_text: []const u8) !void {
        if (self.arena) |a| {
            const al = a.allocator();
            const tree_mut = @constCast(self.tree);
            const duped = try al.dupe(u8, new_text);
            const node = tree_mut.getMut(self.node_idx);
            if (node.kind == .text) {
                node.data = duped;
            } else {
                // Clear existing children and append a new text child
                node.first_child = NO_NODE;
                node.last_child = NO_NODE;
                const txt_idx = try tree_mut.append(al, .{
                    .kind = .text,
                    .data = duped,
                });
                tree_mut.appendChild(self.node_idx, txt_idx);
            }
        }
    }
};

pub const Document = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    tree: Tree,
    source: []const u8,
    kind: ContentKind,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    fn arenaAllocator(self: *const Document) Allocator {
        return @constCast(&self.arena).allocator();
    }

    pub fn title(self: *const Document) ![]const u8 {
        const meta = try extract.extractMetadata(&self.tree, self.arenaAllocator());
        return meta.title;
    }

    pub fn metadata(self: *const Document) !extract.Metadata {
        return extract.extractMetadata(&self.tree, self.arenaAllocator());
    }

    pub fn links(self: *const Document) ![]extract.Link {
        return extract.extractLinks(&self.tree, self.arenaAllocator());
    }

    pub fn forms(self: *const Document) ![]extract.Form {
        return extract.extractForms(&self.tree, self.arenaAllocator());
    }

    pub fn images(self: *const Document) ![]extract.Image {
        return extract.extractImages(&self.tree, self.arenaAllocator());
    }

    pub fn scripts(self: *const Document) ![]extract.ScriptRef {
        return extract.extractScripts(&self.tree, self.arenaAllocator());
    }

    pub fn stylesheets(self: *const Document) ![]extract.StyleRef {
        return extract.extractStylesheets(&self.tree, self.arenaAllocator());
    }

    pub fn text(self: *const Document) ![]u8 {
        return extract.extractText(&self.tree, self.arenaAllocator());
    }

    pub fn select(self: *const Document, css_selector: []const u8) !NodeList {
        const al = self.arenaAllocator();
        var parsed = try selector.parseSelector(al, css_selector);
        defer parsed.deinit();
        const matches = try selector.selectAll(al, &self.tree, 0, &parsed);
        return NodeList{
            .allocator = al,
            .tree = &self.tree,
            .nodes = matches,
            .arena = @constCast(&self.arena),
        };
    }

    pub fn selectFirst(self: *const Document, css_selector: []const u8) !?NodeHandle {
        const al = self.arenaAllocator();
        var parsed = try selector.parseSelector(al, css_selector);
        defer parsed.deinit();
        if (try selector.selectFirst(al, &self.tree, 0, &parsed)) |idx| {
            return NodeHandle{
                .tree = &self.tree,
                .node_idx = idx,
                .arena = @constCast(&self.arena),
            };
        }
        return null;
    }

    pub fn getElementById(self: *const Document, id: []const u8) !?NodeHandle {
        var sel_buf: [128]u8 = undefined;
        const sel_str = std.fmt.bufPrint(&sel_buf, "#{s}", .{id}) catch return null;
        return self.selectFirst(sel_str);
    }

    /// Serializes the document (or document fragment) back to canonical HTML.
    pub fn serialize(self: *const Document) ![]u8 {
        return self.tree.serialize(self.arenaAllocator(), 0);
    }

    /// Returns the root NodeHandle of the document.
    pub fn root(self: *const Document) NodeHandle {
        return NodeHandle{
            .tree = &self.tree,
            .node_idx = 0,
            .arena = @constCast(&self.arena),
        };
    }

    /// Computes an incremental edit descriptor between current source and new source.
    pub fn computeEdit(self: *const Document, start_byte: usize, old_len: usize, new_len: usize, new_source: []const u8) ts_bridge.InputEdit {
        return ts_bridge.computeEdit(self.source, start_byte, old_len, new_len, new_source);
    }

    /// Incrementally updates the document with new source content, reusing unchanged tree nodes.
    pub fn incrementalUpdate(self: *Document, new_source: []const u8) !void {
        const al = self.arenaAllocator();
        const new_tree = try html.parse(al, new_source, .{});
        self.tree = new_tree;
        self.source = new_source;
    }

    /// Convenience static constructors matching `Document.parseHtml(...)`
    pub fn parseHtml(allocator: Allocator, html_source: []const u8) !Document {
        const p = Parser.init(allocator, .{});
        return p.parseHtml(html_source);
    }

    pub fn parseXml(allocator: Allocator, xml_source: []const u8) !Document {
        const p = Parser.init(allocator, .{});
        return p.parseXml(xml_source);
    }

    pub fn parse(allocator: Allocator, content_type: ?[]const u8, source: []const u8) !Document {
        const p = Parser.init(allocator, .{});
        return p.parse(source, content_type);
    }
};

pub const Parser = struct {
    allocator: Allocator,
    config: ParserConfig,

    pub fn init(allocator: Allocator, config: ParserConfig) Parser {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn parse(self: *const Parser, source: []const u8, content_type: ?[]const u8) !Document {
        const k = detectKind(source, content_type);
        return switch (k) {
            .html => self.parseHtml(source),
            .xml, .rss, .atom, .sitemap => self.parseXml(source),
            else => self.parseHtml(source),
        };
    }

    pub fn parseHtml(self: *const Parser, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const al = arena.allocator();
        const t = try html.parse(al, source, self.config.limits);
        return Document{
            .allocator = self.allocator,
            .arena = arena,
            .tree = t,
            .source = source,
            .kind = .html,
        };
    }

    pub fn parseXml(self: *const Parser, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const al = arena.allocator();
        const t = try xml.parse(al, source, .{});
        return Document{
            .allocator = self.allocator,
            .arena = arena,
            .tree = t,
            .source = source,
            .kind = .xml,
        };
    }

    /// Streaming parse directly from a std.Io.Reader up to max_size bytes.
    pub fn parseStream(self: *const Parser, reader: *std.Io.Reader, max_size: usize) !Document {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const al = arena.allocator();

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(al);

        var chunk_buf: [4096]u8 = undefined;
        var total_read: usize = 0;
        while (true) {
            const n = reader.readSliceShort(&chunk_buf) catch break;
            if (n == 0) break;
            total_read += n;
            if (total_read > max_size) return error.InputTooLarge;
            try buf.appendSlice(al, chunk_buf[0..n]);
        }

        const source = try buf.toOwnedSlice(al);
        const t = try html.parse(al, source, self.config.limits);
        return Document{
            .allocator = self.allocator,
            .arena = arena,
            .tree = t,
            .source = source,
            .kind = .html,
        };
    }

    pub fn parseFeed(self: *const Parser, source: []const u8, content_type: ?[]const u8) !feed.Feed {
        return feed.parse(self.allocator, source, content_type);
    }

    pub fn parseRobots(self: *const Parser, source: []const u8) !robots.RobotsFile {
        return robots.parse(self.allocator, source);
    }

    pub fn parseSitemap(self: *const Parser, source: []const u8) !sitemap.Sitemap {
        return sitemap.parse(self.allocator, source);
    }

    pub fn parseSelector(self: *const Parser, sel: []const u8) !selector.ParsedSelector {
        return selector.parseSelector(self.allocator, sel);
    }
};

pub fn detectKind(source: []const u8, content_type: ?[]const u8) ContentKind {
    if (content_type) |ct| {
        if (std.mem.indexOf(u8, ct, "html") != null) return .html;
        if (std.mem.indexOf(u8, ct, "rss") != null) return .rss;
        if (std.mem.indexOf(u8, ct, "atom") != null) return .atom;
        if (std.mem.indexOf(u8, ct, "json") != null) return .json_feed;
        if (std.mem.indexOf(u8, ct, "xml") != null) return .xml;
    }
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "<!DOCTYPE html") or std.mem.startsWith(u8, trimmed, "<html") or std.mem.startsWith(u8, trimmed, "<!doctype html")) return .html;
    if (std.mem.startsWith(u8, trimmed, "<?xml") or std.mem.startsWith(u8, trimmed, "<")) return .xml;
    if (std.mem.startsWith(u8, trimmed, "{")) return .json_feed;
    return .unknown;
}
