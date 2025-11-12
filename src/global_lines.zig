const std = @import("std");
const parser = @import("git/parser.zig");
const comments = @import("comments.zig");
const display_lines = @import("display_lines.zig");

/// Number of blank lines to add between files
pub const file_spacing = 3;

/// Position within a specific file
pub const FilePosition = struct {
    file_idx: usize,
    local_line: usize, // Line within the file (includes file header at 0)
};

/// Type of global line
pub const GlobalLineType = union(enum) {
    file_header: struct {
        file_idx: usize,
    },
    file_content: struct {
        file_idx: usize,
        local_line: usize, // Relative to file content (0 = first hunk header)
    },
    spacer: struct {
        after_file_idx: usize, // Which file this spacer comes after
        spacer_line: usize, // 0, 1, or 2 (for 3 total spacer lines)
    },
};

/// Calculate total display lines across all files
/// Each file has 1 header line + its content lines + spacing after (except last file)
pub fn getTotalGlobalLines(
    files: []const parser.FileDiff,
    comment_store: *const comments.CommentStore,
) usize {
    var total: usize = 0;

    for (files, 0..) |*file, idx| {
        // Add 1 for file header
        total += 1;

        // Add content lines
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        total += display_lines.getTotalDisplayLines(file, comment_store, file_path);

        // Add spacing after this file (except for last file)
        if (idx < files.len - 1) {
            total += file_spacing;
        }
    }

    return total;
}

/// Map global line number to file position
/// Returns null if line is a spacer or out of bounds
pub fn globalLineToFilePosition(
    global_line: usize,
    files: []const parser.FileDiff,
    comment_store: *const comments.CommentStore,
) ?FilePosition {
    var current_global: usize = 0;

    for (files, 0..) |*file, file_idx| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        const file_total = 1 + display_lines.getTotalDisplayLines(file, comment_store, file_path);

        if (global_line < current_global + file_total) {
            // Line is in this file
            const local_line = global_line - current_global;
            return FilePosition{
                .file_idx = file_idx,
                .local_line = local_line,
            };
        }

        current_global += file_total;

        // Check if line is in spacer after this file (except for last file)
        if (file_idx < files.len - 1) {
            if (global_line < current_global + file_spacing) {
                // Line is in spacer, return null
                return null;
            }
            current_global += file_spacing;
        }
    }

    return null; // Line out of bounds
}

/// Map file position to global line number
pub fn filePositionToGlobalLine(
    file_idx: usize,
    local_line: usize,
    files: []const parser.FileDiff,
    comment_store: *const comments.CommentStore,
) ?usize {
    if (file_idx >= files.len) return null;

    var global_line: usize = 0;

    // Sum up lines from all previous files (including spacers)
    for (files[0..file_idx], 0..) |*file, idx| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        global_line += 1 + display_lines.getTotalDisplayLines(file, comment_store, file_path);

        // Add spacing after this file
        if (idx < files.len - 1) {
            global_line += file_spacing;
        }
    }

    // Add local line offset
    global_line += local_line;

    return global_line;
}

/// Get file index for a given global cursor line
/// If on a spacer line, returns the file that follows the spacer
pub fn getCurrentFileFromCursor(
    global_cursor: usize,
    files: []const parser.FileDiff,
    comment_store: *const comments.CommentStore,
) usize {
    if (files.len == 0) return 0;

    const pos = globalLineToFilePosition(global_cursor, files, comment_store) orelse {
        // Cursor is on spacer or beyond bounds
        // Try to find which file comes after this position
        var current_global: usize = 0;
        for (files, 0..) |*file, file_idx| {
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
            const file_total = 1 + display_lines.getTotalDisplayLines(file, comment_store, file_path);

            if (global_cursor < current_global + file_total) {
                // This shouldn't happen (would have been caught by globalLineToFilePosition)
                return file_idx;
            }

            current_global += file_total;

            // Check if we're in spacer after this file
            if (file_idx < files.len - 1) {
                if (global_cursor < current_global + file_spacing) {
                    // On spacer - return the next file
                    return file_idx + 1;
                }
                current_global += file_spacing;
            }
        }
        // Beyond all files, return last file
        return files.len - 1;
    };

    return pos.file_idx;
}

/// Get the type of a global line
pub fn getGlobalLineType(
    global_line: usize,
    files: []const parser.FileDiff,
    comment_store: *const comments.CommentStore,
) ?GlobalLineType {
    var current_global: usize = 0;

    for (files, 0..) |*file, file_idx| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        const file_total = 1 + display_lines.getTotalDisplayLines(file, comment_store, file_path);

        if (global_line < current_global + file_total) {
            // Line is in this file
            const local_line = global_line - current_global;
            if (local_line == 0) {
                return GlobalLineType{
                    .file_header = .{ .file_idx = file_idx },
                };
            } else {
                return GlobalLineType{
                    .file_content = .{
                        .file_idx = file_idx,
                        .local_line = local_line - 1,
                    },
                };
            }
        }

        current_global += file_total;

        // Check if line is in spacer after this file
        if (file_idx < files.len - 1) {
            if (global_line < current_global + file_spacing) {
                const spacer_line = global_line - current_global;
                return GlobalLineType{
                    .spacer = .{
                        .after_file_idx = file_idx,
                        .spacer_line = spacer_line,
                    },
                };
            }
            current_global += file_spacing;
        }
    }

    return null; // Line out of bounds
}

/// Get the starting global line for a file
pub fn getFileStartLine(
    file_idx: usize,
    files: []const parser.FileDiff,
    comment_store: *const comments.CommentStore,
) ?usize {
    return filePositionToGlobalLine(file_idx, 0, files, comment_store);
}

test "global line mapping" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/file1.txt b/file1.txt
        \\--- a/file1.txt
        \\+++ b/file1.txt
        \\@@ -1,1 +1,1 @@
        \\-old line
        \\+new line
        \\diff --git a/file2.txt b/file2.txt
        \\--- a/file2.txt
        \\+++ b/file2.txt
        \\@@ -1,1 +1,2 @@
        \\ context
        \\+addition
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    // Test total lines
    const total = getTotalGlobalLines(files, &store);
    // File 1: 1 header + 1 hunk header + 2 lines = 4
    // File 2: 1 header + 1 hunk header + 2 lines = 4
    // Total: 8
    try std.testing.expectEqual(@as(usize, 8), total);

    // Test mapping global line 0 (file1 header)
    const pos0 = globalLineToFilePosition(0, files, &store).?;
    try std.testing.expectEqual(@as(usize, 0), pos0.file_idx);
    try std.testing.expectEqual(@as(usize, 0), pos0.local_line);

    // Test mapping global line 4 (file2 header)
    const pos4 = globalLineToFilePosition(4, files, &store).?;
    try std.testing.expectEqual(@as(usize, 1), pos4.file_idx);
    try std.testing.expectEqual(@as(usize, 0), pos4.local_line);

    // Test reverse mapping
    const global = filePositionToGlobalLine(1, 0, files, &store).?;
    try std.testing.expectEqual(@as(usize, 4), global);

    // Test getCurrentFileFromCursor
    const file_idx = getCurrentFileFromCursor(5, files, &store);
    try std.testing.expectEqual(@as(usize, 1), file_idx);
}
