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

        // Build argv: command + args
        const argv = try buildArgv(allocator, config.command, config.args);
        defer allocator.free(argv);

        // Initialize child process
        self.* = .{
            .allocator = allocator,
            .child = std.process.Child.init(argv, allocator),
            .stdin = undefined,
            .stdout = undefined,
            .stderr = null,
            .status = .running,
        };

        // Set working directory if provided
        if (config.cwd) |cwd| {
            self.child.cwd = cwd;
        }

        // Configure stdio
        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Pipe;

        // Spawn the process
        self.child.spawn() catch |err| {
            std.log.err("Failed to spawn agent process: {}", .{err});
            return error.SpawnFailed;
        };

        self.stdin = self.child.stdin.?;
        self.stdout = self.child.stdout.?;
        self.stderr = self.child.stderr;

        // Set stdout to non-blocking for async reads
        setNonBlocking(self.stdout) catch |err| {
            std.log.warn("Failed to set stdout non-blocking: {}", .{err});
        };

        return self;
    }

    /// Write data to agent's stdin
    pub fn write(self: *AgentProcess, data: []const u8) !void {
        if (self.status != .running) return error.ProcessNotRunning;
        try self.stdin.writeAll(data);
    }

    /// Read available data from agent's stdout (non-blocking)
    /// Returns null if no data available, empty slice on EOF
    pub fn readAvailable(self: *AgentProcess, buffer: []u8) !?[]u8 {
        if (self.status != .running) return null;

        const n = self.stdout.read(buffer) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (n == 0) {
            // EOF - agent closed stdout
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
    pub fn terminate(self: *AgentProcess) void {
        if (self.status != .running) return;

        // Close stdin to signal EOF to agent
        // Null out child.stdin to prevent wait() from double-closing
        if (self.child.stdin) |_| {
            self.stdin.close();
            self.child.stdin = null;
        }

        // Try graceful termination with SIGTERM
        _ = posix.kill(self.child.id, posix.SIG.TERM) catch {};

        // Wait briefly for exit
        _ = self.child.wait() catch {};
        self.status = .exited;
    }

    /// Force kill the agent process
    pub fn kill(self: *AgentProcess) void {
        if (self.status != .running) return;

        _ = posix.kill(self.child.id, posix.SIG.KILL) catch {};

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
    for (args, 1..) |arg, i| {
        argv[i] = arg;
    }
    return argv;
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
