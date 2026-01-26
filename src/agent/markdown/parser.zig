//! Incremental Tree-sitter Markdown Parser
//!
//! Provides a wrapper around tree-sitter for parsing markdown content.
//! Uses both block and inline grammars for complete markdown parsing.
//! Supports incremental parsing for streaming content updates.

const std = @import("std");
pub const ts = @import("tree-sitter");
const types = @import("types.zig");

pub const NodeType = types.NodeType;

// Extern declarations for markdown grammar language functions
// Provided by the linked grammar libraries (tree-sitter-markdown)
extern fn tree_sitter_markdown() callconv(.c) *const ts.Language;
extern fn tree_sitter_markdown_inline() callconv(.c) *const ts.Language;

/// Error types for markdown parsing
pub const ParseError = error{
    ParserCreateFailed,
    LanguageSetFailed,
    ParseFailed,
    OutOfMemory,
};

/// Wrapper around tree-sitter parser for markdown content
/// Uses both block and inline grammars for complete parsing
pub const MarkdownParser = struct {
    parser: *ts.Parser,
    inline_parser: *ts.Parser,
    tree: ?*ts.Tree,
    source: []const u8,

    /// Initialize a new markdown parser with block and inline grammars
    pub fn init() ParseError!MarkdownParser {
        const parser = ts.Parser.create();

        // Set the markdown block language
        parser.setLanguage(tree_sitter_markdown()) catch {
            parser.destroy();
            return error.LanguageSetFailed;
        };

        // Create inline parser
        const inline_parser = ts.Parser.create();
        inline_parser.setLanguage(tree_sitter_markdown_inline()) catch {
            inline_parser.destroy();
            parser.destroy();
            return error.LanguageSetFailed;
        };

        return .{
            .parser = parser,
            .inline_parser = inline_parser,
            .tree = null,
            .source = "",
        };
    }

    /// Clean up parser resources
    pub fn deinit(self: *MarkdownParser) void {
        if (self.tree) |tree| {
            tree.destroy();
        }
        self.parser.destroy();
        self.inline_parser.destroy();
    }

    /// Parse markdown source content
    /// Returns error if parsing fails
    pub fn parse(self: *MarkdownParser, source: []const u8) ParseError!void {
        // Destroy previous tree if exists
        if (self.tree) |tree| {
            tree.destroy();
        }

        // Parse the source
        self.tree = self.parser.parseString(source, null);
        if (self.tree == null) {
            return error.ParseFailed;
        }

        self.source = source;
    }

    /// Update the parse tree incrementally after content change
    /// This is more efficient than re-parsing the entire document
    ///
    /// Args:
    ///   - start_byte: Start byte of the changed region
    ///   - old_end_byte: End byte of the old content
    ///   - new_end_byte: End byte of the new content
    ///   - new_source: The new complete source after the edit
    pub fn update(
        self: *MarkdownParser,
        start_byte: u32,
        old_end_byte: u32,
        new_end_byte: u32,
        new_source: []const u8,
    ) ParseError!void {
        const old_tree = self.tree orelse {
            // No existing tree, do full parse
            return self.parse(new_source);
        };

        // Create edit descriptor for tree-sitter
        const edit = ts.InputEdit{
            .start_byte = start_byte,
            .old_end_byte = old_end_byte,
            .new_end_byte = new_end_byte,
            // Position info (line/column) - we can compute from source if needed
            // For now use 0,0 as tree-sitter handles byte offsets correctly
            .start_point = .{ .row = 0, .column = 0 },
            .old_end_point = .{ .row = 0, .column = 0 },
            .new_end_point = .{ .row = 0, .column = 0 },
        };

        // Apply edit to old tree
        old_tree.edit(edit);

        // Re-parse with old tree for incremental update
        self.tree = self.parser.parseString(new_source, old_tree);
        if (self.tree == null) {
            return error.ParseFailed;
        }

        self.source = new_source;

        // Destroy the old tree after successful parse
        old_tree.destroy();
    }

    /// Get the root node of the parse tree
    /// Returns null if no tree has been parsed
    pub fn getRoot(self: *const MarkdownParser) ?ts.Node {
        const tree = self.tree orelse return null;
        return tree.rootNode();
    }

    /// Walk the parse tree, calling the visitor for each node
    /// The visitor receives the node and its depth in the tree
    pub fn walk(self: *const MarkdownParser, context: anytype, visitor: fn (@TypeOf(context), ts.Node, usize) void) void {
        const root = self.getRoot() orelse return;
        walkNode(root, 0, context, visitor);
    }

    /// Check if the tree is valid (parsed without errors)
    pub fn isValid(self: *const MarkdownParser) bool {
        const root = self.getRoot() orelse return false;
        return !root.hasError();
    }

    /// Get the node type enum for a tree-sitter node
    pub fn getNodeType(node: ts.Node) NodeType {
        const type_str = node.kind();
        return NodeType.fromTreeSitter(type_str);
    }

    /// Get the text content of a node from the source
    pub fn getNodeText(self: *const MarkdownParser, node: ts.Node) []const u8 {
        const start = node.startByte();
        const end = node.endByte();
        if (start >= self.source.len or end > self.source.len or start >= end) {
            return "";
        }
        return self.source[start..end];
    }

    /// Parse inline content using the inline grammar
    /// Returns the tree for the inline content - caller must destroy it
    /// Returns null if parsing fails
    pub fn parseInline(self: *const MarkdownParser, content: []const u8) ?*ts.Tree {
        return self.inline_parser.parseString(content, null);
    }
};

