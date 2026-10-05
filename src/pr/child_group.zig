//! Run a background worker's git/gh child, and kill it from another thread.
//! `run` spawns each child as the leader of its own process group
//! (`.pgid = 0`) and records it in a `ChildSlot`; `stop` calls `cancel`, which
//! SIGTERMs the whole group (ssh, remote helpers, gh's own children) and
//! returns. The worker notices within `cancel_poll_ns`, and its `release`
//! escalates to SIGKILL for a group that outlives the grace period, so the
//! thread calling `cancel` never waits on a child.
//! Shared by the prefetch worker and `github.runGhArgv` (the sync worker).

const std = @import("std");
const builtin = @import("builtin");
const skim_io = @import("skim_io");

/// The child a worker thread is reading from (pid 0 = none), plus a sticky
/// cancel flag so a child spawned after `cancel` is killed as soon as it is
/// held.
pub const ChildSlot = struct {
    mutex: std.Io.Mutex = .init,
    pid: std.posix.pid_t = 0,
    canceled: bool = false,

    /// Record the child the caller is about to read from. A child held after
    /// `cancel` gets SIGTERM at once: nothing will use its output, and
    /// `cancel` may already have looked for a child to signal.
    pub fn hold(self: *ChildSlot, pid: std.posix.pid_t) void {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        self.pid = pid;
        if (self.canceled) _ = signalGroup(pid, std.posix.SIG.TERM);
    }

    /// Forget the child, killing its group first when `kill_group` (the caller
    /// is abandoning it) or the slot was canceled. Call from the thread that
    /// reaps the child, before reaping it, so its pid (and process group id)
    /// cannot have been reused by the time it is signalled. The kill runs the
    /// full SIGTERM-then-SIGKILL escalation outside the mutex, so a concurrent
    /// `cancel` never waits for it.
    pub fn release(self: *ChildSlot, params: struct { kill_group: bool }) void {
        self.mutex.lockUncancelable(skim_io.get());
        const pid = self.pid;
        const kill = pid != 0 and (params.kill_group or self.canceled);
        self.pid = 0;
        self.mutex.unlock(skim_io.get());
        if (kill) killGroup(pid);
    }

    /// Mark the slot canceled and SIGTERM the held child's group, if any.
    /// Returns without waiting: the worker's `release` escalates to SIGKILL.
    /// Every later `hold` signals its child too.
    pub fn cancel(self: *ChildSlot) void {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        self.canceled = true;
        if (self.pid != 0) _ = signalGroup(self.pid, std.posix.SIG.TERM);
    }

    pub fn isCanceled(self: *ChildSlot) bool {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        return self.canceled;
    }
};

pub const RunParams = struct {
    /// Owns the returned output and the read buffers.
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    /// Child cwd; null inherits the caller's.
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    /// Written to the child's stdin up front, then closed; null ignores stdin.
    stdin: ?[]const u8 = null,
    stdout_limit: usize,
    stderr_limit: usize,
    timeout: Timeout,
    /// Lets another thread cancel the run; null uses a private slot.
    slot: ?*ChildSlot = null,
};

pub const Timeout = union(enum) {
    /// Longest wait for the next byte of output.
    idle_ns: u64,
    /// Wall-clock limit on the whole run.
    total_ns: u64,
};

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

/// How long a child's process group gets to exit on SIGTERM before SIGKILL.
const term_grace_ns = 300 * std.time.ns_per_ms;
const term_poll_ns = 10 * std.time.ns_per_ms;
/// Longest a blocked read goes without checking the slot for a cancel.
const cancel_poll_ns = 50 * std.time.ns_per_ms;

