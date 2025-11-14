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

/// Execute git diff and return the output as a string
pub fn getDiff(allocator: Allocator, source: DiffSource) ![]u8 {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("git");
    try args.append("diff");
    try args.append("--no-color");
    try args.append("--no-ext-diff");
    try args.append("-U10"); // 10 lines of context

    switch (source) {
        .working_dir => |wd| {
            if (wd.staged) {
                try args.append("--cached");
            }
        },
        .single_ref => |sr| {
            if (sr.staged) {
                try args.append("--cached");
            }
            try args.append(sr.ref);
        },
        .two_refs => |tr| {
            if (tr.use_merge_base) {
                var range_buf: [512]u8 = undefined;
                const range = try std.fmt.bufPrint(&range_buf, "{s}...{s}", .{ tr.ref1, tr.ref2 });
                const range_owned = try allocator.dupe(u8, range);
                errdefer allocator.free(range_owned);
                try args.append(range_owned);
            } else {
                try args.append(tr.ref1);
                try args.append(tr.ref2);
            }
        },
    }

    const result = runGitCommand(allocator, args.items);

    // Free any allocated range strings
    switch (source) {
        .two_refs => |tr| {
            if (tr.use_merge_base and args.items.len > 0) {
                // Last item is the allocated range string
                for (args.items) |arg| {
                    const is_git = std.mem.eql(u8, arg, "git");
                    const is_diff = std.mem.eql(u8, arg, "diff");
                    const is_flag = arg.len > 0 and arg[0] == '-';
                    if (!is_git and !is_diff and !is_flag) {
                        allocator.free(arg);
                        break;
                    }
                }
            }
        },
        else => {},
    }

    return result;
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

/// Get list of changed files (fast, without full diff)
pub fn getChangedFiles(allocator: Allocator, source: DiffSource) ![]FileStatus {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("git");
    try args.append("diff");
    try args.append("--name-status");

    switch (source) {
        .working_dir => |wd| {
            if (wd.staged) {
                try args.append("--cached");
            }
        },
        .single_ref => |sr| {
            if (sr.staged) {
                try args.append("--cached");
            }
            try args.append(sr.ref);
        },
        .two_refs => |tr| {
            if (tr.use_merge_base) {
                var range_buf: [512]u8 = undefined;
                const range = try std.fmt.bufPrint(&range_buf, "{s}...{s}", .{ tr.ref1, tr.ref2 });
                const range_owned = try allocator.dupe(u8, range);
                errdefer allocator.free(range_owned);
                try args.append(range_owned);
            } else {
                try args.append(tr.ref1);
                try args.append(tr.ref2);
            }
        },
    }

    const output = try runGitCommand(allocator, args.items);
    defer allocator.free(output);

    // Free any allocated range strings
    switch (source) {
        .two_refs => |tr| {
            if (tr.use_merge_base and args.items.len > 0) {
                // Find and free the allocated range string
                for (args.items) |arg| {
                    const is_git = std.mem.eql(u8, arg, "git");
                    const is_diff = std.mem.eql(u8, arg, "diff");
                    const is_flag = arg.len > 0 and arg[0] == '-';
                    if (!is_git and !is_diff and !is_flag) {
                        allocator.free(arg);
                        break;
                    }
                }
            }
        },
        else => {},
    }

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
    var files = std.ArrayList(FileStatus).init(allocator);
    errdefer {
        for (files.items) |*file| {
            file.deinit(allocator);
        }
        files.deinit();
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

        try files.append(.{
            .status = status,
            .path = try allocator.dupe(u8, path),
        });
    }

    return files.toOwnedSlice();
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

    var branches = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (branches.items) |branch| {
            allocator.free(branch);
        }
        branches.deinit();
    }

    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try branches.append(try allocator.dupe(u8, trimmed));
        }
    }

    return branches.toOwnedSlice();
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

test "getDiff working directory" {
    const allocator = std.testing.allocator;

    const diff = try getDiff(allocator, .{ .working_dir = .{ .staged = false } });
    defer allocator.free(diff);

    // Just verify it doesn't crash - actual output depends on git repo state
}
