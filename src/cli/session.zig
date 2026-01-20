//! CLI command: skim session
//!
//! Unified interface for interacting with running skim TUI sessions.
//!
//! USAGE:
//!     skim session list                              List running sessions
//!     skim session context [--id <pid>]              Get session context
//!     skim session diff [--id <pid>] [--file <f>]    Get diff content
//!     skim session comment add <options>             Add a comment
//!     skim session comment list [--id <pid>]         List comments
//!     skim session comment delete <index>            Delete a comment

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const client = @import("client.zig");
const session_mgr = @import("../mcp/session.zig");

// =============================================================================
// Write Buffers
// =============================================================================

var stdout_buffer: [8192]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

// =============================================================================
// Subcommand Routing
// =============================================================================

pub const Subcommand = enum {
    list,
    context,
    diff,
    comment,
    help,
};

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    // args[0] = "skim", args[1] = "session"
    if (args.len < 3) {
        printHelp();
        return;
    }

    const subcmd = args[2];

    if (std.mem.eql(u8, subcmd, "list")) {
        try runList(allocator, args);
    } else if (std.mem.eql(u8, subcmd, "context")) {
        try runContext(allocator, args);
    } else if (std.mem.eql(u8, subcmd, "diff")) {
        try runDiff(allocator, args);
    } else if (std.mem.eql(u8, subcmd, "comment")) {
        try runComment(allocator, args);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printHelp();
    } else {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        stderr_writer.interface.print("Unknown subcommand: {s}\n", .{subcmd}) catch {};
        stderr_writer.interface.writeAll("Use 'skim session --help' for usage.\n") catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    }
}

// =============================================================================
// List Sessions
// =============================================================================

fn runList(allocator: Allocator, args: []const []const u8) !void {
    var json_output = false;

    // Parse args after "skim session list"
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printListHelp();
            return;
        }
    }

    var sm = session_mgr.SessionManager.init(allocator) catch |err| {
        printError("Failed to initialize session manager: {}", .{err});
        std.process.exit(1);
    };
    defer sm.deinit();

    const sessions = sm.listSessions() catch |err| {
        printError("Failed to list sessions: {}", .{err});
        std.process.exit(1);
    };
    defer {
        for (sessions) |*s| {
            var sess = s.*;
            sess.deinit(allocator);
        }
        allocator.free(sessions);
    }

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    if (sessions.len == 0) {
        if (json_output) {
            try stdout.writeAll("[]\n");
        } else {
            try stdout.writeAll("No skim sessions running.\n");
        }
        return;
    }

    if (json_output) {
        try stdout.writeAll("[");
        for (sessions, 0..) |s, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try stdout.print("{{\"pid\":{d},\"port\":{d},\"cwd\":{f},\"diff_ref\":{f},\"files\":{d}}}", .{
                s.pid,
                s.port,
                std.json.fmt(s.cwd, .{}),
                std.json.fmt(s.diff_ref, .{}),
                s.files.len,
            });
        }
        try stdout.writeAll("]\n");
    } else {
        try stdout.print("Running sessions ({d}):\n\n", .{sessions.len});
        for (sessions) |s| {
            try stdout.print("  PID:   {d}\n", .{s.pid});
            try stdout.print("  CWD:   {s}\n", .{s.cwd});
            try stdout.print("  Diff:  {s}\n", .{s.diff_ref});
            try stdout.print("  Files: {d}\n\n", .{s.files.len});
        }
    }
}

// =============================================================================
// Get Context
// =============================================================================

