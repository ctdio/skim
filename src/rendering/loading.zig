const std = @import("std");
const vaxis = @import("vaxis");
const common = @import("common.zig");

const Color = common.Color;

/// Full-window "loading" indicator shown while the initial diff is still
/// streaming in and no files have arrived yet. Static text only, so it needs no
/// App state and is directly snapshot-testable.
pub fn renderLoadingScreen(win: vaxis.Window) void {
    const title = "Loading diff...";
    const subtitle = "Reading changes from git...";

    const center_row = win.height / 2;
    const start_row = if (center_row > 1) center_row - 1 else 0;

    const title_col = (win.width -| title.len) / 2;
    var title_seg = [_]vaxis.Cell.Segment{.{
        .text = title,
        .style = .{ .fg = Color.white, .bold = true },
    }};
    _ = win.print(&title_seg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(title_col) });

    const subtitle_col = (win.width -| subtitle.len) / 2;
    var subtitle_seg = [_]vaxis.Cell.Segment{.{
        .text = subtitle,
        .style = .{ .fg = Color.dim },
    }};
    _ = win.print(&subtitle_seg, .{ .row_offset = @intCast(start_row + 2), .col_offset = @intCast(subtitle_col) });
}
