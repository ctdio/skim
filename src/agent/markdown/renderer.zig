//! Markdown AST Traversal and Styled Span Generation
//!
//! Transforms parsed markdown AST into styled spans for terminal rendering.
//! Handles inline elements: headers, emphasis, inline code, links.

const std = @import("std");
const vaxis = @import("vaxis");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const colors_mod = @import("colors.zig");
const parser_mod = @import("parser.zig");

const NodeType = types.NodeType;
const StyledSpan = types.StyledSpan;
const MarkdownColors = colors_mod.MarkdownColors;
const MarkdownParser = parser_mod.MarkdownParser;

/// Renderer for transforming markdown AST into styled spans
pub const MarkdownRenderer = struct {
    allocator: std.mem.Allocator,
    colors: MarkdownColors,
    spans: std.ArrayList(StyledSpan),
    style_stack: std.ArrayList(vaxis.Style),

    /// Initialize a new markdown renderer
    pub fn init(allocator: std.mem.Allocator, md_colors: MarkdownColors) MarkdownRenderer {
        return .{
            .allocator = allocator,
            .colors = md_colors,
            .spans = std.ArrayList(StyledSpan).init(allocator),
            .style_stack = std.ArrayList(vaxis.Style).init(allocator),
        };
    }

    /// Clean up renderer resources
    pub fn deinit(self: *MarkdownRenderer) void {
        self.spans.deinit();
        self.style_stack.deinit();
    }

    /// Render markdown source into styled spans
    /// Returns owned slice of spans (caller must free underlying list if needed)
    pub fn render(self: *MarkdownRenderer, md_parser: *const MarkdownParser) ![]StyledSpan {
        // Clear any previous state
        self.spans.clearRetainingCapacity();
        self.style_stack.clearRetainingCapacity();

        // Push base text style
        try self.style_stack.append(self.colors.text);

        // Get root node and traverse
        const root = md_parser.getRoot() orelse return self.spans.items;

        // Use our own recursive traversal for more control
        try self.renderNode(root, md_parser, 0);

        return self.spans.items;
    }

    /// Recursively render a node and its children
    fn renderNode(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser, depth: usize) !void {
        const node_type_str = node.nodeType() orelse return;
        const node_type = NodeType.fromTreeSitter(node_type_str);

        // Check if this is a marker node that should be hidden
        if (isMarkerNode(node_type_str)) {
            return; // Skip markers like #, **, `, etc.
        }

        // Get style for this node type (if any)
        const node_style = self.getStyleForNode(node_type, node, md_parser);

        // Push style if we have one
        if (node_style) |style| {
            try self.style_stack.append(colors_mod.mergeStyles(self.currentStyle(), style));
        }

        // Process based on node type
        const child_count = node.childCount();

        if (child_count == 0) {
            // Leaf node - emit text span
            const text = md_parser.getNodeText(node);
            if (text.len > 0) {
                try self.spans.append(.{
                    .text = text,
                    .style = self.currentStyle(),
                    .indent = 0,
                    .node_type = node_type,
                });
            }
        } else {
            // Interior node - visit children
            var i: u32 = 0;
            while (i < child_count) : (i += 1) {
                if (node.child(i)) |child| {
                    try self.renderNode(child, md_parser, depth + 1);
                }
            }
        }

        // Pop style if we pushed one
        if (node_style != null) {
            _ = self.style_stack.pop();
        }

        // Add newline after block nodes (except document)
        if (node_type.isBlock() and node_type != .document) {
            try self.spans.append(.{
                .text = "\n",
                .style = self.colors.text,
                .indent = 0,
                .node_type = .softbreak,
            });
        }
    }

    /// Get the current style from the stack
    fn currentStyle(self: *const MarkdownRenderer) vaxis.Style {
        if (self.style_stack.items.len > 0) {
            return self.style_stack.items[self.style_stack.items.len - 1];
        }
        return self.colors.text;
    }

    /// Get the style to apply for a given node type
    fn getStyleForNode(self: *const MarkdownRenderer, node_type: NodeType, node: ts.Node, md_parser: *const MarkdownParser) ?vaxis.Style {
        return switch (node_type) {
            .heading => self.getHeaderStyle(node, md_parser),
            .strong_emphasis => self.colors.bold,
            .emphasis => self.colors.italic,
            .strikethrough => self.colors.strikethrough,
            .code_span => .{
                .fg = self.colors.inline_code.fg,
                .bg = self.colors.inline_code_bg,
            },
            .link => self.colors.link_text,
            else => null,
        };
    }

    /// Determine header level (1-6) and return appropriate style
    fn getHeaderStyle(self: *const MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser) vaxis.Style {
        const node_type_str = node.nodeType() orelse "atx_heading";

        // Check for setext heading (uses === or --- underlines)
        if (std.mem.eql(u8, node_type_str, "setext_heading")) {
            const level = getSetextLevel(node);
            return self.getHeaderStyleByLevel(level);
        }

        // ATX heading: count # characters
        const text = md_parser.getNodeText(node);
        var level: usize = 0;
        for (text) |c| {
            if (c == '#') {
                level += 1;
            } else {
                break;
            }
        }

        // Clamp to valid header levels
        level = @max(1, @min(6, level));
        return self.getHeaderStyleByLevel(level);
    }

    /// Get header style by level number
    fn getHeaderStyleByLevel(self: *const MarkdownRenderer, level: usize) vaxis.Style {
        return switch (level) {
            1 => self.colors.h1,
            2 => self.colors.h2,
            3 => self.colors.h3,
            4 => self.colors.h4,
            5 => self.colors.h5,
            else => self.colors.h6,
        };
    }
};