fn runContext(allocator: Allocator, args: []const []const u8) !void {
    var session_pid: ?posix.pid_t = null;
    var json_output = false;

    // Parse args after "skim session context"
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id") or std.mem.eql(u8, args[i], "-i")) {
            if (i + 1 < args.len) {
                i += 1;
                session_pid = std.fmt.parseInt(posix.pid_t, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printContextHelp();
            return;
        }
    }

    var conn = connectOrExit(allocator, session_pid);
    defer conn.deinit();

    var response = conn.request("get_context", "ctx-1", null) catch {
        printError("Request failed", .{});
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    switch (response) {
        .result => |result| {
            if (json_output) {
                try outputJson(allocator, stdout, result);
            } else {
                try outputContextHuman(stdout, result);
            }
        },
        .err => |e| {
            printError("Server error: {s}", .{e.message});
            std.process.exit(1);
        },
    }
}

fn outputContextHuman(writer: anytype, result: std.json.Value) !void {
    if (result != .object) {
        try writer.writeAll("Invalid response format\n");
        return;
    }
    const obj = result.object;

    if (obj.get("cwd")) |v| if (v == .string) try writer.print("CWD:      {s}\n", .{v.string});
    if (obj.get("diff_ref")) |v| if (v == .string) try writer.print("Diff:     {s}\n", .{v.string});
    if (obj.get("view_mode")) |v| if (v == .string) try writer.print("View:     {s}\n", .{v.string});
    if (obj.get("comment_count")) |v| if (v == .integer) try writer.print("Comments: {d}\n", .{v.integer});

    if (obj.get("files")) |files| {
        if (files == .array) {
            try writer.print("\nFiles ({d}):\n", .{files.array.items.len});
            for (files.array.items) |file| {
                if (file == .string) {
                    try writer.print("  - {s}\n", .{file.string});
                }
            }
        }
    }
}

// =============================================================================
// Get Diff
// =============================================================================

fn runDiff(allocator: Allocator, args: []const []const u8) !void {
    var session_pid: ?posix.pid_t = null;
    var file_filter: ?[]const u8 = null;

    // Parse args after "skim session diff"
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id") or std.mem.eql(u8, args[i], "-i")) {
            if (i + 1 < args.len) {
                i += 1;
                session_pid = std.fmt.parseInt(posix.pid_t, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, args[i], "--file") or std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                file_filter = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printDiffHelp();
            return;
        }
    }

    var conn = connectOrExit(allocator, session_pid);
    defer conn.deinit();

    // Build params if file filter specified
    var req_params: ?std.json.Value = null;
    var params_obj: std.json.ObjectMap = undefined;
    if (file_filter) |f| {
        params_obj = std.json.ObjectMap.init(allocator);
        params_obj.put(allocator.dupe(u8, "file") catch unreachable, .{ .string = allocator.dupe(u8, f) catch unreachable }) catch {};
        req_params = .{ .object = params_obj };
    }
    defer if (file_filter != null) {
        var it = params_obj.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.* == .string) allocator.free(entry.value_ptr.string);
        }
        params_obj.deinit();
    };

    var response = conn.request("get_diff", "diff-1", req_params) catch {
        printError("Request failed", .{});
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    switch (response) {
        .result => |result| {
            if (result == .object) {
                if (result.object.get("diff")) |diff| {
                    if (diff == .string) {
                        try stdout.writeAll(diff.string);
                        return;
                    }
                }
            }
            try stdout.writeAll("No diff content\n");
        },
        .err => |e| {
            printError("Server error: {s}", .{e.message});
            std.process.exit(1);
        },
    }
}

// =============================================================================
// Comment Subcommands
// =============================================================================

fn runComment(allocator: Allocator, args: []const []const u8) !void {
    // args[0] = "skim", args[1] = "session", args[2] = "comment"
    if (args.len < 4) {
        printCommentHelp();
        return;
    }

    const subcmd = args[3];

    if (std.mem.eql(u8, subcmd, "add")) {
        try runCommentAdd(allocator, args);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try runCommentList(allocator, args);
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        try runCommentDelete(allocator, args);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printCommentHelp();
    } else {
        printError("Unknown comment subcommand: {s}", .{subcmd});
        std.process.exit(1);
    }
}

fn runCommentAdd(allocator: Allocator, args: []const []const u8) !void {
    var session_pid: ?posix.pid_t = null;
    var file: ?[]const u8 = null;
    var line: ?u32 = null;
    var line_type: []const u8 = "new";
    var text: ?[]const u8 = null;

    // Parse args after "skim session comment add"
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id") or std.mem.eql(u8, args[i], "-i")) {
            if (i + 1 < args.len) {
                i += 1;
                session_pid = std.fmt.parseInt(posix.pid_t, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, args[i], "--file") or std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                file = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--line") or std.mem.eql(u8, args[i], "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                line = std.fmt.parseInt(u32, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, args[i], "--type") or std.mem.eql(u8, args[i], "-t")) {
            if (i + 1 < args.len) {
                i += 1;
                line_type = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printCommentAddHelp();
            return;
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            text = args[i];
        }
    }

    // Validate required args
    if (file == null) {
        printError("--file is required", .{});
        std.process.exit(1);
    }
    if (line == null) {
        printError("--line is required", .{});
        std.process.exit(1);
    }
    if (text == null) {
        printError("Comment text is required", .{});
        std.process.exit(1);
    }

    var conn = connectOrExit(allocator, session_pid);
    defer conn.deinit();

    // Build params
    var params = std.json.ObjectMap.init(allocator);
    defer params.deinit();
    try params.put(try allocator.dupe(u8, "file"), .{ .string = try allocator.dupe(u8, file.?) });
    try params.put(try allocator.dupe(u8, "line"), .{ .integer = @intCast(line.?) });
    try params.put(try allocator.dupe(u8, "line_type"), .{ .string = try allocator.dupe(u8, line_type) });
    try params.put(try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text.?) });

    var response = conn.request("add_comment", "add-1", .{ .object = params }) catch {
        printError("Request failed", .{});
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    switch (response) {
        .result => {
            try stdout_writer.interface.writeAll("Comment added.\n");
        },
        .err => |e| {
            printError("Server error: {s}", .{e.message});
            std.process.exit(1);
        },
    }
}

