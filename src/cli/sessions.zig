//! CLI command: skim sessions list
//!
//! Lists all running skim TUI sessions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const session_mgr = @import("../mcp/session.zig");

// =============================================================================
// Write Buffers (Zig 0.15 requires buffers for file.writer())
// =============================================================================

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

// =============================================================================
// Arguments
// =============================================================================

pub const Args = struct {
    json: bool = false,
};

// =============================================================================
// Command Implementation
// =============================================================================

pub fn run(allocator: Allocator, args: Args) !void {
    var sm = session_mgr.SessionManager.init(allocator) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        defer stderr_writer.interface.flush() catch {};
        try stderr_writer.interface.print("Error: Failed to initialize session manager: {}\n", .{err});
        std.process.exit(1);
    };
    defer sm.deinit();

    const sessions = sm.listSessions() catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        defer stderr_writer.interface.flush() catch {};
        try stderr_writer.interface.print("Error: Failed to list sessions: {}\n", .{err});
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
        if (args.json) {
            try stdout.writeAll("[]\n");
        } else {
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
            defer stderr_writer.interface.flush() catch {};
            try stderr_writer.interface.writeAll("No skim sessions running.\n");
        }
        return;
    }

    if (args.json) {
        try outputJson(allocator, stdout, sessions);
    } else {
        try outputHuman(stdout, sessions);
    }
}

fn outputJson(allocator: Allocator, writer: anytype, sessions: []const session_mgr.SessionInfo) !void {
    try writer.writeAll("[");

    for (sessions, 0..) |s, i| {
        if (i > 0) try writer.writeAll(",");

        try writer.print("{{\"pid\":{d},\"port\":{d},\"cwd\":{f},\"diff_ref\":{f},\"files\":[", .{
            s.pid,
            s.port,
            std.json.fmt(s.cwd, .{}),
            std.json.fmt(s.diff_ref, .{}),
        });

        for (s.files, 0..) |f, j| {
            if (j > 0) try writer.writeAll(",");
            try writer.print("{f}", .{std.json.fmt(f, .{})});
        }

        try writer.print("],\"started_at\":{d}}}", .{s.started_at});
    }

    try writer.writeAll("]\n");
    _ = allocator;
}

fn outputHuman(writer: anytype, sessions: []const session_mgr.SessionInfo) !void {
    try writer.writeAll("Running skim sessions:\n\n");

    for (sessions) |s| {
        try writer.print("  PID:      {d}\n", .{s.pid});
        try writer.print("  Port:     {d}\n", .{s.port});
        try writer.print("  CWD:      {s}\n", .{s.cwd});
        try writer.print("  Diff:     {s}\n", .{s.diff_ref});
        try writer.print("  Files:    {d}\n", .{s.files.len});
        try writer.writeAll("\n");
    }
}

// =============================================================================
// Argument Parsing
// =============================================================================

pub fn parseArgs(args: []const []const u8) Args {
    var result = Args{};

    // Skip "skim sessions list"
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            result.json = true;
        }
    }

    return result;
}

// =============================================================================
// Help
// =============================================================================

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\skim sessions - List running skim sessions
        \\
        \\USAGE:
        \\    skim sessions list [OPTIONS]
        \\
        \\OPTIONS:
        \\    --json    Output in JSON format
        \\    -h, --help    Print this help message
        \\
        \\EXAMPLES:
        \\    skim sessions list           # Human-readable output
        \\    skim sessions list --json    # JSON output
        \\
    );
}
