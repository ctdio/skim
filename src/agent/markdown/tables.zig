//! GFM Table Parsing and Box-Drawing Rendering
//!
//! Handles rendering of GFM (GitHub Flavored Markdown) tables with:
//! - Header row with bold styling
//! - Column alignment (left, center, right)
//! - Unicode box-drawing borders (┌─┬─┐ │ ├─┼─┤ └─┴─┘)
//! - Auto-sizing columns based on content

const std = @import("std");
const ts = @import("tree-sitter");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const colors_mod = @import("colors.zig");
const parser_mod = @import("parser.zig");

const StyledSpan = types.StyledSpan;
const NodeType = types.NodeType;
const MarkdownColors = colors_mod.MarkdownColors;
const MarkdownParser = parser_mod.MarkdownParser;

/// Column alignment as specified in the delimiter row
pub const Alignment = enum {
    left,
    center,
    right,
};

/// Information about a table column
pub const Column = struct {
    alignment: Alignment,
    width: usize,
};

/// Result from table rendering - includes spans and allocated strings
pub const TableRenderResult = struct {
    spans: std.ArrayList(StyledSpan),
    strings: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TableRenderResult) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }
};

/// Renderer for GFM tables
pub const TableRenderer = struct {
    allocator: std.mem.Allocator,
    colors: MarkdownColors,

    /// Initialize a new table renderer
    pub fn init(allocator: std.mem.Allocator, md_colors: MarkdownColors) TableRenderer {
        return .{
            .allocator = allocator,
            .colors = md_colors,
        };
    }

    /// Render a table node into styled spans
    /// Returns result containing spans and allocated strings - caller must call deinit
    pub fn render(
        self: *TableRenderer,
        node: ts.Node,
        md_parser: *const MarkdownParser,
        max_width: usize,
    ) !TableRenderResult {
        var result = TableRenderResult{
            .spans = .{},
            .strings = .{},
            .allocator = self.allocator,
        };
        errdefer result.deinit();

        // Extract table data
        var header_cells: std.ArrayList([]const u8) = .{};
        defer header_cells.deinit(self.allocator);

        var alignments: std.ArrayList(Alignment) = .{};
        defer alignments.deinit(self.allocator);

        var body_rows: std.ArrayList(std.ArrayList([]const u8)) = .{};
        defer {
            for (body_rows.items) |*row| {
                row.deinit(self.allocator);
            }
            body_rows.deinit(self.allocator);
        }

        // Parse the table structure from tree-sitter nodes
        try self.parseTableNode(node, md_parser, &header_cells, &alignments, &body_rows);

        // If no valid table data found, return empty
        if (header_cells.items.len == 0) {
            return result;
        }

        // Calculate column widths
        const num_cols = header_cells.items.len;
        const widths = try self.allocator.alloc(usize, num_cols);
        defer self.allocator.free(widths);

        self.calculateWidths(header_cells.items, body_rows.items, widths, max_width);

        // Ensure alignments match column count
        while (alignments.items.len < num_cols) {
            try alignments.append(self.allocator, .left);
        }

        // Render top border
        try self.renderBorder(&result, widths, .top);

        // Render header row
        try self.renderRow(&result, header_cells.items, widths, alignments.items, true);

        // Render separator between header and body
        try self.renderBorder(&result, widths, .middle);

        // Render body rows
        for (body_rows.items) |row| {
            try self.renderRow(&result, row.items, widths, alignments.items, false);
        }

        // Render bottom border
        try self.renderBorder(&result, widths, .bottom);

        return result;
    }

    /// Parse table structure from tree-sitter node
    fn parseTableNode(
        self: *TableRenderer,
        node: ts.Node,
        md_parser: *const MarkdownParser,
        header_cells: *std.ArrayList([]const u8),
        alignments: *std.ArrayList(Alignment),
        body_rows: *std.ArrayList(std.ArrayList([]const u8)),
    ) !void {
        const child_count = node.childCount();
        var i: u32 = 0;
        var found_delimiter = false;

        while (i < child_count) : (i += 1) {
            if (node.child(i)) |child| {
                const child_type = child.kind();

                if (std.mem.indexOf(u8, child_type, "header") != null or
                    (std.mem.indexOf(u8, child_type, "row") != null and !found_delimiter and header_cells.items.len == 0))
                {
                    // Parse header row
                    try self.parseCells(child, md_parser, header_cells);
                } else if (std.mem.indexOf(u8, child_type, "delimiter") != null) {
                    // Parse delimiter row for alignments
                    try self.parseDelimiter(child, md_parser, alignments);
                    found_delimiter = true;
                } else if (std.mem.indexOf(u8, child_type, "row") != null and found_delimiter) {
                    // Parse body row
                    var row: std.ArrayList([]const u8) = .{};
                    try self.parseCells(child, md_parser, &row);
                    try body_rows.append(self.allocator, row);
                }
            }
        }
    }

    /// Parse cells from a row node
    fn parseCells(
        self: *TableRenderer,
        row_node: ts.Node,
        md_parser: *const MarkdownParser,
        cells: *std.ArrayList([]const u8),
    ) !void {
        const child_count = row_node.childCount();
        var i: u32 = 0;

        while (i < child_count) : (i += 1) {
            if (row_node.child(i)) |child| {
                const child_type = child.kind();

                if (std.mem.indexOf(u8, child_type, "cell") != null or
                    std.mem.eql(u8, child_type, "pipe_table_cell"))
                {
                    const text = md_parser.getNodeText(child);
                    const trimmed = std.mem.trim(u8, text, " \t");
                    try cells.append(self.allocator, trimmed);
                }
            }
        }
    }

    /// Parse delimiter row for column alignments
    fn parseDelimiter(
        self: *TableRenderer,
        delim_node: ts.Node,
        md_parser: *const MarkdownParser,
        alignments: *std.ArrayList(Alignment),
    ) !void {
        const child_count = delim_node.childCount();
        var i: u32 = 0;

        while (i < child_count) : (i += 1) {
            if (delim_node.child(i)) |child| {
                const child_type = child.kind();

                if (std.mem.indexOf(u8, child_type, "cell") != null or
                    std.mem.indexOf(u8, child_type, "delimiter") != null)
                {
                    const text = md_parser.getNodeText(child);
                    const col_align = parseAlignment(text);
                    try alignments.append(self.allocator, col_align);
                }
            }
        }

        // If no alignments found from children, try parsing text directly
        if (alignments.items.len == 0) {
            const text = md_parser.getNodeText(delim_node);
            var iter = std.mem.splitScalar(u8, text, '|');
            while (iter.next()) |segment| {
                const trimmed = std.mem.trim(u8, segment, " \t");
                if (trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '-') != null) {
                    try alignments.append(self.allocator, parseAlignment(trimmed));
                }
            }
        }
    }

    /// Calculate column widths based on content
    fn calculateWidths(
        self: *TableRenderer,
        header: []const []const u8,
        body: []const std.ArrayList([]const u8),
        widths: []usize,
        max_total: usize,
    ) void {
        _ = self;
        // Initialize with minimum width and header content
        for (header, 0..) |cell, i| {
            if (i < widths.len) {
                widths[i] = @max(3, cell.len);
            }
        }

        // Update with body content
        for (body) |row| {
            for (row.items, 0..) |cell, i| {
                if (i < widths.len) {
                    widths[i] = @max(widths[i], cell.len);
                }
            }
        }

        // Cap individual column widths
        for (widths) |*w| {
            w.* = @min(w.*, 40); // Max 40 chars per column
        }

        // Shrink if total exceeds max_total
        var total: usize = 0;
        for (widths) |w| {
            total += w + 3; // +3 for " | "
        }

        if (total > max_total and widths.len > 0) {
            const per_col = @max(5, (max_total - 4) / widths.len);
            for (widths) |*w| {
                w.* = @min(w.*, per_col);
            }
        }
    }

    /// Render a single row (header or body)
    fn renderRow(
        self: *TableRenderer,
        result: *TableRenderResult,
        cells: []const []const u8,
        widths: []const usize,
        alignments: []const Alignment,
        is_header: bool,
    ) !void {
        const style = if (is_header) self.colors.table_header else self.colors.table_cell;

        // Start border with box-drawing vertical bar
        try result.spans.append(self.allocator, .{
            .text = "│ ",
            .style = self.colors.table_border,
            .indent = 0,
            .node_type = .table,
        });

        // Render each cell
        for (cells, 0..) |cell, i| {
            const width = if (i < widths.len) widths[i] else 10;
            const col_align = if (i < alignments.len) alignments[i] else .left;

            // Pad and align cell content - allocate the result
            const padded = try padCellAlloc(self.allocator, cell, width, col_align);
            try result.strings.append(self.allocator, padded);

            try result.spans.append(self.allocator, .{
                .text = padded,
                .style = style,
                .indent = 0,
                .node_type = .table,
            });

            try result.spans.append(self.allocator, .{
                .text = " │ ",
                .style = self.colors.table_border,
                .indent = 0,
                .node_type = .table,
            });
        }

        // Newline
        try result.spans.append(self.allocator, .{
            .text = "\n",
            .style = self.colors.text,
            .indent = 0,
            .node_type = .softbreak,
        });
    }

    /// Border position for box-drawing
    const BorderPosition = enum {
        top, // ┌───┬───┐
        middle, // ├───┼───┤
        bottom, // └───┴───┘
    };

    /// Box-drawing characters for table borders
    const BorderChars = struct {
        left: []const u8,
        mid: []const u8,
        right: []const u8,
    };

    /// Render a horizontal border row (top, middle, or bottom)
    fn renderBorder(
        self: *TableRenderer,
        result: *TableRenderResult,
        widths: []const usize,
        position: BorderPosition,
    ) !void {
        // Box-drawing characters for each position
        const chars: BorderChars = switch (position) {
            .top => .{ .left = "┌", .mid = "┬", .right = "┐" },
            .middle => .{ .left = "├", .mid = "┼", .right = "┤" },
            .bottom => .{ .left = "└", .mid = "┴", .right = "┘" },
        };

        // Start with left corner/junction
        try result.spans.append(self.allocator, .{
            .text = chars.left,
            .style = self.colors.table_border,
            .indent = 0,
            .node_type = .table,
        });

        // Render horizontal line for each column
        for (widths, 0..) |w, i| {
            // Build horizontal line (width + 2 for padding spaces)
            const line = try buildHorizontalLineAlloc(self.allocator, w + 2);
            try result.strings.append(self.allocator, line);

            try result.spans.append(self.allocator, .{
                .text = line,
                .style = self.colors.table_border,
                .indent = 0,
                .node_type = .table,
            });

            // Add junction or right corner
            const junction = if (i == widths.len - 1) chars.right else chars.mid;
            try result.spans.append(self.allocator, .{
                .text = junction,
                .style = self.colors.table_border,
                .indent = 0,
                .node_type = .table,
            });
        }

        // Newline
        try result.spans.append(self.allocator, .{
            .text = "\n",
            .style = self.colors.text,
            .indent = 0,
            .node_type = .softbreak,
        });
    }
};

