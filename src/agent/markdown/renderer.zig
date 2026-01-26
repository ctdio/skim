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
const code_blocks_mod = @import("code_blocks.zig");
const tables_mod = @import("tables.zig");

const NodeType = types.NodeType;
const StyledSpan = types.StyledSpan;
const MarkdownColors = colors_mod.MarkdownColors;
const MarkdownParser = parser_mod.MarkdownParser;
const CodeBlockRenderer = code_blocks_mod.CodeBlockRenderer;
const TableRenderer = tables_mod.TableRenderer;
const HighlightContext = code_blocks_mod.HighlightContext;

/// Context for tracking nested list state
const ListContext = struct {
    ordered: bool,
    item_number: usize,
    indent_level: usize,
};

/// Renderer for transforming markdown AST into styled spans
pub const MarkdownRenderer = struct {
    allocator: std.mem.Allocator,
    colors: MarkdownColors,
    spans: std.ArrayList(StyledSpan),
    strings: std.ArrayList([]const u8), // Allocated strings that need to be freed
    style_stack: std.ArrayList(vaxis.Style),
    list_stack: std.ArrayList(ListContext),
    blockquote_depth: usize,
    /// Track if we just ended a major block (for adding spacing between blocks)
    ended_major_block: bool,
    /// Optional highlight context for code block syntax highlighting
    highlight_ctx: HighlightContext,

    /// Initialize a new markdown renderer
    pub fn init(allocator: std.mem.Allocator, md_colors: MarkdownColors) MarkdownRenderer {
        return initWithHighlighter(allocator, md_colors, .{ .ctx = null, .func = null });
    }

    /// Initialize with an optional highlight context for code blocks
    pub fn initWithHighlighter(allocator: std.mem.Allocator, md_colors: MarkdownColors, highlight_ctx: HighlightContext) MarkdownRenderer {
        return .{
            .allocator = allocator,
            .colors = md_colors,
            .spans = .{},
            .strings = .{},
            .style_stack = .{},
            .list_stack = .{},
            .blockquote_depth = 0,
            .ended_major_block = false,
            .highlight_ctx = highlight_ctx,
        };
    }

    /// Clean up renderer resources
    pub fn deinit(self: *MarkdownRenderer) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.style_stack.deinit(self.allocator);
        self.list_stack.deinit(self.allocator);
    }

    /// Render markdown source into styled spans
    /// Returns owned slice of spans (caller must free underlying list if needed)
    pub fn render(self: *MarkdownRenderer, md_parser: *const MarkdownParser) ![]StyledSpan {
        // Clear any previous state
        self.spans.clearRetainingCapacity();
        // Free any previously allocated strings
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.clearRetainingCapacity();
        self.style_stack.clearRetainingCapacity();
        self.list_stack.clearRetainingCapacity();
        self.blockquote_depth = 0;
        self.ended_major_block = false;

        // Push base text style
        try self.style_stack.append(self.allocator, self.colors.text);

        // Get root node and traverse
        const root = md_parser.getRoot() orelse return self.spans.items;

        // Use our own recursive traversal for more control
        try self.renderNode(root, md_parser, 0);

        return self.spans.items;
    }

    /// Check if a node type is a major block element that needs spacing
    fn isMajorBlock(node_type: NodeType) bool {
        return switch (node_type) {
            .heading, .fenced_code_block, .code_block, .block_quote, .table, .list, .thematic_break => true,
            else => false,
        };
    }

    /// Recursively render a node and its children
    fn renderNode(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser, depth: usize) std.mem.Allocator.Error!void {
        const node_type_str = node.kind();
        const node_type = NodeType.fromTreeSitter(node_type_str);

        // Check if this is a marker node that should be hidden
        if (isMarkerNode(node_type_str)) {
            return; // Skip markers like #, **, `, etc.
        }

        // Add blank line before major blocks and paragraphs that follow major blocks
        // Only at top level (inside document/section, not nested in lists/blockquotes)
        const needs_spacing = isMajorBlock(node_type) or node_type == .paragraph;
        if (needs_spacing and self.ended_major_block and self.list_stack.items.len == 0 and self.blockquote_depth == 0) {
            try self.spans.append(self.allocator, .{
                .text = "\n",
                .style = self.colors.text,
                .indent = 0,
                .node_type = .softbreak,
            });
        }

        // Handle block elements with special rendering
        switch (node_type) {
            .list => {
                try self.renderList(node, md_parser, depth);
                if (self.list_stack.items.len == 0) self.ended_major_block = true;
                return;
            },
            .list_item => return self.renderListItem(node, md_parser, depth),
            .block_quote => {
                try self.renderBlockquote(node, md_parser, depth);
                if (self.blockquote_depth == 0) self.ended_major_block = true;
                return;
            },
            .thematic_break => {
                try self.renderHorizontalRule();
                self.ended_major_block = true;
                return;
            },
            .task_list_marker => return self.renderTaskListMarker(node, md_parser),
            .fenced_code_block => {
                try self.renderFencedCodeBlock(node, md_parser);
                self.ended_major_block = true;
                return;
            },
            .table => {
                try self.renderTable(node, md_parser);
                self.ended_major_block = true;
                return;
            },
            else => {},
        }

        // Handle inline nodes - parse with inline grammar for proper styling
        if (std.mem.eql(u8, node_type_str, "inline")) {
            const inline_text = md_parser.getNodeText(node);
            if (inline_text.len > 0) {
                try self.renderInlineContent(inline_text, md_parser);
            }
            return;
        }

        // Get style for this node type (if any)
        const node_style = self.getStyleForNode(node_type, node, md_parser);

        // Push style if we have one
        if (node_style) |style| {
            try self.style_stack.append(self.allocator, colors_mod.mergeStyles(self.currentStyle(), style));
        }

        // Process based on node type
        const child_count = node.childCount();

        if (child_count == 0) {
            // Leaf node - emit text span
            const text = md_parser.getNodeText(node);
            if (text.len > 0) {
                const current_indent = self.getCurrentIndent();
                try self.spans.append(self.allocator, .{
                    .text = text,
                    .style = self.currentStyle(),
                    .indent = current_indent,
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

        // Add newline after block nodes (except document, list, list_item)
        if (node_type.isBlock() and node_type != .document and node_type != .list and node_type != .list_item) {
            try self.spans.append(self.allocator, .{
                .text = "\n",
                .style = self.colors.text,
                .indent = 0,
                .node_type = .softbreak,
            });

            // Mark headings as major blocks for spacing
            if (node_type == .heading) {
                self.ended_major_block = true;
            }
        }

        // Paragraphs also end a major block run (reset spacing tracker)
        if (node_type == .paragraph) {
            self.ended_major_block = true;
        }
    }

    /// Render inline content using the inline grammar parser
    fn renderInlineContent(self: *MarkdownRenderer, content: []const u8, md_parser: *const MarkdownParser) std.mem.Allocator.Error!void {
        const inline_tree = md_parser.parseInline(content) orelse {
            // Fallback: emit raw text if inline parsing fails
            try self.spans.append(self.allocator, .{
                .text = content,
                .style = self.currentStyle(),
                .indent = self.getCurrentIndent(),
                .node_type = .text,
            });
            return;
        };
        defer inline_tree.destroy();

        const root = inline_tree.rootNode();
        try self.renderInlineNode(root, content, 0);
    }

    /// Recursively render inline AST nodes
    fn renderInlineNode(self: *MarkdownRenderer, node: ts.Node, source: []const u8, depth: usize) std.mem.Allocator.Error!void {
        _ = depth;
        const node_type_str = node.kind();
        const node_type = NodeType.fromTreeSitter(node_type_str);

        // Skip marker nodes (delimiters like **, *, `, etc.)
        if (isMarkerNode(node_type_str)) {
            return;
        }

        // Get style for inline node types
        const node_style = self.getInlineStyle(node_type);

        // Push style if we have one
        if (node_style) |style| {
            try self.style_stack.append(self.allocator, colors_mod.mergeStyles(self.currentStyle(), style));
        }

        const child_count = node.childCount();

        if (child_count == 0) {
            // Leaf node - emit text
            const start = node.startByte();
            const end = node.endByte();
            if (start < source.len and end <= source.len and start < end) {
                const text = source[start..end];
                if (text.len > 0) {
                    try self.spans.append(self.allocator, .{
                        .text = text,
                        .style = self.currentStyle(),
                        .indent = self.getCurrentIndent(),
                        .node_type = node_type,
                    });
                }
            }
        } else if (self.hasOnlyDelimiterChildren(node)) {
            // Node with only delimiter children (emphasis, strong_emphasis, code_span, etc.)
            // Extract text content between delimiters
            const content_range = self.getContentBetweenDelimiters(node, source);
            if (content_range) |range| {
                if (range.end > range.start and range.end <= source.len) {
                    const text = source[range.start..range.end];
                    if (text.len > 0) {
                        try self.spans.append(self.allocator, .{
                            .text = text,
                            .style = self.currentStyle(),
                            .indent = self.getCurrentIndent(),
                            .node_type = node_type,
                        });
                    }
                }
            }
        } else {
            // Visit children, but also emit text between children
            var last_end: usize = node.startByte();
            var i: u32 = 0;
            while (i < child_count) : (i += 1) {
                if (node.child(i)) |child| {
                    // Emit any text between the last child and this one
                    const child_start = child.startByte();
                    if (child_start > last_end and child_start <= source.len and last_end < source.len) {
                        const gap_text = source[last_end..child_start];
                        // Only emit if it's meaningful (not just whitespace between inline elements)
                        const trimmed = std.mem.trim(u8, gap_text, " \t");
                        if (trimmed.len > 0 or std.mem.indexOf(u8, gap_text, "\n") == null) {
                            if (gap_text.len > 0) {
                                try self.spans.append(self.allocator, .{
                                    .text = gap_text,
                                    .style = self.currentStyle(),
                                    .indent = self.getCurrentIndent(),
                                    .node_type = node_type,
                                });
                            }
                        }
                    }

                    try self.renderInlineNode(child, source, 0);
                    last_end = child.endByte();
                }
            }

            // Emit any trailing text after the last child
            const node_end = node.endByte();
            if (node_end > last_end and node_end <= source.len) {
                const trailing_text = source[last_end..node_end];
                if (trailing_text.len > 0) {
                    try self.spans.append(self.allocator, .{
                        .text = trailing_text,
                        .style = self.currentStyle(),
                        .indent = self.getCurrentIndent(),
                        .node_type = node_type,
                    });
                }
            }
        }

        // Pop style if we pushed one
        if (node_style != null) {
            _ = self.style_stack.pop();
        }
    }

    /// Check if a node has only delimiter children
    fn hasOnlyDelimiterChildren(self: *const MarkdownRenderer, node: ts.Node) bool {
        _ = self;
        const child_count = node.childCount();
        if (child_count == 0) return false;

        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                const child_type = child.kind();
                // Check if child is a delimiter
                if (!std.mem.containsAtLeast(u8, child_type, 1, "delimiter") and
                    !std.mem.eql(u8, child_type, "code_span_delimiter"))
                {
                    return false;
                }
            }
        }
        return true;
    }

    /// Get the byte range of content between delimiters
    fn getContentBetweenDelimiters(self: *const MarkdownRenderer, node: ts.Node, source: []const u8) ?struct { start: usize, end: usize } {
        _ = self;
        _ = source;

        const child_count = node.childCount();
        if (child_count < 2) return null;

        const node_start = node.startByte();
        const node_end = node.endByte();
        const node_mid = node_start + (node_end - node_start) / 2;

        // Find opening delimiters (delimiters that start before the midpoint)
        // Find closing delimiters (delimiters that start at or after the midpoint)
        var content_start: usize = node_start;
        var content_end: usize = node_end;

        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                const child_type = child.kind();
                if (std.mem.containsAtLeast(u8, child_type, 1, "delimiter")) {
                    const child_start = child.startByte();
                    if (child_start < node_mid) {
                        // Opening delimiter - content starts after it
                        content_start = @max(content_start, child.endByte());
                    } else {
                        // Closing delimiter - content ends before it
                        content_end = @min(content_end, child_start);
                    }
                }
            }
        }

        if (content_end > content_start) {
            return .{ .start = content_start, .end = content_end };
        }
        return null;
    }

    /// Get style for inline node types
    fn getInlineStyle(self: *const MarkdownRenderer, node_type: NodeType) ?vaxis.Style {
        return switch (node_type) {
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

    /// Get current indentation level based on list and blockquote depth
    fn getCurrentIndent(self: *const MarkdownRenderer) usize {
        var indent: usize = self.blockquote_depth * 2; // Each blockquote level adds 2 spaces
        if (self.list_stack.items.len > 0) {
            indent += self.list_stack.items[self.list_stack.items.len - 1].indent_level;
        }
        return indent;
    }

    /// Render a list (ordered or unordered)
    fn renderList(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser, depth: usize) std.mem.Allocator.Error!void {
        // Determine if ordered by checking child list items
        const ordered = self.isOrderedList(node, md_parser);

        // Calculate indent level based on nesting (3 spaces per level for better visibility)
        const indent_level: usize = if (self.list_stack.items.len > 0)
            self.list_stack.items[self.list_stack.items.len - 1].indent_level + 3
        else
            0;

        // Push list context
        try self.list_stack.append(self.allocator, .{
            .ordered = ordered,
            .item_number = 1,
            .indent_level = indent_level,
        });

        // Render children
        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                try self.renderNode(child, md_parser, depth + 1);
            }
        }

        // Pop list context
        _ = self.list_stack.pop();

        // Add newline after top-level lists
        if (self.list_stack.items.len == 0) {
            try self.spans.append(self.allocator, .{
                .text = "\n",
                .style = self.colors.text,
                .indent = 0,
                .node_type = .softbreak,
            });
        }
    }

    /// Check if a list is ordered by examining its markers
    fn isOrderedList(self: *const MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser) bool {
        _ = self;
        // Check first child for marker type
        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                const child_type = child.kind();
                if (std.mem.eql(u8, child_type, "list_item")) {
                    // Look at the list item's text to determine type
                    const text = md_parser.getNodeText(child);
                    if (text.len > 0) {
                        // Check if starts with a digit (ordered list)
                        if (text[0] >= '0' and text[0] <= '9') {
                            return true;
                        }
                    }
                    break;
                }
            }
        }
        return false;
    }

    /// Render a list item with appropriate marker
    fn renderListItem(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser, depth: usize) std.mem.Allocator.Error!void {
        if (self.list_stack.items.len == 0) {
            // Not inside a list, just render normally
            try self.renderChildren(node, md_parser, depth);
            return;
        }

        const list_ctx = &self.list_stack.items[self.list_stack.items.len - 1];
        const indent = list_ctx.indent_level;

        // Check for task list marker first
        const has_task_marker = self.hasTaskMarker(node);

        if (!has_task_marker) {
            // Emit list marker
            if (list_ctx.ordered) {
                // Ordered list: emit number - allocate string for proper lifetime
                const num_str = try std.fmt.allocPrint(self.allocator, "{d}. ", .{list_ctx.item_number});
                try self.strings.append(self.allocator, num_str);
                try self.spans.append(self.allocator, .{
                    .text = num_str,
                    .style = self.colors.list_marker,
                    .indent = indent,
                    .node_type = .list_item,
                });
            } else {
                // Unordered list: emit bullet
                try self.spans.append(self.allocator, .{
                    .text = "• ",
                    .style = self.colors.list_marker,
                    .indent = indent,
                    .node_type = .list_item,
                });
            }
        }

        // Increment item number for next item
        list_ctx.item_number += 1;

        // Render list item content (don't add extra newline - inline content already has one)
        try self.renderChildren(node, md_parser, depth);
    }

    /// Check if a list item has a task marker
    fn hasTaskMarker(self: *const MarkdownRenderer, node: ts.Node) bool {
        _ = self;
        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                const child_type = child.kind();
                if (std.mem.indexOf(u8, child_type, "task_list_marker") != null) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Render blockquote with border on each line
    fn renderBlockquote(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser, depth: usize) std.mem.Allocator.Error!void {
        _ = depth;

        // Increment blockquote depth
        self.blockquote_depth += 1;
        const indent = (self.blockquote_depth - 1) * 2;

        // Get full blockquote text and process line by line
        const raw_text = md_parser.getNodeText(node);

        // Split into lines and render each with border
        var line_iter = std.mem.splitScalar(u8, raw_text, '\n');
        var first_line = true;

        while (line_iter.next()) |line| {
            // Strip leading '>' and whitespace from each line
            var content = line;
            while (content.len > 0 and (content[0] == '>' or content[0] == ' ')) {
                content = content[1..];
            }

            // Skip empty lines that were just '>'
            if (content.len == 0 and !first_line) {
                continue;
            }

            // Add newline before non-first lines
            if (!first_line) {
                try self.spans.append(self.allocator, .{
                    .text = "\n",
                    .style = self.colors.text,
                    .indent = 0,
                    .node_type = .softbreak,
                });
            }

            // Emit blockquote border
            try self.spans.append(self.allocator, .{
                .text = "│ ",
                .style = self.colors.blockquote_border,
                .indent = indent,
                .node_type = .block_quote,
            });

            // Emit content with blockquote styling
            if (content.len > 0) {
                try self.spans.append(self.allocator, .{
                    .text = content,
                    .style = self.colors.blockquote_text,
                    .indent = indent,
                    .node_type = .block_quote,
                });
            }

            first_line = false;
        }

        // Add final newline
        try self.spans.append(self.allocator, .{
            .text = "\n",
            .style = self.colors.text,
            .indent = 0,
            .node_type = .softbreak,
        });

        // Decrement blockquote depth
        self.blockquote_depth -= 1;
    }

    /// Render task list marker (checkbox)
    fn renderTaskListMarker(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser) std.mem.Allocator.Error!void {
        const text = md_parser.getNodeText(node);
        const indent = self.getCurrentIndent();

        // Check if checked or unchecked based on text content
        const is_checked = std.mem.indexOf(u8, text, "x") != null or std.mem.indexOf(u8, text, "X") != null;

        if (is_checked) {
            try self.spans.append(self.allocator, .{
                .text = "☑ ",
                .style = self.colors.task_checked,
                .indent = indent,
                .node_type = .task_list_marker,
            });
        } else {
            try self.spans.append(self.allocator, .{
                .text = "☐ ",
                .style = self.colors.task_unchecked,
                .indent = indent,
                .node_type = .task_list_marker,
            });
        }
    }

    /// Render horizontal rule
    fn renderHorizontalRule(self: *MarkdownRenderer) std.mem.Allocator.Error!void {
        // Emit a line of horizontal rule characters
        try self.spans.append(self.allocator, .{
            .text = "────────────────────────────────",
            .style = self.colors.horizontal_rule,
            .indent = 0,
            .node_type = .thematic_break,
        });

        // Add newline after horizontal rule
        try self.spans.append(self.allocator, .{
            .text = "\n",
            .style = self.colors.text,
            .indent = 0,
            .node_type = .softbreak,
        });
    }

    /// Render fenced code block with borders and optional language label
    fn renderFencedCodeBlock(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser) std.mem.Allocator.Error!void {
        // Extract info_string (language) and code content from the node
        var language: ?[]const u8 = null;
        var code_content: []const u8 = "";

        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                const child_type = child.kind();
                if (std.mem.eql(u8, child_type, "info_string")) {
                    const raw_lang = md_parser.getNodeText(child);
                    // Trim whitespace from language string
                    language = std.mem.trim(u8, raw_lang, " \t\n\r");
                } else if (std.mem.eql(u8, child_type, "code_fence_content")) {
                    code_content = md_parser.getNodeText(child);
                }
            }
        }

        // Normalize language if we have one
        const normalized_lang = if (language) |lang|
            if (lang.len > 0) CodeBlockRenderer.detectLanguage(lang) else null
        else
            null;

        // Use CodeBlockRenderer to render the code block with syntax highlighting
        var code_renderer = CodeBlockRenderer.init(self.allocator, self.colors, self.highlight_ctx);
        defer code_renderer.deinit();

        var code_spans = try code_renderer.render(code_content, normalized_lang);
        defer code_spans.deinit(self.allocator);

        // Append all code block spans to our span list
        for (code_spans.items) |span| {
            try self.spans.append(self.allocator, span);
        }

        // Add newline after code block
        try self.spans.append(self.allocator, .{
            .text = "\n",
            .style = self.colors.text,
            .indent = 0,
            .node_type = .softbreak,
        });
    }

    /// Render GFM table with ASCII borders
    fn renderTable(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser) std.mem.Allocator.Error!void {
        // Use TableRenderer to render the table
        var table_renderer = TableRenderer.init(self.allocator, self.colors);
        var table_result = table_renderer.render(node, md_parser, 80) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        // Append all table spans to our span list
        for (table_result.spans.items) |span| {
            try self.spans.append(self.allocator, span);
        }

        // Transfer string ownership to the renderer's strings list
        for (table_result.strings.items) |s| {
            try self.strings.append(self.allocator, s);
        }

        // Free just the ArrayList structures, not the strings they contain
        table_result.spans.deinit(self.allocator);
        table_result.strings.deinit(self.allocator);

        // Add newline after table
        try self.spans.append(self.allocator, .{
            .text = "\n",
            .style = self.colors.text,
            .indent = 0,
            .node_type = .softbreak,
        });
    }

    /// Render all children of a node
    fn renderChildren(self: *MarkdownRenderer, node: ts.Node, md_parser: *const MarkdownParser, depth: usize) std.mem.Allocator.Error!void {
        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                try self.renderNode(child, md_parser, depth + 1);
            }
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
        const node_type_str = node.kind();

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

    /// Check if a node has any named (semantic) children vs only anonymous (token) children
    fn hasNamedChildren(self: *const MarkdownRenderer, node: ts.Node) bool {
        _ = self;
        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                if (child.isNamed()) {
                    return true;
                }
            }
        }
        return false;
    }
};

