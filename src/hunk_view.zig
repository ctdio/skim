//! Controller for hunk view-mode and viewport-anchor logic. Owns the hunk
//! filtering sub-state on `App.state` (`hunk_view_mode`, `view_mode`) and the
//! viewport preservation that keeps the cursor/scroll stable across LineMap
//! rebuilds. App keeps only mode dispatch and the shared cross-cutting services
//! these functions reach through.

const std = @import("std");
const App = @import("app.zig").App;
const line_map = @import("line_map.zig");
const navigation = @import("navigation.zig");

const Navigation = navigation.Navigation;

/// Anchor for preserving viewport position across LineMap rebuilds.
/// Captures position relative to a stable reference (file/hunk header).
pub const ViewportAnchor = struct {
    file_idx: usize,
    hunk_idx: ?usize, // null = anchor to file header
    scroll_offset_from_anchor: isize,
    cursor_offset_from_anchor: isize,
};

pub fn cycleHunkViewModePrev(app: *App) !void {
    // Only apply in unified mode
    if (!shouldApplyHunkFiltering(app)) return;

    // Capture anchor based on cursor position (for hunk cycling, cursor is the reference)
    const anchor = captureViewportAnchor(app, app.state.global_cursor_line);

    // Cycle to previous mode
    app.state.hunk_view_mode = app.state.hunk_view_mode.prev();

    // Rebuild LineMap
    app.state.line_map.deinit();
    app.state.line_map = try line_map.LineMap.build(app.allocator, app.state.files, &app.state.comment_store, convertHunkViewMode(app), shouldApplyHunkFiltering(app), &app.state.collapsed_folds, app.reviewAnchored());

    // Restore positions from anchor
    _ = restoreViewportFromAnchor(app, anchor);
}

pub fn cycleHunkViewMode(app: *App) !void {
    // Only apply in unified mode
    if (!shouldApplyHunkFiltering(app)) return;

    // Capture anchor based on cursor position (for hunk cycling, cursor is the reference)
    const anchor = captureViewportAnchor(app, app.state.global_cursor_line);

    // Cycle to next mode
    app.state.hunk_view_mode = app.state.hunk_view_mode.next();

    // Rebuild LineMap to reflect new filtering
    app.state.line_map.deinit();
    app.state.line_map = try line_map.LineMap.build(app.allocator, app.state.files, &app.state.comment_store, convertHunkViewMode(app), shouldApplyHunkFiltering(app), &app.state.collapsed_folds, app.reviewAnchored());

    // Restore positions from anchor
    _ = restoreViewportFromAnchor(app, anchor);
}

/// Capture viewport anchor for preserving position across LineMap rebuilds.
/// Uses the viewport top (global_scroll_offset) as reference by default.
/// Pass a specific reference_line to anchor from a different position (e.g., cursor).
pub fn captureViewportAnchor(app: *App, reference_line: usize) ?ViewportAnchor {
    const record = app.state.line_map.getLineRecord(reference_line) orelse return null;

    var anchor_line: ?usize = null;
    var anchor_file: usize = record.file_idx;
    var anchor_hunk: ?usize = null;

    switch (record.line_type) {
        .file_header => {
            anchor_line = reference_line;
            anchor_hunk = null;
        },
        .hunk_header => |hunk_info| {
            anchor_line = reference_line;
            anchor_hunk = hunk_info.hunk_idx;
        },
        .code_line => |code_info| {
            anchor_line = findHunkHeaderLine(app, record.file_idx, code_info.hunk_idx);
            anchor_hunk = code_info.hunk_idx;
        },
        .comment_line => |comment_info| {
            anchor_line = findHunkHeaderLine(app, record.file_idx, comment_info.parent_hunk_idx);
            anchor_hunk = comment_info.parent_hunk_idx;
        },
        .review_thread => {
            // Threads carry no hunk index in the record; anchor to the file header.
            anchor_line = app.state.line_map.getFileHeaderLine(record.file_idx);
            anchor_hunk = null;
        },
        .spacer => |spacer_info| {
            const next_file_idx = if (spacer_info.is_header_spacer)
                spacer_info.after_file_idx
            else
                spacer_info.after_file_idx + 1;

            anchor_file = next_file_idx;
            anchor_line = app.state.line_map.getFileHeaderLine(next_file_idx);
            anchor_hunk = null;
        },
    }

    const anc_line = anchor_line orelse return null;
    return ViewportAnchor{
        .file_idx = anchor_file,
        .hunk_idx = anchor_hunk,
        .scroll_offset_from_anchor = @as(isize, @intCast(app.state.global_scroll_offset)) - @as(isize, @intCast(anc_line)),
        .cursor_offset_from_anchor = @as(isize, @intCast(app.state.global_cursor_line)) - @as(isize, @intCast(anc_line)),
    };
}

/// Restore viewport position from anchor after LineMap rebuild.
/// Returns true if anchor was found and positions restored, false if fallback clamping was used.
pub fn restoreViewportFromAnchor(app: *App, anchor: ?ViewportAnchor) bool {
    const total_lines = app.getTotalGlobalLines();
    if (total_lines == 0) {
        app.state.global_cursor_line = 0;
        app.state.global_scroll_offset = 0;
        return false;
    }

    if (anchor) |anc| {
        if (anc.file_idx < app.state.files.len) {
            // Find anchor line in new LineMap
            const new_anchor_line = if (anc.hunk_idx) |hunk_idx|
                findHunkHeaderLine(app, anc.file_idx, hunk_idx)
            else
                app.state.line_map.getFileHeaderLine(anc.file_idx);

            if (new_anchor_line) |anchor_line| {
                // Restore cursor position
                const target_cursor_signed = @as(isize, @intCast(anchor_line)) + anc.cursor_offset_from_anchor;
                const target_cursor = if (target_cursor_signed < 0) 0 else @as(usize, @intCast(target_cursor_signed));
                app.state.global_cursor_line = @min(target_cursor, total_lines - 1);

                // Restore scroll position
                const target_scroll_signed = @as(isize, @intCast(anchor_line)) + anc.scroll_offset_from_anchor;
                const target_scroll = if (target_scroll_signed < 0) 0 else @as(usize, @intCast(target_scroll_signed));
                app.state.global_scroll_offset = target_scroll;

                Navigation.clampScrollOffset(app);
                return true;
            }
        }
    }

    // Fallback: clamp positions if anchor restoration failed
    if (app.state.global_cursor_line >= total_lines) {
        app.state.global_cursor_line = total_lines - 1;
    }
    Navigation.clampScrollOffset(app);
    return false;
}

// Convert App.State.HunkViewMode to LineMap.HunkViewMode
pub fn convertHunkViewMode(app: *App) line_map.LineMap.HunkViewMode {
    return switch (app.state.hunk_view_mode) {
        .all => .all,
        .old => .old,
        .new => .new,
    };
}

// Check if hunk view mode filtering should be applied (only in unified view)
pub fn shouldApplyHunkFiltering(app: *App) bool {
    return app.state.view_mode == .unified;
}

// Helper: Find the global line number of a hunk header
fn findHunkHeaderLine(app: *App, file_idx: usize, hunk_idx: usize) ?usize {
    for (app.state.line_map.records) |*record| {
        if (record.file_idx == file_idx and record.line_type == .hunk_header) {
            if (record.line_type.hunk_header.hunk_idx == hunk_idx) {
                return record.global_line;
            }
        }
    }
    return null;
}