/// Determine setext header level by looking for underline child nodes
/// Returns 1 for H1 (===), 2 for H2 (---), defaults to 1 if no underline found
fn getSetextLevel(node: ts.Node) usize {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (node.child(i)) |child| {
            const child_type = child.nodeType() orelse continue;
            if (std.mem.eql(u8, child_type, "setext_h1_underline")) {
                return 1;
            }
            if (std.mem.eql(u8, child_type, "setext_h2_underline")) {
                return 2;
            }
        }
    }
    return 1; // Default to H1 if no underline found
}

/// Check if a tree-sitter node type represents a marker that should be hidden
fn isMarkerNode(node_type_str: []const u8) bool {
    // List of node types that are syntax markers to be hidden
    const markers = [_][]const u8{
        "atx_h1_marker",
        "atx_h2_marker",
        "atx_h3_marker",
        "atx_h4_marker",
        "atx_h5_marker",
        "atx_h6_marker",
        "emphasis_delimiter",
        "code_span_delimiter",
        "link_destination",
        "left_bracket",
        "right_bracket",
        "left_paren",
        "right_paren",
    };

    for (markers) |marker| {
        if (std.mem.eql(u8, node_type_str, marker)) {
            return true;
        }
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "render plain paragraph" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("Hello world");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Should have at least one text span plus newline
    try std.testing.expect(spans.len >= 1);

    // Find the text span
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Hello world") != null) {
            found_text = true;
            // Should use default text style
            try std.testing.expectEqual(colors_mod.default.text.fg, span.style.fg);
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "render H1 header" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("# Title");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Should have at least one span
    try std.testing.expect(spans.len >= 1);

    // Find the title text span (not the marker)
    var found_title = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Title") != null) {
            found_title = true;
            // Should have H1 style (bold and blue)
            try std.testing.expect(span.style.bold);
            break;
        }
    }
    try std.testing.expect(found_title);
}

test "render all header levels" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    const source =
        \\# H1
        \\## H2
        \\### H3
        \\#### H4
        \\##### H5
        \\###### H6
    ;
    try parser.parse(source);

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Should have multiple spans
    try std.testing.expect(spans.len >= 6);

    // Verify we find text for each header level
    var found_count: usize = 0;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "H1") or
            std.mem.eql(u8, span.text, "H2") or
            std.mem.eql(u8, span.text, "H3") or
            std.mem.eql(u8, span.text, "H4") or
            std.mem.eql(u8, span.text, "H5") or
            std.mem.eql(u8, span.text, "H6"))
        {
            found_count += 1;
        }
    }
    try std.testing.expect(found_count >= 6);
}