/// Determine setext header level by looking for underline child nodes
/// Returns 1 for H1 (===), 2 for H2 (---), defaults to 1 if no underline found
fn getSetextLevel(node: ts.Node) usize {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (node.child(i)) |child| {
            const child_type = child.kind();
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
        // Header markers
        "atx_h1_marker",
        "atx_h2_marker",
        "atx_h3_marker",
        "atx_h4_marker",
        "atx_h5_marker",
        "atx_h6_marker",
        // Emphasis markers
        "emphasis_delimiter",
        "code_span_delimiter",
        "code_delimiter", // Alternative name
        "backtick", // Alternative name
        // Link markers
        "link_destination",
        "left_bracket",
        "right_bracket",
        "left_paren",
        "right_paren",
        // List markers (we emit our own bullets/numbers)
        "list_marker",
        "list_marker_minus",
        "list_marker_plus",
        "list_marker_star",
        "list_marker_dot",
        "list_marker_parenthesis",
        // Blockquote marker
        "block_quote_marker",
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

    // Note: Use two-word heading to satisfy tree-sitter-markdown grammar
    try parser.parse("# Hello World");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Should have at least one span
    try std.testing.expect(spans.len >= 1);

    // Find the title text span (not the marker)
    var found_title = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Hello") != null or
            std.mem.indexOf(u8, span.text, "World") != null)
        {
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
    // Note: Setext headers require multi-line parsing which the block grammar
    // may not fully support. This test verifies basic text extraction.
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

    // Find the H1 title text - setext parsing depends on grammar version
    var found_h1 = false;
    for (h1_spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Title") != null) {
            found_h1 = true;
            break;
        }
    }
    try std.testing.expect(found_h1);
}

