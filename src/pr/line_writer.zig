//! A tiny left-to-right cell writer over a `vaxis.Window` row, shared by the PR
//! picker (`render.zig`) and the review overlays (`review_render.zig`). It clips
//! at the window's right edge and, when `bg` is set, forces that background onto
//! every cell so a popup layers cleanly over the diff underneath. Pure drawing —
//! it only writes cells.

const std = @import("std");
const vaxis = @import("vaxis");

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
        var iter = self.win.unicode.graphemeIterator(value);
        while (iter.next()) |item| {
            const bytes = item.bytes(value);
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
        const width = self.win.gwidth(value);
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
