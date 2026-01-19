//! CLI command: skim context
//!
//! Gets context information from a running skim TUI session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const client = @import("client.zig");

// =============================================================================
// Write Buffers (Zig 0.15 requires buffers for file.writer())
// =============================================================================

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

// =============================================================================
// Arguments
// =============================================================================

pub const Args = struct {
    session_pid: ?std.posix.pid_t = null,
    json: bool = false,
};

// =============================================================================
// Command Implementation
// =============================================================================

pub fn run(allocator: Allocator, args: Args) !void {
    var conn = client.autoConnect(allocator, args.session_pid) catch |err| {
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
    defer conn.deinit();

    var response = conn.request("get_context", "ctx-1", null) catch |err| {
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
                try outputHuman(stdout, result);
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

fn outputJson(allocator: Allocator, writer: anytype, result: std.json.Value) !void {
    // Serialize the result JSON to output
    var alloc_writer: std.io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &alloc_writer.writer };
    stringify.write(result) catch return error.JsonSerializationFailed;
    try writer.writeAll(alloc_writer.written());
    try writer.writeAll("\n");
}

fn outputHuman(writer: anytype, result: std.json.Value) !void {
    if (result != .object) {
        try writer.writeAll("Invalid response format\n");
        return;
    }

    const obj = result.object;

    // CWD
    if (obj.get("cwd")) |cwd| {
        if (cwd == .string) {
            try writer.print("Working Directory: {s}\n", .{cwd.string});
        }
    }

    // Diff ref
    if (obj.get("diff_ref")) |diff_ref| {
        if (diff_ref == .string) {
            try writer.print("Diff Reference: {s}\n", .{diff_ref.string});
        }
    }

    // Files
    if (obj.get("files")) |files| {
        if (files == .array) {
            try writer.print("\nFiles ({d}):\n", .{files.array.items.len});
            for (files.array.items) |file| {
                if (file == .object) {
                    const file_obj = file.object;
                    if (file_obj.get("path")) |path| {
                        if (path == .string) {
                            try writer.print("  - {s}", .{path.string});
                            if (file_obj.get("status")) |status| {
                                if (status == .string) {
                                    try writer.print(" ({s})", .{status.string});
                                }
                            }
                            try writer.writeAll("\n");
                        }
                    }
                }
            }
        }
    }

    // Comments
    if (obj.get("comments")) |comments| {
        if (comments == .array) {
            if (comments.array.items.len > 0) {
                try writer.print("\nComments ({d}):\n", .{comments.array.items.len});
                for (comments.array.items) |comment| {
                    if (comment == .object) {
                        const c = comment.object;
                        const file = if (c.get("file")) |f| if (f == .string) f.string else "?" else "?";
                        const line = if (c.get("line")) |l| if (l == .integer) @as(i64, l.integer) else 0 else 0;
                        const text = if (c.get("text")) |t| if (t == .string) t.string else "" else "";
                        try writer.print("  [{s}:{d}] {s}\n", .{ file, line, text });
                    }
                }
            }
        }
    }
}

// =============================================================================
// Argument Parsing
// =============================================================================

pub fn parseArgs(args: []const []const u8) Args {
    var result = Args{};

    // Skip "skim context"
    var i: usize = 2;
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

// =============================================================================
// Help
// =============================================================================

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\skim context - Get diff context from a running session
        \\
        \\USAGE:
        \\    skim context [OPTIONS]
        \\
        \\OPTIONS:
        \\    --session, -s <PID>    Target specific session by PID
        \\    --json                 Output in JSON format
        \\    -h, --help             Print this help message
        \\
        \\EXAMPLES:
        \\    skim context               # Get context from only/matching session
        \\    skim context --json        # JSON output
        \\    skim context -s 12345      # Target specific session
        \\
    );
}