/// Parse alignment from delimiter cell text
fn parseAlignment(text: []const u8) Alignment {
    const trimmed = std.mem.trim(u8, text, " \t|");
    if (trimmed.len == 0) return .left;

    const starts_colon = trimmed[0] == ':';
    const ends_colon = trimmed[trimmed.len - 1] == ':';

    if (starts_colon and ends_colon) return .center;
    if (ends_colon) return .right;
    return .left;
}

/// Pad cell content to specified width with alignment - allocates result
fn padCellAlloc(allocator: std.mem.Allocator, text: []const u8, width: usize, col_align: Alignment) ![]const u8 {
    const actual_width = @min(width, 126);
    const text_len = @min(text.len, actual_width);

    const buf = try allocator.alloc(u8, actual_width);
    @memset(buf, ' ');

    const offset: usize = switch (col_align) {
        .left => 0,
        .right => actual_width -| text_len,
        .center => (actual_width -| text_len) / 2,
    };

    @memcpy(buf[offset..][0..text_len], text[0..text_len]);
    return buf;
}

/// Build a horizontal line of box-drawing characters - allocates result
/// Uses ─ (U+2500) which is 3 bytes in UTF-8
fn buildHorizontalLineAlloc(allocator: std.mem.Allocator, char_width: usize) ![]const u8 {
    const actual_width = @min(char_width, 62);
    // ─ is 3 bytes in UTF-8 (0xE2 0x94 0x80)
    const buf = try allocator.alloc(u8, actual_width * 3);

    var i: usize = 0;
    while (i < actual_width) : (i += 1) {
        buf[i * 3] = 0xE2;
        buf[i * 3 + 1] = 0x94;
        buf[i * 3 + 2] = 0x80;
    }

    return buf;
}

