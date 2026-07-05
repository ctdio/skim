//! Minimal vaxis backing shared by the `pr/` render test blocks. Lets `draw`
//! run against real cells without importing `../testing` (which would escape the
//! `pr/` module root). Kept inside `pr/` so both `render.zig` and
//! `review_render.zig` can reuse one copy.

const std = @import("std");
const vaxis = @import("vaxis");

const testing = std.testing;

pub const TestScreen = struct {
    screen: vaxis.Screen,
    unicode: vaxis.Unicode,

    pub fn init(cols: u16, rows: u16) !TestScreen {
        var screen = try vaxis.Screen.init(testing.allocator, .{
            .cols = cols,
            .rows = rows,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        errdefer screen.deinit(testing.allocator);
        const unicode = try vaxis.Unicode.init(testing.allocator);
        return .{ .screen = screen, .unicode = unicode };
    }

    pub fn deinit(self: *TestScreen) void {
        self.screen.deinit(testing.allocator);
        self.unicode.deinit(testing.allocator);
    }

    pub fn window(self: *TestScreen) vaxis.Window {
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
};

pub fn rowContains(screen: vaxis.Screen, row: u16, needle: []const u8) bool {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    var col: u16 = 0;
    while (col < screen.width) : (col += 1) {
        const cell = screen.readCell(col, row) orelse continue;
        const g = cell.char.grapheme;
        if (len + g.len > buf.len) break;
        @memcpy(buf[len .. len + g.len], g);
        len += g.len;
    }
    return std.mem.indexOf(u8, buf[0..len], needle) != null;
}
