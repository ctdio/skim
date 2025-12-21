const std = @import("std");
const parser = @import("../git/parser.zig");

const Allocator = std.mem.Allocator;

/// Result of resolving a file:line to diff coordinates
pub const ResolvedLine = struct {
    file_idx: usize,
    hunk_idx: usize,
    line_idx: usize,
    line_type: parser.Line.LineType,
    line_content: []const u8,
    old_lineno: ?u32,
    new_lineno: ?u32,
};

/// Resolves absolute file:line numbers to diff hunk coordinates.
/// This allows agents to reference lines by their file position rather than
/// needing to understand the internal hunk structure.
pub const LineResolver = struct {
    allocator: Allocator,
    files: []const parser.FileDiff,

    pub fn init(allocator: Allocator, files: []const parser.FileDiff) LineResolver {
        return .{
            .allocator = allocator,
            .files = files,
        };
    }

    /// Resolve a file path and line number to diff coordinates.
    /// Returns null if the line is not part of the diff.
    ///
    /// For added/context lines, use `new_line` (line number in new file).
    /// For deleted lines, use `old_line` (line number in old file).
    pub fn resolveNewLine(self: *const LineResolver, file_path: []const u8, line_number: u32) ?ResolvedLine {
        return self.resolveLineInternal(file_path, line_number, false);
    }

    /// Resolve using old file line numbers (for referencing deleted lines)
    pub fn resolveOldLine(self: *const LineResolver, file_path: []const u8, line_number: u32) ?ResolvedLine {
        return self.resolveLineInternal(file_path, line_number, true);
    }

    /// Auto-detect: try new line first, then old line
    pub fn resolve(self: *const LineResolver, file_path: []const u8, line_number: u32) ?ResolvedLine {
        // Try new file line numbers first (most common case: add/context lines)
        if (self.resolveNewLine(file_path, line_number)) |result| {
            return result;
        }
        // Fall back to old file line numbers (for deleted lines)
        return self.resolveOldLine(file_path, line_number);
    }

    fn resolveLineInternal(self: *const LineResolver, file_path: []const u8, line_number: u32, use_old: bool) ?ResolvedLine {
        // Find the file
        const file_idx = self.findFile(file_path) orelse return null;
        const file = &self.files[file_idx];

        // Search through hunks for the line
        for (file.hunks, 0..) |hunk, hunk_idx| {
            for (hunk.lines, 0..) |line, line_idx| {
                const target_lineno = if (use_old) line.old_lineno else line.new_lineno;
                if (target_lineno) |lineno| {
                    if (lineno == line_number) {
                        return .{
                            .file_idx = file_idx,
                            .hunk_idx = hunk_idx,
                            .line_idx = line_idx,
                            .line_type = line.line_type,
                            .line_content = line.content,
                            .old_lineno = line.old_lineno,
                            .new_lineno = line.new_lineno,
                        };
                    }
                }
            }
        }

        return null;
    }

    /// Find file index by path (tries both new_path and old_path)
    fn findFile(self: *const LineResolver, path: []const u8) ?usize {
        for (self.files, 0..) |file, idx| {
            // Try new_path first
            if (file.new_path.len > 0 and std.mem.eql(u8, file.new_path, path)) {
                return idx;
            }
            // Fall back to old_path
            if (file.old_path.len > 0 and std.mem.eql(u8, file.old_path, path)) {
                return idx;
            }
        }
        return null;
    }

    /// Get all files in the diff
    pub fn listFiles(self: *const LineResolver) []const parser.FileDiff {
        return self.files;
    }

    /// Get file path for display (prefers new_path)
    pub fn getFilePath(file: *const parser.FileDiff) []const u8 {
        return if (file.new_path.len > 0) file.new_path else file.old_path;
    }

    /// Check if a line number is in the diff for a given file
    pub fn isLineInDiff(self: *const LineResolver, file_path: []const u8, line_number: u32) bool {
        return self.resolve(file_path, line_number) != null;
    }

    /// Get all line numbers in the diff for a file (useful for validation)
    pub fn getLineNumbersForFile(self: *const LineResolver, allocator: Allocator, file_path: []const u8) !?struct {
        new_lines: []u32,
        old_lines: []u32,
    } {
        const file_idx = self.findFile(file_path) orelse return null;
        const file = &self.files[file_idx];

        var new_lines: std.ArrayList(u32) = .{};
        var old_lines: std.ArrayList(u32) = .{};
        errdefer new_lines.deinit(allocator);
        errdefer old_lines.deinit(allocator);

        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                if (line.new_lineno) |n| try new_lines.append(allocator, n);
                if (line.old_lineno) |o| try old_lines.append(allocator, o);
            }
        }

        return .{
            .new_lines = try new_lines.toOwnedSlice(allocator),
            .old_lines = try old_lines.toOwnedSlice(allocator),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "resolve new line in diff" {
    const allocator = std.testing.allocator;

    // Create mock diff data
    var lines = [_]parser.Line{
        .{ .line_type = .context, .content = "unchanged", .old_lineno = 10, .new_lineno = 10 },
        .{ .line_type = .delete, .content = "removed", .old_lineno = 11, .new_lineno = null },
        .{ .line_type = .add, .content = "added", .old_lineno = null, .new_lineno = 11 },
        .{ .line_type = .context, .content = "unchanged2", .old_lineno = 12, .new_lineno = 12 },
    };

    var hunks = [_]parser.Hunk{
        .{
            .header = .{ .old_start = 10, .old_count = 3, .new_start = 10, .new_count = 3, .context = "" },
            .lines = &lines,
        },
    };

    var files = [_]parser.FileDiff{
        .{
            .old_path = "test.zig",
            .new_path = "test.zig",
            .hunks = &hunks,
            .highlights = null,
            .old_highlights = null,
        },
    };

    const resolver = LineResolver.init(allocator, &files);

    // Test resolving an added line
    const result = resolver.resolve("test.zig", 11);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(parser.Line.LineType.add, result.?.line_type);
    try std.testing.expectEqualStrings("added", result.?.line_content);

    // Test resolving a context line
    const context_result = resolver.resolve("test.zig", 10);
    try std.testing.expect(context_result != null);
    try std.testing.expectEqual(parser.Line.LineType.context, context_result.?.line_type);

    // Test non-existent line
    const no_result = resolver.resolve("test.zig", 999);
    try std.testing.expect(no_result == null);

    // Test non-existent file
    const no_file = resolver.resolve("nonexistent.zig", 10);
    try std.testing.expect(no_file == null);
}

test "resolve deleted line using old line number" {
    const allocator = std.testing.allocator;

    var lines = [_]parser.Line{
        .{ .line_type = .delete, .content = "old content", .old_lineno = 50, .new_lineno = null },
    };

    var hunks = [_]parser.Hunk{
        .{
            .header = .{ .old_start = 50, .old_count = 1, .new_start = 50, .new_count = 0, .context = "" },
            .lines = &lines,
        },
    };

    var files = [_]parser.FileDiff{
        .{
            .old_path = "deleted.zig",
            .new_path = "deleted.zig",
            .hunks = &hunks,
            .highlights = null,
            .old_highlights = null,
        },
    };

    const resolver = LineResolver.init(allocator, &files);

    // Should find deleted line via auto-resolve (falls back to old_lineno)
    const result = resolver.resolve("deleted.zig", 50);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(parser.Line.LineType.delete, result.?.line_type);
}

test "isLineInDiff" {
    const allocator = std.testing.allocator;

    var lines = [_]parser.Line{
        .{ .line_type = .add, .content = "new", .old_lineno = null, .new_lineno = 100 },
    };

    var hunks = [_]parser.Hunk{
        .{
            .header = .{ .old_start = 100, .old_count = 0, .new_start = 100, .new_count = 1, .context = "" },
            .lines = &lines,
        },
    };

    var files = [_]parser.FileDiff{
        .{
            .old_path = "check.zig",
            .new_path = "check.zig",
            .hunks = &hunks,
            .highlights = null,
            .old_highlights = null,
        },
    };

    const resolver = LineResolver.init(allocator, &files);

    try std.testing.expect(resolver.isLineInDiff("check.zig", 100));
    try std.testing.expect(!resolver.isLineInDiff("check.zig", 99));
    try std.testing.expect(!resolver.isLineInDiff("other.zig", 100));
}
