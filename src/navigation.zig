const std = @import("std");
const App = @import("app.zig").App;
const rendering = @import("rendering/common.zig");
const state_helpers = @import("state.zig");
const Layout = rendering.Layout;
const StateHelpers = state_helpers.StateHelpers;

pub const Navigation = struct {
    pub fn moveCursorDown(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalGlobalLines();
        if (total_lines > 0) {
            const new_line = @min(app.state.global_cursor_line + count, total_lines - 1);
            app.state.global_cursor_line = new_line;
        }

        // Ensure cursor stays visible
        ensureCursorVisible(app);
        clampCursorColumn(app);
    }

    pub fn moveCursorUp(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        if (app.state.global_cursor_line >= count) {
            app.state.global_cursor_line -= count;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Ensure cursor stays visible
        ensureCursorVisible(app);
        clampCursorColumn(app);
    }


    pub fn navigateToNextFile(app: *App) void {
        if (app.state.files.len == 0) return;

        // Find which file cursor is currently in
        const current_file = app.state.line_map.getFileIndexForLine(app.state.global_cursor_line) orelse 0;

        // Jump to start of next file (or wrap to first)
        const next_file = if (current_file + 1 < app.state.files.len)
            current_file + 1
        else
            0;

        if (app.state.line_map.getFileHeaderLine(next_file)) |start_line| {
            app.state.current_file_idx = next_file;
            app.state.global_cursor_line = start_line;
            app.state.global_scroll_offset = start_line;

            // Force a full re-render when jumping files
            app.needs_render = true;
        }

        triggerAsyncHighlight(app);
    }

    pub fn navigateToPreviousFile(app: *App) void {
        if (app.state.files.len == 0) return;

        // Find which file cursor is currently in
        const current_file = app.state.line_map.getFileIndexForLine(app.state.global_cursor_line) orelse 0;

        // Jump to start of previous file (or wrap to last)
        const prev_file = if (current_file > 0)
            current_file - 1
        else
            app.state.files.len - 1;

        if (app.state.line_map.getFileHeaderLine(prev_file)) |start_line| {
            app.state.current_file_idx = prev_file;
            app.state.global_cursor_line = start_line;
            app.state.global_scroll_offset = start_line;

            // Force a full re-render when jumping files
            app.needs_render = true;
        }

        triggerAsyncHighlight(app);
    }

    // Trigger async highlighting for current file (non-blocking)
    fn triggerAsyncHighlight(app: *App) void {
        if (app.state.current_file_idx >= app.state.files.len) return;
        const file = &app.state.files[app.state.current_file_idx];

        // Try to highlight immediately if parser is cached (fast)
        StateHelpers.startAsyncHighlight(app, file) catch {};

        // If we just added highlights, request a re-render
        if (file.highlights != null) {
            app.needs_render = true;
        } else {
            // Parser not cached - flag that we need async highlighting
            app.needs_async_highlight = true;
        }
    }

    pub fn resetFileState(app: *App) void {
        // Deprecated: In continuous mode, we use global coordinates
        // Keep for backwards compatibility but make it a no-op
        _ = app;
    }

    pub fn pageDown(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;
        const total_lines = app.getTotalGlobalLines();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = @min(app.state.global_cursor_line + scroll_amount, total_lines - 1);
        }

        // Move viewport down by same amount to maintain screen position
        app.state.global_scroll_offset += scroll_amount;
        clampScrollOffset(app);

        // Clamp cursor column to new line length
        clampCursorColumn(app);
    }

    pub fn pageUp(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        if (app.state.global_cursor_line >= scroll_amount) {
            app.state.global_cursor_line -= scroll_amount;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (app.state.global_scroll_offset >= scroll_amount) {
            app.state.global_scroll_offset -= scroll_amount;
        } else {
            app.state.global_scroll_offset = 0;
        }

        // Clamp cursor column to new line length
        clampCursorColumn(app);
    }

    pub fn scrollDown(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalGlobalLines();

        // Move cursor down, clamped to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = @min(app.state.global_cursor_line + count, total_lines - 1);
        }

        // Move viewport down by same amount
        app.state.global_scroll_offset += count;
        clampScrollOffset(app);
        clampCursorColumn(app);
    }

    pub fn scrollUp(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        // Move cursor up, clamped to 0
        if (app.state.global_cursor_line >= count) {
            app.state.global_cursor_line -= count;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Move viewport up by same amount
        if (app.state.global_scroll_offset >= count) {
            app.state.global_scroll_offset -= count;
        } else {
            app.state.global_scroll_offset = 0;
        }

        clampCursorColumn(app);
    }

    pub fn scrollToTop(app: *App) void {
        app.state.global_cursor_line = 0;
        app.state.global_scroll_offset = 0;
        clampCursorColumn(app);
    }

    pub fn scrollToBottom(app: *App) void {
        const total_lines = app.getTotalGlobalLines();
        const viewport_height = app.state.viewport_height;

        // Move cursor to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = total_lines - 1;
        }

        // Move viewport to show last page
        app.state.global_scroll_offset = if (total_lines > viewport_height)
            total_lines - viewport_height
        else
            0;

        clampCursorColumn(app);
    }

    pub fn centerCursor(app: *App) void {
        // Move cursor to the middle line of the current viewport (like vim's 'M')
        const viewport_height = app.state.viewport_height;
        const scroll_offset = app.state.global_scroll_offset;

        if (viewport_height > 0) {
            const half_viewport = viewport_height / 2;
            const middle_line = scroll_offset + half_viewport;

            const total_lines = app.getTotalGlobalLines();
            if (total_lines > 0) {
                app.state.global_cursor_line = @min(middle_line, total_lines - 1);
            }
        }

        clampCursorColumn(app);
    }

    pub fn scrollPageDown(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;
        const total_lines = app.getTotalGlobalLines();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = @min(app.state.global_cursor_line + scroll_amount, total_lines - 1);
        }

        // Move viewport down by same amount to maintain screen position
        app.state.global_scroll_offset += scroll_amount;
        clampScrollOffset(app);
        clampCursorColumn(app);
    }

    pub fn scrollPageUp(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        if (app.state.global_cursor_line >= scroll_amount) {
            app.state.global_cursor_line -= scroll_amount;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (app.state.global_scroll_offset >= scroll_amount) {
            app.state.global_scroll_offset -= scroll_amount;
        } else {
            app.state.global_scroll_offset = 0;
        }

        clampCursorColumn(app);
    }

    // No-op function - kept for backward compatibility
    // (horizontal cursor movement removed with FOCUSED mode)
    pub fn clampCursorColumn(_: *App) void {}

    pub fn clampScrollOffset(app: *App) void {
        const total_lines = app.getTotalGlobalLines();

        // Allow over-scrolling at the end so last file can be at top of screen
        // This creates a natural "padding" at the bottom for small files
        const max_scroll = if (total_lines > 0)
            total_lines - 1  // Any line can be at top of viewport
        else
            0;

        if (app.state.global_scroll_offset > max_scroll) {
            app.state.global_scroll_offset = max_scroll;
        }
    }

    // Adjust scroll to ensure cursor is visible with padding
    // Only called after explicit cursor movement (j/k), not during file navigation
    fn ensureCursorVisible(app: *App) void {
        const padding = Layout.cursor_padding;
        const cursor_line = app.state.global_cursor_line;
        const scroll_offset = app.state.global_scroll_offset;
        const window_height = app.state.viewport_height;

        if (cursor_line < scroll_offset + padding) {
            app.state.global_scroll_offset = if (cursor_line >= padding)
                cursor_line - padding
            else
                0;
        } else if (cursor_line >= scroll_offset + window_height -| (padding + 1)) {
            app.state.global_scroll_offset = cursor_line -| (window_height -| (padding + 2));
        }
    }

    // Keep old function name for backwards compatibility (deprecated)
    pub fn adjustScrollToKeepCursorVisible(app: *App, window_height: usize) void {
        _ = window_height; // Use viewport_height from app.state instead
        ensureCursorVisible(app);
    }
};