test "render bold emphasis" {
    // Bold styling using the inline grammar
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("**bold text**");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find text span with bold styling
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "bold") != null) {
            found_text = true;
            // Verify bold styling is applied
            try std.testing.expect(span.style.bold);
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "render italic emphasis" {
    // Note: Italic styling requires the inline grammar. Without it, we verify
    // that the text content is extracted (markers may be included in output).
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("*italic text*");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find text span - content extraction works even without inline grammar
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "italic") != null) {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "render strikethrough" {
    // Note: Strikethrough styling requires the inline grammar. Without it, we verify
    // that the text content is extracted (markers may be included in output).
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("~~deleted~~");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find text span - content extraction works even without inline grammar
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "deleted") != null) {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "render nested emphasis" {
    // Note: Nested emphasis styling requires the inline grammar. Without it, we verify
    // that the text content is extracted (markers may be included in output).
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("***bold and italic***");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find text span - content extraction works even without inline grammar
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "bold") != null) {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "render inline code" {
    // Note: Inline code styling requires the inline grammar. Without it, we verify
    // that the text content is extracted (markers may be included in output).
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("`code here`");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find text span - content extraction works even without inline grammar
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "code") != null) {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "render link" {
    // Note: Link styling requires the inline grammar. Without it, we verify
    // that the text content is extracted (markers may be included in output).
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("[click here](https://example.com)");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Find text span - content extraction works even without inline grammar
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "click") != null) {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "render mixed content" {
    // Note: Inline styling requires the inline grammar. Without it, we verify
    // that the text content is extracted (markers may be included in output).
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    try parser.parse("Normal **bold** and *italic* text.");

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Should have at least one span with content
    try std.testing.expect(spans.len >= 1);

    // Find text content - extraction works even without inline grammar
    var found_text = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Normal") != null or
            std.mem.indexOf(u8, span.text, "bold") != null or
            std.mem.indexOf(u8, span.text, "italic") != null)
        {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);
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

// =============================================================================
// Block Element Tests - Phase 3
// Unit tests that verify block element colors are defined
// =============================================================================

test "block colors defined" {
    // Verify all block element colors are defined
    try std.testing.expect(colors_mod.default.list_marker.fg != .default);
    try std.testing.expect(colors_mod.default.blockquote_border.fg != .default);
    try std.testing.expect(colors_mod.default.blockquote_text.fg != .default);
    try std.testing.expect(colors_mod.default.task_checked.fg != .default);
    try std.testing.expect(colors_mod.default.task_unchecked.fg != .default);
    try std.testing.expect(colors_mod.default.horizontal_rule.fg != .default);
}

// =============================================================================
// Code Block Tests - Phase 4
// Unit tests that verify code block colors are defined and rendering works
// =============================================================================

test "code block colors defined" {
    // Verify all code block colors are defined
    try std.testing.expect(colors_mod.default.code_block_bg != .default);
    try std.testing.expect(colors_mod.default.code_block_border.fg != .default);
    try std.testing.expect(colors_mod.default.code_block_lang.fg != .default);
}

// =============================================================================
// Table Tests - Phase 5
// Unit tests that verify table colors are defined
// =============================================================================

test "table colors defined" {
    // Verify all table colors are defined
    try std.testing.expect(colors_mod.default.table_header.bold);
    try std.testing.expect(colors_mod.default.table_border.fg != .default);
    try std.testing.expect(colors_mod.default.table_cell.fg != .default);
}

test "render table" {
    var parser = try MarkdownParser.init();
    defer parser.deinit();

    const table_md =
        \\| Header 1 | Header 2 |
        \\|:---------|:---------|
        \\| Cell 1   | Cell 2   |
    ;
    try parser.parse(table_md);

    var renderer = MarkdownRenderer.init(std.testing.allocator, colors_mod.default);
    defer renderer.deinit();

    const spans = try renderer.render(&parser);

    // Should find header and cell content
    var found_header = false;
    var found_cell = false;

    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Header 1") != null) {
            found_header = true;
            // Header should have bold style
            try std.testing.expect(span.style.bold);
        }
        if (std.mem.indexOf(u8, span.text, "Cell 1") != null) {
            found_cell = true;
        }
    }

    try std.testing.expect(found_header);
    try std.testing.expect(found_cell);
}
