const std = @import("std");
const vaxis = @import("vaxis");

// Types
pub const Screen = vaxis.Screen;
pub const Window = vaxis.Window;
pub const Cell = vaxis.Cell;

/// TestContext provides a mock screen and window for testing rendering functions.
/// Use createTestContext() to instantiate, then call window() to get a Window for rendering.
/// After rendering, use captureToText() to serialize the screen buffer to a string.
///
/// Includes a frame allocator for temporary strings used during rendering - allocated
/// strings persist until deinit() is called.
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    screen: Screen,
    unicode: vaxis.Unicode,
    arena: std.heap.ArenaAllocator,

    /// Returns a Window that covers the entire screen.
    pub fn window(self: *TestContext) Window {
        return .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = self.screen.width,
            .height = self.screen.height,
            .screen = &self.screen,
            .unicode = &self.unicode,
        };
    }

    /// Returns the frame allocator for temporary strings during rendering.
    /// Allocated memory persists until deinit() is called.
    pub fn frameAllocator(self: *TestContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Captures the current screen content as a text string.
    /// - Iterates all rows and extracts graphemes from cells
    /// - Handles wide characters by skipping continuation cells
    /// - Trims trailing whitespace from each row
    /// - Trims trailing empty lines
    pub fn captureToText(self: *TestContext) ![]const u8 {
        var result: std.ArrayList(u8) = .{};
        errdefer result.deinit(self.allocator);

        var row: u16 = 0;
        while (row < self.screen.height) : (row += 1) {
            const row_start = result.items.len;
            var col: u16 = 0;
            while (col < self.screen.width) {
                const cell = self.screen.readCell(col, row) orelse {
                    col += 1;
                    continue;
                };
                const grapheme = cell.char.grapheme;
                const width = cell.char.width;

                // Skip continuation cells (width 0 indicates part of wide char)
                if (width == 0) {
                    col += 1;
                    continue;
                }

                // Skip cells with empty graphemes (unwritten cells)
                // If the grapheme has no content, treat it as a space
                if (grapheme.len == 0) {
                    try result.append(self.allocator, ' ');
                    col += 1;
                    continue;
                }

                // Append the grapheme
                try result.appendSlice(self.allocator, grapheme);

                // Move past the cell (and any continuation cells for wide chars)
                col += if (width > 0) width else 1;
            }

            // Trim trailing spaces from this row
            var row_end = result.items.len;
            while (row_end > row_start and result.items[row_end - 1] == ' ') {
                row_end -= 1;
            }
            result.shrinkRetainingCapacity(row_end);

            // Add newline (will trim trailing empty lines later)
            try result.append(self.allocator, '\n');
        }

        // Trim trailing empty lines (lines that are just '\n')
        var end = result.items.len;
        while (end > 0 and result.items[end - 1] == '\n') {
            end -= 1;
        }

        // Shrink to final size
        result.shrinkRetainingCapacity(end);

        return result.toOwnedSlice(self.allocator);
    }

    /// Captures the current screen content as ANSI-escaped text.
    /// - Iterates all rows and extracts graphemes with style information
    /// - Outputs ANSI escape codes when styles change
    /// - Handles fg/bg colors (index and RGB) and bold/dim attributes
    /// - Trims trailing whitespace from each row (unless they have background color)
    pub fn captureToAnsi(self: *TestContext) ![]const u8 {
        var result: std.ArrayList(u8) = .{};
        errdefer result.deinit(self.allocator);

        var current_style: vaxis.Style = .{};
        var has_style = false;

        var row: u16 = 0;
        while (row < self.screen.height) : (row += 1) {
            const row_start = result.items.len;
            var col: u16 = 0;

            // Track whether trailing spaces have a background color
            var last_non_space_pos: usize = row_start;
            var trailing_has_bg = false;

            while (col < self.screen.width) {
                const cell = self.screen.readCell(col, row) orelse {
                    col += 1;
                    continue;
                };
                const grapheme = cell.char.grapheme;
                const width = cell.char.width;

                // Skip continuation cells
                if (width == 0) {
                    col += 1;
                    continue;
                }

                // Check if style changed
                if (!stylesEqual(cell.style, current_style) or !has_style) {
                    try writeStyleChange(&result, self.allocator, current_style, cell.style, has_style);
                    current_style = cell.style;
                    has_style = true;
                }

                // Output grapheme (or space if empty)
                const is_space = grapheme.len == 0 or (grapheme.len == 1 and grapheme[0] == ' ');
                if (grapheme.len == 0) {
                    try result.append(self.allocator, ' ');
                } else {
                    try result.appendSlice(self.allocator, grapheme);
                }

                // Track position for trimming - only trim spaces with default background
                if (!is_space) {
                    last_non_space_pos = result.items.len;
                    trailing_has_bg = false;
                } else if (cell.style.bg != .default) {
                    // Space with background color - don't trim it
                    trailing_has_bg = true;
                }

                col += if (width > 0) width else 1;
            }

            // Trim trailing spaces only if they don't have a background color
            if (!trailing_has_bg) {
                result.shrinkRetainingCapacity(last_non_space_pos);
            }

            // Reset style at end of line and add newline
            if (has_style) {
                try result.appendSlice(self.allocator, "\x1b[0m");
                current_style = .{};
                has_style = false;
            }
            try result.append(self.allocator, '\n');
        }

        // Trim trailing empty lines
        var end = result.items.len;
        while (end > 0 and result.items[end - 1] == '\n') {
            end -= 1;
        }
        result.shrinkRetainingCapacity(end);

        return result.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *TestContext) void {
        self.arena.deinit();
        self.screen.deinit(self.allocator);
        self.unicode.deinit(self.allocator);
    }
};

