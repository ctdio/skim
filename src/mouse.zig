//! Mouse-wheel scrolling support.
//!
//! Skim reuses each surface's existing keyboard scroll behavior for the mouse
//! wheel: a wheel notch is translated into the navigation keystroke that the
//! active mode already binds to "scroll one line", then routed through the
//! normal keyboard dispatch. This module owns that routing decision.

const std = @import("std");
const vaxis = @import("vaxis");
const Mode = @import("mode.zig").Mode;

/// Number of lines to scroll per mouse-wheel notch.
pub const lines_per_notch = 3;

/// Selects the navigation keystroke a given mode already binds to "scroll one
/// line" in the requested direction, so a mouse-wheel notch can be routed
/// through the existing keyboard dispatch. Returns null for modes that should
/// ignore the wheel (text-input modes and any mode not listed).
pub fn wheelKeyForMode(mode: Mode, down: bool) ?u21 {
    return switch (mode) {
        // The main diff view binds j/k for line scrolling; arrow keys are not
        // bound there.
        .normal, .visual => if (down) 'j' else 'k',

        // Every other scrollable surface binds the arrow keys (some, like the
        // command palette and selection menus, bind *only* arrows).
        .command_palette,
        .model_selection,
        .permission_selection,
        .help,
        .session_picker,
        .branch_selection,
        .commit_selection,
        .graphite_stack,
        .agent_selection,
        .agent,
        => if (down) vaxis.Key.down else vaxis.Key.up,

        // Text-input modes and any surface without meaningful vertical scroll
        // ignore the wheel.
        .comment, .search, .commit_diff_mode => null,
    };
}

test "wheelKeyForMode routes each scrollable surface to its bound key" {
    const K = vaxis.Key;

    // Diff surfaces bind j/k, not arrows.
    try std.testing.expectEqual(@as(?u21, 'j'), wheelKeyForMode(.normal, true));
    try std.testing.expectEqual(@as(?u21, 'k'), wheelKeyForMode(.normal, false));
    try std.testing.expectEqual(@as(?u21, 'j'), wheelKeyForMode(.visual, true));
    try std.testing.expectEqual(@as(?u21, 'k'), wheelKeyForMode(.visual, false));

    // Arrow-only menus.
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.command_palette, true));
    try std.testing.expectEqual(@as(?u21, K.up), wheelKeyForMode(.command_palette, false));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.model_selection, true));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.permission_selection, true));

    // Surfaces that bind both — we emit arrows.
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.help, true));
    try std.testing.expectEqual(@as(?u21, K.up), wheelKeyForMode(.help, false));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.agent, true));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.session_picker, true));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.branch_selection, true));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.commit_selection, true));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.graphite_stack, true));
    try std.testing.expectEqual(@as(?u21, K.down), wheelKeyForMode(.agent_selection, true));

    // Text-input modes ignore the wheel.
    try std.testing.expectEqual(@as(?u21, null), wheelKeyForMode(.comment, true));
    try std.testing.expectEqual(@as(?u21, null), wheelKeyForMode(.search, true));
}
