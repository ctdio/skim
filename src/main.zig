const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("app.zig").App;
const DiffSource = @import("git/diff.zig").DiffSource;
const McpServer = @import("mcp/server.zig").McpServer;
const adapter = @import("mcp/adapter.zig");
const logging = @import("logging.zig");
const app_config = @import("config.zig");
const cli = @import("cli/mod.zig");

/// Override std.log to use file-based logging
pub const std_options = std.Options{
    .logFn = logging.logFn,
    .log_level = .debug,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for subcommands first
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "session")) {
            return cli.session.run(allocator, args);
        } else if (std.mem.eql(u8, args[1], "sessions")) {
            // Legacy: `skim sessions` -> `skim session list`
            return runSessionsCommand(allocator, args);
        } else if (std.mem.eql(u8, args[1], "context")) {
            // Legacy: `skim context` -> `skim session context`
            return runContextCommand(allocator, args);
        } else if (std.mem.eql(u8, args[1], "comment")) {
            // Legacy: `skim comment` -> `skim session comment`
            return runCommentCommand(allocator, args);
        } else if (std.mem.eql(u8, args[1], "mcp")) {
            if (!app_config.isMcpEnabled(allocator)) {
                printMcpDisabledMessage();
                std.process.exit(1);
            }
            logging.init(.mcp);
            defer logging.deinit();
            return runMcpCommand(allocator, args);
        } else if (std.mem.eql(u8, args[1], "diff")) {
            // `skim diff [args]` is an alias for `skim [args]`
            // Strip the "diff" subcommand and parse remaining args
            logging.init(.tui);
            defer logging.deinit();

            std.log.info("TUI starting up (diff subcommand)", .{});

            // Check for piped stdin (pager mode)
            const stdin_content = try readStdinIfPiped(allocator);

            // Create a new args slice without the "diff" subcommand
            var diff_args = try allocator.alloc([]const u8, args.len - 1);
            defer allocator.free(diff_args);
            diff_args[0] = args[0]; // Keep program name
            for (args[2..], 0..) |arg, i| {
                diff_args[i + 1] = arg;
            }

            var config = try parseArgs(allocator, diff_args);
            defer config.deinit();

            // If stdin was piped, use it as the diff source
            if (stdin_content) |content| {
                config.stdin_content = content;
                config.diff_source = .stdin;
                std.log.info("Pager mode: reading diff from stdin ({d} bytes)", .{content.len});
            }

            var app = try App.init(allocator, config);
            defer app.deinit();

            try app.run();
            return;
        } else if (std.mem.eql(u8, args[1], "agent")) {
            // `skim agent` starts the agent panel directly
            if (!app_config.isAcpEnabled(allocator)) {
                printAcpDisabledMessage();
                std.process.exit(1);
            }
            logging.init(.tui);
            defer logging.deinit();

            std.log.info("TUI starting up (agent mode)", .{});

            const config = Config{
                .allocator = allocator,
                .diff_source = .{ .working_dir = .{ .staged = false } },
                .stdin_content = null,
                .mcp_port = null,
                .serve_port = null,
                .agent_only = true,
            };
            defer config.deinit();

            var app = try App.init(allocator, config);
            defer app.deinit();

            try app.run();
            return;
        }
    }

    // Initialize TUI logging
    logging.init(.tui);
    defer logging.deinit();

    std.log.info("TUI starting up", .{});

    // Check for piped stdin (pager mode) BEFORE initializing TUI
    const stdin_content = try readStdinIfPiped(allocator);

    var config = try parseArgs(allocator, args);
    defer config.deinit();

    // If stdin was piped, use it as the diff source
    if (stdin_content) |content| {
        config.stdin_content = content;
        config.diff_source = .stdin;
        std.log.info("Pager mode: reading diff from stdin ({d} bytes)", .{content.len});
    }

    // Check if we should run as MCP server (deprecated --serve flag)
    if (config.serve_port) |port| {
        std.debug.print("Warning: --serve is deprecated.\n", .{});

        const server = try McpServer.init(allocator, port);
        defer server.deinit();

        try server.start();
        try server.run();
        return;
    }

    // Initialize and run the app
    var app = try App.init(allocator, config);
    defer app.deinit();

    try app.run();
}

