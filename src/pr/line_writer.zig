//! A tiny left-to-right cell writer over a `vaxis.Window` row, shared by the PR
//! picker (`render.zig`) and the review overlays (`review_render.zig`). It clips
//! at the window's right edge and, when `bg` is set, forces that background onto
//! every cell so a popup layers cleanly over the diff underneath. Pure drawing —
//! it only writes cells.

const std = @import("std");
const vaxis = @import("vaxis");
const skim_io = @import("skim_io");

const Style = vaxis.Cell.Style;
const Color = vaxis.Cell.Color;

const digit_graphemes = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

pub const LineWriter = struct {
    win: vaxis.Window,
    row: u16,
    col: u16,
    style: Style,
    bg: ?Color,

    pub fn init(params: struct {
        win: vaxis.Window,
        row: u16,
        col: u16 = 0,
        style: Style = .{},
        bg: ?Color = null,
    }) LineWriter {
        return .{
            .win = params.win,
            .row = params.row,
            .col = params.col,
            .style = params.style,
            .bg = params.bg,
        };
    }

    pub fn text(self: *LineWriter, value: []const u8) void {
        const ascii = asciiRun(value);
        for (0..ascii) |index| self.cell(value[index..][0..1], 1);
        const rest = value[ascii..];
        var iter = vaxis.unicode.graphemeIterator(rest);
        while (iter.next()) |item| {
            const bytes = item.bytes(rest);
            if (std.mem.eql(u8, bytes, "\n")) return;
            self.grapheme(bytes);
        }
    }

    pub fn styledText(self: *LineWriter, value: []const u8, style: Style) void {
        const old_style = self.style;
        self.style = style;
        self.text(value);
        self.style = old_style;
    }

    pub fn unsigned(self: *LineWriter, value: u64) void {
        var divisor: u64 = 1;
        while (value / divisor >= 10) divisor *= 10;
        var remaining = divisor;
        while (remaining > 0) : (remaining /= 10) {
            const digit: usize = @intCast((value / remaining) % 10);
            self.grapheme(digit_graphemes[digit]);
        }
    }

    pub fn styledUnsigned(self: *LineWriter, value: u64, style: Style) void {
        const old_style = self.style;
        self.style = style;
        self.unsigned(value);
        self.style = old_style;
    }

    fn grapheme(self: *LineWriter, value: []const u8) void {
        self.cell(value, self.win.gwidth(value));
    }

    fn cell(self: *LineWriter, value: []const u8, width: u16) void {
        if (width == 0) return;
        if (width > self.win.width - self.col) {
            self.col = self.win.width;
            return;
        }
        var style = self.style;
        if (self.bg) |bg| style.bg = bg;
        self.win.writeCell(self.col, self.row, .{
            .char = .{ .grapheme = value, .width = @intCast(width) },
            .style = style,
        });
        self.col += width;
    }
};

/// Cells `value` takes in `win`. Printable ASCII is one cell per byte, which
/// skips grapheme segmentation for the common case.
pub fn displayWidth(win: vaxis.Window, value: []const u8) u16 {
    if (asciiRun(value) == value.len) return @intCast(@min(value.len, std.math.maxInt(u16)));
    return win.gwidth(value);
}

/// Length of the leading run of bytes that are each a one-cell grapheme:
/// printable ASCII, minus the last byte when something else follows, since a
/// combining mark after it would join its grapheme.
fn asciiRun(value: []const u8) usize {
    var end: usize = 0;
    while (end < value.len and value[end] >= 0x20 and value[end] < 0x7f) end += 1;
    return if (end == value.len) end else end -| 1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const TestScreen = @import("render_test_screen.zig").TestScreen;

fn cellAt(ts: *TestScreen, col: u16) vaxis.Cell {
    return ts.screen.readCell(col, 0).?;
}

test "text writes printable ASCII one cell per byte in the writer's style" {
    var ts = try TestScreen.init(10, 1);
    defer ts.deinit();
    var writer = LineWriter.init(.{ .win = ts.window(), .row = 0, .col = 1, .style = .{ .bold = true } });

    writer.text("ab c");

    try testing.expectEqual(@as(u16, 5), writer.col);
    try testing.expectEqualStrings("a", cellAt(&ts, 1).char.grapheme);
    try testing.expectEqualStrings(" ", cellAt(&ts, 3).char.grapheme);
    try testing.expectEqualStrings("c", cellAt(&ts, 4).char.grapheme);
    try testing.expect(cellAt(&ts, 4).style.bold);
}

test "text keeps an ASCII letter and its combining mark in one cell" {
    var ts = try TestScreen.init(10, 1);
    defer ts.deinit();
    var writer = LineWriter.init(.{ .win = ts.window(), .row = 0 });

    writer.text("ae\u{301}x");

    try testing.expectEqual(@as(u16, 3), writer.col);
    try testing.expectEqualStrings("e\u{301}", cellAt(&ts, 1).char.grapheme);
    try testing.expectEqualStrings("x", cellAt(&ts, 2).char.grapheme);
}

test "text gives a wide grapheme two cells after ASCII" {
    var ts = try TestScreen.init(10, 1);
    defer ts.deinit();
    var writer = LineWriter.init(.{ .win = ts.window(), .row = 0 });

    writer.text("a漢b");

    try testing.expectEqual(@as(u16, 4), writer.col);
    try testing.expectEqualStrings("漢", cellAt(&ts, 1).char.grapheme);
    try testing.expectEqualStrings("b", cellAt(&ts, 3).char.grapheme);
}

test "text stops at a newline" {
    var ts = try TestScreen.init(10, 1);
    defer ts.deinit();
    var writer = LineWriter.init(.{ .win = ts.window(), .row = 0 });

    writer.text("ab\ncd");

    try testing.expectEqual(@as(u16, 2), writer.col);
    try testing.expectEqualStrings(" ", cellAt(&ts, 2).char.grapheme);
}

test "text clips ASCII at the window's right edge" {
    var ts = try TestScreen.init(3, 1);
    defer ts.deinit();
    var writer = LineWriter.init(.{ .win = ts.window(), .row = 0, .col = 1 });

    writer.text("abcdef");

    try testing.expectEqual(@as(u16, 3), writer.col);
    try testing.expectEqualStrings("b", cellAt(&ts, 2).char.grapheme);
}

test "text forces bg onto ASCII cells" {
    var ts = try TestScreen.init(4, 1);
    defer ts.deinit();
    const bg: Color = .{ .index = 4 };
    var writer = LineWriter.init(.{ .win = ts.window(), .row = 0, .bg = bg });

    writer.text("ab");

    try testing.expect(Color.eql(cellAt(&ts, 1).style.bg, bg));
}
