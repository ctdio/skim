//! Timed wait on the vaxis event queue.
//!
//! The event loop cannot block in `pollEvent` while something needs polling on
//! a timer (the TUI server, a running agent, an open PR sidebar), and Zig 0.16
//! dropped `Condition.timedWait`. `waitForInput` fills the gap: it sleeps on
//! the queue's own `not_empty` condition with a timeout, so the loop thread
//! wakes once per tick or as soon as the tty reader queues an event, instead
//! of napping in 1ms slices (about 1000 wakeups/s while idle).
//!
//! It reaches into private fields of `std.Io.Condition` (Zig 0.16.0) and
//! `vaxis.Queue` (libvaxis c060d314930c5552b99a89278a6a695baf0352da, vaxis
//! 0.6.0). The comptime checks below pin that layout, so an upgrade that
//! changes it fails to compile here instead of hanging the event loop.

const std = @import("std");
const skim_io = @import("skim_io");

comptime {
    assertConditionLayout();
}

/// Waits up to `max_ns` for the queue to hold an event, returning as soon as
/// one is pushed. `queue` is a `vaxis.Queue`; the event stays queued for the
/// caller's `tryEvent` drain.
pub fn waitForInput(queue: anytype, max_ns: u64) void {
    comptime assertQueueLayout(@TypeOf(queue.*));
    const io = skim_io.get();
    queue.mutex.lockUncancelable(io);
    defer queue.mutex.unlock(io);
    if (queue.write_index != queue.read_index) return;
    timedWait(.{ .cond = &queue.not_empty, .mutex = &queue.mutex, .max_ns = max_ns });
}

/// `std.Io.Condition.wait` with a timeout, following the same waiter/signal
/// protocol so a `signal` from `Queue.push` wakes it. Called with `mutex`
/// held; returns with it held.
///
/// Leaving on timeout must not strand a signal: `signal` only bumps the epoch
/// while `waiters > signals`, so a signal counted for a waiter that then left
/// would keep every later `pollEvent` asleep through the next push. The
/// waiter count is therefore dropped with a compare-and-swap that fails (and
/// consumes the signal instead) if one arrived in the meantime.
fn timedWait(params: struct { cond: *std.Io.Condition, mutex: *std.Io.Mutex, max_ns: u64 }) void {
    const io = skim_io.get();
    const cond = params.cond;
    var epoch = cond.epoch.load(.acquire);
    _ = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);

    params.mutex.unlock(io);
    defer params.mutex.lockUncancelable(io);

    var timer = skim_io.Timer.start() catch |err| switch (err) {};
    while (true) {
        const elapsed_ns = timer.read();
        const expired = elapsed_ns >= params.max_ns;
        if (!expired) {
            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = .fromNanoseconds(params.max_ns - elapsed_ns),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, timeout) catch {
                leave(cond);
                return;
            };
            epoch = cond.epoch.load(.acquire);
        }
        if (takeSignal(cond)) return;
        if (expired) {
            leave(cond);
            return;
        }
    }
}

/// `timedWait` reimplements `Condition.wait`'s protocol against these fields.
fn assertConditionLayout() void {
    const Condition = std.Io.Condition;
    expectFields(Condition, &.{ "state", "epoch" });
    if (@FieldType(Condition, "epoch") != std.atomic.Value(u32)) @compileError("std.Io.Condition.epoch is no longer an atomic u32");
    const State = @FieldType(@FieldType(Condition, "state"), "raw");
    const info = @typeInfo(State).@"struct";
    if (info.layout != .@"packed" or info.backing_integer != u32) @compileError("std.Io.Condition.State is no longer a packed u32");
    expectFields(State, &.{ "waiters", "signals" });
    if (@FieldType(State, "waiters") != u16 or @FieldType(State, "signals") != u16) @compileError("std.Io.Condition.State counters are no longer u16");
}

/// `waitForInput` reads the ring indices and waits on `not_empty` under
/// `mutex`, which `Queue.push` signals.
fn assertQueueLayout(comptime Queue: type) void {
    if (@FieldType(Queue, "mutex") != std.Io.Mutex) @compileError("vaxis.Queue.mutex is no longer a std.Io.Mutex");
    if (@FieldType(Queue, "not_empty") != std.Io.Condition) @compileError("vaxis.Queue.not_empty is no longer a std.Io.Condition");
    if (@FieldType(Queue, "read_index") != usize or @FieldType(Queue, "write_index") != usize) @compileError("vaxis.Queue ring indices are no longer usize");
}