fn runCommentList(allocator: Allocator, args: []const []const u8) !void {
    var session_pid: ?posix.pid_t = null;
    var json_output = false;

    // Parse args after "skim session comment list"
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id") or std.mem.eql(u8, args[i], "-i")) {
            if (i + 1 < args.len) {
                i += 1;
                session_pid = std.fmt.parseInt(posix.pid_t, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printCommentListHelp();
            return;
        }
    }

    var conn = connectOrExit(allocator, session_pid);
    defer conn.deinit();

    var response = conn.request("list_comments", "list-1", null) catch {
        printError("Request failed", .{});
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    switch (response) {
        .result => |result| {
            if (json_output) {
                try outputJson(allocator, stdout, result);
            } else {
                try outputCommentsHuman(stdout, result);
            }
        },
        .err => |e| {
            printError("Server error: {s}", .{e.message});
            std.process.exit(1);
        },
    }
}

fn runCommentDelete(allocator: Allocator, args: []const []const u8) !void {
    var session_pid: ?posix.pid_t = null;
    var index: ?u32 = null;

    // Parse args after "skim session comment delete"
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id") or std.mem.eql(u8, args[i], "-i")) {
            if (i + 1 < args.len) {
                i += 1;
                session_pid = std.fmt.parseInt(posix.pid_t, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printCommentDeleteHelp();
            return;
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            index = std.fmt.parseInt(u32, args[i], 10) catch null;
        }
    }

    if (index == null) {
        printError("Comment index is required", .{});
        std.process.exit(1);
    }

    var conn = connectOrExit(allocator, session_pid);
    defer conn.deinit();

    var params = std.json.ObjectMap.init(allocator);
    defer params.deinit();
    try params.put(try allocator.dupe(u8, "index"), .{ .integer = @intCast(index.?) });

    var response = conn.request("delete_comment", "del-1", .{ .object = params }) catch {
        printError("Request failed", .{});
        std.process.exit(1);
    };
    defer response.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    switch (response) {
        .result => {
            try stdout_writer.interface.writeAll("Comment deleted.\n");
        },
        .err => |e| {
            printError("Server error: {s}", .{e.message});
            std.process.exit(1);
        },
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn connectOrExit(allocator: Allocator, session_pid: ?posix.pid_t) client.Client {
    return client.autoConnect(allocator, session_pid) catch |err| {
        switch (err) {
            error.NoSessionsRunning => printError("No skim sessions running", .{}),
            error.AmbiguousSessions => printError("Multiple sessions found. Use --id <pid> to specify", .{}),
            error.SessionNotFound => printError("Session not found", .{}),
            error.ConnectionFailed => printError("Failed to connect to session", .{}),
        }
        std.process.exit(1);
    };
}

fn outputJson(allocator: Allocator, writer: anytype, result: std.json.Value) !void {
    var alloc_writer: std.io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &alloc_writer.writer };
    stringify.write(result) catch return;
    try writer.writeAll(alloc_writer.written());
    try writer.writeAll("\n");
}

fn outputCommentsHuman(writer: anytype, result: std.json.Value) !void {
    if (result != .object) return;
    const comments = result.object.get("comments") orelse return;
    if (comments != .array) return;

    if (comments.array.items.len == 0) {
        try writer.writeAll("No comments.\n");
        return;
    }

    try writer.print("Comments ({d}):\n\n", .{comments.array.items.len});
    for (comments.array.items, 0..) |comment, idx| {
        if (comment == .object) {
            const c = comment.object;
            const file_path = if (c.get("file_path")) |f| if (f == .string) f.string else "?" else "?";
            const text = if (c.get("text")) |t| if (t == .string) t.string else "" else "";
            try writer.print("  [{d}] {s}\n", .{ idx, file_path });
            try writer.print("      {s}\n\n", .{text});
        }
    }
}

fn printError(comptime fmt: []const u8, fmtargs: anytype) void {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    stderr_writer.interface.print("Error: " ++ fmt ++ "\n", fmtargs) catch {};
    stderr_writer.interface.flush() catch {};
}

// =============================================================================
// Help Text
// =============================================================================

fn printHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session - Interact with running skim sessions
        \\
        \\USAGE:
        \\    skim session <SUBCOMMAND> [OPTIONS]
        \\
        \\SUBCOMMANDS:
        \\    list                     List running sessions
        \\    context                  Get session context (files, diff ref, etc.)
        \\    diff                     Get diff content with line numbers
        \\    comment                  Manage comments (add/list/delete)
        \\
        \\OPTIONS:
        \\    --id, -i <PID>           Target specific session by PID
        \\    -h, --help               Print help
        \\
        \\EXAMPLES:
        \\    skim session list
        \\    skim session context
        \\    skim session diff --file src/app.zig
        \\    skim session comment add -f src/app.zig -l 42 "Check for null"
        \\    skim session comment list
        \\    skim session comment delete 0
        \\
    ) catch {};
}

