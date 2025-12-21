const std = @import("std");

const Allocator = std.mem.Allocator;

pub const DiffSource = union(enum) {
    working_dir: struct {
        staged: bool,
    },
    single_ref: struct {
        ref: []const u8,
        staged: bool,
    },
    two_refs: struct {
        ref1: []const u8,
        ref2: []const u8,
        use_merge_base: bool,
    },
};

/// Build common git diff arguments for a given source
/// Returns the args list and an optional allocated range string that the caller must free
fn buildDiffArgs(allocator: Allocator, source: DiffSource, extra_flags: []const []const u8) !struct { args: std.ArrayList([]const u8), range_owned: ?[]const u8 } {
    var args: std.ArrayList([]const u8) = .{};
    errdefer args.deinit(allocator);

    try args.append(allocator, "git");
    try args.append(allocator, "diff");

    for (extra_flags) |flag| {
        try args.append(allocator, flag);
    }

    var range_owned: ?[]const u8 = null;

    switch (source) {
        .working_dir => |wd| {
            if (wd.staged) {
                try args.append(allocator, "--cached");
            } else if (isInMergeConflict(allocator)) {
                try args.append(allocator, "HEAD");
            }
        },
        .single_ref => |sr| {
            if (sr.staged) {
                try args.append(allocator, "--cached");
            }
            try args.append(allocator, sr.ref);
        },
        .two_refs => |tr| {
            if (tr.use_merge_base) {
                var range_buf: [512]u8 = undefined;
                const range = try std.fmt.bufPrint(&range_buf, "{s}...{s}", .{ tr.ref1, tr.ref2 });
                range_owned = try allocator.dupe(u8, range);
                errdefer if (range_owned) |r| allocator.free(r);
                try args.append(allocator, range_owned.?);
            } else {
                try args.append(allocator, tr.ref1);
                try args.append(allocator, tr.ref2);
            }
        },
    }

    return .{ .args = args, .range_owned = range_owned };
}

/// Execute git diff and return the output as a string
pub fn getDiff(allocator: Allocator, source: DiffSource) ![]u8 {
    const extra_flags = &[_][]const u8{ "--no-color", "--no-ext-diff", "-U10" };
    var build = try buildDiffArgs(allocator, source, extra_flags);
    defer build.args.deinit(allocator);
    defer if (build.range_owned) |r| allocator.free(r);

    return runGitCommand(allocator, build.args.items);
}

fn runGitCommand(allocator: Allocator, args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB limit
    errdefer allocator.free(stdout);

    // Read stderr (for error messages)
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Git command failed with exit code {d}\n", .{code});
                std.debug.print("stderr: {s}\n", .{stderr});
                allocator.free(stdout);
                return error.GitCommandFailed;
            }
        },
        else => {
            allocator.free(stdout);
            return error.GitCommandFailed;
        },
    }

    return stdout;
}

/// Quick stats result
pub const DiffStats = struct {
    files: usize,
    additions: usize,
    deletions: usize,
};

/// Get quick diff stats using --shortstat (very fast)
pub fn getDiffStats(allocator: Allocator, source: DiffSource) !DiffStats {
    const extra_flags = &[_][]const u8{"--shortstat"};
    var build = try buildDiffArgs(allocator, source, extra_flags);
    defer build.args.deinit(allocator);
    defer if (build.range_owned) |r| allocator.free(r);

    const output = try runGitCommand(allocator, build.args.items);
    defer allocator.free(output);

    // Parse shortstat output
    // Format: " 3 files changed, 25 insertions(+), 10 deletions(-)"
    // or: " 1 file changed, 5 insertions(+)"
    // or: "" (no changes)
    if (output.len == 0) {
        return DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
    }

    var files: usize = 0;
    var additions: usize = 0;
    var deletions: usize = 0;

    var iter = std.mem.tokenizeAny(u8, output, " ,\n");
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "file") or std.mem.eql(u8, token, "files")) {
            // Previous token should be the number
            continue;
        } else if (std.mem.eql(u8, token, "changed")) {
            continue;
        } else if (std.mem.eql(u8, token, "insertion") or std.mem.eql(u8, token, "insertions(+)")) {
            continue;
        } else if (std.mem.eql(u8, token, "deletion") or std.mem.eql(u8, token, "deletions(-)")) {
            continue;
        } else {
            // Try to parse as number
            const num = std.fmt.parseInt(usize, token, 10) catch continue;
            // Look ahead to see what this number represents
            const next = iter.peek();
            if (next) |n| {
                if (std.mem.indexOf(u8, n, "file") != null) {
                    files = num;
                } else if (std.mem.indexOf(u8, n, "insertion") != null) {
                    additions = num;
                } else if (std.mem.indexOf(u8, n, "deletion") != null) {
                    deletions = num;
                }
            }
        }
    }

    return DiffStats{ .files = files, .additions = additions, .deletions = deletions };
}