/// Spawn `argv` as the leader of its own process group, feed it `stdin`, and
/// collect its output. Every error path kills the group (SIGTERM, then
/// SIGKILL) before the child is reaped. Errors besides spawn and read
/// failures: `Canceled` (the slot was canceled, before or during the run),
/// `Timeout`, `StdoutTooLong`, `StderrTooLong`; a missing binary is
/// `FileNotFound`. Never logs at .err and never prints to stderr.
pub fn run(params: RunParams) !Output {
    var local_slot: ChildSlot = .{};
    const slot = params.slot orelse &local_slot;
    if (slot.isCanceled()) return error.Canceled;

    const io = skim_io.get();
    var child = try std.process.spawn(io, .{
        .argv = params.argv,
        .cwd = if (params.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = params.environ_map,
        .stdin = if (params.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    defer child.kill(io);
    slot.hold(child.id.?);
    var released = false;
    defer if (!released) slot.release(.{ .kill_group = true });
    if (slot.isCanceled()) return error.Canceled;

    if (params.stdin) |bytes| {
        const stdin = child.stdin.?;
        stdin.writeStreamingAll(io, bytes) catch |err| std.log.warn("child group: writing {s}'s stdin failed: {any}", .{ params.argv[0], err });
        stdin.close(io);
        child.stdin = null;
    }

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(params.allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    try readAll(.{ .reader = &reader, .slot = slot, .params = params });
    try reader.checkAnyError();
    if (slot.isCanceled()) return error.Canceled;

    released = true;
    slot.release(.{ .kill_group = false });
    const term = try child.wait(io);
    if (slot.isCanceled()) return error.Canceled;
    const stdout = try reader.toOwnedSlice(0);
    errdefer params.allocator.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

// =============================================================================
// Helpers
// =============================================================================

/// Fill `reader` until both streams end. Waits in `cancel_poll_ns` slices so
/// a cancel is noticed even while a child that ignores SIGTERM holds its
/// pipes open.
fn readAll(args: struct { reader: *std.Io.File.MultiReader, slot: *ChildSlot, params: RunParams }) !void {
    const reader = args.reader;
    var timer = try skim_io.Timer.start();
    var last_output_ns: u64 = 0;
    while (true) {
        if (args.slot.isCanceled()) return error.Canceled;
        const now_ns = timer.read();
        const limit_ns = switch (args.params.timeout) {
            .idle_ns => |ns| last_output_ns + ns,
            .total_ns => |ns| ns,
        };
        if (now_ns >= limit_ns) return error.Timeout;
        const slice: std.Io.Timeout = .{ .duration = .{
            .raw = .fromNanoseconds(@min(limit_ns - now_ns, cancel_poll_ns)),
            .clock = .awake,
        } };
        reader.fill(64, slice) catch |err| switch (err) {
            error.EndOfStream => return,
            error.Timeout => continue,
            else => |e| return e,
        };
        last_output_ns = timer.read();
        if (reader.reader(0).buffered().len > args.params.stdout_limit) return error.StdoutTooLong;
        if (reader.reader(1).buffered().len > args.params.stderr_limit) return error.StderrTooLong;
    }
}

/// SIGTERM the child's process group so git can remove its lock files, then
/// SIGKILL whatever is left once the leader has exited or `term_grace_ns`
/// has passed, whichever comes first. Only the thread that reaps the leader
/// calls this, before reaping it, so its pid cannot be reused as a group id
/// until this returns.
fn killGroup(pid: std.posix.pid_t) void {
    if (!signalGroup(pid, std.posix.SIG.TERM)) return;
    var waited_ns: u64 = 0;
    while (waited_ns < term_grace_ns) : (waited_ns += term_poll_ns) {
        skim_io.sleep(term_poll_ns);
        if (!signalGroup(pid, @enumFromInt(0))) return;
        if (leaderExited(pid)) break;
    }
    _ = signalGroup(pid, std.posix.SIG.KILL);
}

/// The unreaped leader's zombie keeps its group visible to `signalGroup`,
/// so its exit is read with `waitid(WNOWAIT)`, which leaves it for the
/// worker to reap. Linux only; elsewhere the full grace period runs.
fn leaderExited(pid: std.posix.pid_t) bool {
    if (builtin.os.tag != .linux) return false;
    const linux = std.os.linux;
    var info = std.mem.zeroes(linux.siginfo_t);
    const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
    if (linux.errno(rc) != .SUCCESS) return false;
    return info.fields.common.first.piduid.pid == pid;
}

/// False once the group is gone.
fn signalGroup(pid: std.posix.pid_t, sig: std.posix.SIG) bool {
    std.posix.kill(-pid, sig) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => {
            std.log.warn("child group: signalling process group {d} failed: {any}", .{ pid, err });
            return false;
        },
    };
    return true;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn spawnSleeper() !std.process.Child {
    return std.process.spawn(skim_io.get(), .{
        .argv = &.{ "sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

fn shParams(comptime script: []const u8, params: struct {
    timeout: Timeout = .{ .total_ns = 10 * std.time.ns_per_s },
    stdout_limit: usize = 1 << 20,
    stderr_limit: usize = 1 << 20,
    slot: ?*ChildSlot = null,
    cwd: ?[]const u8 = null,
    stdin: ?[]const u8 = null,
}) RunParams {
    return .{
        .allocator = testing.allocator,
        .argv = &.{ "sh", "-c", script },
        .cwd = params.cwd,
        .stdin = params.stdin,
        .stdout_limit = params.stdout_limit,
        .stderr_limit = params.stderr_limit,
        .timeout = params.timeout,
        .slot = params.slot,
    };
}

fn freeOutput(output: Output) void {
    testing.allocator.free(output.stdout);
    testing.allocator.free(output.stderr);
}

/// `run` on its own thread, for tests that cancel it from this one.
const BackgroundRun = struct {
    params: RunParams,
    result: anyerror!Output = error.TestUnexpectedResult,
    thread: std.Thread = undefined,

    fn start(self: *BackgroundRun) !void {
        self.thread = try std.Thread.spawn(.{}, runInto, .{self});
    }

    fn runInto(self: *BackgroundRun) void {
        self.result = run(self.params);
    }
};

/// Polls `slot` until it holds a child, returning the child's pid.
fn waitForHeld(slot: *ChildSlot) !std.posix.pid_t {
    var waited_ms: u64 = 0;
    while (waited_ms < 5_000) : (waited_ms += 5) {
        slot.mutex.lockUncancelable(skim_io.get());
        const pid = slot.pid;
        slot.mutex.unlock(skim_io.get());
        if (pid != 0) return pid;
        skim_io.sleep(5 * std.time.ns_per_ms);
    }
    return error.ChildNeverHeld;
}

/// True once nothing in `pgid`'s group is left, polling for up to 2s.
fn groupGone(pgid: std.posix.pid_t) bool {
    var waited_ms: u64 = 0;
    while (waited_ms < 2_000) : (waited_ms += 10) {
        if (!signalGroup(pgid, @enumFromInt(0))) return true;
        skim_io.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

fn waitForFile(dir: std.Io.Dir, name: []const u8) !void {
    var waited_ms: u64 = 0;
    while (waited_ms < 5_000) : (waited_ms += 5) {
        if (dir.access(skim_io.get(), name, .{})) return else |_| {}
        skim_io.sleep(5 * std.time.ns_per_ms);
    }
    return error.FileNeverAppeared;
}

test "cancel kills the held child's process group" {
    var slot: ChildSlot = .{};
    var child = try spawnSleeper();
    slot.hold(child.id.?);

    var timer = try skim_io.Timer.start();
    slot.cancel();
    slot.release(.{ .kill_group = false });
    const term = try child.wait(skim_io.get());

    try testing.expect(timer.read() < std.time.ns_per_s);
    try testing.expect(term == .signal);
}

test "a child held after cancel is killed at once" {
    var slot: ChildSlot = .{};
    slot.cancel();
    var child = try spawnSleeper();

    slot.hold(child.id.?);
    slot.release(.{ .kill_group = false });
    const term = try child.wait(skim_io.get());

    try testing.expect(term == .signal);
    try testing.expect(slot.isCanceled());
}

test "release without kill_group leaves the child running" {
    var slot: ChildSlot = .{};
    var child = try spawnSleeper();
    defer child.kill(skim_io.get());

    slot.hold(child.id.?);
    slot.release(.{ .kill_group = false });
    slot.cancel();

    try testing.expect(signalGroup(child.id.?, @enumFromInt(0)));
}

test "run returns stdout, stderr and the exit status" {
    const output = try run(shParams("printf out; printf err >&2; exit 3", .{}));
    defer freeOutput(output);

    try testing.expectEqualStrings("out", output.stdout);
    try testing.expectEqualStrings("err", output.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, output.term);
}

test "run feeds stdin to the child and closes it" {
    const output = try run(shParams("cat", .{ .stdin = "line one\nline two\n" }));
    defer freeOutput(output);

    try testing.expectEqualStrings("line one\nline two\n", output.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term);
}

test "run starts the child in cwd" {
    const output = try run(shParams("pwd", .{ .cwd = "/" }));
    defer freeOutput(output);

    try testing.expectEqualStrings("/\n", output.stdout);
}

test "run reports a missing binary as FileNotFound" {
    try testing.expectError(error.FileNotFound, run(.{
        .allocator = testing.allocator,
        .argv = &.{"/nonexistent/skim-child-group-test-bin"},
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .timeout = .{ .total_ns = std.time.ns_per_s },
    }));
}

test "run fails with StdoutTooLong once stdout passes its limit" {
    try testing.expectError(error.StdoutTooLong, run(shParams("head -c 4096 /dev/zero", .{ .stdout_limit = 100 })));
}

test "run fails with StderrTooLong once stderr passes its limit" {
    try testing.expectError(error.StderrTooLong, run(shParams("head -c 4096 /dev/zero >&2", .{ .stderr_limit = 100 })));
}

test "a total timeout kills a child that never finishes" {
    var slot: ChildSlot = .{};
    var background: BackgroundRun = .{ .params = shParams("exec sleep 30", .{
        .timeout = .{ .total_ns = 100 * std.time.ns_per_ms },
        .slot = &slot,
    }) };
    var timer = try skim_io.Timer.start();
    try background.start();
    const pid = try waitForHeld(&slot);
    background.thread.join();

    try testing.expectError(error.Timeout, background.result);
    try testing.expect(timer.read() < 2 * std.time.ns_per_s);
    try testing.expect(groupGone(pid));
}

test "an idle timeout spares a child that keeps writing" {
    const output = try run(shParams("for i in 1 2 3 4 5 6; do echo $i; sleep 0.05; done", .{
        .timeout = .{ .idle_ns = 200 * std.time.ns_per_ms },
    }));
    defer freeOutput(output);

    try testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n", output.stdout);
}

test "a total timeout shorter than the run fails a child that keeps writing" {
    try testing.expectError(error.Timeout, run(shParams("for i in 1 2 3 4 5 6; do echo $i; sleep 0.05; done", .{
        .timeout = .{ .total_ns = 120 * std.time.ns_per_ms },
    })));
}

test "run on a canceled slot spawns nothing" {
    var slot: ChildSlot = .{};
    slot.cancel();

    try testing.expectError(error.Canceled, run(shParams("echo ran", .{ .slot = &slot })));
}

test "cancel during a run ends it with Canceled and leaves no process behind" {
    var slot: ChildSlot = .{};
    var background: BackgroundRun = .{ .params = shParams("sleep 30 & wait", .{ .slot = &slot }) };
    try background.start();
    const pid = try waitForHeld(&slot);

    slot.cancel();
    background.thread.join();

    try testing.expectError(error.Canceled, background.result);
    try testing.expect(groupGone(pid));
}

test "cancel returns at once for a child that ignores SIGTERM, and the worker still kills it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(cwd);
    var slot: ChildSlot = .{};
    var background: BackgroundRun = .{ .params = shParams("trap '' TERM; : > ready; exec sleep 30", .{
        .slot = &slot,
        .cwd = cwd,
    }) };
    try background.start();
    const pid = try waitForHeld(&slot);
    try waitForFile(tmp.dir, "ready");

    var timer = try skim_io.Timer.start();
    slot.cancel();
    const cancel_ns = timer.read();
    background.thread.join();

    try testing.expect(cancel_ns < 20 * std.time.ns_per_ms);
    try testing.expectError(error.Canceled, background.result);
    try testing.expect(timer.read() < 2 * std.time.ns_per_s);
    try testing.expect(groupGone(pid));
}
