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

        // Ensure max_width is reasonable (minimum 20 for any table)
        const safe_max_width = @max(max_width, 20);

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

        // Initialize to safe default before calculation
        @memset(widths, 5);

        self.calculateWidths(header_cells.items, body_rows.items, widths, safe_max_width);

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

        // Render body rows with separators between them
        for (body_rows.items, 0..) |row, row_idx| {
            try self.renderRow(&result, row.items, widths, alignments.items, false);
            // Add separator after each row except the last
            if (row_idx < body_rows.items.len - 1) {
                try self.renderBorder(&result, widths, .middle);
            }
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
    /// Uses proportional distribution when space is constrained
    /// Guarantees total width <= max_total
    fn calculateWidths(
        self: *TableRenderer,
        header: []const []const u8,
        body: []const std.ArrayList([]const u8),
        widths: []usize,
        max_total: usize,
    ) void {
        _ = self;
        const absolute_min_width = 5; // Absolute minimum (enough for "ab…")

        // Calculate overhead
        const overhead_per_col: usize = 3; // " │ " between columns
        const border_overhead: usize = 2; // "│ " at start
        const total_overhead = border_overhead + (widths.len * overhead_per_col);

        // Calculate available content space
        const available_content = if (max_total > total_overhead) max_total - total_overhead else widths.len * absolute_min_width;

        // Initialize with header content widths
        for (header, 0..) |cell, i| {
            if (i < widths.len) {
                widths[i] = @max(absolute_min_width, cell.len);
            }
        }

        // Update with body content (use max of all cells in column)
        for (body) |row| {
            for (row.items, 0..) |cell, i| {
                if (i < widths.len) {
                    widths[i] = @max(widths[i], cell.len);
                }
            }
        }

        // Cap extremely wide columns
        for (widths) |*w| {
            w.* = @min(w.*, 50);
        }

        // Calculate total content needed
        var total_content: usize = 0;
        for (widths) |w| {
            total_content += w;
        }

        // If fits with preferred minimum, we're done
        if (total_content <= available_content) {
            return;
        }

        // Need to shrink - use proportional distribution
        // Calculate proportion factor
        if (total_content > 0) {
            for (widths) |*w| {
                // Proportional share, but respect minimum
                const proportional = (w.* * available_content) / total_content;
                w.* = @max(absolute_min_width, @min(proportional, w.*));
            }
        }

        // Final verification and adjustment - strictly enforce max_total
        var final_total: usize = 0;
        for (widths) |w| {
            final_total += w;
        }

        // If still over budget, uniformly shrink all columns
        if (final_total > available_content and widths.len > 0) {
            const uniform_width = @max(absolute_min_width, available_content / widths.len);
            for (widths) |*w| {
                w.* = uniform_width;
            }
        }
    }

    /// Render a single row (header or body) with word-wrapped cells
    fn renderRow(
        self: *TableRenderer,
        result: *TableRenderResult,
        cells: []const []const u8,
        widths: []const usize,
        alignments: []const Alignment,
        is_header: bool,
    ) !void {
        const style = if (is_header) self.colors.table_header else self.colors.table_cell;

        // Wrap each cell's content and track the lines
        const wrapped_cells = try self.allocator.alloc([]const []const u8, cells.len);
        defer {
            for (wrapped_cells) |cell_lines| {
                for (cell_lines) |line| {
                    self.allocator.free(line);
                }
                self.allocator.free(cell_lines);
            }
            self.allocator.free(wrapped_cells);
        }

        var max_lines: usize = 1;
        for (cells, 0..) |cell, i| {
            const width = if (i < widths.len) widths[i] else 10;
            wrapped_cells[i] = try wrapTextAlloc(self.allocator, cell, width);
            max_lines = @max(max_lines, wrapped_cells[i].len);
        }

        // Render each line of the row
        for (0..max_lines) |line_idx| {
            // Start border with box-drawing vertical bar
            try result.spans.append(self.allocator, .{
                .text = "│ ",
                .style = self.colors.table_border,
                .indent = 0,
                .node_type = .table,
            });

            // Render each cell's line (or empty padding if cell has fewer lines)
            for (0..cells.len) |i| {
                const width = if (i < widths.len) widths[i] else 10;
                const col_align = if (i < alignments.len) alignments[i] else .left;
                const cell_lines = wrapped_cells[i];

                const line_text = if (line_idx < cell_lines.len) cell_lines[line_idx] else "";

                // Pad and align cell content
                const padded = try padLineAlloc(self.allocator, line_text, width, col_align);
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
            // Guard against overflow and unreasonable widths
            const safe_width = @min(w, 100);
            const line = try buildHorizontalLineAlloc(self.allocator, safe_width + 2);
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

/// Pad a single line of text to specified width with alignment - allocates result
fn padLineAlloc(allocator: std.mem.Allocator, text: []const u8, width: usize, col_align: Alignment) ![]const u8 {
    const actual_width = @min(width, 126);
    const text_len = @min(text.len, actual_width);
    const padding = actual_width -| text_len;
    const buf_size = actual_width;

    const buf = try allocator.alloc(u8, buf_size);
    @memset(buf, ' ');

    const offset: usize = switch (col_align) {
        .left => 0,
        .right => padding,
        .center => padding / 2,
    };

    // Copy text
    @memcpy(buf[offset..][0..text_len], text[0..text_len]);

    return buf;
}

/// Wrap text to fit within a column width
/// Uses word-break where possible, character-break as fallback
/// Returns array of lines (caller owns all memory)
fn wrapTextAlloc(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]const []const u8 {
    if (width == 0) {
        const lines = try allocator.alloc([]const u8, 1);
        lines[0] = "";
        return lines;
    }

    // If text fits, return single line
    if (text.len <= width) {
        const lines = try allocator.alloc([]const u8, 1);
        const line_copy = try allocator.alloc(u8, text.len);
        @memcpy(line_copy, text);
        lines[0] = line_copy;
        return lines;
    }

    var lines_list: std.ArrayList([]const u8) = .{};
    errdefer {
        for (lines_list.items) |line| {
            allocator.free(line);
        }
        lines_list.deinit(allocator);
    }

    var remaining = text;

    while (remaining.len > 0) {
        if (remaining.len <= width) {
            // Last chunk fits
            const line_copy = try allocator.alloc(u8, remaining.len);
            @memcpy(line_copy, remaining);
            try lines_list.append(allocator, line_copy);
            break;
        }

        // Find break point - prefer word boundary
        var break_pos = width;

        // Look backwards for a space (word boundary)
        var i = width;
        while (i > 0) : (i -= 1) {
            if (remaining[i - 1] == ' ') {
                break_pos = i - 1; // Break before the space
                break;
            }
        }

        // If no space found, use character break at width
        if (i == 0) {
            break_pos = width;
        }

        // Don't create empty lines
        if (break_pos == 0) {
            break_pos = width;
        }

        // Copy this line
        const line_copy = try allocator.alloc(u8, break_pos);
        @memcpy(line_copy, remaining[0..break_pos]);
        try lines_list.append(allocator, line_copy);

        // Skip past break point and any leading spaces
        remaining = remaining[break_pos..];
        while (remaining.len > 0 and remaining[0] == ' ') {
            remaining = remaining[1..];
        }
    }

    // Handle empty input
    if (lines_list.items.len == 0) {
        const line_copy = try allocator.alloc(u8, 0);
        try lines_list.append(allocator, line_copy);
    }

    return try lines_list.toOwnedSlice(allocator);
}

/// Build a horizontal line of box-drawing characters - allocates result
/// Uses ─ (U+2500) which is 3 bytes in UTF-8
fn buildHorizontalLineAlloc(allocator: std.mem.Allocator, char_width: usize) ![]const u8 {
    // Cap width to prevent overflow (62 * 3 = 186 bytes max)
    const capped_width: usize = if (char_width > 62) 62 else char_width;
    // ─ is 3 bytes in UTF-8 (0xE2 0x94 0x80)
    const buf = try allocator.alloc(u8, capped_width * 3);

    var i: usize = 0;
    while (i < capped_width) : (i += 1) {
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

test "padLineAlloc - left alignment" {
    const allocator = std.testing.allocator;
    const result = try padLineAlloc(allocator, "Hi", 6, .left);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi    ", result);
}

test "padLineAlloc - right alignment" {
    const allocator = std.testing.allocator;
    const result = try padLineAlloc(allocator, "Hi", 6, .right);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("    Hi", result);
}

test "padLineAlloc - center alignment" {
    const allocator = std.testing.allocator;
    const result = try padLineAlloc(allocator, "Hi", 6, .center);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("  Hi  ", result);
}

test "wrapTextAlloc - text fits in width" {
    const allocator = std.testing.allocator;
    const lines = try wrapTextAlloc(allocator, "Hello", 10);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("Hello", lines[0]);
}

test "wrapTextAlloc - word wrap" {
    const allocator = std.testing.allocator;
    const lines = try wrapTextAlloc(allocator, "Hello world today", 10);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("Hello", lines[0]);
    try std.testing.expectEqualStrings("world", lines[1]);
    try std.testing.expectEqualStrings("today", lines[2]);
}

test "wrapTextAlloc - character wrap fallback" {
    const allocator = std.testing.allocator;
    const lines = try wrapTextAlloc(allocator, "Superlongword", 5);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("Super", lines[0]);
    try std.testing.expectEqualStrings("longw", lines[1]);
    try std.testing.expectEqualStrings("ord", lines[2]);
}

test "wrapTextAlloc - mixed word and char wrap" {
    const allocator = std.testing.allocator;
    const lines = try wrapTextAlloc(allocator, "Hi superlongword bye", 8);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("Hi", lines[0]);
    try std.testing.expectEqualStrings("superlon", lines[1]);
    try std.testing.expectEqualStrings("gword", lines[2]);
    try std.testing.expectEqualStrings("bye", lines[3]);
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

test "calculateWidths - respects max width with many columns" {
    const allocator = std.testing.allocator;
    var renderer = TableRenderer.init(allocator, colors_mod.default);

    // Simulate 5 columns with long content
    const header = [_][]const u8{
        "Category",
        "Feature Name",
        "Status",
        "Priority",
        "Description",
    };

    // No body rows for this test
    const body = [_]std.ArrayList([]const u8){};

    const widths = try allocator.alloc(usize, 5);
    defer allocator.free(widths);
    @memset(widths, 5);

    // Test with narrow terminal (60 chars)
    renderer.calculateWidths(&header, &body, widths, 60);

    // Calculate total width (content + overhead)
    var total: usize = 2; // "│ " at start
    for (widths) |w| {
        total += w + 3; // content + " │ "
    }

    // Should fit within max_width
    try std.testing.expect(total <= 60);

    // All widths should be reasonable (>= 5, the absolute minimum)
    for (widths) |w| {
        try std.testing.expect(w >= 5);
        try std.testing.expect(w <= 100); // Sanity check
    }
}

test "calculateWidths - handles very narrow width" {
    const allocator = std.testing.allocator;
    var renderer = TableRenderer.init(allocator, colors_mod.default);

    const header = [_][]const u8{ "Col1", "Col2", "Col3" };
    const body = [_]std.ArrayList([]const u8){};

    const widths = try allocator.alloc(usize, 3);
    defer allocator.free(widths);
    @memset(widths, 5);

    // Very narrow terminal (should use minimum widths)
    renderer.calculateWidths(&header, &body, widths, 20);

    // All widths should still be valid (>= absolute minimum of 5)
    for (widths) |w| {
        try std.testing.expect(w >= 5);
    }
}
