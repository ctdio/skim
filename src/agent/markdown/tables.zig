//! GFM Table Parsing and ASCII Rendering
//!
//! Handles rendering of GFM (GitHub Flavored Markdown) tables with:
//! - Header row with bold styling
//! - Column alignment (left, center, right)
//! - ASCII borders using | and -
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
    pub fn render(
        self: *TableRenderer,
        node: ts.Node,
        md_parser: *const MarkdownParser,
        max_width: usize,
    ) !std.ArrayList(StyledSpan) {
        var spans = std.ArrayList(StyledSpan).init(self.allocator);
        errdefer spans.deinit();

        // Extract table data
        var header_cells = std.ArrayList([]const u8).init(self.allocator);
        defer header_cells.deinit();

        var alignments = std.ArrayList(Alignment).init(self.allocator);
        defer alignments.deinit();

        var body_rows = std.ArrayList(std.ArrayList([]const u8)).init(self.allocator);
        defer {
            for (body_rows.items) |*row| {
                row.deinit();
            }
            body_rows.deinit();
        }

        // Parse the table structure from tree-sitter nodes
        try self.parseTableNode(node, md_parser, &header_cells, &alignments, &body_rows);

        // If no valid table data found, return empty
        if (header_cells.items.len == 0) {
            return spans;
        }

        // Calculate column widths
        const num_cols = header_cells.items.len;
        var widths = try self.allocator.alloc(usize, num_cols);
        defer self.allocator.free(widths);

        self.calculateWidths(header_cells.items, body_rows.items, widths, max_width);

        // Ensure alignments match column count
        while (alignments.items.len < num_cols) {
            try alignments.append(.left);
        }

        // Render header row
        try self.renderRow(&spans, header_cells.items, widths, alignments.items, true);

        // Render separator
        try self.renderSeparator(&spans, widths, alignments.items);

        // Render body rows
        for (body_rows.items) |row| {
            try self.renderRow(&spans, row.items, widths, alignments.items, false);
        }

        return spans;
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
                    var row = std.ArrayList([]const u8).init(self.allocator);
                    try self.parseCells(child, md_parser, &row);
                    try body_rows.append(row);
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
        _ = self;
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
                    try cells.append(trimmed);
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
        _ = self;
        const child_count = delim_node.childCount();
        var i: u32 = 0;

        while (i < child_count) : (i += 1) {
            if (delim_node.child(i)) |child| {
                const child_type = child.kind();

                if (std.mem.indexOf(u8, child_type, "cell") != null or
                    std.mem.indexOf(u8, child_type, "delimiter") != null)
                {
                    const text = md_parser.getNodeText(child);
                    const alignment = parseAlignment(text);
                    try alignments.append(alignment);
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
                    try alignments.append(parseAlignment(trimmed));
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
        spans: *std.ArrayList(StyledSpan),
        cells: []const []const u8,
        widths: []const usize,
        alignments: []const Alignment,
        is_header: bool,
    ) !void {
        const style = if (is_header) self.colors.table_header else self.colors.table_cell;

        // Start border
        try spans.append(.{
            .text = "| ",
            .style = self.colors.table_border,
            .indent = 0,
            .node_type = .table,
        });

        // Render each cell
        for (cells, 0..) |cell, i| {
            const width = if (i < widths.len) widths[i] else 10;
            const align = if (i < alignments.len) alignments[i] else .left;

            // Pad and align cell content
            var buf: [128]u8 = undefined;
            const padded = padCell(cell, width, align, &buf);

            try spans.append(.{
                .text = padded,
                .style = style,
                .indent = 0,
                .node_type = .table,
            });

            try spans.append(.{
                .text = " | ",
                .style = self.colors.table_border,
                .indent = 0,
                .node_type = .table,
            });
        }

        // Newline
        try spans.append(.{
            .text = "\n",
            .style = self.colors.text,
            .indent = 0,
            .node_type = .softbreak,
        });
    }

    /// Render the separator row between header and body
    fn renderSeparator(
        self: *TableRenderer,
        spans: *std.ArrayList(StyledSpan),
        widths: []const usize,
        alignments: []const Alignment,
    ) !void {
        // Start border
        try spans.append(.{
            .text = "|",
            .style = self.colors.table_border,
            .indent = 0,
            .node_type = .table,
        });

        // Render separator for each column
        for (widths, 0..) |w, i| {
            const align = if (i < alignments.len) alignments[i] else .left;

            // Build separator string: :---:, :---, ---:, or ---
            var sep_buf: [64]u8 = undefined;
            const sep = buildSeparator(w, align, &sep_buf);

            try spans.append(.{
                .text = sep,
                .style = self.colors.table_border,
                .indent = 0,
                .node_type = .table,
            });

            try spans.append(.{
                .text = "|",
                .style = self.colors.table_border,
                .indent = 0,
                .node_type = .table,
            });
        }

        // Newline
        try spans.append(.{
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

/// Pad cell content to specified width with alignment
fn padCell(text: []const u8, width: usize, alignment: Alignment, buf: *[128]u8) []const u8 {
    const actual_width = @min(width, 126);
    const text_len = @min(text.len, actual_width);

    @memset(buf[0..actual_width], ' ');

    const offset: usize = switch (alignment) {
        .left => 0,
        .right => actual_width -| text_len,
        .center => (actual_width -| text_len) / 2,
    };

    @memcpy(buf[offset..][0..text_len], text[0..text_len]);
    return buf[0..actual_width];
}

/// Build separator string for a column
fn buildSeparator(width: usize, alignment: Alignment, buf: *[64]u8) []const u8 {
    const actual_width = @min(width + 2, 62); // +2 for padding

    switch (alignment) {
        .left => {
            buf[0] = ':';
            @memset(buf[1..actual_width], '-');
        },
        .right => {
            @memset(buf[0 .. actual_width - 1], '-');
            buf[actual_width - 1] = ':';
        },
        .center => {
            buf[0] = ':';
            @memset(buf[1 .. actual_width - 1], '-');
            buf[actual_width - 1] = ':';
        },
    }

    return buf[0..actual_width];
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

test "padCell - left alignment" {
    var buf: [128]u8 = undefined;
    const result = padCell("Hi", 6, .left, &buf);
    try std.testing.expectEqualStrings("Hi    ", result);
}

test "padCell - right alignment" {
    var buf: [128]u8 = undefined;
    const result = padCell("Hi", 6, .right, &buf);
    try std.testing.expectEqualStrings("    Hi", result);
}

test "padCell - center alignment" {
    var buf: [128]u8 = undefined;
    const result = padCell("Hi", 6, .center, &buf);
    try std.testing.expectEqualStrings("  Hi  ", result);
}

test "buildSeparator - left" {
    var buf: [64]u8 = undefined;
    const result = buildSeparator(4, .left, &buf);
    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqual(@as(u8, ':'), result[0]);
    try std.testing.expectEqual(@as(u8, '-'), result[1]);
}

test "buildSeparator - right" {
    var buf: [64]u8 = undefined;
    const result = buildSeparator(4, .right, &buf);
    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqual(@as(u8, '-'), result[0]);
    try std.testing.expectEqual(@as(u8, ':'), result[result.len - 1]);
}

test "buildSeparator - center" {
    var buf: [64]u8 = undefined;
    const result = buildSeparator(4, .center, &buf);
    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqual(@as(u8, ':'), result[0]);
    try std.testing.expectEqual(@as(u8, ':'), result[result.len - 1]);
}

test "table renderer init" {
    const allocator = std.testing.allocator;
    const renderer = TableRenderer.init(allocator, colors_mod.default);

    // Just verify it doesn't crash and has expected fields
    try std.testing.expect(renderer.colors.table_header.bold);
    try std.testing.expect(renderer.colors.table_border.fg != .default);
}
