//! Markdown AST Node Types and Styled Span Structures
//!
//! Provides type definitions for markdown parsing and rendering:
//! - NodeType: Enum mapping tree-sitter markdown node types to semantic categories
//! - StyledSpan: Represents a styled text segment for rendering

const std = @import("std");
const vaxis = @import("vaxis");

/// Markdown AST node types mapped from tree-sitter node names
pub const NodeType = enum {
    document,
    paragraph,
    heading,
    emphasis,
    strong_emphasis,
    strikethrough,
    code_span,
    link,
    image,
    code_block,
    fenced_code_block,
    block_quote,
    list,
    list_item,
    task_list_marker,
    table,
    thematic_break,
    text,
    softbreak,
    hardbreak,
    unknown,

    /// Map tree-sitter node type string to NodeType enum
    pub fn fromTreeSitter(node_type: []const u8) NodeType {
        // Use compile-time string map for efficient lookup
        const type_map = std.StaticStringMap(NodeType).initComptime(.{
            // Document structure
            .{ "document", .document },
            .{ "section", .document },

            // Headings (ATX and setext styles)
            .{ "atx_heading", .heading },
            .{ "setext_heading", .heading },

            // Paragraphs and text
            .{ "paragraph", .paragraph },
            .{ "text", .text },
            .{ "inline", .text },

            // Emphasis (inline formatting)
            .{ "emphasis", .emphasis },
            .{ "strong_emphasis", .strong_emphasis },
            .{ "strikethrough", .strikethrough },

            // Code
            .{ "code_span", .code_span },
            .{ "code", .code_span }, // Alternative name in some grammars
            .{ "inline_code", .code_span }, // Alternative name
            .{ "code_block", .code_block },
            .{ "indented_code_block", .code_block },
            .{ "fenced_code_block", .fenced_code_block },
            .{ "code_fence_content", .fenced_code_block },

            // Links and images
            .{ "link", .link },
            .{ "image", .image },
            .{ "link_destination", .link },
            .{ "link_text", .text },
            .{ "link_title", .text },

            // Block quotes
            .{ "block_quote", .block_quote },

            // Lists
            .{ "list", .list },
            .{ "tight_list", .list },
            .{ "loose_list", .list },
            .{ "list_item", .list_item },
            .{ "task_list_marker", .task_list_marker },
            .{ "task_list_marker_checked", .task_list_marker },
            .{ "task_list_marker_unchecked", .task_list_marker },

            // Tables
            .{ "table", .table },
            .{ "pipe_table", .table },
            .{ "table_header_row", .table },
            .{ "table_row", .table },
            .{ "table_cell", .text },

            // Breaks
            .{ "thematic_break", .thematic_break },
            .{ "soft_line_break", .softbreak },
            .{ "hard_line_break", .hardbreak },
            .{ "line_break", .hardbreak },
        });

        return type_map.get(node_type) orelse .unknown;
    }

    /// Returns true if this node type represents a block-level element
    pub fn isBlock(self: NodeType) bool {
        return switch (self) {
            .document,
            .paragraph,
            .heading,
            .code_block,
            .fenced_code_block,
            .block_quote,
            .list,
            .list_item,
            .table,
            .thematic_break,
            => true,
            else => false,
        };
    }

    /// Returns true if this node type represents inline formatting
    pub fn isInline(self: NodeType) bool {
        return switch (self) {
            .emphasis,
            .strong_emphasis,
            .strikethrough,
            .code_span,
            .link,
            .image,
            .text,
            .softbreak,
            .hardbreak,
            => true,
            else => false,
        };
    }
};

/// Represents a styled span of text for rendering
/// Used to pass parsed markdown information to the renderer
pub const StyledSpan = struct {
    /// The text content to render
    text: []const u8,
    /// The vaxis style to apply (colors, bold, italic, etc.)
    style: vaxis.Style,
    /// Indentation level (for nested structures like lists, block quotes)
    indent: usize,
    /// The type of markdown node this span came from
    node_type: NodeType,

    /// Create a default span with no styling
    pub fn plain(text: []const u8) StyledSpan {
        return .{
            .text = text,
            .style = .{},
            .indent = 0,
            .node_type = .text,
        };
    }

    /// Create a span with a specific node type but default style
    pub fn withType(text: []const u8, node_type: NodeType) StyledSpan {
        return .{
            .text = text,
            .style = .{},
            .indent = 0,
            .node_type = node_type,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "node type mapping - known types" {
    // Headings
    try std.testing.expectEqual(NodeType.heading, NodeType.fromTreeSitter("atx_heading"));
    try std.testing.expectEqual(NodeType.heading, NodeType.fromTreeSitter("setext_heading"));

    // Emphasis
    try std.testing.expectEqual(NodeType.emphasis, NodeType.fromTreeSitter("emphasis"));
    try std.testing.expectEqual(NodeType.strong_emphasis, NodeType.fromTreeSitter("strong_emphasis"));

    // Code
    try std.testing.expectEqual(NodeType.code_span, NodeType.fromTreeSitter("code_span"));
    try std.testing.expectEqual(NodeType.fenced_code_block, NodeType.fromTreeSitter("fenced_code_block"));
    try std.testing.expectEqual(NodeType.code_block, NodeType.fromTreeSitter("indented_code_block"));

    // Lists
    try std.testing.expectEqual(NodeType.list, NodeType.fromTreeSitter("list"));
    try std.testing.expectEqual(NodeType.list_item, NodeType.fromTreeSitter("list_item"));

    // Block quote
    try std.testing.expectEqual(NodeType.block_quote, NodeType.fromTreeSitter("block_quote"));

    // Links
    try std.testing.expectEqual(NodeType.link, NodeType.fromTreeSitter("link"));
    try std.testing.expectEqual(NodeType.image, NodeType.fromTreeSitter("image"));
}

test "unknown node type" {
    try std.testing.expectEqual(NodeType.unknown, NodeType.fromTreeSitter("nonexistent_node"));
    try std.testing.expectEqual(NodeType.unknown, NodeType.fromTreeSitter(""));
    try std.testing.expectEqual(NodeType.unknown, NodeType.fromTreeSitter("xyz_invalid"));
}

test "NodeType isBlock" {
    try std.testing.expect(NodeType.document.isBlock());
    try std.testing.expect(NodeType.paragraph.isBlock());
    try std.testing.expect(NodeType.heading.isBlock());
    try std.testing.expect(NodeType.fenced_code_block.isBlock());
    try std.testing.expect(NodeType.list.isBlock());
    try std.testing.expect(!NodeType.emphasis.isBlock());
    try std.testing.expect(!NodeType.text.isBlock());
    try std.testing.expect(!NodeType.code_span.isBlock());
}

test "NodeType isInline" {
    try std.testing.expect(NodeType.emphasis.isInline());
    try std.testing.expect(NodeType.strong_emphasis.isInline());
    try std.testing.expect(NodeType.code_span.isInline());
    try std.testing.expect(NodeType.text.isInline());
    try std.testing.expect(!NodeType.paragraph.isInline());
    try std.testing.expect(!NodeType.document.isInline());
}

test "StyledSpan plain" {
    const span = StyledSpan.plain("hello");
    try std.testing.expectEqualStrings("hello", span.text);
    try std.testing.expectEqual(@as(usize, 0), span.indent);
    try std.testing.expectEqual(NodeType.text, span.node_type);
}

test "StyledSpan withType" {
    const span = StyledSpan.withType("# Heading", .heading);
    try std.testing.expectEqualStrings("# Heading", span.text);
    try std.testing.expectEqual(NodeType.heading, span.node_type);
}
