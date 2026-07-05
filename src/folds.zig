const std = @import("std");
const App = @import("app.zig").App;
const parser = @import("git/parser.zig");
const navigation = @import("navigation.zig");
const hunk_view = @import("hunk_view.zig");
const Navigation = navigation.Navigation;

const FoldSet = std.AutoHashMap(u64, void);

/// Packed key for fold state HashMap
/// Bit 63: 0 = file fold, 1 = hunk fold
/// Bits 0-30: file_idx (for files) or file_idx (for hunks)
/// Bits 31-62: hunk_idx (for hunks, 0 for files)
pub const FoldKey = struct {
    pub fn fileKey(file_idx: usize) u64 {
        return @as(u64, @intCast(file_idx)); // Bit 63 = 0 indicates file
    }

    pub fn hunkKey(file_idx: usize, hunk_idx: usize) u64 {
        // Set bit 63 to indicate hunk, pack file_idx in low bits, hunk_idx in mid bits
        return (@as(u64, 1) << 63) | (@as(u64, @intCast(hunk_idx)) << 31) | @as(u64, @intCast(file_idx));
    }
};

// Check if a file is folded (collapsed)
pub fn isFileFolded(folds: *const FoldSet, file_idx: usize) bool {
    return folds.contains(FoldKey.fileKey(file_idx));
}

// Check if a hunk is folded (collapsed)
pub fn isHunkFolded(folds: *const FoldSet, file_idx: usize, hunk_idx: usize) bool {
    // If file is folded, hunk is implicitly folded
    if (isFileFolded(folds, file_idx)) return true;
    return folds.contains(FoldKey.hunkKey(file_idx, hunk_idx));
}

// Toggle file fold state
pub fn toggleFileFold(folds: *FoldSet, file_idx: usize) void {
    const key = FoldKey.fileKey(file_idx);
    if (folds.contains(key)) {
        _ = folds.remove(key);
    } else {
        folds.put(key, {}) catch {};
    }
}

// Toggle hunk fold state
pub fn toggleHunkFold(folds: *FoldSet, file_idx: usize, hunk_idx: usize) void {
    const key = FoldKey.hunkKey(file_idx, hunk_idx);
    if (folds.contains(key)) {
        _ = folds.remove(key);
    } else {
        folds.put(key, {}) catch {};
    }
}

// Close (fold) a file
pub fn closeFileFold(folds: *FoldSet, file_idx: usize) void {
    folds.put(FoldKey.fileKey(file_idx), {}) catch {};
}

// Close (fold) a hunk
pub fn closeHunkFold(folds: *FoldSet, file_idx: usize, hunk_idx: usize) void {
    folds.put(FoldKey.hunkKey(file_idx, hunk_idx), {}) catch {};
}

// Open (unfold) a file
pub fn openFileFold(folds: *FoldSet, file_idx: usize) void {
    _ = folds.remove(FoldKey.fileKey(file_idx));
}

// Open (unfold) a hunk
pub fn openHunkFold(folds: *FoldSet, file_idx: usize, hunk_idx: usize) void {
    _ = folds.remove(FoldKey.hunkKey(file_idx, hunk_idx));
}

// Close all folds (fold all files and hunks)
pub fn closeAllFolds(folds: *FoldSet, files: []const parser.FileDiff) void {
    for (files, 0..) |file, file_idx| {
        folds.put(FoldKey.fileKey(file_idx), {}) catch {};
        for (file.hunks, 0..) |_, hunk_idx| {
            folds.put(FoldKey.hunkKey(file_idx, hunk_idx), {}) catch {};
        }
    }
}

// Open all folds (unfold everything)
pub fn openAllFolds(folds: *FoldSet) void {
    folds.clearRetainingCapacity();
}

// Toggle fold at cursor position (file header -> fold file, hunk/code -> fold hunk)
pub fn toggleFoldUnderCursor(app: *App) !void {
    return foldUnderCursor(app, .toggle);
}

// Close fold at cursor position
pub fn closeFoldUnderCursor(app: *App) !void {
    return foldUnderCursor(app, .close);
}

// Open fold at cursor position
pub fn openFoldUnderCursor(app: *App) !void {
    return foldUnderCursor(app, .open);
}

// Close all folds and rebuild LineMap
pub fn closeAllFoldsAndRebuild(app: *App) !void {
    // Capture anchor before closing all
    const anchor = hunk_view.captureViewportAnchor(app, app.state.global_cursor_line);

    closeAllFolds(&app.state.collapsed_folds, app.state.files);

    try hunk_view.rebuildLineMap(app);
    _ = hunk_view.restoreViewportFromAnchor(app, anchor);
    app.needs_render = true;
}

