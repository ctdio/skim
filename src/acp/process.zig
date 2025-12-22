const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// =============================================================================
// Agent Process
// =============================================================================

/// Manages an ACP agent subprocess
pub const AgentProcess = struct {
    allocator: Allocator,
    child: std.process.Child,
    stdin: std.fs.File,
    stdout: std.fs.File,
    stderr: ?std.fs.File,
    status: Status,

    pub const Status = enum {
        running,
        exited,
        crashed,
    };

    pub const SpawnError = error{
        CommandNotFound,
        SpawnFailed,
    } || Allocator.Error || std.process.Child.SpawnError;

    /// Spawn a new agent process
    pub fn spawn(allocator: Allocator, config: SpawnConfig) SpawnError!*AgentProcess {
        const self = try allocator.create(AgentProcess);
        errdefer allocator.destroy(self);

        // Build argv with 'script' wrapper to force PTY/line-buffered output
        // This fixes Node.js stdout buffering when connected to pipes
        const argv = try buildArgvWithStdbuf(allocator, config.command, config.args);
        defer allocator.free(argv);

        self.* = .{
            .allocator = allocator,
            .child = std.process.Child.init(argv, allocator),
            .stdin = undefined,
            .stdout = undefined,
            .stderr = null,
            .status = .running,
        };

        if (config.cwd) |cwd| {
            self.child.cwd = cwd;
        }

        // Log if the CLAUDE_CODE_OAUTH_TOKEN is available (for debugging)
        if (std.posix.getenv("CLAUDE_CODE_OAUTH_TOKEN")) |_| {
            std.log.info("ACP: CLAUDE_CODE_OAUTH_TOKEN is present in environment", .{});
        } else {
            std.log.warn("ACP: CLAUDE_CODE_OAUTH_TOKEN NOT found in environment!", .{});
        }

        // Log file descriptors for debugging
        std.log.info("ACP: Spawning with stdin_behavior=Pipe, stdout_behavior=Pipe", .{});

        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Pipe;

        self.child.spawn() catch |err| {
            std.log.err("Failed to spawn agent process: {}", .{err});
            return error.SpawnFailed;
        };

        self.stdin = self.child.stdin.?;
        self.stdout = self.child.stdout.?;
        self.stderr = self.child.stderr;

        return self;
    }

    /// Write data to agent's stdin
    pub fn write(self: *AgentProcess, data: []const u8) !void {
        if (self.status != .running) return error.ProcessNotRunning;
        std.log.debug("ACP Process: writing {d} bytes to stdin: {s}", .{ data.len, data });
        try self.stdin.writeAll(data);
        std.log.debug("ACP Process: write completed", .{});
    }

    /// Check and log stderr output (for debugging)
    pub fn checkStderr(self: *AgentProcess) void {
        const stderr_file = self.stderr orelse return;

        var buffer: [4096]u8 = undefined;

        // Use poll to check if stderr has data
        var fds = [_]posix.pollfd{
            .{
                .fd = stderr_file.handle,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const poll_result = posix.poll(&fds, 0) catch return;
        if (poll_result == 0) return;

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = stderr_file.read(&buffer) catch return;
            if (n > 0) {
                std.log.debug("ACP Process STDERR: {s}", .{buffer[0..n]});
            }
        }
    }

    /// Read available data from agent's stdout (non-blocking)
    /// Returns null if no data available, empty slice on EOF
    pub fn readAvailable(self: *AgentProcess, buffer: []u8) !?[]u8 {
        if (self.status != .running) {
            std.log.debug("ACP Process: readAvailable skipped - not running", .{});
            return null;
        }

        // Use poll to check if data is available (non-blocking, timeout=0)
        var fds = [_]posix.pollfd{
            .{
                .fd = self.stdout.handle,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const poll_result = posix.poll(&fds, 0) catch |err| {
            std.log.debug("ACP Process: poll error: {}", .{err});
            return null;
        };

        if (poll_result == 0) {
            return null; // No data available
        }

        std.log.debug("ACP Process: poll returned {d}, revents=0x{x}", .{ poll_result, fds[0].revents });

        if (fds[0].revents & posix.POLL.IN == 0) {
            if (fds[0].revents & posix.POLL.HUP != 0) {
                std.log.debug("ACP Process: HUP received", .{});
                self.status = .exited;
                return buffer[0..0];
            }
            std.log.debug("ACP Process: poll returned but no IN flag", .{});
            return null;
        }

        const n = self.stdout.read(buffer) catch |err| {
            std.log.debug("ACP Process: read error: {}", .{err});
            return err;
        };

        if (n == 0) {
            std.log.debug("ACP Process: EOF received", .{});
            self.status = .exited;
            return buffer[0..0];
        }

        std.log.debug("ACP Process: read {d} bytes", .{n});
        return buffer[0..n];
    }

    /// Check if process is still running
    pub fn isAlive(self: *AgentProcess) bool {
        return self.status == .running;
    }

    /// Terminate the agent process gracefully
    /// Kills the entire process group to ensure child subprocesses are also terminated
    pub fn terminate(self: *AgentProcess) void {
        if (self.status != .running) return;

        if (self.child.stdin) |_| {
            self.stdin.close();
            self.child.stdin = null;
        }

        // Kill entire process group (negative PID) to terminate child subprocesses
        // claude-code-acp spawns a Node.js subprocess that would otherwise become orphaned
        // Use child.id as pgid since child processes typically inherit parent's pgid
        _ = posix.kill(-self.child.id, posix.SIG.TERM) catch {
            // Fallback to killing just the direct child if process group kill fails
            _ = posix.kill(self.child.id, posix.SIG.TERM) catch {};
        };
        _ = self.child.wait() catch {};
        self.status = .exited;
    }

    /// Force kill the agent process
    /// Kills the entire process group to ensure child subprocesses are also terminated
    pub fn kill(self: *AgentProcess) void {
        if (self.status != .running) return;

        // Kill entire process group (negative PID) to terminate child subprocesses
        _ = posix.kill(-self.child.id, posix.SIG.KILL) catch {
            // Fallback to killing just the direct child if process group kill fails
            _ = posix.kill(self.child.id, posix.SIG.KILL) catch {};
        };
        _ = self.child.wait() catch {};
        self.status = .crashed;
    }

    /// Wait for process to exit and get exit code
    pub fn wait(self: *AgentProcess) !u32 {
        const term = try self.child.wait();

        // Parse termination status
        return switch (term) {
            .Exited => |code| blk: {
                self.status = .exited;
                break :blk code;
            },
            .Signal => |sig| blk: {
                self.status = .crashed;
                break :blk @intCast(sig + 128);
            },
            .Stopped => |sig| blk: {
                self.status = .crashed;
                break :blk @intCast(sig + 128);
            },
            .Unknown => blk: {
                self.status = .crashed;
                break :blk 128;
            },
        };
    }

    pub fn deinit(self: *AgentProcess) void {
        self.terminate();
        self.allocator.destroy(self);
    }
};

// =============================================================================
// Spawn Configuration
// =============================================================================

pub const SpawnConfig = struct {
    /// Command to execute (e.g., "claude", "/usr/bin/gemini")
    command: []const u8,
    /// Arguments to pass to command
    args: []const []const u8 = &.{},
    /// Working directory (null = inherit)
    cwd: ?[]const u8 = null,
    /// Environment variables (null = inherit)
    env: ?*const std.process.EnvMap = null,
};

// =============================================================================
// Helper Functions
// =============================================================================

fn buildArgv(allocator: Allocator, command: []const u8, args: []const []const u8) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, 1 + args.len);
    argv[0] = command;
    for (args, 0..) |arg, i| {
        argv[1 + i] = arg;
    }
    return argv;
}

/// Check if a command needs PTY wrapping for stdout buffering fix.
/// This is needed for Node.js processes (like claude-code-acp) which fully buffer stdout
/// when connected to pipes instead of TTY.
fn needsPtyWrapper(command: []const u8) bool {
    // Only wrap known ACP agent commands that are Node.js-based
    return std.mem.indexOf(u8, command, "claude-code-acp") != null or
        std.mem.indexOf(u8, command, "gemini-cli") != null or
        std.mem.indexOf(u8, command, "codex") != null;
}

/// Build argv, optionally wrapped with `script` to force PTY/line-buffered output.
/// This fixes stdout buffering issues with Node.js processes connected to pipes.
/// On macOS: script -qF /dev/null <command>
/// The -F flag forces flush after each write, -q suppresses script messages.
/// Note: script echoes input, so the transport layer must filter echoed commands.
fn buildArgvWithStdbuf(allocator: Allocator, command: []const u8, args: []const []const u8) ![]const []const u8 {
    const builtin = @import("builtin");

    // Only use script wrapper for commands that need it (Node.js-based agents)
    if (builtin.os.tag == .macos and needsPtyWrapper(command)) {
        // macOS: script -qF /dev/null command args...
        // -q = quiet (no "Script started" message)
        // -F = flush output after each write
        var argv = try allocator.alloc([]const u8, 4 + args.len);
        argv[0] = "script";
        argv[1] = "-qF";
        argv[2] = "/dev/null";
        argv[3] = command;
        for (args, 0..) |arg, i| {
            argv[4 + i] = arg;
        }
        return argv;
    } else {
        // No wrapper needed for this command, or on Linux
        return buildArgv(allocator, command, args);
    }
}

fn setNonBlocking(file: std.fs.File) !void {
    const flags = try posix.fcntl(file.handle, posix.F.GETFL, @as(u32, 0));
    _ = try posix.fcntl(file.handle, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
}

// =============================================================================
// Tests
// =============================================================================

test "spawn echo process" {
    const allocator = std.testing.allocator;

    var process = try AgentProcess.spawn(allocator, .{
        .command = "/bin/echo",
        .args = &.{"hello"},
    });
    defer process.deinit();

    try std.testing.expect(process.isAlive());

    // Wait for process to complete
    const exit_code = try process.wait();
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    try std.testing.expect(!process.isAlive());
}

test "spawn cat and write/read" {
    const allocator = std.testing.allocator;

    var process = try AgentProcess.spawn(allocator, .{
        .command = "/bin/cat",
    });
    defer process.deinit();

    // Write to stdin
    try process.write("hello\n");

    // Close stdin to signal EOF to cat
    // Also null out child.stdin to prevent wait() from double-closing
    process.stdin.close();
    process.child.stdin = null;

    // Set stdout to blocking for this test
    const flags = try posix.fcntl(process.stdout.handle, posix.F.GETFL, @as(u32, 0));
    _ = try posix.fcntl(process.stdout.handle, posix.F.SETFL, flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

    // Read output before wait (data should be available)
    var buffer: [1024]u8 = undefined;
    const n = try process.stdout.read(&buffer);
    try std.testing.expectEqualStrings("hello\n", buffer[0..n]);

    // Now wait for process
    _ = try process.wait();
}

test "terminate process" {
    const allocator = std.testing.allocator;

    // Start a long-running process
    var process = try AgentProcess.spawn(allocator, .{
        .command = "/bin/sleep",
        .args = &.{"10"},
    });
    defer process.deinit();

    try std.testing.expect(process.isAlive());

    // Terminate it
    process.terminate();

    try std.testing.expect(!process.isAlive());
    try std.testing.expectEqual(AgentProcess.Status.exited, process.status);
}
