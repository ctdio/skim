const std = @import("std");
// Mirrors `is_web` in src/platform.zig. This subtree has its own test target
// rooted at its own directory, so it cannot import across the parent boundary.
const is_web = @import("builtin").target.cpu.arch.isWasm();
const skim_io = @import("skim_io");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// =============================================================================
// Agent Process
// =============================================================================

/// Manages an ACP agent subprocess
pub const AgentProcess = struct {
    allocator: Allocator,
    child: std.process.Child,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: ?std.Io.File,
    status: Status,

    pub const Status = enum {
        running,
        exited,
        crashed,
    };

    pub const SpawnError = error{
        CommandNotFound,
        SpawnFailed,
    } || Allocator.Error || std.process.SpawnError;

    /// Spawn a new agent process
    pub fn spawn(allocator: Allocator, config: SpawnConfig) SpawnError!*AgentProcess {
        const self = try allocator.create(AgentProcess);
        errdefer allocator.destroy(self);

        // Build argv with 'script' wrapper to force PTY/line-buffered output
        // This fixes Node.js stdout buffering when connected to pipes
        const argv = try buildArgvWithStdbuf(allocator, config.command, config.args);
        defer allocator.free(argv);

        // Extra env vars mean a full copy of the parent environment, since the
        // child either inherits it wholesale or replaces it wholesale.
        var environ_map: ?*std.process.Environ.Map = null;
        if (config.extra_env.len > 0) {
            const env_ptr = try allocator.create(std.process.Environ.Map);
            env_ptr.* = try skim_io.environMap().clone(allocator);
            environ_map = env_ptr;

            for (config.extra_env) |ev| {
                try env_ptr.put(ev.name, ev.value);
                std.log.debug("ACP: Setting env {s}=<{d} chars>", .{ ev.name, ev.value.len });
            }
        }

        std.log.info("ACP: Spawning with piped stdin, stdout, and stderr", .{});

        const child = std.process.spawn(skim_io.get(), .{
            .argv = argv,
            .cwd = if (config.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            std.log.err("Failed to spawn agent process: {}", .{err});
            return error.SpawnFailed;
        };

        self.* = .{
            .allocator = allocator,
            .child = child,
            .stdin = undefined,
            .stdout = undefined,
            .stderr = null,
            .status = .running,
        };

        self.stdin = self.child.stdin.?;
        self.stdout = self.child.stdout.?;
        self.stderr = self.child.stderr;

        return self;
    }

    /// Write data to agent's stdin
    pub fn write(self: *AgentProcess, data: []const u8) !void {
        if (self.status != .running) return error.ProcessNotRunning;
        try self.stdin.writeStreamingAll(skim_io.get(), data);
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
            _ = skim_io.readFile(stderr_file, &buffer) catch return;
        }
    }

    /// Read available data from agent's stdout (non-blocking)
    /// Returns null if no data available, empty slice on EOF
    pub fn readAvailable(self: *AgentProcess, buffer: []u8) !?[]u8 {
        if (self.status != .running) {
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

        const poll_result = posix.poll(&fds, 0) catch {
            return null;
        };

        if (poll_result == 0) {
            return null; // No data available
        }

        if (fds[0].revents & posix.POLL.IN == 0) {
            if (fds[0].revents & posix.POLL.HUP != 0) {
                self.status = .exited;
                return buffer[0..0];
            }
            return null;
        }

        const n = self.stdout.read(buffer) catch |err| {
            return err;
        };

        if (n == 0) {
            self.status = .exited;
            return buffer[0..0];
        }

        return buffer[0..n];
    }

    /// Check if process is still running
    pub fn isAlive(self: *AgentProcess) bool {
        return self.status == .running;
    }

    /// Terminate the agent process gracefully
    /// Kills the entire process group to ensure child subprocesses are also terminated
    pub fn terminate(self: *AgentProcess) void {
        // The browser build never spawns, and wasi has no pid to signal.
        if (is_web) return;

        if (self.status != .running) return;

        if (self.child.stdin) |_| {
            self.stdin.close(skim_io.get());
            self.child.stdin = null;
        }

        // Kill entire process group (negative PID) to terminate child subprocesses
        // claude-code-acp spawns a Node.js subprocess that would otherwise become orphaned
        // Use child.id as pgid since child processes typically inherit parent's pgid
        if (self.child.id) |child_pid| _ = posix.kill(-child_pid, posix.SIG.TERM) catch {
            // Fallback to killing just the direct child if process group kill fails
            _ = posix.kill(child_pid, posix.SIG.TERM) catch {};
        };
        _ = self.child.wait(skim_io.get()) catch {};
        self.status = .exited;
    }

    /// Force kill the agent process
    /// Kills the entire process group to ensure child subprocesses are also terminated
    pub fn kill(self: *AgentProcess) void {
        // The browser build never spawns, and wasi has no pid to signal.
        if (is_web) return;

        if (self.status != .running) return;

        // Kill entire process group (negative PID) to terminate child subprocesses
        if (self.child.id) |child_pid| _ = posix.kill(-child_pid, posix.SIG.KILL) catch {
            // Fallback to killing just the direct child if process group kill fails
            _ = posix.kill(child_pid, posix.SIG.KILL) catch {};
        };
        _ = self.child.wait(skim_io.get()) catch {};
        self.status = .crashed;
    }

    /// Wait for process to exit and get exit code
    pub fn wait(self: *AgentProcess) !u32 {
        const term = try self.child.wait(skim_io.get());

        // Parse termination status
        return switch (term) {
            .exited => |code| blk: {
                self.status = .exited;
                break :blk code;
            },
            .signal => |sig| blk: {
                self.status = .crashed;
                break :blk @as(u32, @intFromEnum(sig)) + 128;
            },
            .stopped => |sig| blk: {
                self.status = .crashed;
                break :blk @as(u32, @intFromEnum(sig)) + 128;
            },
            .unknown => blk: {
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

/// Environment variable for agent process
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const SpawnConfig = struct {
    /// Command to execute (e.g., "claude", "/usr/bin/gemini")
    command: []const u8,
    /// Arguments to pass to command
    args: []const []const u8 = &.{},
    /// Working directory (null = inherit)
    cwd: ?[]const u8 = null,
    /// Extra environment variables to set (in addition to inherited env)
    extra_env: []const EnvVar = &.{},
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
    // TEMPORARILY DISABLED: Testing if script wrapper causes mode setting issues
    // The script wrapper echoes input which may interfere with request/response handling
    _ = command;
    return false;
    // Only wrap known ACP agent commands that are Node.js-based
    // return std.mem.indexOf(u8, command, "claude-code-acp") != null or
    //     std.mem.indexOf(u8, command, "gemini-cli") != null or
    //     std.mem.indexOf(u8, command, "codex") != null;
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

fn setNonBlocking(file: std.Io.File) !void {
    try skim_io.setNonBlocking(file.handle, true);
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
    process.stdin.close(skim_io.get());
    process.child.stdin = null;

    // Set stdout to blocking for this test
    try skim_io.setNonBlocking(process.stdout.handle, false);

    // Read output before wait (data should be available)
    var buffer: [1024]u8 = undefined;
    const n = try skim_io.readFile(process.stdout, &buffer);
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