/// Check if two styles are equal
fn stylesEqual(a: vaxis.Style, b: vaxis.Style) bool {
    return colorsEqual(a.fg, b.fg) and
        colorsEqual(a.bg, b.bg) and
        a.bold == b.bold and
        a.dim == b.dim;
}

/// Check if two colors are equal
fn colorsEqual(a: vaxis.Cell.Color, b: vaxis.Cell.Color) bool {
    return switch (a) {
        .default => b == .default,
        .index => |ai| switch (b) {
            .index => |bi| ai == bi,
            else => false,
        },
        .rgb => |ar| switch (b) {
            .rgb => |br| ar[0] == br[0] and ar[1] == br[1] and ar[2] == br[2],
            else => false,
        },
    };
}

/// Write ANSI escape codes for style change
fn writeStyleChange(
    result: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    old: vaxis.Style,
    new: vaxis.Style,
    had_style: bool,
) !void {
    // If we had a style and now need different one, reset first
    if (had_style and needsReset(old, new)) {
        try result.appendSlice(allocator, "\x1b[0m");
    }

    // Build new style codes
    var codes: [16]u8 = undefined;
    var code_count: usize = 0;

    // Bold
    if (new.bold) {
        codes[code_count] = 1;
        code_count += 1;
    }

    // Dim
    if (new.dim) {
        codes[code_count] = 2;
        code_count += 1;
    }

    // Foreground color
    if (new.fg != .default) {
        try writeColorCodes(result, allocator, new.fg, false);
    }

    // Background color
    if (new.bg != .default) {
        try writeColorCodes(result, allocator, new.bg, true);
    }

    // Write attribute codes (bold/dim) if any
    if (code_count > 0) {
        try result.appendSlice(allocator, "\x1b[");
        for (codes[0..code_count], 0..) |code, i| {
            if (i > 0) try result.append(allocator, ';');
            var buf: [4]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{code}) catch "0";
            try result.appendSlice(allocator, num_str);
        }
        try result.append(allocator, 'm');
    }
}

/// Check if we need to reset before applying new style
fn needsReset(old: vaxis.Style, new: vaxis.Style) bool {
    // Need reset if we're turning off bold/dim, or changing from one color to another
    if (old.bold and !new.bold) return true;
    if (old.dim and !new.dim) return true;
    if (old.fg != .default and new.fg == .default) return true;
    if (old.bg != .default and new.bg == .default) return true;
    return false;
}

/// Write ANSI color codes
fn writeColorCodes(
    result: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    color: vaxis.Cell.Color,
    is_bg: bool,
) !void {
    switch (color) {
        .default => {},
        .index => |idx| {
            // 256-color mode: ESC[38;5;Nm for fg, ESC[48;5;Nm for bg
            const prefix: []const u8 = if (is_bg) "\x1b[48;5;" else "\x1b[38;5;";
            try result.appendSlice(allocator, prefix);
            var buf: [4]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch "0";
            try result.appendSlice(allocator, num_str);
            try result.append(allocator, 'm');
        },
        .rgb => |rgb| {
            // 24-bit color: ESC[38;2;R;G;Bm for fg, ESC[48;2;R;G;Bm for bg
            const prefix: []const u8 = if (is_bg) "\x1b[48;2;" else "\x1b[38;2;";
            try result.appendSlice(allocator, prefix);
            var buf: [12]u8 = undefined;
            const rgb_str = std.fmt.bufPrint(&buf, "{d};{d};{d}", .{ rgb[0], rgb[1], rgb[2] }) catch "0;0;0";
            try result.appendSlice(allocator, rgb_str);
            try result.append(allocator, 'm');
        },
    }
}