// Open all folds and rebuild LineMap
pub fn openAllFoldsAndRebuild(app: *App) !void {
    // Capture anchor before opening all
    const anchor = hunk_view.captureViewportAnchor(app, app.state.global_cursor_line);

    openAllFolds(&app.state.collapsed_folds);

    try hunk_view.rebuildLineMap(app);
    _ = hunk_view.restoreViewportFromAnchor(app, anchor);
    app.needs_render = true;
}

// Close the file containing the cursor (zC - fold entire file from anywhere)
pub fn closeFileFoldUnderCursor(app: *App) !void {
    const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return;
    const file_idx = record.file_idx;

    // Close the file fold
    closeFileFold(&app.state.collapsed_folds, file_idx);

    try hunk_view.rebuildLineMap(app);

    // Move cursor to the file header
    moveCursorToFoldHeader(app, file_idx, null);
    app.needs_render = true;
}

// Open the file containing the cursor (zO - unfold entire file from anywhere)
pub fn openFileFoldUnderCursor(app: *App) !void {
    const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return;
    const file_idx = record.file_idx;

    // Open the file fold
    openFileFold(&app.state.collapsed_folds, file_idx);

    try hunk_view.rebuildLineMap(app);

    // Move cursor to the file header
    moveCursorToFoldHeader(app, file_idx, null);
    app.needs_render = true;
}

// The fold target under the cursor: which file, and (for hunk/code/comment
// lines) which hunk. Null when the cursor is on a line with no fold action.
const FoldTarget = struct { file_idx: usize, hunk_idx: ?usize };

const FoldOp = enum { toggle, close, open };

// Apply a fold op to the target under the cursor, then rebuild and reposition.
fn foldUnderCursor(app: *App, op: FoldOp) !void {
    const target = foldTargetUnderCursor(app) orelse return;
    const folds = &app.state.collapsed_folds;
    if (target.hunk_idx) |hunk_idx| {
        switch (op) {
            .toggle => toggleHunkFold(folds, target.file_idx, hunk_idx),
            .close => closeHunkFold(folds, target.file_idx, hunk_idx),
            .open => openHunkFold(folds, target.file_idx, hunk_idx),
        }
    } else {
        switch (op) {
            .toggle => toggleFileFold(folds, target.file_idx),
            .close => closeFileFold(folds, target.file_idx),
            .open => openFileFold(folds, target.file_idx),
        }
    }
    try hunk_view.rebuildLineMap(app);
    moveCursorToFoldHeader(app, target.file_idx, target.hunk_idx);
    app.needs_render = true;
}

fn foldTargetUnderCursor(app: *App) ?FoldTarget {
    const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return null;
    return switch (record.line_type) {
        .file_header => .{ .file_idx = record.file_idx, .hunk_idx = null },
        .hunk_header => |hunk_info| .{ .file_idx = record.file_idx, .hunk_idx = hunk_info.hunk_idx },
        .code_line => |code_info| .{ .file_idx = record.file_idx, .hunk_idx = code_info.hunk_idx },
        .comment_line => |comment_info| .{ .file_idx = record.file_idx, .hunk_idx = comment_info.parent_hunk_idx },
        .review_thread, .spacer => null,
    };
}

// Move cursor to the fold header (file or hunk) after folding
fn moveCursorToFoldHeader(app: *App, file_idx: usize, hunk_idx: ?usize) void {
    // Search for the header line in the rebuilt LineMap
    for (0..app.state.line_map.records.len) |line_idx| {
        const record = app.state.line_map.getLineRecord(line_idx) orelse continue;
        if (record.file_idx != file_idx) continue;

        if (hunk_idx) |h_idx| {
            // Looking for hunk header
            switch (record.line_type) {
                .hunk_header => |hunk_info| {
                    if (hunk_info.hunk_idx == h_idx) {
                        app.state.global_cursor_line = line_idx;
                        Navigation.ensureCursorVisible(app, true);
                        return;
                    }
                },
                else => {},
            }
        } else {
            // Looking for file header
            switch (record.line_type) {
                .file_header => {
                    app.state.global_cursor_line = line_idx;
                    Navigation.ensureCursorVisible(app, true);
                    return;
                },
                else => {},
            }
        }
    }
}
