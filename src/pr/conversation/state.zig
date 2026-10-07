//! The Conversation screen shown in place of the diff (`gc`): whether it is
//! up, and its row cursor and scroll. The cursor moves freely here and is
//! clamped against the laid-out rows when the screen is drawn.

const std = @import("std");

pub const ConversationState = struct {
    showing: bool = false,
    /// The PR the cursor belongs to; a different PR starts at the top.
    number: u32 = 0,
    cursor: usize = 0,
    scroll: usize = 0,
    /// The code thread under the cursor as of the last draw, for `Enter`.
    cursor_thread: ?usize = null,
    /// Rows on screen as of the last draw, for half-page moves.
    visible: usize = 1,
    pending_g: bool = false,
};

pub const Edge = enum { top, bottom };

pub fn toggle(state: *ConversationState) void {
    state.showing = !state.showing;
    state.pending_g = false;
}

pub fn move(state: *ConversationState, delta: isize) void {
    state.cursor = if (delta < 0) state.cursor -| @abs(delta) else state.cursor +| @as(usize, @intCast(delta));
}

/// `gg` / `G`. The bottom is found by the next clamp.
pub fn moveToEdge(state: *ConversationState, edge: Edge) void {
    state.cursor = switch (edge) {
        .top => 0,
        .bottom => std.math.maxInt(usize),
    };
}

/// Reset the cursor when the shown PR changed since the last draw.
pub fn follow(state: *ConversationState, number: u32) void {
    if (state.number == number) return;
    state.number = number;
    state.cursor = 0;
    state.scroll = 0;
}

/// Keep the cursor on a row and the scroll window around it.
pub fn clamp(state: *ConversationState, params: struct { rows: usize, visible: usize }) void {
    state.cursor = @min(state.cursor, params.rows -| 1);
    const visible = @max(params.visible, 1);
    state.visible = visible;
    if (state.cursor < state.scroll) state.scroll = state.cursor;
    if (state.cursor >= state.scroll + visible) state.scroll = state.cursor + 1 - visible;
    state.scroll = @min(state.scroll, params.rows -| visible);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "move: stops at the top" {
    var state = ConversationState{ .cursor = 2 };

    move(&state, -5);

    try testing.expectEqual(@as(usize, 0), state.cursor);
}

test "clamp: G lands on the last row with it at the bottom of the window" {
    var state = ConversationState{};
    moveToEdge(&state, .bottom);

    clamp(&state, .{ .rows = 50, .visible = 10 });

    try testing.expectEqual(@as(usize, 49), state.cursor);
    try testing.expectEqual(@as(usize, 40), state.scroll);
}

test "clamp: scrolls up to a cursor above the window" {
    var state = ConversationState{ .cursor = 3, .scroll = 20 };

    clamp(&state, .{ .rows = 50, .visible = 10 });

    try testing.expectEqual(@as(usize, 3), state.scroll);
}

test "clamp: content shorter than the window never scrolls" {
    var state = ConversationState{ .cursor = 4, .scroll = 2 };

    clamp(&state, .{ .rows = 5, .visible = 10 });

    try testing.expectEqual(@as(usize, 4), state.cursor);
    try testing.expectEqual(@as(usize, 0), state.scroll);
}

test "follow: a different PR starts at the top" {
    var state = ConversationState{ .number = 7, .cursor = 30, .scroll = 20 };

    follow(&state, 8);

    try testing.expectEqual(@as(usize, 0), state.cursor);
    try testing.expectEqual(@as(usize, 0), state.scroll);
    follow(&state, 8);
    try testing.expectEqual(@as(u32, 8), state.number);
}
