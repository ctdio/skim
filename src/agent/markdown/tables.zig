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
const gwidth = vaxis.gwidth;
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

        // If tree-sitter parsing failed, try text-based fallback parsing.
        // This handles cases where tree-sitter's AST is temporarily inconsistent
        // during streaming (e.g., when a new row is being typed).
        if (header_cells.items.len == 0) {
            const raw_text = md_parser.getNodeText(node);
            try self.parseTableFromText(raw_text, &header_cells, &alignments, &body_rows);
        }

        // If still no valid table data, return empty to trigger dimmed fallback
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

    /// Fallback text-based table parser for when tree-sitter AST is inconsistent.
    /// Parses table structure directly from raw text.
    fn parseTableFromText(
        self: *TableRenderer,
        text: []const u8,
        header_cells: *std.ArrayList([]const u8),
        alignments: *std.ArrayList(Alignment),
        body_rows: *std.ArrayList(std.ArrayList([]const u8)),
    ) !void {
        var line_iter = std.mem.splitScalar(u8, text, '\n');
        var found_header = false;
        var found_delimiter = false;

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Skip lines that don't start with |
            if (trimmed[0] != '|') continue;

            if (!found_header) {
                // First | line is header
                try self.parseCellsFromText(trimmed, header_cells);
                found_header = true;
            } else if (!found_delimiter) {
                // Second | line should be delimiter
                if (isDelimiterRow(trimmed)) {
                    try self.parseAlignmentsFromText(trimmed, alignments);
                    found_delimiter = true;
                } else {
                    // Not a delimiter - might be malformed, treat as body
                    var row: std.ArrayList([]const u8) = .{};
                    try self.parseCellsFromText(trimmed, &row);
                    if (row.items.len > 0) {
                        try body_rows.append(self.allocator, row);
                    }
                }
            } else {
                // After delimiter, all | lines are body rows
                var row: std.ArrayList([]const u8) = .{};
                try self.parseCellsFromText(trimmed, &row);
                if (row.items.len > 0) {
                    try body_rows.append(self.allocator, row);
                }
            }
        }
    }

    /// Parse cells from a text line (split by |)
    fn parseCellsFromText(
        self: *TableRenderer,
        line: []const u8,
        cells: *std.ArrayList([]const u8),
    ) !void {
        var iter = std.mem.splitScalar(u8, line, '|');
        while (iter.next()) |cell| {
            const trimmed = std.mem.trim(u8, cell, " \t");
            // Skip empty cells at start/end from leading/trailing |
            if (trimmed.len > 0 or cells.items.len > 0) {
                // Only add non-empty cells, or empty cells in the middle
                if (trimmed.len > 0) {
                    try cells.append(self.allocator, trimmed);
                }
            }
        }
    }

    /// Parse alignments from delimiter row text
    fn parseAlignmentsFromText(
        self: *TableRenderer,
        line: []const u8,
        alignments: *std.ArrayList(Alignment),
    ) !void {
        var iter = std.mem.splitScalar(u8, line, '|');
        while (iter.next()) |cell| {
            const trimmed = std.mem.trim(u8, cell, " \t");
            if (trimmed.len == 0) continue;
            // Check if it looks like a delimiter cell (contains ---)
            if (std.mem.indexOf(u8, trimmed, "---") != null or
                std.mem.indexOf(u8, trimmed, "--") != null)
            {
                try alignments.append(self.allocator, parseAlignment(trimmed));
            }
        }
    }

    /// Check if a line looks like a delimiter row
    fn isDelimiterRow(line: []const u8) bool {
        // Must contain at least one sequence of 3+ dashes
        var consecutive_dashes: usize = 0;
        for (line) |c| {
            if (c == '-') {
                consecutive_dashes += 1;
                if (consecutive_dashes >= 3) return true;
            } else {
                consecutive_dashes = 0;
            }
        }
        return false;
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

        // Initialize with header content widths (using display width for multi-byte chars)
        for (header, 0..) |cell, i| {
            if (i < widths.len) {
                widths[i] = @max(absolute_min_width, displayWidth(cell));
            }
        }

        // Update with body content (use max of all cells in column)
        for (body) |row| {
            for (row.items, 0..) |cell, i| {
                if (i < widths.len) {
                    widths[i] = @max(widths[i], displayWidth(cell));
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

/// Calculate display width of UTF-8 text in terminal cells
/// Handles multi-byte characters like emojis correctly
fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var byte_pos: usize = 0;

    while (byte_pos < text.len) {
        const char_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
        const char_end = @min(byte_pos + char_len, text.len);
        const grapheme = text[byte_pos..char_end];
        width += gwidth.gwidth(grapheme, .unicode);
        byte_pos = char_end;
    }

    return width;
}

/// Slice a UTF-8 string by display width (terminal cells), not bytes.
/// Returns a slice of the input text containing at most `max_width` terminal cells.
/// The returned slice ends at a valid UTF-8 boundary.
fn sliceByDisplayWidth(text: []const u8, max_width: usize) []const u8 {
    if (max_width == 0) return text[0..0];

    var width: usize = 0;
    var byte_pos: usize = 0;

    while (byte_pos < text.len) {
        const char_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
        const char_end = @min(byte_pos + char_len, text.len);
        const grapheme = text[byte_pos..char_end];
        const char_width = gwidth.gwidth(grapheme, .unicode);

        // Check if adding this character would exceed max_width
        if (width + char_width > max_width) break;

        width += char_width;
        byte_pos = char_end;
    }

    return text[0..byte_pos];
}

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

/// Pad a single line of text to specified width (in display cells) with alignment - allocates result
/// Handles multi-byte characters like emojis correctly by using display width, not byte length
fn padLineAlloc(allocator: std.mem.Allocator, text: []const u8, width: usize, col_align: Alignment) ![]const u8 {
    const actual_width = @min(width, 126);

    // Calculate display width (terminal cells), not byte length
    const text_display_width = displayWidth(text);
    const padding_cells = actual_width -| text_display_width;

    // Buffer needs: text bytes + padding spaces (1 byte each)
    const buf_size = text.len + padding_cells;

    const buf = try allocator.alloc(u8, buf_size);

    // Calculate offset in bytes for alignment
    const offset_cells: usize = switch (col_align) {
        .left => 0,
        .right => padding_cells,
        .center => padding_cells / 2,
    };

    // Fill with spaces first
    @memset(buf, ' ');

    // Copy text at the calculated offset (offset is in spaces/cells, but text is bytes)
    @memcpy(buf[offset_cells..][0..text.len], text);

    return buf;
}

/// Wrap text to fit within a column width (in display cells)
/// Uses word-break where possible, character-break as fallback
/// Handles multi-byte characters like emojis correctly
/// Returns array of lines (caller owns all memory)
fn wrapTextAlloc(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]const []const u8 {
    if (width == 0) {
        const lines = try allocator.alloc([]const u8, 1);
        lines[0] = "";
        return lines;
    }

    // If text fits (by display width), return single line
    if (displayWidth(text) <= width) {
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
        const remaining_width = displayWidth(remaining);
        if (remaining_width <= width) {
            // Last chunk fits
            const line_copy = try allocator.alloc(u8, remaining.len);
            @memcpy(line_copy, remaining);
            try lines_list.append(allocator, line_copy);
            break;
        }

        // Get max_width display cells worth of text (byte slice)
        const max_chunk = sliceByDisplayWidth(remaining, width);

        // Find break point - look backwards for a space (word boundary)
        var break_pos = max_chunk.len;
        var found_space = false;

        // Look backwards through the bytes to find a space
        var i = max_chunk.len;
        while (i > 0) : (i -= 1) {
            if (max_chunk[i - 1] == ' ') {
                break_pos = i - 1; // Break before the space
                found_space = true;
                break;
            }
        }

        // If no space found, hard break at max display width
        if (!found_space) {
            break_pos = max_chunk.len;
        }

        // Don't create empty lines
        if (break_pos == 0) {
            break_pos = max_chunk.len;
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
    // Cap at reasonable max (500 chars = 1500 bytes) to prevent extreme allocations
    const capped_width: usize = @min(char_width, 500);
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

test "padLineAlloc - emoji uses display width not byte length" {
    const allocator = std.testing.allocator;
    // ✅ is U+2705, takes 3 bytes in UTF-8 but displays as 2 terminal cells
    // With width=6, emoji (2 cells) + 4 spaces should give us total of 6 display cells
    const result = try padLineAlloc(allocator, "✅", 6, .left);
    defer allocator.free(result);
    // Result should be: emoji (3 bytes) + 4 spaces = 7 bytes
    // Display width: 2 (emoji) + 4 (spaces) = 6 cells
    try std.testing.expectEqual(@as(usize, 7), result.len); // 3 bytes for ✅ + 4 spaces
    try std.testing.expectEqualStrings("✅    ", result);
}

test "padLineAlloc - emoji right alignment" {
    const allocator = std.testing.allocator;
    // ✅ is 2 display cells, so with width=6 we need 4 spaces before it
    const result = try padLineAlloc(allocator, "✅", 6, .right);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 7), result.len); // 4 spaces + 3 bytes for ✅
    try std.testing.expectEqualStrings("    ✅", result);
}

test "displayWidth - ascii text" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("Hello"));
}

test "displayWidth - emoji" {
    // ✅ (U+2705) displays as 2 terminal cells
    try std.testing.expectEqual(@as(usize, 2), displayWidth("✅"));
}

test "displayWidth - mixed ascii and emoji" {
    // "A✅B" = 1 + 2 + 1 = 4 display cells
    try std.testing.expectEqual(@as(usize, 4), displayWidth("A✅B"));
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

test "wrapTextAlloc - emoji uses display width not byte length" {
    const allocator = std.testing.allocator;
    // "✅ (209KB)" is 10 display cells: ✅=2, space=1, (209KB)=7
    // With width=12, it should fit on one line (not wrap due to byte length)
    const lines = try wrapTextAlloc(allocator, "✅ (209KB)", 12);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("✅ (209KB)", lines[0]);
}

test "wrapTextAlloc - emoji word wrap" {
    const allocator = std.testing.allocator;
    // "🐕 Dog woof" is 10 display cells: 🐕=2, space=1, Dog=3, space=1, woof=4
    // With width=8, should wrap to "🐕 Dog" (6 cells) and "woof" (4 cells)
    const lines = try wrapTextAlloc(allocator, "🐕 Dog woof", 8);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("🐕 Dog", lines[0]);
    try std.testing.expectEqualStrings("woof", lines[1]);
}

test "sliceByDisplayWidth - ascii" {
    const result = sliceByDisplayWidth("Hello World", 5);
    try std.testing.expectEqualStrings("Hello", result);
}

test "sliceByDisplayWidth - emoji" {
    // ✅ is 2 display cells, so with max_width=3 we get ✅ (2 cells)
    const result = sliceByDisplayWidth("✅AB", 3);
    try std.testing.expectEqualStrings("✅A", result);
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