fn expectFields(comptime T: type, comptime names: []const []const u8) void {
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len != names.len) @compileError(@typeName(T) ++ " gained or lost fields");
    for (fields, names) |field, name| {
        if (!std.mem.eql(u8, field.name, name)) @compileError(@typeName(T) ++ " has field " ++ field.name ++ " where " ++ name ++ " was expected");
    }
}

/// Consume a pending signal, dropping this waiter with it.
fn takeSignal(cond: *std.Io.Condition) bool {
    var state = cond.state.load(.monotonic);
    while (state.signals > 0) {
        state = cond.state.cmpxchgWeak(state, .{
            .waiters = state.waiters - 1,
            .signals = state.signals - 1,
        }, .acquire, .monotonic) orelse return true;
    }
    return false;
}

/// Drop this waiter, or consume the signal that raced in instead.
fn leave(cond: *std.Io.Condition) void {
    var state = cond.state.load(.monotonic);
    while (true) {
        const next: @TypeOf(state) = if (state.signals > 0)
            .{ .waiters = state.waiters - 1, .signals = state.signals - 1 }
        else
            .{ .waiters = state.waiters - 1, .signals = 0 };
        state = cond.state.cmpxchgWeak(state, next, .acquire, .monotonic) orelse return;
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const TestQueue = vaxis.Queue(u8, 8);

fn pushAfter(queue: *TestQueue, delay_ns: u64) void {
    skim_io.sleep(delay_ns);
    queue.push(1) catch unreachable;
}

/// Context switches this thread has made, from /proc. Linux only.
fn threadSwitches() !u64 {
    const file = try std.Io.Dir.cwd().openFile(skim_io.get(), "/proc/thread-self/status", .{});
    defer file.close(skim_io.get());
    var buf: [4096]u8 = undefined;
    const status = buf[0..try skim_io.readFile(file, &buf)];
    var total: u64 = 0;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "ctxt_switches:") == null) continue;
        const value = std.mem.trim(u8, line[std.mem.indexOfScalar(u8, line, ':').? + 1 ..], " \t");
        total += try std.fmt.parseInt(u64, value, 10);
    }
    return total;
}

test "returns at once when an event is already queued" {
    var queue: TestQueue = .init(skim_io.get());
    try queue.push(1);

    var timer = try skim_io.Timer.start();
    waitForInput(&queue, 5 * std.time.ns_per_s);

    try testing.expect(timer.read() < 100 * std.time.ns_per_ms);
}

test "returns after the budget when nothing is pushed" {
    var queue: TestQueue = .init(skim_io.get());

    var timer = try skim_io.Timer.start();
    waitForInput(&queue, 30 * std.time.ns_per_ms);
    const elapsed_ns = timer.read();

    try testing.expect(elapsed_ns >= 30 * std.time.ns_per_ms);
    try testing.expect(elapsed_ns < 2 * std.time.ns_per_s);
    try testing.expect(try queue.isEmpty());
}

test "wakes as soon as another thread pushes, long before the budget" {
    var queue: TestQueue = .init(skim_io.get());
    const pusher = try std.Thread.spawn(.{}, pushAfter, .{ &queue, 20 * std.time.ns_per_ms });
    defer pusher.join();

    var timer = try skim_io.Timer.start();
    waitForInput(&queue, 5 * std.time.ns_per_s);

    try testing.expect(timer.read() < std.time.ns_per_s);
    try testing.expectEqual(@as(?u8, 1), try queue.tryPop());
}

test "sleeps through an idle budget instead of waking every millisecond" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var queue: TestQueue = .init(skim_io.get());

    const before = try threadSwitches();
    waitForInput(&queue, 100 * std.time.ns_per_ms);
    const switches = try threadSwitches() - before;

    try testing.expect(switches < 10);
}

test "a blocking pop after timed-out waits is still woken by a push" {
    var queue: TestQueue = .init(skim_io.get());
    for (0..20) |_| waitForInput(&queue, 1 * std.time.ns_per_ms);

    const pusher = try std.Thread.spawn(.{}, pushAfter, .{ &queue, 20 * std.time.ns_per_ms });
    defer pusher.join();

    try testing.expectEqual(@as(u8, 1), try queue.pop());
}
