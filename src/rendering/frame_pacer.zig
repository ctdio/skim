//! Frame pacing for the event loop.

const std = @import("std");

const testing = std.testing;

/// Holds a frame back only while the terminal is behind.
///
/// The loop renders once per input event, and a held key repeats faster than a
/// slow terminal drains. Writing every frame anyway fills the tty buffer until
/// the next write blocks: against a consumer that drained at 30Hz, a 250Hz key
/// rate stretched a loop iteration from 3.7ms to 60ms.
///
/// The interval is the time the previous frame took to write, not a constant.
/// A terminal that keeps up reports microseconds and gates nothing, so a fast
/// machine still runs flat out. A terminal that blocks reports its own stall
/// and buys back exactly that much time, so the input that arrives meanwhile
/// rides along on the next frame instead of queueing another one behind it.
pub const FramePacer = struct {
    last_frame_ns: u64 = 0,
    last_write_ns: u64 = 0,
    has_rendered: bool = false,

    /// Whether a frame wanted at `now_ns` on a monotonic clock may be drawn.
    pub fn shouldRender(self: *const FramePacer, now_ns: u64) bool {
        if (!self.has_rendered) return true;
        return now_ns -| self.last_frame_ns >= self.last_write_ns;
    }

    /// Record a frame drawn at `now_ns` whose write to the terminal took
    /// `write_ns`. That cost is what gates the next frame.
    pub fn recordFrame(self: *FramePacer, now_ns: u64, write_ns: u64) void {
        self.has_rendered = true;
        self.last_frame_ns = now_ns;
        self.last_write_ns = write_ns;
    }
};

test "draws the first frame it is asked for" {
    const pacer: FramePacer = .{};
    try testing.expect(pacer.shouldRender(0));
}

test "a terminal that keeps up gates nothing" {
    var pacer: FramePacer = .{};
    pacer.recordFrame(1_000_000, 200 * std.time.ns_per_us);
    try testing.expect(pacer.shouldRender(1_000_000 + 200 * std.time.ns_per_us));
}

test "holds back a frame while the previous write is still being paid for" {
    var pacer: FramePacer = .{};
    pacer.recordFrame(1_000_000, 20 * std.time.ns_per_ms);
    try testing.expect(!pacer.shouldRender(1_000_000 + 5 * std.time.ns_per_ms));
}

test "draws again once the previous write has been paid for" {
    var pacer: FramePacer = .{};
    pacer.recordFrame(1_000_000, 20 * std.time.ns_per_ms);
    try testing.expect(pacer.shouldRender(1_000_000 + 20 * std.time.ns_per_ms));
}

test "a fast terminal runs far above any display rate" {
    var pacer: FramePacer = .{};
    var drawn: usize = 0;
    var now: u64 = 0;
    while (now < std.time.ns_per_s) : (now += 100 * std.time.ns_per_us) {
        if (pacer.shouldRender(now)) {
            drawn += 1;
            pacer.recordFrame(now, 50 * std.time.ns_per_us);
        }
    }
    try testing.expectEqual(@as(usize, 10_000), drawn);
}

test "a blocked terminal coalesces a 500Hz burst" {
    var pacer: FramePacer = .{};
    var drawn: usize = 0;
    var now: u64 = 0;
    while (now < std.time.ns_per_s) : (now += 2 * std.time.ns_per_ms) {
        if (pacer.shouldRender(now)) {
            drawn += 1;
            pacer.recordFrame(now, 20 * std.time.ns_per_ms);
        }
    }
    try testing.expectEqual(@as(usize, 50), drawn);
}
