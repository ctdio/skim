const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// =============================================================================
// Codex Process
// =============================================================================

/// Manages a codex app-server subprocess.
/// Spawns `codex app-server` with stdio pipes for JSON-RPC communication.
pub const CodexProcess = struct {
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
        SpawnFailed,
    } || Allocator.Error || std.process.Child.SpawnError;

    /// Spawn a new codex app-server process.
    /// The command should be the path to the codex binary.
    /// Extra args are appended after "app-server".
    pub fn spawn(allocator: Allocator, command: []const u8, args: ?[]const []const u8, cwd: ?[]const u8) SpawnError!*CodexProcess {
        const self = try allocator.create(CodexProcess);
        errdefer allocator.destroy(self);

        const extra = args orelse &[_][]const u8{};
        const argv = try buildArgv(allocator, command, extra);
        defer allocator.free(argv);

        self.* = .{
            .allocator = allocator,
            .child = std.process.Child.init(argv, allocator),
            .stdin = undefined,
            .stdout = undefined,
            .stderr = null,
            .status = .running,
        };

        if (cwd) |dir| {
            self.child.cwd = dir;
        }

        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Ignore;

        self.child.spawn() catch |err| {
            std.log.err("Codex: Failed to spawn process: {}", .{err});
            return error.SpawnFailed;
        };

        self.stdin = self.child.stdin.?;
        self.stdout = self.child.stdout.?;

        return self;
    }

    /// Spawn a process with an explicit argv (for testing or custom commands).
    /// Unlike spawn(), this does NOT prepend "app-server" to the arguments.
    pub fn spawnRaw(allocator: Allocator, argv: []const []const u8) SpawnError!*CodexProcess {
        const self = try allocator.create(CodexProcess);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .child = std.process.Child.init(argv, allocator),
            .stdin = undefined,
            .stdout = undefined,
            .stderr = null,
            .status = .running,
        };

        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Ignore;

        self.child.spawn() catch |err| {
            std.log.err("Codex: Failed to spawn process: {}", .{err});
            return error.SpawnFailed;
        };

        self.stdin = self.child.stdin.?;
        self.stdout = self.child.stdout.?;

        return self;
    }

    /// Write data to the process stdin
    pub fn write(self: *CodexProcess, data: []const u8) !void {
        if (self.status != .running) return error.BrokenPipe;
        try self.stdin.writeAll(data);
    }

    /// Check if process is still running
    pub fn isAlive(self: *CodexProcess) bool {
        return self.status == .running;
    }

    /// Terminate the process gracefully.
    /// Kills the entire process group to ensure child subprocesses are terminated.
    pub fn terminate(self: *CodexProcess) void {
        if (self.status != .running) return;

        if (self.child.stdin) |_| {
            self.stdin.close();
            self.child.stdin = null;
        }

        // Kill entire process group to terminate child subprocesses
        _ = posix.kill(-self.child.id, posix.SIG.TERM) catch {
            _ = posix.kill(self.child.id, posix.SIG.TERM) catch {};
        };
        _ = self.child.wait() catch {};
        self.status = .exited;
    }

    /// Force kill the process
    pub fn kill(self: *CodexProcess) void {
        if (self.status != .running) return;

        _ = posix.kill(-self.child.id, posix.SIG.KILL) catch {
            _ = posix.kill(self.child.id, posix.SIG.KILL) catch {};
        };
        _ = self.child.wait() catch {};
        self.status = .crashed;
    }

    pub fn deinit(self: *CodexProcess) void {
        self.terminate();
        self.allocator.destroy(self);
    }
};

// =============================================================================
// Helpers
// =============================================================================

/// Build argv: [command, ...extra_args]
/// The caller provides all arguments (e.g. "app-server") via extra_args.
fn buildArgv(allocator: Allocator, command: []const u8, extra_args: []const []const u8) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, 1 + extra_args.len);
    argv[0] = command;
    for (extra_args, 0..) |arg, i| {
        argv[1 + i] = arg;
    }
    return argv;
}

// =============================================================================
// Tests
// =============================================================================

test "spawn and terminate process" {
    const allocator = std.testing.allocator;

    // Use spawnRaw with /bin/sleep to test process lifecycle
    var proc = try CodexProcess.spawnRaw(allocator, &.{ "/bin/sleep", "10" });
    defer proc.deinit();

    try std.testing.expect(proc.isAlive());
    try std.testing.expectEqual(CodexProcess.Status.running, proc.status);

    proc.terminate();

    try std.testing.expect(!proc.isAlive());
    try std.testing.expectEqual(CodexProcess.Status.exited, proc.status);
}

test "write to process stdin" {
    const allocator = std.testing.allocator;

    var proc = try CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    defer proc.deinit();

    try proc.write("hello\n");
}

test "double terminate is safe" {
    const allocator = std.testing.allocator;

    var proc = try CodexProcess.spawnRaw(allocator, &.{ "/bin/sleep", "10" });
    defer proc.deinit();

    proc.terminate();
    try std.testing.expectEqual(CodexProcess.Status.exited, proc.status);

    proc.terminate();
    try std.testing.expectEqual(CodexProcess.Status.exited, proc.status);
}

test "kill sets crashed status" {
    const allocator = std.testing.allocator;

    var proc = try CodexProcess.spawnRaw(allocator, &.{ "/bin/sleep", "10" });
    defer proc.deinit();

    proc.kill();
    try std.testing.expectEqual(CodexProcess.Status.crashed, proc.status);
}

test "buildArgv passes args through" {
    const allocator = std.testing.allocator;

    const argv = try buildArgv(allocator, "codex", &.{ "app-server", "--flag", "value" });
    defer allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("codex", argv[0]);
    try std.testing.expectEqualStrings("app-server", argv[1]);
    try std.testing.expectEqualStrings("--flag", argv[2]);
    try std.testing.expectEqualStrings("value", argv[3]);
}

test "buildArgv with no extra args" {
    const allocator = std.testing.allocator;

    const argv = try buildArgv(allocator, "/usr/bin/codex", &.{});
    defer allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 1), argv.len);
    try std.testing.expectEqualStrings("/usr/bin/codex", argv[0]);
}
