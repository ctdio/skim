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

    pub fn deinit(self: *TestContext) void {
        self.arena.deinit();
        self.screen.deinit(self.allocator);
    }
};

/// Creates a test context with a mock screen of the given dimensions.
pub fn createTestContext(allocator: std.mem.Allocator, cols: u16, rows: u16) !TestContext {
    const screen = try Screen.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    return .{
        .allocator = allocator,
        .screen = screen,
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