// =============================================================================
// Subcommand Handlers
// =============================================================================

fn runMcpCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stdio_mode = false;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--stdio")) {
            stdio_mode = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try printMcpHelp();
            std.process.exit(0);
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            try printMcpHelp();
            std.process.exit(1);
        }
    }

    if (!stdio_mode) {
        std.debug.print("Error: --stdio flag is required\n\n", .{});
        try printMcpHelp();
        std.process.exit(1);
    }

    try adapter.runAdapter(allocator);
}

/// Write buffer for stdout (Zig 0.15 requires buffer for file.writer())
var stdout_buffer: [4096]u8 = undefined;

fn runSessionsCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Handle `skim sessions list` (or just `skim sessions`)
    if (args.len >= 3 and std.mem.eql(u8, args[2], "list")) {
        const parsed = cli.sessions.parseArgs(args);
        try cli.sessions.run(allocator, parsed);
    } else if (args.len >= 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
        defer file_writer.interface.flush() catch {};
        try cli.sessions.printHelp(&file_writer.interface);
    } else if (args.len == 2) {
        // `skim sessions` defaults to list
        const parsed = cli.sessions.Args{};
        try cli.sessions.run(allocator, parsed);
    } else {
        std.debug.print("Unknown sessions subcommand. Use 'skim sessions list'.\n", .{});
        std.process.exit(1);
    }
}

fn runContextCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Check for help
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
            defer file_writer.interface.flush() catch {};
            try cli.context.printHelp(&file_writer.interface);
            return;
        }
    }

    const parsed = cli.context.parseArgs(args);
    try cli.context.run(allocator, parsed);
}

fn runCommentCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
        defer file_writer.interface.flush() catch {};
        try cli.comment.printHelp(&file_writer.interface);
        std.process.exit(1);
    }

    // Check for help
    if (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h")) {
        var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
        defer file_writer.interface.flush() catch {};
        try cli.comment.printHelp(&file_writer.interface);
        return;
    }

    if (std.mem.eql(u8, args[2], "add")) {
        const parsed = cli.comment.parseAddArgs(args);
        try cli.comment.runAdd(allocator, parsed);
    } else if (std.mem.eql(u8, args[2], "list")) {
        const parsed = cli.comment.parseListArgs(args);
        try cli.comment.runList(allocator, parsed);
    } else if (std.mem.eql(u8, args[2], "delete")) {
        const parsed = cli.comment.parseDeleteArgs(args);
        try cli.comment.runDelete(allocator, parsed);
    } else {
        std.debug.print("Unknown comment subcommand: {s}\n", .{args[2]});
        std.debug.print("Use 'skim comment --help' for usage.\n", .{});
        std.process.exit(1);
    }
}

fn printMcpDisabledMessage() void {
    std.debug.print(
        \\MCP features are experimental and disabled by default.
        \\
        \\To enable, add to ~/.skim/config.json:
        \\  {{
        \\    "experimental": {{
        \\      "mcp_enabled": true
        \\    }}
        \\  }}
        \\
    , .{});
}

fn printAcpDisabledMessage() void {
    std.debug.print(
        \\ACP (Agent Client Protocol) is experimental and disabled by default.
        \\
        \\To enable, add to ~/.skim/config.json:
        \\  {{
        \\    "experimental": {{
        \\      "acp_enabled": true
        \\    }}
        \\  }}
        \\
    , .{});
}

