const std = @import("std");
const Allocator = std.mem.Allocator;

/// Get all files in the git repository (tracked + untracked, respecting .gitignore)
/// Returns owned slice of owned strings - caller must free each path and the slice.
pub fn getAllFiles(allocator: Allocator) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .{};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    // Get tracked files
    const tracked = getTrackedFiles(allocator) catch |err| {
        std.log.warn("Failed to get tracked files: {}", .{err});
        return files.toOwnedSlice(allocator);
    };
    defer {
        for (tracked) |f| allocator.free(f);
        allocator.free(tracked);
    }

    for (tracked) |path| {
        try files.append(allocator, try allocator.dupe(u8, path));
    }

    // Get untracked files (respecting .gitignore)
    const untracked = getUntrackedFiles(allocator) catch |err| {
        std.log.debug("Failed to get untracked files: {}", .{err});
        return files.toOwnedSlice(allocator);
    };
    defer {
        for (untracked) |f| allocator.free(f);
        allocator.free(untracked);
    }

    for (untracked) |path| {
        // Skip if already in tracked (shouldn't happen, but be safe)
        var found = false;
        for (files.items) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try files.append(allocator, try allocator.dupe(u8, path));
        }
    }

    return files.toOwnedSlice(allocator);
}

/// Get tracked files via `git ls-files`
fn getTrackedFiles(allocator: Allocator) ![][]const u8 {
    const args = &[_][]const u8{ "git", "ls-files" };
    return runGitLsFiles(allocator, args);
}

/// Get untracked files via `git ls-files --others --exclude-standard`
fn getUntrackedFiles(allocator: Allocator) ![][]const u8 {
    const args = &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" };
    return runGitLsFiles(allocator, args);
}

/// Run a git ls-files command and parse the output into a list of paths
fn runGitLsFiles(allocator: Allocator, args: []const []const u8) ![][]const u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB limit
    defer allocator.free(stdout);

    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        return error.GitCommandFailed;
    }

    return parseGitLsFilesOutput(allocator, stdout);
}

/// Parse newline-separated file paths from git ls-files output
fn parseGitLsFilesOutput(allocator: Allocator, output: []const u8) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .{};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try files.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    return files.toOwnedSlice(allocator);
}

/// Check if we're in a git repository
pub fn isGitRepository(allocator: Allocator) bool {
    const args = &[_][]const u8{ "git", "rev-parse", "--is-inside-work-tree" };

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return term == .Exited and term.Exited == 0;
}

/// Free a file list returned by getAllFiles
pub fn freeFileList(allocator: Allocator, files: [][]const u8) void {
    for (files) |f| {
        allocator.free(f);
    }
    allocator.free(files);
}

// =============================================================================
// Tests
// =============================================================================

test "parseGitLsFilesOutput empty" {
    const allocator = std.testing.allocator;
    const result = try parseGitLsFilesOutput(allocator, "");
    defer freeFileList(allocator, result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseGitLsFilesOutput single file" {
    const allocator = std.testing.allocator;
    const result = try parseGitLsFilesOutput(allocator, "src/main.zig\n");
    defer freeFileList(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("src/main.zig", result[0]);
}

test "parseGitLsFilesOutput multiple files" {
    const allocator = std.testing.allocator;
    const result = try parseGitLsFilesOutput(allocator, "build.zig\nsrc/main.zig\nsrc/app.zig\n");
    defer freeFileList(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("build.zig", result[0]);
    try std.testing.expectEqualStrings("src/main.zig", result[1]);
    try std.testing.expectEqualStrings("src/app.zig", result[2]);
}

test "parseGitLsFilesOutput handles trailing whitespace" {
    const allocator = std.testing.allocator;
    const result = try parseGitLsFilesOutput(allocator, "  src/main.zig  \n\t\n");
    defer freeFileList(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("src/main.zig", result[0]);
}
