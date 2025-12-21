const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("app.zig").App;
const DiffSource = @import("git/diff.zig").DiffSource;
const McpServer = @import("mcp/server.zig").McpServer;
const Daemon = @import("mcp/daemon.zig").Daemon;
const adapter = @import("mcp/adapter.zig");
const discovery = @import("mcp/discovery.zig");
const logging = @import("logging.zig");

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
        if (std.mem.eql(u8, args[1], "daemon")) {
            logging.init(.daemon);
            defer logging.deinit();
            return runDaemonCommand(allocator, args);
        } else if (std.mem.eql(u8, args[1], "mcp")) {
            logging.init(.mcp);
            defer logging.deinit();
            return runMcpCommand(allocator, args);
        }
    }

    // Initialize TUI logging
    logging.init(.tui);
    defer logging.deinit();

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    // Check if we should run as MCP server (deprecated --serve flag)
    if (config.serve_port) |port| {
        std.debug.print("Warning: --serve is deprecated. Use 'skim daemon start' instead.\n", .{});

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

fn runDaemonCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        try printDaemonHelp();
        std.process.exit(1);
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "start")) {
        // Parse optional arguments
        var tui_port: u16 = discovery.DEFAULT_TUI_PORT;
        var adapter_port: u16 = discovery.DEFAULT_ADAPTER_PORT;
        var foreground = false;

        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
                i += 1;
                if (i >= args.len) {
                    std.debug.print("--port requires a port number\n", .{});
                    std.process.exit(1);
                }
                tui_port = std.fmt.parseInt(u16, args[i], 10) catch {
                    std.debug.print("Invalid port number: {s}\n", .{args[i]});
                    std.process.exit(1);
                };
                adapter_port = tui_port - 1; // Adapter port is one below TUI port
            } else if (std.mem.eql(u8, args[i], "--foreground") or std.mem.eql(u8, args[i], "-f")) {
                foreground = true;
            } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
                try printDaemonHelp();
                std.process.exit(0);
            }
        }

        // Check if daemon is already running
        const status = discovery.discoverDaemon(allocator);
        switch (status) {
            .running => |info| {
                std.debug.print("Daemon already running (PID {d}) on ports {d}/{d}\n", .{ info.pid, info.tui_port, info.adapter_port });
                std.process.exit(1);
            },
            .stale => {
                // Clean up stale discovery file
                discovery.deleteDiscoveryFile(allocator);
            },
            else => {},
        }

        std.debug.print("Starting skim daemon on ports {d} (TUI) and {d} (adapters)...\n", .{ tui_port, adapter_port });

        // Daemonize unless --foreground is specified
        if (!foreground) {
            const daemon_pid = try daemonize(allocator, tui_port, adapter_port);
            std.debug.print("Daemon started (PID {d})\n", .{daemon_pid});
            return; // Parent exits, daemon runs in background
        }

        // Foreground mode - run directly
        const daemon = try Daemon.init(allocator, tui_port, adapter_port);
        defer daemon.deinit();

        try daemon.start();
        std.debug.print("Daemon running in foreground (PID {d})\n", .{getCurrentPid()});
        try daemon.run();
    } else if (std.mem.eql(u8, subcommand, "stop")) {
        const status = discovery.discoverDaemon(allocator);
        switch (status) {
            .running => |info| {
                // Send SIGTERM to the daemon
                std.posix.kill(info.pid, std.posix.SIG.TERM) catch |err| {
                    if (err == error.NoSuchProcess) {
                        std.debug.print("Daemon process not found, cleaning up...\n", .{});
                        discovery.deleteDiscoveryFile(allocator);
                    }
                    return;
                };
                std.debug.print("Sent stop signal to daemon (PID {d})\n", .{info.pid});
            },
            .stale => {
                std.debug.print("Cleaning up stale daemon state...\n", .{});
                discovery.deleteDiscoveryFile(allocator);
            },
            .not_running => {
                std.debug.print("Daemon is not running\n", .{});
            },
            .unhealthy => {
                std.debug.print("Daemon appears unhealthy, cleaning up...\n", .{});
                discovery.deleteDiscoveryFile(allocator);
            },
        }
    } else if (std.mem.eql(u8, subcommand, "status")) {
        const status = discovery.discoverDaemon(allocator);
        const formatted = try discovery.formatStatus(allocator, status);
        defer allocator.free(formatted);
        std.debug.print("{s}\n", .{formatted});
    } else if (std.mem.eql(u8, subcommand, "restart")) {
        // Stop then start
        const status = discovery.discoverDaemon(allocator);
        switch (status) {
            .running => |info| {
                std.debug.print("Stopping daemon (PID {d})...\n", .{info.pid});
                std.posix.kill(info.pid, std.posix.SIG.TERM) catch {};
                // Wait a bit for it to stop
                std.Thread.sleep(500 * std.time.ns_per_ms);
            },
            else => {},
        }
        discovery.deleteDiscoveryFile(allocator);

        // Now start (restart always daemonizes)
        const restart_tui_port = discovery.DEFAULT_TUI_PORT;
        const restart_adapter_port = discovery.DEFAULT_ADAPTER_PORT;

        std.debug.print("Starting skim daemon on ports {d} (TUI) and {d} (adapters)...\n", .{ restart_tui_port, restart_adapter_port });

        const daemon_pid = try daemonize(allocator, restart_tui_port, restart_adapter_port);
        std.debug.print("Daemon started (PID {d})\n", .{daemon_pid});
    } else if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        try printDaemonHelp();
    } else {
        std.debug.print("Unknown daemon command: {s}\n", .{subcommand});
        try printDaemonHelp();
        std.process.exit(1);
    }
}