fn printMcpHelp() !void {
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    const stdout = &file_writer.interface;
    try stdout.writeAll(
        \\skim mcp - Run as MCP adapter (for AI agents)
        \\
        \\USAGE:
        \\    skim mcp --stdio
        \\
        \\This command runs skim as an MCP adapter that connects to running
        \\skim TUI sessions. It reads MCP JSON-RPC from stdin and writes responses
        \\to stdout, suitable for use as an MCP server in Claude Desktop,
        \\Cursor, or similar AI coding assistants.
        \\
        \\The adapter automatically discovers running skim sessions via
        \\~/.skim/sessions/ and connects to them on-demand when tools are called.
        \\
        \\OPTIONS:
        \\    --stdio              Use stdio transport (required)
        \\    -h, --help           Print this help message
        \\
        \\TOOLS:
        \\    list_sessions        List all running skim TUI sessions
        \\    get_context          Get diff context and comments from a session
        \\    add_comment          Add a comment to a line in the diff
        \\    list_comments        List all comments in a session
        \\    delete_comment       Delete a comment by index
        \\
        \\CONFIGURATION:
        \\    Add to your MCP configuration (e.g., Claude Desktop):
        \\    {
        \\      "mcpServers": {
        \\        "skim": {
        \\          "command": "skim",
        \\          "args": ["mcp", "--stdio"]
        \\        }
        \\      }
        \\    }
        \\
    );
}

const Config = struct {
    allocator: std.mem.Allocator,
    diff_source: DiffSource,
    stdin_content: ?[]const u8, // Diff content from stdin (pager mode)
    mcp_port: ?u16, // Port to connect to MCP server
    serve_port: ?u16, // Port to run MCP server on
    agent_only: bool, // Start in agent-only mode (no diff view)

    fn deinit(self: *const Config) void {
        // Free stdin_content if we own it
        if (self.stdin_content) |content| {
            self.allocator.free(content);
        }

        switch (self.diff_source) {
            .working_dir, .stdin => {},
            .single_ref => |sr| {
                self.allocator.free(sr.ref);
            },
            .two_refs => |tr| {
                self.allocator.free(tr.ref1);
                self.allocator.free(tr.ref2);
            },
        }
    }
};

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var staged = false;
    var mcp_port: ?u16 = null;
    var serve_port: ?u16 = null;
    // Zig 0.15: ArrayList is now unmanaged, pass allocator to methods
    var positional_args: std.ArrayList([]const u8) = .{};
    defer positional_args.deinit(allocator);

    // Parse flags and collect positional arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "--connect")) {
            // Parse port argument
            i += 1;
            if (i >= args.len) {
                std.debug.print("--connect requires a port number\n", .{});
                try printHelp(allocator);
                std.process.exit(1);
            }
            mcp_port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("Invalid port number: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--serve")) {
            // Parse port argument (optional, defaults to 9999)
            if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                serve_port = std.fmt.parseInt(u16, args[i], 10) catch {
                    std.debug.print("Invalid port number: {s}\n", .{args[i]});
                    std.process.exit(1);
                };
            } else {
                serve_port = 9999; // Default port
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(allocator);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try printVersion();
            std.process.exit(0);
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            try printHelp(allocator);
            std.process.exit(1);
        } else {
            try positional_args.append(allocator, arg);
        }
    }

    // Build DiffSource based on positional arguments
    const diff_source = if (positional_args.items.len == 0) blk: {
        // No refs: working dir or staged
        break :blk DiffSource{ .working_dir = .{ .staged = staged } };
    } else if (positional_args.items.len == 1) blk: {
        const arg = positional_args.items[0];

        // Check for triple-dot syntax first (must come before double-dot check)
        if (std.mem.indexOf(u8, arg, "...")) |pos| {
            const ref1 = try allocator.dupe(u8, arg[0..pos]);
            const ref2 = try allocator.dupe(u8, arg[pos + 3 ..]);
            break :blk DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = true } };
        }
        // Check for double-dot syntax
        else if (std.mem.indexOf(u8, arg, "..")) |pos| {
            const ref1 = try allocator.dupe(u8, arg[0..pos]);
            const ref2 = try allocator.dupe(u8, arg[pos + 2 ..]);
            break :blk DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = false } };
        }
        // Single ref
        else {
            const ref = try allocator.dupe(u8, arg);
            break :blk DiffSource{ .single_ref = .{ .ref = ref, .staged = staged } };
        }
    } else if (positional_args.items.len == 2) blk: {
        // Two separate refs
        const ref1 = try allocator.dupe(u8, positional_args.items[0]);
        const ref2 = try allocator.dupe(u8, positional_args.items[1]);
        break :blk DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = false } };
    } else {
        std.debug.print("Too many arguments. Expected at most 2 refs.\n", .{});
        try printHelp(allocator);
        std.process.exit(1);
    };

    return Config{
        .allocator = allocator,
        .diff_source = diff_source,
        .stdin_content = null,
        .mcp_port = mcp_port,
        .serve_port = serve_port,
        .agent_only = false,
    };
}