test "render setext headers" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    const h1_setext =
        \\Title H1
        \\========
    ;
    try parser.parse(h1_setext);

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const h1_spans = try renderer.render(&parser);

    // Find the H1 title text and verify it has H1 style (bold)
    var found_h1 = false;
    for (h1_spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Title H1") != null) {
            found_h1 = true;
            // H1 should have bold style
            try std.testing.expect(span.style.bold);
            try std.testing.expectEqual(colors_mod.default.h1.fg, span.style.fg);
            break;
        }
    }
    try std.testing.expect(found_h1);

    // Test H2 setext
    var parser2 = try MarkdownParser.init();
    defer parser2.deinit();

    const h2_setext =
        \\Title H2
        \\--------
    ;
    try parser2.parse(h2_setext);

    var renderer2 = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer2.deinit();

    const h2_spans = try renderer2.render(&parser2);

    // Find the H2 title text and verify it has H2 style
    var found_h2 = false;
    for (h2_spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Title H2") != null) {
            found_h2 = true;
            // H2 should have H2 color (not H1)
            try std.testing.expectEqual(colors_mod.default.h2.fg, span.style.fg);
            break;
        }
    }
    try std.testing.expect(found_h2);
}

test "render bold emphasis" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("**bold text**");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find bold text span
    var found_bold = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "bold text") != null) {
            found_bold = true;
            try std.testing.expect(span.style.bold);
            break;
        }
    }
    try std.testing.expect(found_bold);
}

test "render italic emphasis" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("*italic text*");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find italic text span
    var found_italic = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "italic text") != null) {
            found_italic = true;
            try std.testing.expect(span.style.italic);
            break;
        }
    }
    try std.testing.expect(found_italic);
}

test "render strikethrough" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("~~deleted~~");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find strikethrough text span
    var found_strike = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "deleted") != null) {
            found_strike = true;
            try std.testing.expect(span.style.strikethrough);
            break;
        }
    }
    try std.testing.expect(found_strike);
}

test "render nested emphasis" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("***bold and italic***");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find text with both bold and italic
    var found_nested = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "bold and italic") != null) {
            found_nested = true;
            // Should have both attributes
            try std.testing.expect(span.style.bold and span.style.italic);
            break;
        }
    }
    try std.testing.expect(found_nested);
}

test "render inline code" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("`code here`");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find code text span
    var found_code = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "code here") != null) {
            found_code = true;
            // Should have inline code style
            try std.testing.expectEqual(colors_mod.default.inline_code.fg, span.style.fg);
            break;
        }
    }
    try std.testing.expect(found_code);
}

test "render link" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("[click here](https://example.com)");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find link text span
    var found_link = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "click here") != null) {
            found_link = true;
            // Should have link style with underline
            try std.testing.expect(span.style.ul_style != .off);
            break;
        }
    }
    try std.testing.expect(found_link);
}

test "render mixed content" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("Normal **bold** and *italic* text.");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Should have multiple spans with different styles
    try std.testing.expect(spans.len >= 3);

    // Find bold and italic spans
    var found_bold = false;
    var found_italic = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "bold") != null) {
            found_bold = span.style.bold;
        }
        if (std.mem.indexOf(u8, span.text, "italic") != null) {
            found_italic = span.style.italic;
        }
    }
    try std.testing.expect(found_bold);
    try std.testing.expect(found_italic);
}

test "isMarkerNode - header markers" {
    try std.testing.expect(isMarkerNode("atx_h1_marker"));
    try std.testing.expect(isMarkerNode("atx_h2_marker"));
    try std.testing.expect(isMarkerNode("atx_h3_marker"));
}

test "isMarkerNode - emphasis markers" {
    try std.testing.expect(isMarkerNode("emphasis_delimiter"));
    try std.testing.expect(isMarkerNode("code_span_delimiter"));
}

test "isMarkerNode - not markers" {
    try std.testing.expect(!isMarkerNode("paragraph"));
    try std.testing.expect(!isMarkerNode("heading"));
    try std.testing.expect(!isMarkerNode("text"));
    try std.testing.expect(!isMarkerNode("inline"));
}
