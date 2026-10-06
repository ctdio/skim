//! p50/p95/p99 summaries and NFR-1 budget checks for `bench_pr_flip`. Pure (no
//! App import) so it carries its own unit tests, unlike `bench_support.zig`.

const std = @import("std");

pub const Summary = struct { min: u64, p50: u64, p95: u64, p99: u64, max: u64, avg: u64 };

pub const Budget = struct { label: []const u8, p95_limit_ns: u64 };

pub const FormatParams = struct {
    label: []const u8,
    summary: Summary,
    budget: Budget,
};

/// Sorts `samples` in place. Same index rule as `bench_support.computeStats`
/// (`samples[(len*pct)/100]`) so numbers line up across benches. An empty
/// slice summarizes to all zeros, which is never over budget.
pub fn summarize(samples: []u64) Summary {
    if (samples.len == 0) return .{ .min = 0, .p50 = 0, .p95 = 0, .p99 = 0, .max = 0, .avg = 0 };
    std.mem.sort(u64, samples, {}, comptime std.sort.asc(u64));

    var total: u64 = 0;
    for (samples) |value| total += value;

    const len = samples.len;
    return .{
        .min = samples[0],
        .p50 = samples[(len * 50) / 100],
        .p95 = samples[(len * 95) / 100],
        .p99 = samples[(len * 99) / 100],
        .max = samples[len - 1],
        .avg = total / @as(u64, @intCast(len)),
    };
}

pub fn exceeds(summary: Summary, budget: Budget) bool {
    return summary.p95 > budget.p95_limit_ns;
}

/// `budget` with its limit multiplied by `percent`/100 (SKIM_BENCH_BUDGET_SCALE).
/// Lets a slow CI box or a laptop on battery run the gate without editing the
/// budgets; the defaults stay the NFR-1 numbers.
pub fn scaled(budget: Budget, percent: u64) Budget {
    return .{ .label = budget.label, .p95_limit_ns = budget.p95_limit_ns * percent / 100 };
}

/// How many summaries exceed their budget. `summaries[i]` pairs with
/// `budgets[i]`; lengths must match. This is the whole exit-1 decision, kept
/// pure so it is unit-tested.
pub fn overCount(summaries: []const Summary, budgets: []const Budget) usize {
    std.debug.assert(summaries.len == budgets.len);
    var count: usize = 0;
    for (summaries, budgets) |summary, budget| count += @intFromBool(exceeds(summary, budget));
    return count;
}

/// "flip (db hit)   : min=…us p50=…us p95=…us p99=…us avg=…us  budget p95<30000us  OK"
pub fn formatLine(writer: *std.Io.Writer, params: FormatParams) !void {
    const s = params.summary;
    try writer.print("{s: <15} : min={d}us p50={d}us p95={d}us p99={d}us avg={d}us  budget p95<{d}us  {s}", .{
        params.label,
        nsToUs(s.min),
        nsToUs(s.p50),
        nsToUs(s.p95),
        nsToUs(s.p99),
        nsToUs(s.avg),
        nsToUs(params.budget.p95_limit_ns),
        if (exceeds(s, params.budget)) "OVER" else "OK",
    });
}

fn nsToUs(ns: u64) u64 {
    return ns / std.time.ns_per_us;
}

// =============================================================================
// Tests
// =============================================================================

test "summarize of an empty slice is all zeros" {
    var samples: [0]u64 = .{};
    const summary = summarize(&samples);
    try std.testing.expectEqual(Summary{ .min = 0, .p50 = 0, .p95 = 0, .p99 = 0, .max = 0, .avg = 0 }, summary);
}

test "summarize uses the computeStats index rule" {
    var samples: [100]u64 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = i + 1;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().shuffle(u64, &samples);

    const summary = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 51), summary.p50);
    try std.testing.expectEqual(@as(u64, 96), summary.p95);
    try std.testing.expectEqual(@as(u64, 100), summary.p99);
}

test "summarize reports min, max and integer avg" {
    var samples = [_]u64{ 5, 1, 9 };
    const summary = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 1), summary.min);
    try std.testing.expectEqual(@as(u64, 9), summary.max);
    try std.testing.expectEqual(@as(u64, 5), summary.avg);
}

test "summarize of a single sample reports it at every percentile" {
    var samples = [_]u64{42};
    const summary = summarize(&samples);
    try std.testing.expectEqual(Summary{ .min = 42, .p50 = 42, .p95 = 42, .p99 = 42, .max = 42, .avg = 42 }, summary);
}

test "summarize sorts in place" {
    var samples = [_]u64{ 30, 10, 20, 50, 40 };
    _ = summarize(&samples);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 30, 40, 50 }, &samples);
}

