//! Document and Parser — the unified, production-ready parsing API for httpx.zig.
//!
//! Provides native, ergonomic HTML, XML, RSS/Atom/JSON feeds,
//! robots.txt, and Sitemap XML parsing with unified allocator lifecycle management.

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

    pub fn innerHtml(self: NodeHandle) []const u8 {
        return self.tree.get(self.node_idx).innerHtml(self.tree);
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