// Helper function for recursive tree walking
fn walkNode(node: ts.Node, depth: usize, context: anytype, visitor: fn (@TypeOf(context), ts.Node, usize) void) void {
    // Visit current node
    visitor(context, node, depth);

    // Visit children
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (node.child(i)) |child| {
            walkNode(child, depth + 1, context, visitor);
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parser init and parse" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("# Hello World");

    const root = parser.getRoot();
    try std.testing.expect(root != null);

    // Root should be document node
    const root_node = root.?;
    const node_type = root_node.kind();
    try std.testing.expectEqualStrings("document", node_type);
}

test "parse empty string" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("");

    const root = parser.getRoot();
    try std.testing.expect(root != null);

    // Even empty string should have document root
    const root_node = root.?;
    const node_type = root_node.kind();
    try std.testing.expectEqualStrings("document", node_type);
}

test "parser incremental update" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    // Initial parse
    try parser.parse("Hello");

    // Incremental update: "Hello" -> "Hello World"
    // start_byte: 5 (after "Hello")
    // old_end_byte: 5 (nothing was replaced)
    // new_end_byte: 11 (added " World")
    try parser.update(5, 5, 11, "Hello World");

    // Verify tree is still valid
    try std.testing.expect(parser.isValid());

    // Verify we can get root
    const root = parser.getRoot();
    try std.testing.expect(root != null);
}

test "walk callback" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("# Title\n\nParagraph text.");

    // Count nodes visited
    const Counter = struct {
        count: usize = 0,

        fn visit(self: *@This(), _: ts.Node, _: usize) void {
            self.count += 1;
        }
    };

    var counter = Counter{};
    parser.walk(&counter, Counter.visit);

    // Should have visited at least: document, heading, inline, paragraph, inline, text nodes
    try std.testing.expect(counter.count >= 4);
}

test "getNodeType" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("# Hello World");

    const root = parser.getRoot().?;
    const root_type = MarkdownParser.getNodeType(root);
    try std.testing.expectEqual(NodeType.document, root_type);
}

test "getNodeText" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    const source = "# Hello";
    try parser.parse(source);

    const root = parser.getRoot().?;
    const text = parser.getNodeText(root);
    try std.testing.expectEqualStrings(source, text);
}

test "isValid - valid markdown" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("# Valid Markdown\n\nWith paragraph.");
    try std.testing.expect(parser.isValid());
}

test "parse complex markdown" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    const complex_md =
        \\# Title
        \\
        \\This is a paragraph with **bold** and *italic*.
        \\
        \\- List item 1
        \\- List item 2
    ;

    try parser.parse(complex_md);

    // Should parse without error
    try std.testing.expect(parser.isValid());

    // Should have a document root
    const root = parser.getRoot();
    try std.testing.expect(root != null);
}
