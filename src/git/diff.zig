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
    try args.append("-U7"); // 7 lines of context

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
                defer allocator.free(range_owned);
                try args.append(range_owned);
            } else {
                try args.append(tr.ref1);
                try args.append(tr.ref2);
            }
        },
    }

    return runGitCommand(allocator, args.items);
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
                defer allocator.free(range_owned);
                try args.append(range_owned);
            } else {
                try args.append(tr.ref1);
                try args.append(tr.ref2);
            }
        },
    }

    const output = try runGitCommand(allocator, args.items);
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

test "getDiff working directory" {
    const allocator = std.testing.allocator;

    const diff = try getDiff(allocator, .{ .working_dir = .{ .staged = false } });
    defer allocator.free(diff);

    // Just verify it doesn't crash - actual output depends on git repo state
}
