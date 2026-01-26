const std = @import("std");
const fs = std.fs;

const SNAPSHOT_DIR = "src/testing/snapshots";
const UPDATE_ENV_VAR = "SKIM_UPDATE_SNAPSHOTS";

/// Error returned when snapshot comparison fails
pub const SnapshotError = error{
    SnapshotMismatch,
    SnapshotMissing,
    SnapshotUpdateFailed,
    FileReadFailed,
};

/// Compares actual output to a snapshot file.
/// - If SKIM_UPDATE_SNAPSHOTS env var is set, writes actual content to snapshot file
/// - If snapshot file doesn't exist and not in update mode, returns SnapshotMissing
/// - If content differs and not in update mode, returns SnapshotMismatch
pub fn expectSnapshot(allocator: std.mem.Allocator, name: []const u8, actual: []const u8) !void {
    if (shouldUpdate()) {
        try writeSnapshot(name, actual);
        return;
    }

    const expected = loadSnapshot(allocator, name) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                \\
                \\Snapshot not found: {s}
                \\
                \\To create the snapshot, run:
                \\  SKIM_UPDATE_SNAPSHOTS=1 zig build test
                \\
                \\
            , .{name});
            return SnapshotError.SnapshotMissing;
        },
        else => return SnapshotError.FileReadFailed,
    };
    defer allocator.free(expected);

    if (!std.mem.eql(u8, expected, actual)) {
        printDiff(expected, actual, name);
        return SnapshotError.SnapshotMismatch;
    }
}

/// Checks if the update environment variable is set
fn shouldUpdate() bool {
    return std.posix.getenv(UPDATE_ENV_VAR) != null;
}

/// Loads snapshot content from file
fn loadSnapshot(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.snap", .{ SNAPSHOT_DIR, name }) catch unreachable;

    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(content);

    const bytes_read = try file.readAll(content);
    if (bytes_read != stat.size) {
        return error.UnexpectedEndOfFile;
    }

    return content;
}

/// Writes content to snapshot file
fn writeSnapshot(name: []const u8, content: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.snap", .{ SNAPSHOT_DIR, name }) catch unreachable;

    // Ensure directory exists
    fs.cwd().makePath(SNAPSHOT_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return SnapshotError.SnapshotUpdateFailed,
    };

    const file = fs.cwd().createFile(path, .{}) catch return SnapshotError.SnapshotUpdateFailed;
    defer file.close();

    file.writeAll(content) catch return SnapshotError.SnapshotUpdateFailed;

    std.debug.print("Updated snapshot: {s}\n", .{path});
}

/// Prints a diff showing expected vs actual content
fn printDiff(expected: []const u8, actual: []const u8, name: []const u8) void {
    std.debug.print(
        \\
        \\Snapshot mismatch: {s}
        \\
        \\--- Expected ---
        \\{s}
        \\--- Actual ---
        \\{s}
        \\--- End ---
        \\
        \\To update the snapshot, run:
        \\  SKIM_UPDATE_SNAPSHOTS=1 zig build test
        \\
        \\
    , .{ name, expected, actual });
}

// Tests

test "expectSnapshot passes when content matches" {
    const allocator = std.testing.allocator;

    // Test with a known snapshot file that exists
    try expectSnapshot(allocator, "_test_simple", "Hello, World!");
}

test "expectSnapshot fails when content differs" {
    const allocator = std.testing.allocator;

    // This should fail because the content doesn't match
    const result = expectSnapshot(allocator, "_test_simple", "Wrong content!");
    try std.testing.expectError(SnapshotError.SnapshotMismatch, result);
}

test "expectSnapshot fails when snapshot missing" {
    const allocator = std.testing.allocator;

    // This should fail because the snapshot file doesn't exist
    const result = expectSnapshot(allocator, "_nonexistent_snapshot_xyz123", "Some content");
    try std.testing.expectError(SnapshotError.SnapshotMissing, result);
}

test "loadSnapshot reads file content" {
    const allocator = std.testing.allocator;

    const content = try loadSnapshot(allocator, "_test_simple");
    defer allocator.free(content);

    try std.testing.expectEqualStrings("Hello, World!", content);
}

test "loadSnapshot reads multiline content" {
    const allocator = std.testing.allocator;

    const content = try loadSnapshot(allocator, "_test_multiline");
    defer allocator.free(content);

    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", content);
}

test "shouldUpdate returns false when env not set" {
    // In normal test runs, env var is not set
    try std.testing.expect(!shouldUpdate());
}