fn readStdinIfPiped(allocator: std.mem.Allocator) !?[]const u8 {
    const stdin_file = std.fs.File.stdin();
    const stdin_is_tty = std.posix.isatty(stdin_file.handle);

    if (stdin_is_tty) {
        return null;
    }

    // Read all stdin content (max 50MB for large diffs)
    const max_size = 50 * 1024 * 1024;
    return try stdin_file.readToEndAlloc(allocator, max_size);
}

fn printHelp(allocator: std.mem.Allocator) !void {
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    const stdout = &file_writer.interface;

    const mcp_enabled = app_config.isMcpEnabled(allocator);
    const acp_enabled = app_config.isAcpEnabled(allocator);

    // Base usage
    try stdout.writeAll(
        \\skim
        \\
        \\USAGE:
        \\    skim [OPTIONS] [<ref> | <ref1> <ref2> | <ref1>..<ref2> | <ref1>...<ref2>]
        \\    skim diff [OPTIONS] [<refs>]
        \\
    );

    // Experimental subcommands in usage
    if (acp_enabled) {
        try stdout.writeAll("    skim agent\n");
    }
    if (mcp_enabled) {
        try stdout.writeAll(
            \\    skim mcp
            \\
        );
    }

    // Subcommands section
    try stdout.writeAll(
        \\
        \\SUBCOMMANDS:
        \\    diff               Review diffs (same as running skim directly)
        \\    sessions           List running skim sessions
        \\    context            Get diff context from a running session
        \\    comment            Manage comments in a running session
        \\
    );
    if (acp_enabled) {
        try stdout.writeAll("    agent              Start the AI agent panel directly (ACP mode)\n");
    }
    if (mcp_enabled) {
        try stdout.writeAll(
            \\    mcp                Run as MCP adapter (for Claude Desktop, Cursor, etc.)
            \\
        );
    }

    // Options
    try stdout.writeAll(
        \\
        \\OPTIONS:
        \\    --staged, --cached    Review staged changes (or staged vs. ref if ref provided)
        \\
    );
    if (mcp_enabled) {
        try stdout.writeAll("    --connect <port>      Override MCP client port (default: 9999, auto-connects)\n");
    }
    try stdout.writeAll(
        \\    -h, --help            Print this help message
        \\    -v, --version         Print version information
        \\
        \\DIFF PATTERNS (git-like):
        \\    <none>                Working directory vs. index
        \\    --staged              Index vs. HEAD
        \\    <ref>                 Working directory vs. ref
        \\    --staged <ref>        Index vs. ref
        \\    <ref1> <ref2>         ref1 vs. ref2
        \\    <ref1>..<ref2>        ref1 vs. ref2 (same as above)
        \\    <ref1>...<ref2>       Merge-base of ref1 and ref2 vs. ref2
        \\
        \\EXAMPLES:
        \\    skim                      # Working directory changes
        \\    skim diff main            # Working dir vs. main branch (same as 'skim main')
        \\    skim --staged             # Staged changes
        \\    skim main                 # Working dir vs. main branch
        \\    skim --staged main        # Staged vs. main branch
        \\    skim main feature         # Compare two branches
        \\    skim main..feature        # Same as above
        \\    skim main...feature       # Changes on feature since diverging from main
        \\    skim HEAD~5               # Working dir vs. 5 commits ago
        \\
    );
    if (acp_enabled) {
        try stdout.writeAll("    skim agent                # Open AI agent directly\n");
    }

    // AI integration section (only if any experimental feature is enabled)
    if (acp_enabled or mcp_enabled) {
        try stdout.writeAll("\nAI INTEGRATION:\n");
        if (acp_enabled) {
            try stdout.writeAll("    skim agent                # Open AI agent panel (full-screen)\n");
        }
        if (mcp_enabled) {
            try stdout.writeAll(
                \\    skim mcp                  # Run MCP adapter (for agent configs)
                \\
            );
        }
    }

    try stdout.writeAll(
        \\
        \\KEYBINDINGS:
        \\    h/l or Ctrl-n/p    Navigate files
        \\    j/k                Cursor up/down (vim-style)
        \\    Ctrl-d/u           Page down/up
        \\    Enter              Focus mode
        \\    c                  Add comment on cursor line
        \\    s                  Toggle split view
        \\    Ctrl-C × 2         Force exit (double-press)
        \\    ?                  Help
        \\
    );
}

