const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const rendering_common = @import("common.zig");
const App = @import("../app.zig").App;

const Color = rendering_common.Color;

pub const Styles = struct {
    /// Get style for a line based on cursor, visual selection, and line type
    pub fn getDisplayStyle(
        app: *App,
        is_cursor: bool,
        is_in_visual: bool,
        base_style: vaxis.Style,
    ) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else if (is_cursor) {
            return .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = false };
        } else {
            return base_style;
        }
    }

    /// Get fill style for backgrounds (e.g., hunk headers)
    pub fn getFillStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .bg = Color.visual_select_bg };
        } else if (is_cursor) {
            return .{ .bg = Color.cursor_bg };
        } else if (is_in_visual) {
            return .{ .bg = Color.visual_select_bg };
        } else {
            return .{};
        }
    }

    /// Get range style for hunk headers (bold text with icons)
    pub fn getHunkRangeStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else if (is_cursor) {
            return .{ .fg = Color.white, .bg = Color.cursor_bg, .bold = true };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else {
            return .{ .fg = Color.dim };
        }
    }

    /// Get context style for hunk headers (dimmer text)
    pub fn getHunkContextStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg };
        } else if (is_cursor) {
            return .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg };
        } else {
            return .{ .fg = Color.dim };
        }
    }

    /// Get line style based on diff line type (add/delete/context)
    pub fn getLineStyle(_: *App, line_type: parser.Line.LineType) vaxis.Style {
        return switch (line_type) {
            .add => .{ .bg = Color.add },
            .delete => .{ .bg = Color.delete },
            .context => .{},
        };
    }
};