// =============================================================================
// Tests
// =============================================================================

test "parseAlignment - left" {
    try std.testing.expectEqual(Alignment.left, parseAlignment("---"));
    try std.testing.expectEqual(Alignment.left, parseAlignment(":---"));
    try std.testing.expectEqual(Alignment.left, parseAlignment(" --- "));
}

test "parseAlignment - right" {
    try std.testing.expectEqual(Alignment.right, parseAlignment("---:"));
    try std.testing.expectEqual(Alignment.right, parseAlignment(" ---: "));
}

test "parseAlignment - center" {
    try std.testing.expectEqual(Alignment.center, parseAlignment(":---:"));
    try std.testing.expectEqual(Alignment.center, parseAlignment(" :---: "));
    try std.testing.expectEqual(Alignment.center, parseAlignment(":--:"));
}

test "padCellAlloc - left alignment" {
    const allocator = std.testing.allocator;
    const result = try padCellAlloc(allocator, "Hi", 6, .left);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi    ", result);
}

test "padCellAlloc - right alignment" {
    const allocator = std.testing.allocator;
    const result = try padCellAlloc(allocator, "Hi", 6, .right);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("    Hi", result);
}

test "padCellAlloc - center alignment" {
    const allocator = std.testing.allocator;
    const result = try padCellAlloc(allocator, "Hi", 6, .center);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("  Hi  ", result);
}

test "buildHorizontalLineAlloc - creates box drawing line" {
    const allocator = std.testing.allocator;
    const result = try buildHorizontalLineAlloc(allocator, 4);
    defer allocator.free(result);
    // 4 characters * 3 bytes per character (─ is U+2500 = E2 94 80)
    try std.testing.expectEqual(@as(usize, 12), result.len);
    // Check first character is ─
    try std.testing.expectEqual(@as(u8, 0xE2), result[0]);
    try std.testing.expectEqual(@as(u8, 0x94), result[1]);
    try std.testing.expectEqual(@as(u8, 0x80), result[2]);
}

test "table renderer init" {
    const allocator = std.testing.allocator;
    const renderer = TableRenderer.init(allocator, colors_mod.default);

    // Just verify it doesn't crash and has expected fields
    try std.testing.expect(renderer.colors.table_header.bold);
    try std.testing.expect(renderer.colors.table_border.fg != .default);
}