test "exceeds is false at exactly the limit" {
    const summary: Summary = .{ .min = 0, .p50 = 0, .p95 = 1000, .p99 = 5000, .max = 5000, .avg = 0 };
    try std.testing.expect(!exceeds(summary, .{ .label = "x", .p95_limit_ns = 1000 }));
}

test "exceeds is true one nanosecond over" {
    const summary: Summary = .{ .min = 0, .p50 = 0, .p95 = 1001, .p99 = 1001, .max = 1001, .avg = 0 };
    try std.testing.expect(exceeds(summary, .{ .label = "x", .p95_limit_ns = 1000 }));
}

test "exceeds ignores p99 and max" {
    const summary: Summary = .{ .min = 0, .p50 = 0, .p95 = 10, .p99 = 1_000_000, .max = 9_000_000, .avg = 0 };
    try std.testing.expect(!exceeds(summary, .{ .label = "x", .p95_limit_ns = 10 }));
}

test "formatLine marks OVER for an exceeded budget" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try formatLine(&out.writer, .{
        .label = "flip (db hit)",
        .summary = .{ .min = 1_000_000, .p50 = 20_000_000, .p95 = 31_500_000, .p99 = 40_000_000, .max = 41_000_000, .avg = 22_000_000 },
        .budget = .{ .label = "flip (db hit)", .p95_limit_ns = 30 * std.time.ns_per_ms },
    });
    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "flip (db hit)"));
    try std.testing.expect(std.mem.indexOf(u8, text, "p95=31500us") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "budget p95<30000us") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "OVER"));
}

test "formatLine marks OK within budget" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try formatLine(&out.writer, .{
        .label = "sidebar draw",
        .summary = .{ .min = 100_000, .p50 = 200_000, .p95 = 300_000, .p99 = 400_000, .max = 500_000, .avg = 250_000 },
        .budget = .{ .label = "sidebar draw", .p95_limit_ns = std.time.ns_per_ms },
    });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "min=100us p50=200us p95=300us p99=400us avg=250us") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "OK"));
}

test "scaled at 100 percent is unchanged" {
    const budget: Budget = .{ .label = "flip (db hit)", .p95_limit_ns = 30 * std.time.ns_per_ms };
    const result = scaled(budget, 100);
    try std.testing.expectEqual(budget.p95_limit_ns, result.p95_limit_ns);
    try std.testing.expectEqualStrings(budget.label, result.label);
}

test "scaled at 150 percent raises the limit" {
    const result = scaled(.{ .label = "flip (db hit)", .p95_limit_ns = 30 * std.time.ns_per_ms }, 150);
    try std.testing.expectEqual(@as(u64, 45 * std.time.ns_per_ms), result.p95_limit_ns);
}

test "scaled at 1 percent lowers the limit" {
    const result = scaled(.{ .label = "cold paint", .p95_limit_ns = 50 * std.time.ns_per_ms }, 1);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_us), result.p95_limit_ns);
}

test "overCount is zero when every summary is within budget" {
    const summaries = [_]Summary{ summaryAt(10), summaryAt(20), summaryAt(30) };
    const budgets = [_]Budget{ budgetAt(10), budgetAt(25), budgetAt(30) };
    try std.testing.expectEqual(@as(usize, 0), overCount(&summaries, &budgets));
}

test "overCount counts each exceeded pair once" {
    const summaries = [_]Summary{ summaryAt(11), summaryAt(20), summaryAt(31) };
    const budgets = [_]Budget{ budgetAt(10), budgetAt(25), budgetAt(30) };
    try std.testing.expectEqual(@as(usize, 2), overCount(&summaries, &budgets));
}

test "overCount pairs summaries with budgets by index" {
    const summaries = [_]Summary{ summaryAt(5), summaryAt(50) };
    try std.testing.expectEqual(@as(usize, 1), overCount(&summaries, &.{ budgetAt(10), budgetAt(40) }));
    try std.testing.expectEqual(@as(usize, 0), overCount(&summaries, &.{ budgetAt(40), budgetAt(50) }));
    try std.testing.expectEqual(@as(usize, 2), overCount(&summaries, &.{ budgetAt(4), budgetAt(10) }));
}

test "overCount of no measurements is zero" {
    try std.testing.expectEqual(@as(usize, 0), overCount(&.{}, &.{}));
}

fn summaryAt(p95: u64) Summary {
    return .{ .min = p95, .p50 = p95, .p95 = p95, .p99 = p95, .max = p95, .avg = p95 };
}

fn budgetAt(limit: u64) Budget {
    return .{ .label = "x", .p95_limit_ns = limit };
}
