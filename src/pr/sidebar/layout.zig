//! Column math for the PR surface (AD-8): how many columns the sidebar takes
//! on the left and where the main area (diff + agent panel) starts. Pure, so
//! `rendering/frame.zig` stays a thin caller. Not called `sidebar_width`:
//! `rendering/common.zig` `Layout.sidebar_width` is the diff's `┃` gutter.

const std = @import("std");

pub const min_cols: u16 = 32;
pub const max_cols: u16 = 56;
pub const pct: u16 = 28;
pub const min_diff_cols: u16 = 40;

pub const Split = struct {
    sidebar_cols: u16,
    main_x: u16,
    main_cols: u16,
};

/// `clamp(width * 28 / 100, 32, 56)` columns for the sidebar, the rest for
/// the main area. When the terminal cannot fit a minimum sidebar beside a
/// 40-column diff, the focused pane takes the full width.
pub fn split(params: struct { width: u16, visible: bool, sidebar_focused: bool }) Split {
    const width = params.width;
    if (!params.visible) return .{ .sidebar_cols = 0, .main_x = 0, .main_cols = width };
    if (width < min_cols + min_diff_cols) {
        if (params.sidebar_focused) return .{ .sidebar_cols = width, .main_x = width, .main_cols = 0 };
        return .{ .sidebar_cols = 0, .main_x = 0, .main_cols = width };
    }
    const share: u16 = @intCast(@as(u32, width) * pct / 100);
    const sidebar_cols = std.math.clamp(share, min_cols, max_cols);
    return .{ .sidebar_cols = sidebar_cols, .main_x = sidebar_cols, .main_cols = width - sidebar_cols };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "split: 28% of width clamped to [32, 56]" {
    try testing.expectEqual(Split{ .sidebar_cols = 32, .main_x = 32, .main_cols = 68 }, split(.{ .width = 100, .visible = true, .sidebar_focused = false }));
    try testing.expectEqual(Split{ .sidebar_cols = 44, .main_x = 44, .main_cols = 116 }, split(.{ .width = 160, .visible = true, .sidebar_focused = true }));
    try testing.expectEqual(Split{ .sidebar_cols = 56, .main_x = 56, .main_cols = 244 }, split(.{ .width = 300, .visible = true, .sidebar_focused = false }));
}

test "split: hidden sidebar gives the full width to main" {
    try testing.expectEqual(Split{ .sidebar_cols = 0, .main_x = 0, .main_cols = 160 }, split(.{ .width = 160, .visible = false, .sidebar_focused = true }));
}

test "split: exactly 72 cols fits a minimum sidebar beside a minimum diff" {
    try testing.expectEqual(Split{ .sidebar_cols = 32, .main_x = 32, .main_cols = 40 }, split(.{ .width = 72, .visible = true, .sidebar_focused = false }));
}

test "split: below 72 cols the focused sidebar takes the full width" {
    try testing.expectEqual(Split{ .sidebar_cols = 60, .main_x = 60, .main_cols = 0 }, split(.{ .width = 60, .visible = true, .sidebar_focused = true }));
}

test "split: below 72 cols a focused diff hides the sidebar" {
    try testing.expectEqual(Split{ .sidebar_cols = 0, .main_x = 0, .main_cols = 60 }, split(.{ .width = 60, .visible = true, .sidebar_focused = false }));
}

test "split: zero width yields an empty split" {
    try testing.expectEqual(Split{ .sidebar_cols = 0, .main_x = 0, .main_cols = 0 }, split(.{ .width = 0, .visible = true, .sidebar_focused = false }));
}
