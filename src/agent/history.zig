const std = @import("std");

/// State for history browsing mode within the agent panel.
/// Tracks cursor position, visual selection, and pending key chords.
pub const HistoryState = struct {
    /// Whether history mode is active (browsing messages vs editing input)
    active: bool,
    /// Current cursor line in history view
    cursor_line: usize,
    /// Pending 'g' key for gg command
    pending_g: bool,
    /// Pending 'y' key for yy command
    pending_y: bool,
    /// Visual selection mode active
    visual_mode: bool,
    /// Starting line of visual selection (anchor point)
    visual_anchor: usize,

    pub fn init() HistoryState {
        return .{
            .active = false,
            .cursor_line = 0,
            .pending_g = false,
            .pending_y = false,
            .visual_mode = false,
            .visual_anchor = 0,
        };
    }

    /// Reset all state (called when exiting history mode)
    pub fn reset(self: *HistoryState) void {
        self.active = false;
        self.cursor_line = 0;
        self.pending_g = false;
        self.pending_y = false;
        self.visual_mode = false;
        self.visual_anchor = 0;
    }

    /// Enter history mode, initializing cursor at given line
    pub fn enter(self: *HistoryState, initial_cursor_line: usize) void {
        self.active = true;
        self.cursor_line = initial_cursor_line;
        self.pending_g = false;
        self.pending_y = false;
    }

    /// Exit history mode, clearing visual selection
    pub fn exit(self: *HistoryState) void {
        self.active = false;
        self.visual_mode = false;
    }

    /// Enter visual selection mode, anchoring at current cursor
    pub fn enterVisualMode(self: *HistoryState) void {
        if (!self.active) return;
        self.visual_mode = true;
        self.visual_anchor = self.cursor_line;
    }

    /// Exit visual selection mode
    pub fn exitVisualMode(self: *HistoryState) void {
        self.visual_mode = false;
    }

    /// Get visual selection range (always start <= end)
    pub fn getVisualRange(self: *const HistoryState) struct { start: usize, end: usize } {
        const a = self.visual_anchor;
        const b = self.cursor_line;
        return .{
            .start = @min(a, b),
            .end = @max(a, b),
        };
    }

    /// Check if a line is within visual selection
    pub fn isLineInVisualSelection(self: *const HistoryState, line: usize) bool {
        if (!self.active or !self.visual_mode) return false;
        const range = self.getVisualRange();
        return line >= range.start and line <= range.end;
    }

    /// Move cursor up, clamping at 0
    pub fn cursorUp(self: *HistoryState) void {
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
        }
    }

    /// Move cursor down, clamping at max_line
    pub fn cursorDown(self: *HistoryState, max_line: usize) void {
        if (self.cursor_line < max_line) {
            self.cursor_line += 1;
        }
    }

    /// Page up by half viewport
    pub fn pageUp(self: *HistoryState, viewport_height: usize) void {
        const half = viewport_height / 2;
        if (half == 0) return;
        self.cursor_line = self.cursor_line -| half;
    }

    /// Page down by half viewport, clamping at max_line
    pub fn pageDown(self: *HistoryState, viewport_height: usize, max_line: usize) void {
        const half = viewport_height / 2;
        if (half == 0) return;
        self.cursor_line = @min(self.cursor_line + half, max_line);
    }

    /// Jump to top (line 0)
    pub fn jumpToTop(self: *HistoryState) void {
        self.cursor_line = 0;
    }

    /// Jump to bottom (max_line)
    pub fn jumpToBottom(self: *HistoryState, max_line: usize) void {
        self.cursor_line = max_line;
    }

    /// Move cursor to center of viewport
    pub fn centerCursor(self: *HistoryState, scroll_offset: usize, viewport_height: usize, max_line: usize) void {
        if (viewport_height == 0) return;
        const middle = scroll_offset + viewport_height / 2;
        self.cursor_line = @min(middle, max_line);
    }

    /// Ensure cursor is visible, returning required scroll adjustment.
    /// Returns new scroll_offset to make cursor visible.
    pub fn ensureCursorVisible(self: *HistoryState, scroll_offset: usize, viewport_height: usize, max_line: usize) usize {
        if (viewport_height == 0) return scroll_offset;

        // Clamp cursor to valid range
        self.cursor_line = @min(self.cursor_line, max_line);

        // Calculate new scroll offset
        if (self.cursor_line < scroll_offset) {
            return self.cursor_line;
        } else if (self.cursor_line >= scroll_offset + viewport_height) {
            return self.cursor_line - viewport_height + 1;
        }
        return scroll_offset;
    }

    /// Clear pending key state
    pub fn clearPendingKeys(self: *HistoryState) void {
        self.pending_g = false;
        self.pending_y = false;
    }
};

test "HistoryState basic operations" {
    var state = HistoryState.init();

    // Initially inactive
    try std.testing.expect(!state.active);

    // Enter history mode
    state.enter(10);
    try std.testing.expect(state.active);
    try std.testing.expectEqual(@as(usize, 10), state.cursor_line);

    // Cursor movement
    state.cursorUp();
    try std.testing.expectEqual(@as(usize, 9), state.cursor_line);

    state.cursorDown(100);
    try std.testing.expectEqual(@as(usize, 10), state.cursor_line);

    // Visual mode
    state.enterVisualMode();
    try std.testing.expect(state.visual_mode);
    try std.testing.expectEqual(@as(usize, 10), state.visual_anchor);

    state.cursorDown(100);
    state.cursorDown(100);
    const range = state.getVisualRange();
    try std.testing.expectEqual(@as(usize, 10), range.start);
    try std.testing.expectEqual(@as(usize, 12), range.end);

    // Exit
    state.exit();
    try std.testing.expect(!state.active);
    try std.testing.expect(!state.visual_mode);
}

test "HistoryState scroll visibility" {
    var state = HistoryState.init();
    state.enter(50);

    // Cursor below viewport
    var new_scroll = state.ensureCursorVisible(0, 20, 100);
    try std.testing.expectEqual(@as(usize, 31), new_scroll);

    // Cursor above viewport
    state.cursor_line = 5;
    new_scroll = state.ensureCursorVisible(30, 20, 100);
    try std.testing.expectEqual(@as(usize, 5), new_scroll);

    // Cursor within viewport - no change
    state.cursor_line = 35;
    new_scroll = state.ensureCursorVisible(30, 20, 100);
    try std.testing.expectEqual(@as(usize, 30), new_scroll);
}