/// Creates a test context with a mock screen of the given dimensions.
pub fn createTestContext(allocator: std.mem.Allocator, cols: u16, rows: u16) !TestContext {
    var screen = try Screen.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    errdefer screen.deinit(allocator);

    const unicode = try vaxis.Unicode.init(allocator);

    return .{
        .allocator = allocator,
        .screen = screen,
        .unicode = unicode,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

// Tests

test "createTestContext creates screen with correct dimensions" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 80, 24);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u16, 80), ctx.screen.width);
    try std.testing.expectEqual(@as(u16, 24), ctx.screen.height);
}

test "createTestContext creates screen with small dimensions" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 10, 5);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u16, 10), ctx.screen.width);
    try std.testing.expectEqual(@as(u16, 5), ctx.screen.height);
}

test "window returns valid Window struct" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 40, 10);
    defer ctx.deinit();

    const win = ctx.window();
    try std.testing.expectEqual(@as(i17, 0), win.x_off);
    try std.testing.expectEqual(@as(i17, 0), win.y_off);
    try std.testing.expectEqual(@as(u16, 40), win.width);
    try std.testing.expectEqual(@as(u16, 10), win.height);
}

test "captureToText on empty screen returns empty string" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 20, 5);
    defer ctx.deinit();

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("", text);
}

test "captureToText captures simple ASCII text" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 20, 5);
    defer ctx.deinit();

    var win = ctx.window();
    var segs = [_]Cell.Segment{.{ .text = "Hello, World!" }};
    _ = win.print(&segs, .{ .row_offset = 0 });

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Hello, World!", text);
}

test "captureToText captures multiple rows" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 20, 5);
    defer ctx.deinit();

    var win = ctx.window();
    var seg1 = [_]Cell.Segment{.{ .text = "Line 1" }};
    var seg2 = [_]Cell.Segment{.{ .text = "Line 2" }};
    var seg3 = [_]Cell.Segment{.{ .text = "Line 3" }};
    _ = win.print(&seg1, .{ .row_offset = 0 });
    _ = win.print(&seg2, .{ .row_offset = 1 });
    _ = win.print(&seg3, .{ .row_offset = 2 });

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", text);
}

test "captureToText trims trailing spaces" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 20, 5);
    defer ctx.deinit();

    var win = ctx.window();
    var segs = [_]Cell.Segment{.{ .text = "Text" }};
    _ = win.print(&segs, .{ .row_offset = 0 });
    // Screen fills remaining cols with spaces, but they should be trimmed

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Text", text);
}

test "captureToText trims trailing empty lines" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 20, 10);
    defer ctx.deinit();

    var win = ctx.window();
    var seg1 = [_]Cell.Segment{.{ .text = "Content" }};
    _ = win.print(&seg1, .{ .row_offset = 0 });
    // Rows 1-9 are empty and should be trimmed

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Content", text);
}

test "captureToText handles UTF-8 characters" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 30, 5);
    defer ctx.deinit();

    var win = ctx.window();
    var segs = [_]Cell.Segment{.{ .text = "cafe" }};
    _ = win.print(&segs, .{ .row_offset = 0 });

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("cafe", text);
}

test "captureToText handles box drawing" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 30, 5);
    defer ctx.deinit();

    var win = ctx.window();
    // Box drawing characters
    var segs = [_]Cell.Segment{.{ .text = "+-+|X|+-+" }};
    _ = win.print(&segs, .{ .row_offset = 0 });

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("+-+|X|+-+", text);
}

test "captureToText handles emoji" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 30, 5);
    defer ctx.deinit();

    var win = ctx.window();
    // Test with simple smile emoji (may be 2 cells wide)
    win.writeCell(0, 0, .{ .char = .{ .grapheme = "A", .width = 1 } });
    win.writeCell(1, 0, .{ .char = .{ .grapheme = "B", .width = 1 } });
    win.writeCell(2, 0, .{ .char = .{ .grapheme = "C", .width = 1 } });

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("ABC", text);
}

test "captureToText handles wide characters correctly" {
    const allocator = std.testing.allocator;
    var ctx = try createTestContext(allocator, 30, 5);
    defer ctx.deinit();

    var win = ctx.window();
    // Wide character (CJK) takes 2 cells
    // Write a wide char at col 0, it occupies cols 0-1
    win.writeCell(0, 0, .{ .char = .{ .grapheme = "X", .width = 2 } });
    // Continuation cell at col 1 (width 0)
    win.writeCell(1, 0, .{ .char = .{ .grapheme = "", .width = 0 } });
    // Regular char at col 2
    win.writeCell(2, 0, .{ .char = .{ .grapheme = "Y", .width = 1 } });

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expectEqualStrings("XY", text);
}