fn printVersion() !void {
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    const stdout = &file_writer.interface;
    try stdout.writeAll("skim 0.1.0\n");
}

fn getCurrentPid() i32 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    } else {
        // Use extern for macOS and other POSIX systems
        const c_getpid = @extern(*const fn () callconv(.c) c_int, .{ .name = "getpid" });
        return @intCast(c_getpid());
    }
}

test "parse args: working directory" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{"skim"};

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .working_dir);
    try std.testing.expect(config.diff_source.working_dir.staged == false);
}

test "parse args: staged" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "--staged" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .working_dir);
    try std.testing.expect(config.diff_source.working_dir.staged == true);
}

test "parse args: two refs with double-dot" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main..feature" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .two_refs);
    try std.testing.expectEqualStrings("main", config.diff_source.two_refs.ref1);
    try std.testing.expectEqualStrings("feature", config.diff_source.two_refs.ref2);
    try std.testing.expect(config.diff_source.two_refs.use_merge_base == false);
}

test "parse args: single ref" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .single_ref);
    try std.testing.expectEqualStrings("main", config.diff_source.single_ref.ref);
    try std.testing.expect(config.diff_source.single_ref.staged == false);
}

test "parse args: single ref with staged" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "--staged", "main" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .single_ref);
    try std.testing.expectEqualStrings("main", config.diff_source.single_ref.ref);
    try std.testing.expect(config.diff_source.single_ref.staged == true);
}

test "parse args: two refs separated" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main", "feature" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .two_refs);
    try std.testing.expectEqualStrings("main", config.diff_source.two_refs.ref1);
    try std.testing.expectEqualStrings("feature", config.diff_source.two_refs.ref2);
    try std.testing.expect(config.diff_source.two_refs.use_merge_base == false);
}

test "parse args: two refs with triple-dot" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main...feature" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .two_refs);
    try std.testing.expectEqualStrings("main", config.diff_source.two_refs.ref1);
    try std.testing.expectEqualStrings("feature", config.diff_source.two_refs.ref2);
    try std.testing.expect(config.diff_source.two_refs.use_merge_base == true);
}

test "parse args: connect to mcp server" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "--connect", "9999" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .working_dir);
    try std.testing.expect(config.mcp_port != null);
    try std.testing.expectEqual(@as(u16, 9999), config.mcp_port.?);
}

test "parse args: connect with staged" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "--staged", "--connect", "8080" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .working_dir);
    try std.testing.expect(config.diff_source.working_dir.staged == true);
    try std.testing.expect(config.mcp_port != null);
    try std.testing.expectEqual(@as(u16, 8080), config.mcp_port.?);
}

test "parse args: agent_only is false by default" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{"skim"};

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.agent_only == false);
}

test "parse args: agent_only is false for single ref" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.agent_only == false);
}
