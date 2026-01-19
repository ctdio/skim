//! CLI command: skim comment add/list/delete
//!
//! Manages comments in a running skim TUI session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const client = @import("client.zig");

// =============================================================================
// Write Buffers (Zig 0.15 requires buffers for file.writer())
// =============================================================================

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

// =============================================================================
// Subcommands and Arguments
// =============================================================================

pub const Subcommand = enum {
    add,
    list,
    delete,
};

pub const AddArgs = struct {
    session_pid: ?std.posix.pid_t = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    line_type: []const u8 = "new",
    text: ?[]const u8 = null,
};

pub const ListArgs = struct {
    session_pid: ?std.posix.pid_t = null,
    json: bool = false,
};

pub const DeleteArgs = struct {
    session_pid: ?std.posix.pid_t = null,
    index: ?u32 = null,
};

// =============================================================================
// Command Implementation
// =============================================================================

pub fn runAdd(allocator: Allocator, args: AddArgs) !void {
    // Validate required args
    const file = args.file orelse {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.writeAll("Error: --file is required\n") catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    const line = args.line orelse {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.writeAll("Error: --line is required\n") catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    const text = args.text orelse {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.writeAll("Error: Comment text is required\n") catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };

    var conn = connectOrExit(allocator, args.session_pid);
    defer conn.deinit();

    // Build params object
    var params = std.json.ObjectMap.init(allocator);
    defer params.deinit();

    try params.put(try allocator.dupe(u8, "file"), .{ .string = try allocator.dupe(u8, file) });
    try params.put(try allocator.dupe(u8, "line"), .{ .integer = @as(i64, @intCast(line)) });
    try params.put(try allocator.dupe(u8, "line_type"), .{ .string = try allocator.dupe(u8, args.line_type) });
    try params.put(try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });

    var response = conn.request("add_comment", "add-1", .{ .object = params }) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.print("Error: Request failed: {}\n", .{err}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    switch (response) {
        .result => |result| {
            if (result == .object) {
                if (result.object.get("success")) |success| {
                    if (success == .bool and success.bool) {
                        try stdout.writeAll("Comment added successfully.\n");
                        return;
                    }
                }
            }
            try stdout.writeAll("Comment add response received.\n");
        },
        .err => |e| {
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
            stderr_writer.interface.print("Error from server: {s}\n", .{e.message}) catch {};
            stderr_writer.interface.flush() catch {};
            std.process.exit(1);
        },
    }
}

pub fn runList(allocator: Allocator, args: ListArgs) !void {
    var conn = connectOrExit(allocator, args.session_pid);
    defer conn.deinit();

    var response = conn.request("list_comments", "list-1", null) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.print("Error: Request failed: {}\n", .{err}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    switch (response) {
        .result => |result| {
            if (args.json) {
                try outputJson(allocator, stdout, result);
            } else {
                try outputCommentsHuman(stdout, result);
            }
        },
        .err => |e| {
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
            stderr_writer.interface.print("Error from server: {s}\n", .{e.message}) catch {};
            stderr_writer.interface.flush() catch {};
            std.process.exit(1);
        },
    }
}

pub fn runDelete(allocator: Allocator, args: DeleteArgs) !void {
    const index = args.index orelse {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.writeAll("Error: Comment index is required\n") catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };

    var conn = connectOrExit(allocator, args.session_pid);
    defer conn.deinit();

    // Build params object
    var params = std.json.ObjectMap.init(allocator);
    defer params.deinit();

    try params.put(try allocator.dupe(u8, "index"), .{ .integer = @as(i64, @intCast(index)) });

    var response = conn.request("delete_comment", "del-1", .{ .object = params }) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.print("Error: Request failed: {}\n", .{err}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    switch (response) {
        .result => |result| {
            if (result == .object) {
                if (result.object.get("success")) |success| {
                    if (success == .bool and success.bool) {
                        try stdout.writeAll("Comment deleted successfully.\n");
                        return;
                    }
                }
            }
            try stdout.writeAll("Comment delete response received.\n");
        },
        .err => |e| {
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
            stderr_writer.interface.print("Error from server: {s}\n", .{e.message}) catch {};
            stderr_writer.interface.flush() catch {};
            std.process.exit(1);
        },
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn connectOrExit(allocator: Allocator, session_pid: ?std.posix.pid_t) client.Client {
    return client.autoConnect(allocator, session_pid) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        switch (err) {
            error.NoSessionsRunning => stderr.writeAll("Error: No skim sessions running.\n") catch {},
            error.AmbiguousSessions => stderr.writeAll("Error: Multiple sessions found. Specify --session <pid>.\n") catch {},
            error.SessionNotFound => stderr.writeAll("Error: Session not found.\n") catch {},
            error.ConnectionFailed => stderr.writeAll("Error: Failed to connect to session.\n") catch {},
        }
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn outputJson(allocator: Allocator, writer: anytype, result: std.json.Value) !void {
    var alloc_writer: std.io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &alloc_writer.writer };
    stringify.write(result) catch return error.JsonSerializationFailed;
    try writer.writeAll(alloc_writer.written());
    try writer.writeAll("\n");
}

fn outputCommentsHuman(writer: anytype, result: std.json.Value) !void {
    if (result != .object) {
        try writer.writeAll("Invalid response format\n");
        return;
    }

    const comments = result.object.get("comments") orelse {
        try writer.writeAll("No comments.\n");
        return;
    };

    if (comments != .array) {
        try writer.writeAll("Invalid response format\n");
        return;
    }

    if (comments.array.items.len == 0) {
        try writer.writeAll("No comments.\n");
        return;
    }

    try writer.print("Comments ({d}):\n\n", .{comments.array.items.len});

    for (comments.array.items, 0..) |comment, i| {
        if (comment == .object) {
            const c = comment.object;
            const file = if (c.get("file")) |f| if (f == .string) f.string else "?" else "?";
            const line = if (c.get("line")) |l| if (l == .integer) @as(i64, l.integer) else 0 else 0;
            const line_type = if (c.get("line_type")) |lt| if (lt == .string) lt.string else "?" else "?";
            const text = if (c.get("text")) |t| if (t == .string) t.string else "" else "";

            try writer.print("  [{d}] {s}:{d} ({s})\n", .{ i, file, line, line_type });
            try writer.print("      {s}\n\n", .{text});
        }
    }
}

// =============================================================================
// Argument Parsing
// =============================================================================

pub fn parseAddArgs(args: []const []const u8) AddArgs {
    var result = AddArgs{};

    // Skip "skim comment add"
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--file") or std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                result.file = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--line") or std.mem.eql(u8, args[i], "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                result.line = std.fmt.parseInt(u32, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, args[i], "--line-type") or std.mem.eql(u8, args[i], "-t")) {
            if (i + 1 < args.len) {
                i += 1;
                result.line_type = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--session") or std.mem.eql(u8, args[i], "-s")) {
            if (i + 1 < args.len) {
                i += 1;
                result.session_pid = std.fmt.parseInt(std.posix.pid_t, args[i], 10) catch null;
            }
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            // Positional argument = comment text
            result.text = args[i];
        }
    }

    return result;
}

pub fn parseListArgs(args: []const []const u8) ListArgs {
    var result = ListArgs{};

    // Skip "skim comment list"
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, args[i], "--session") or std.mem.eql(u8, args[i], "-s")) {
            if (i + 1 < args.len) {
                i += 1;
                result.session_pid = std.fmt.parseInt(std.posix.pid_t, args[i], 10) catch null;
            }
        }
    }

    return result;
}

pub fn parseDeleteArgs(args: []const []const u8) DeleteArgs {
    var result = DeleteArgs{};

    // Skip "skim comment delete"
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--session") or std.mem.eql(u8, args[i], "-s")) {
            if (i + 1 < args.len) {
                i += 1;
                result.session_pid = std.fmt.parseInt(std.posix.pid_t, args[i], 10) catch null;
            }
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            // Positional argument = index
            result.index = std.fmt.parseInt(u32, args[i], 10) catch null;
        }
    }

    return result;
}

// =============================================================================
// Help
// =============================================================================

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\skim comment - Manage comments in a running session
        \\
        \\USAGE:
        \\    skim comment <SUBCOMMAND> [OPTIONS]
        \\
        \\SUBCOMMANDS:
        \\    add       Add a comment to a file
        \\    list      List all comments
        \\    delete    Delete a comment by index
        \\
        \\OPTIONS:
        \\    --session, -s <PID>    Target specific session by PID
        \\
        \\ADD OPTIONS:
        \\    --file, -f <PATH>      File path (required)
        \\    --line, -l <N>         Line number (required)
        \\    --line-type, -t <TYPE> Line type: new or old (default: new)
        \\    TEXT                   Comment text (positional, required)
        \\
        \\LIST OPTIONS:
        \\    --json                 Output in JSON format
        \\
        \\EXAMPLES:
        \\    skim comment add -f src/app.zig -l 42 "Check for null"
        \\    skim comment list
        \\    skim comment list --json
        \\    skim comment delete 0
        \\    skim comment add -f main.zig -l 10 -t old "Obsolete code" -s 12345
        \\
    );
}