/// Get list of changed files (fast, without full diff)
pub fn getChangedFiles(allocator: Allocator, source: DiffSource) ![]FileStatus {
    const extra_flags = &[_][]const u8{"--name-status"};
    var build = try buildDiffArgs(allocator, source, extra_flags);
    defer build.args.deinit(allocator);
    defer if (build.range_owned) |r| allocator.free(r);

    const output = try runGitCommand(allocator, build.args.items);
    defer allocator.free(output);

    return parseFileStatus(allocator, output);
}

pub const FileStatus = struct {
    status: Status,
    path: []const u8,

    pub const Status = enum {
        added,
        modified,
        deleted,
        renamed,
        copied,
    };

    pub fn deinit(self: *const FileStatus, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

fn parseFileStatus(allocator: Allocator, output: []const u8) ![]FileStatus {
    var files: std.ArrayList(FileStatus) = .{};
    errdefer {
        for (files.items) |*file| {
            file.deinit(allocator);
        }
        files.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len < 3) continue;

        const status_char = line[0];
        const path = std.mem.trim(u8, line[1..], " \t");

        const status: FileStatus.Status = switch (status_char) {
            'A' => .added,
            'M' => .modified,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            else => continue,
        };

        try files.append(allocator, .{
            .status = status,
            .path = try allocator.dupe(u8, path),
        });
    }

    return files.toOwnedSlice(allocator);
}

/// Get list of all branches (local and remote)
pub fn getBranches(allocator: Allocator) ![][]const u8 {
    const args = &[_][]const u8{ "git", "branch", "-a", "--format=%(refname:short)" };

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stdout);

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return error.GitCommandFailed;
    }

    var branches: std.ArrayList([]const u8) = .{};
    errdefer {
        for (branches.items) |branch| {
            allocator.free(branch);
        }
        branches.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try branches.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    return branches.toOwnedSlice(allocator);
}

/// Detect the default branch (main or master) by checking which exists
pub fn detectDefaultBranch(allocator: Allocator) ![]const u8 {
    // Try main first
    const main_check = checkBranchExists(allocator, "main") catch false;
    if (main_check) {
        return try allocator.dupe(u8, "main");
    }

    // Fall back to master
    const master_check = checkBranchExists(allocator, "master") catch false;
    if (master_check) {
        return try allocator.dupe(u8, "master");
    }

    // If neither exists, default to main
    return try allocator.dupe(u8, "main");
}

fn checkBranchExists(allocator: Allocator, branch: []const u8) !bool {
    const args = &[_][]const u8{ "git", "rev-parse", "--verify", branch };

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Get the absolute path to the git repository root
pub fn getRepoRoot(allocator: Allocator) ![]u8 {
    const args = &[_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const output = try runGitCommand(allocator, args);

    // Trim trailing newline/whitespace
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(output);

    return result;
}

/// Check if we're currently in any conflict state (merge, rebase, cherry-pick, revert)
/// Returns true if we're in an incomplete merge/rebase/cherry-pick/revert with conflicts
pub fn isInMergeConflict(allocator: Allocator) bool {
    // Get the git directory path
    const args = &[_][]const u8{ "git", "rev-parse", "--git-dir" };

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024) catch return false;
    defer allocator.free(stdout);

    const term = child.wait() catch return false;
    if (term != .Exited or term.Exited != 0) {
        return false;
    }

    const git_dir = std.mem.trim(u8, stdout, " \t\r\n");

    // Check for conflict markers in git directory
    // These files/directories indicate an incomplete merge/rebase/cherry-pick/revert
    const conflict_markers = [_][]const u8{
        "/MERGE_HEAD", // merge conflict
        "/rebase-merge", // rebase conflict
        "/rebase-apply", // rebase conflict (older format)
        "/CHERRY_PICK_HEAD", // cherry-pick conflict
        "/REVERT_HEAD", // revert conflict
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (conflict_markers) |marker| {
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ git_dir, marker }) catch continue;
        if (std.fs.cwd().access(path, .{})) {
            return true;
        } else |_| {}
    }

    return false;
}

/// Get list of untracked files via git status --porcelain
pub fn getUntrackedFiles(allocator: Allocator) ![][]const u8 {
    const args = &[_][]const u8{ "git", "status", "--porcelain" };
    const output = try runGitCommand(allocator, args);
    defer allocator.free(output);

    var files: std.ArrayList([]const u8) = .{};
    errdefer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        // Untracked files start with "?? "
        if (line.len > 3 and std.mem.startsWith(u8, line, "?? ")) {
            const path = line[3..];
            try files.append(allocator, try allocator.dupe(u8, path));
        }
    }

    return files.toOwnedSlice(allocator);
}