fn printListHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session list - List running skim sessions
        \\
        \\USAGE:
        \\    skim session list [OPTIONS]
        \\
        \\OPTIONS:
        \\    --json        Output in JSON format
        \\    -h, --help    Print help
        \\
    ) catch {};
}

fn printContextHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session context - Get session context
        \\
        \\USAGE:
        \\    skim session context [OPTIONS]
        \\
        \\OPTIONS:
        \\    --id, -i <PID>    Target specific session
        \\    --json            Output in JSON format
        \\    -h, --help        Print help
        \\
    ) catch {};
}

fn printDiffHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session diff - Get diff content with line numbers
        \\
        \\USAGE:
        \\    skim session diff [OPTIONS]
        \\
        \\OPTIONS:
        \\    --id, -i <PID>       Target specific session
        \\    --file, -f <PATH>    Filter to specific file
        \\    -h, --help           Print help
        \\
        \\OUTPUT FORMAT:
        \\    Each line shows: MARKER OLD_LINE NEW_LINE | CONTENT
        \\    + = added line (use --type new for comments)
        \\    - = deleted line (use --type old for comments)
        \\    (space) = context line
        \\
    ) catch {};
}

fn printCommentHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session comment - Manage comments
        \\
        \\USAGE:
        \\    skim session comment <SUBCOMMAND> [OPTIONS]
        \\
        \\SUBCOMMANDS:
        \\    add       Add a comment
        \\    list      List all comments
        \\    delete    Delete a comment by index
        \\
        \\Use 'skim session comment <SUBCOMMAND> --help' for more info.
        \\
    ) catch {};
}

fn printCommentAddHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session comment add - Add a comment
        \\
        \\USAGE:
        \\    skim session comment add [OPTIONS] <TEXT>
        \\
        \\OPTIONS:
        \\    --id, -i <PID>       Target specific session
        \\    --file, -f <PATH>    File path (required)
        \\    --line, -l <N>       Line number (required)
        \\    --type, -t <TYPE>    Line type: new or old (default: new)
        \\    -h, --help           Print help
        \\
        \\EXAMPLES:
        \\    skim session comment add -f src/app.zig -l 42 "Check for null"
        \\    skim session comment add -f main.zig -l 10 -t old "Remove this"
        \\
    ) catch {};
}

fn printCommentListHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session comment list - List all comments
        \\
        \\USAGE:
        \\    skim session comment list [OPTIONS]
        \\
        \\OPTIONS:
        \\    --id, -i <PID>    Target specific session
        \\    --json            Output in JSON format
        \\    -h, --help        Print help
        \\
    ) catch {};
}

fn printCommentDeleteHelp() void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.writeAll(
        \\skim session comment delete - Delete a comment
        \\
        \\USAGE:
        \\    skim session comment delete [OPTIONS] <INDEX>
        \\
        \\OPTIONS:
        \\    --id, -i <PID>    Target specific session
        \\    -h, --help        Print help
        \\
        \\EXAMPLES:
        \\    skim session comment delete 0
        \\    skim session comment delete 2 --id 12345
        \\
    ) catch {};
}