fn runMcpCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var port: u16 = discovery.DEFAULT_ADAPTER_PORT;
    var stdio_mode = false;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--stdio")) {
            stdio_mode = true;
        } else if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("--port requires a port number\n", .{});
                std.process.exit(1);
            }
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("Invalid port number: {s}\n", .{args[i]});
                std.process.exit(1);
            };
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

    try adapter.runAdapter(allocator, port);
}

/// Write buffer for stdout (Zig 0.15 requires buffer for file.writer())
var stdout_buffer: [4096]u8 = undefined;

fn printDaemonHelp() !void {
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    const stdout = &file_writer.interface;
    try stdout.writeAll(
        \\skim daemon - Manage the skim MCP daemon
        \\
        \\USAGE:
        \\    skim daemon <command> [OPTIONS]
        \\
        \\COMMANDS:
        \\    start      Start the daemon
        \\    stop       Stop the daemon
        \\    status     Show daemon status
        \\    restart    Restart the daemon
        \\
        \\OPTIONS:
        \\    -p, --port <port>    Set TUI port (default: 9999, adapter port is TUI-1)
        \\    -f, --foreground     Run in foreground (don't daemonize)
        \\    -h, --help           Print this help message
        \\
        \\EXAMPLES:
        \\    skim daemon start              # Start daemon in background
        \\    skim daemon start --foreground # Run in foreground (for debugging)
        \\    skim daemon start --port 8888  # Start on custom port
        \\    skim daemon status             # Check if daemon is running
        \\    skim daemon stop               # Stop the daemon
        \\
    );
}

fn printMcpHelp() !void {
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    const stdout = &file_writer.interface;
    try stdout.writeAll(
        \\skim mcp - Run as MCP adapter (for AI agents)
        \\
        \\USAGE:
        \\    skim mcp --stdio [OPTIONS]
        \\
        \\This command runs skim as a thin MCP adapter that connects to the
        \\skim daemon. It reads MCP JSON-RPC from stdin and writes responses
        \\to stdout, suitable for use as an MCP server in Claude Desktop,
        \\Cursor, or similar AI coding assistants.
        \\
        \\OPTIONS:
        \\    --stdio              Use stdio transport (required)
        \\    -p, --port <port>    Daemon adapter port (default: 9998)
        \\    -h, --help           Print this help message
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
        \\ENVIRONMENT:
        \\    SKIM_DAEMON_AUTO_START=1   Auto-start daemon if not running
        \\
    );
}

const Config = struct {
    allocator: std.mem.Allocator,
    diff_source: DiffSource,
    mcp_port: ?u16, // Port to connect to MCP server
    serve_port: ?u16, // Port to run MCP server on

    fn deinit(self: *const Config) void {
        switch (self.diff_source) {
            .working_dir => {},
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
                try printHelp();
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
            try printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try printVersion();
            std.process.exit(0);
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            try printHelp();
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
        try printHelp();
        std.process.exit(1);
    };

    return Config{
        .allocator = allocator,
        .diff_source = diff_source,
        .mcp_port = mcp_port,
        .serve_port = serve_port,
    };
}

fn printHelp() !void {
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    const stdout = &file_writer.interface;
    try stdout.writeAll(
        \\skim - Lightning-fast code review TUI
        \\
        \\USAGE:
        \\    skim [OPTIONS] [<ref> | <ref1> <ref2> | <ref1>..<ref2> | <ref1>...<ref2>]
        \\    skim daemon <start|stop|status|restart>
        \\    skim mcp
        \\
        \\SUBCOMMANDS:
        \\    daemon             Manage the MCP daemon (for AI agent integration)
        \\    mcp                Run as MCP adapter (for Claude Desktop, Cursor, etc.)
        \\
        \\OPTIONS:
        \\    --staged, --cached    Review staged changes (or staged vs. ref if ref provided)
        \\    --connect <port>      Override MCP client port (default: 9999, auto-connects)
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
        \\    skim --staged             # Staged changes
        \\    skim main                 # Working dir vs. main branch
        \\    skim --staged main        # Staged vs. main branch
        \\    skim main feature         # Compare two branches
        \\    skim main..feature        # Same as above
        \\    skim main...feature       # Changes on feature since diverging from main
        \\    skim HEAD~5               # Working dir vs. 5 commits ago
        \\
        \\AI INTEGRATION:
        \\    skim daemon start         # Start MCP daemon
        \\    skim daemon status        # Check daemon status
        \\    skim mcp                  # Run MCP adapter (for agent configs)
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

/// Daemonize the process using double-fork pattern.
/// Returns the daemon's PID to the parent process.
/// The daemon process does not return - it runs the daemon loop.
fn daemonize(allocator: std.mem.Allocator, tui_port: u16, adapter_port: u16) !i32 {
    const posix = std.posix;
    const c = struct {
        extern "c" fn setsid() c_int;
    };

    // Create a pipe to communicate daemon PID back to parent
    const pipe_fds = try posix.pipe();
    const pipe_read = pipe_fds[0];
    const pipe_write = pipe_fds[1];

    // First fork
    const pid1 = try posix.fork();
    if (pid1 != 0) {
        // Parent: close write end, read daemon PID, return
        posix.close(pipe_write);

        var pid_buf: [16]u8 = undefined;
        const bytes_read = posix.read(pipe_read, &pid_buf) catch |err| {
            posix.close(pipe_read);
            return err;
        };
        posix.close(pipe_read);

        if (bytes_read == 0) {
            return error.DaemonFailed;
        }

        const daemon_pid = std.fmt.parseInt(i32, pid_buf[0..bytes_read], 10) catch {
            return error.DaemonFailed;
        };

        // Wait for first child to exit
        _ = posix.waitpid(pid1, 0);

        return daemon_pid;
    }

    // First child: close read end, create new session
    posix.close(pipe_read);

    // Create new session (detach from controlling terminal)
    if (c.setsid() == -1) {
        posix.close(pipe_write);
        posix.exit(1);
    }

    // Second fork (prevents reacquiring a controlling terminal)
    const pid2 = posix.fork() catch {
        posix.close(pipe_write);
        posix.exit(1);
    };

    if (pid2 != 0) {
        // First child exits, letting grandchild be adopted by init
        posix.close(pipe_write);
        posix.exit(0);
    }

    // Grandchild: this is the daemon process

    // Write our PID to the pipe
    const daemon_pid = getCurrentPid();
    var pid_str: [16]u8 = undefined;
    const pid_slice = std.fmt.bufPrint(&pid_str, "{d}", .{daemon_pid}) catch "";
    _ = posix.write(pipe_write, pid_slice) catch {};
    posix.close(pipe_write);

    // Redirect stdin/stdout/stderr to /dev/null
    const dev_null = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        posix.exit(1);
    };
    posix.dup2(dev_null, posix.STDIN_FILENO) catch {};
    posix.dup2(dev_null, posix.STDOUT_FILENO) catch {};
    posix.dup2(dev_null, posix.STDERR_FILENO) catch {};
    if (dev_null > 2) {
        posix.close(dev_null);
    }

    // Now run the daemon
    const daemon = Daemon.init(allocator, tui_port, adapter_port) catch {
        posix.exit(1);
    };
    defer daemon.deinit();

    daemon.start() catch {
        posix.exit(1);
    };

    daemon.run() catch {
        posix.exit(1);
    };

    posix.exit(0);
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