/// Generate a synthetic diff for an untracked file (as if diffing /dev/null to the file)
pub fn getUntrackedFileDiff(allocator: Allocator, file_path: []const u8) ![]u8 {
    const args = &[_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "-U10", "--no-index", "/dev/null", file_path };

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 100 * 1024 * 1024);
    errdefer allocator.free(stdout);

    // Consume stderr but ignore it
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    // git diff --no-index exits with 1 when there are differences (which is expected)
    // Exit code 0 means no differences, 1 means differences, other codes are errors
    switch (term) {
        .Exited => |code| {
            if (code == 0 or code == 1) {
                return stdout;
            } else {
                allocator.free(stdout);
                return error.GitCommandFailed;
            }
        },
        else => {
            allocator.free(stdout);
            return error.GitCommandFailed;
        },
    }
}

/// Stage a file (git add)
pub fn stageFile(allocator: Allocator, file_path: []const u8) !void {
    const args = &[_][]const u8{ "git", "add", file_path };
    const output = try runGitCommand(allocator, args);
    allocator.free(output);
}

/// Stage all files (git add -A)
pub fn stageAllFiles(allocator: Allocator) !void {
    const args = &[_][]const u8{ "git", "add", "-A" };
    const output = try runGitCommand(allocator, args);
    allocator.free(output);
}

/// Result of getDiffWithUntracked - includes diff text and list of untracked file paths
pub const DiffWithUntrackedResult = struct {
    diff_text: []u8,
    untracked_paths: [][]const u8,

    pub fn deinit(self: *const DiffWithUntrackedResult, allocator: Allocator) void {
        allocator.free(self.diff_text);
        for (self.untracked_paths) |path| {
            allocator.free(path);
        }
        allocator.free(self.untracked_paths);
    }
};

/// Get diff including untracked files (only for working_dir non-staged mode)
/// Returns the combined diff text and a list of untracked file paths that were included
pub fn getDiffWithUntracked(allocator: Allocator, source: DiffSource) !DiffWithUntrackedResult {
    // Get the normal tracked diff
    const tracked_diff = try getDiff(allocator, source);
    errdefer allocator.free(tracked_diff);

    // Only include untracked files for working directory non-staged mode
    const include_untracked = switch (source) {
        .working_dir => |wd| !wd.staged,
        else => false,
    };

    if (!include_untracked) {
        return DiffWithUntrackedResult{
            .diff_text = tracked_diff,
            .untracked_paths = try allocator.alloc([]const u8, 0),
        };
    }

    // Get untracked files
    const untracked_files = getUntrackedFiles(allocator) catch {
        // If we can't get untracked files, just return tracked diff
        return DiffWithUntrackedResult{
            .diff_text = tracked_diff,
            .untracked_paths = try allocator.alloc([]const u8, 0),
        };
    };
    errdefer {
        for (untracked_files) |f| allocator.free(f);
        allocator.free(untracked_files);
    }

    if (untracked_files.len == 0) {
        allocator.free(untracked_files);
        return DiffWithUntrackedResult{
            .diff_text = tracked_diff,
            .untracked_paths = try allocator.alloc([]const u8, 0),
        };
    }

    // Build combined diff text
    var combined: std.ArrayList(u8) = .{};
    errdefer combined.deinit(allocator);

    try combined.appendSlice(allocator, tracked_diff);
    allocator.free(tracked_diff);

    // Keep track of which untracked files we successfully got diffs for
    var successful_paths: std.ArrayList([]const u8) = .{};
    errdefer {
        for (successful_paths.items) |p| allocator.free(p);
        successful_paths.deinit(allocator);
    }

    for (untracked_files) |file_path| {
        const untracked_diff = getUntrackedFileDiff(allocator, file_path) catch {
            // Skip files we can't diff (binary, permission issues, etc.)
            allocator.free(file_path);
            continue;
        };
        defer allocator.free(untracked_diff);

        if (untracked_diff.len > 0) {
            // Add newline separator if needed
            if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n') {
                try combined.append(allocator, '\n');
            }
            try combined.appendSlice(allocator, untracked_diff);
            try successful_paths.append(allocator, file_path);
        } else {
            allocator.free(file_path);
        }
    }
    allocator.free(untracked_files);

    return DiffWithUntrackedResult{
        .diff_text = try combined.toOwnedSlice(allocator),
        .untracked_paths = try successful_paths.toOwnedSlice(allocator),
    };
}

test "getDiff working directory" {
    const allocator = std.testing.allocator;

    const diff = try getDiff(allocator, .{ .working_dir = .{ .staged = false } });
    defer allocator.free(diff);

    // Just verify it doesn't crash - actual output depends on git repo state
}
