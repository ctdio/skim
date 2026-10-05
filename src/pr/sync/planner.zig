//! Every decision the sync worker makes, as pure functions: when to stop
//! paging, how watermarks advance, when reconcile and teams refreshes are due,
//! which PRs to hydrate in what order, and when to run again at once. `sync.zig` is the imperative shell
//! that acts on them. Imports `db/types.zig` only (D4).
//!
//! Timestamps are GitHub's fixed `YYYY-MM-DDTHH:MM:SSZ` form, so a byte-wise
//! comparison is a time comparison.

const std = @import("std");
const types = @import("../db/types.zig");
const queries = @import("queries.zig");
const epoch = std.time.epoch;

pub const reconcile_every = 10;
pub const teams_ttl_secs = 86_400;
pub const max_hydrate_batches_per_run = 8;
/// How far below the stored watermark paging continues. GitHub's
/// `UPDATED_AT` sort key lags the reported `updatedAt` (captured next.js page
/// 1 has a 19:47 row after 18:00 rows), so a PR changed after the last run can
/// sort below rows that are older than the watermark.
pub const watermark_lookback_secs = 6 * 3600;

/// A timestamp in GitHub's fixed `YYYY-MM-DDTHH:MM:SSZ` form.
pub const Timestamp = [20]u8;

pub const StopParams = struct {
    watermark: ?[]const u8,
    /// `updated_at` of the page's last row; null for an empty page.
    last_updated_at: ?[]const u8,
    has_next: bool,
};

pub const ReconcileParams = struct {
    had_open_watermark: bool,
    /// Runs since the worker started: 0, 1, 2, ...
    sync_index: u64,
};

pub const TeamsParams = struct {
    teams_synced_at: i64,
    now: i64,
    viewer_changed: bool,
};

pub const RerunParams = struct {
    /// PRs still waiting for hydrate after the run that just finished.
    remaining: usize,
    /// `remaining` after the previous run, when that run was itself an
    /// immediate rerun; null otherwise.
    previous_remaining: ?usize,
};

pub const HydrateOrderParams = struct {
    /// PRs needing hydrate, newest change first (`Store.needsHydrate` order).
    refs: []const types.NodeRef,
    /// PR numbers the sidebar is showing, most important first.
    priority: []const u32,
};

pub const HydratePlan = struct {
    batches: BatchIter,
    /// Refs left for a later run; > 0 tells the worker to run again at once.
    remaining: usize,
};

/// Yields consecutive slices of at most `queries.hydrate_batch_size` refs.
pub const BatchIter = struct {
    refs: []const types.NodeRef,
    offset: usize = 0,

    pub fn next(self: *BatchIter) ?[]const types.NodeRef {
        if (self.offset >= self.refs.len) return null;
        const end = @min(self.offset + queries.hydrate_batch_size, self.refs.len);
        defer self.offset = end;
        return self.refs[self.offset..end];
    }
};

/// Keep paging while the page still reaches `watermark`, the stop line the
/// caller derives with `lookbackWatermark`. Stopping only when
/// the *last* row is strictly older means rows that tie the watermark are
/// always re-read: GitHub has one-second resolution, so a PR updated in the
/// same second as the previous run's newest row would otherwise be skipped.
pub fn shouldStopPaging(params: StopParams) bool {
    if (!params.has_next) return true;
    const watermark = params.watermark orelse return false;
    const last = params.last_updated_at orelse return true;
    return std.mem.order(u8, last, watermark) == .lt;
}

/// `watermark` moved back by `lookback_secs` (clamped at the Unix epoch), for
/// use as the paging stop line. Null when `watermark` is not in the fixed
/// form; the caller then pages to the end rather than trust it.
pub fn lookbackWatermark(watermark: []const u8, lookback_secs: u32) ?Timestamp {
    const secs = parseTimestamp(watermark) orelse return null;
    return formatTimestamp(secs -| lookback_secs);
}

/// The newer of the previous watermark and the first (newest) row of this
/// run's first page.
pub fn nextWatermark(previous: ?[]const u8, first_row_updated_at: ?[]const u8) ?[]const u8 {
    const candidate = first_row_updated_at orelse return previous;
    const prev = previous orelse return candidate;
    return if (std.mem.order(u8, candidate, prev) == .gt) candidate else prev;
}

/// Reconcile on the first sync (no watermark), on the first run of every
/// worker session, and on every tenth run after. Reconcile runs also re-read
/// the whole open index, ignoring the watermark.
pub fn reconcileDue(params: ReconcileParams) bool {
    if (!params.had_open_watermark) return true;
    return params.sync_index % reconcile_every == 0;
}

pub fn teamsDue(params: TeamsParams) bool {
    if (params.viewer_changed or params.teams_synced_at == 0) return true;
    return params.now - params.teams_synced_at >= teams_ttl_secs;
}

/// Run again at once while hydrate work is left and the previous rerun made
/// progress. A PR whose hydrate never clears it from `needsHydrate` would
/// otherwise keep the worker in a tight loop of full runs.
pub fn rerunImmediately(params: RerunParams) bool {
    if (params.remaining == 0) return false;
    const previous = params.previous_remaining orelse return true;
    return params.remaining < previous;
}

/// Priority numbers (PRs the sidebar is currently showing) first, in the
/// priority order; then everything else in `refs` order. Priority numbers not
/// in `refs` (already hydrated) are skipped, and no ref appears twice.
/// Caller owns the returned slice.
pub fn orderForHydrate(allocator: std.mem.Allocator, params: HydrateOrderParams) ![]types.NodeRef {
    const ordered = try allocator.alloc(types.NodeRef, params.refs.len);
    errdefer allocator.free(ordered);
    const taken = try allocator.alloc(bool, params.refs.len);
    defer allocator.free(taken);
    @memset(taken, false);

    var len: usize = 0;
    for (params.priority) |number| {
        for (params.refs, taken) |ref, *used| {
            if (used.* or ref.number != number) continue;
            used.* = true;
            ordered[len] = ref;
            len += 1;
            break;
        }
    }
    for (params.refs, taken) |ref, used| {
        if (used) continue;
        ordered[len] = ref;
        len += 1;
    }
    return ordered;
}

/// Slices `ordered` into batches of `queries.hydrate_batch_size`, at most
/// `max_hydrate_batches_per_run` of them.
pub fn hydrateBatches(ordered: []const types.NodeRef) HydratePlan {
    const cap = queries.hydrate_batch_size * max_hydrate_batches_per_run;
    const this_run = @min(ordered.len, cap);
    return .{ .batches = .{ .refs = ordered[0..this_run] }, .remaining = ordered.len - this_run };
}

// =============================================================================
// Helpers
// =============================================================================

/// Seconds since the Unix epoch of a fixed-form timestamp, or null.
fn parseTimestamp(text: []const u8) ?u64 {
    if (text.len != 20) return null;
    if (text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[19] != 'Z') return null;
    const year = digits(text[0..4]) orelse return null;
    const month = digits(text[5..7]) orelse return null;
    const day = digits(text[8..10]) orelse return null;
    const hour = digits(text[11..13]) orelse return null;
    const minute = digits(text[14..16]) orelse return null;
    const second = digits(text[17..19]) orelse return null;
    if (year < epoch.epoch_year or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return null;
    const y: epoch.Year = @intCast(year);
    if (day < 1 or day > epoch.getDaysInMonth(y, @enumFromInt(month))) return null;

    var days: u64 = 0;
    var year_cursor: epoch.Year = epoch.epoch_year;
    while (year_cursor < y) : (year_cursor += 1) days += epoch.getDaysInYear(year_cursor);
    var month_cursor: u4 = 1;
    while (month_cursor < month) : (month_cursor += 1) days += epoch.getDaysInMonth(y, @enumFromInt(month_cursor));
    days += day - 1;
    return days * epoch.secs_per_day + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
}

fn formatTimestamp(secs: u64) Timestamp {
    const epoch_secs: epoch.EpochSeconds = .{ .secs = secs };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    var out: Timestamp = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

/// An all-digit field, or null.
fn digits(text: []const u8) ?u16 {
    var value: u16 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "shouldStopPaging: no next page stops" {
    try testing.expect(shouldStopPaging(.{ .watermark = null, .last_updated_at = "2026-01-01T00:00:00Z", .has_next = false }));
}

test "shouldStopPaging: no watermark never stops while has_next is set" {
    try testing.expect(!shouldStopPaging(.{ .watermark = null, .last_updated_at = "2020-01-01T00:00:00Z", .has_next = true }));
}

test "shouldStopPaging: last row older than the watermark stops" {
    try testing.expect(shouldStopPaging(.{ .watermark = "2026-01-01T00:00:10Z", .last_updated_at = "2026-01-01T00:00:09Z", .has_next = true }));
}

test "shouldStopPaging: last row equal to the watermark keeps paging" {
    try testing.expect(!shouldStopPaging(.{ .watermark = "2026-01-01T00:00:10Z", .last_updated_at = "2026-01-01T00:00:10Z", .has_next = true }));
}

test "shouldStopPaging: last row newer keeps paging" {
    try testing.expect(!shouldStopPaging(.{ .watermark = "2026-01-01T00:00:10Z", .last_updated_at = "2026-01-01T00:00:11Z", .has_next = true }));
}

test "shouldStopPaging: an empty page stops" {
    try testing.expect(shouldStopPaging(.{ .watermark = "2026-01-01T00:00:10Z", .last_updated_at = null, .has_next = true }));
}

test "nextWatermark keeps the newer of previous and first row" {
    try testing.expectEqualStrings("2026-01-02T00:00:00Z", nextWatermark("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z").?);
    try testing.expectEqualStrings("2026-01-02T00:00:00Z", nextWatermark("2026-01-02T00:00:00Z", "2026-01-01T00:00:00Z").?);
}

test "nextWatermark handles null on either side" {
    try testing.expectEqualStrings("2026-01-01T00:00:00Z", nextWatermark(null, "2026-01-01T00:00:00Z").?);
    try testing.expectEqualStrings("2026-01-01T00:00:00Z", nextWatermark("2026-01-01T00:00:00Z", null).?);
    try testing.expectEqual(null, nextWatermark(null, null));
}

test "reconcileDue is true without an open watermark" {
    try testing.expect(reconcileDue(.{ .had_open_watermark = false, .sync_index = 3 }));
}

test "reconcileDue is true on the first run of a session and every tenth run after" {
    for ([_]u64{ 0, 10, 20 }) |index| try testing.expect(reconcileDue(.{ .had_open_watermark = true, .sync_index = index }));
    for ([_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 11 }) |index| try testing.expect(!reconcileDue(.{ .had_open_watermark = true, .sync_index = index }));
}

test "lookbackWatermark subtracts within a day" {
    const floor = lookbackWatermark("2026-10-04T19:47:09Z", 6 * 3600).?;
    try testing.expectEqualStrings("2026-10-04T13:47:09Z", &floor);
}

test "lookbackWatermark rolls back across midnight" {
    const floor = lookbackWatermark("2026-10-04T02:00:00Z", 6 * 3600).?;
    try testing.expectEqualStrings("2026-10-03T20:00:00Z", &floor);
}

test "lookbackWatermark rolls back across a month boundary" {
    const floor = lookbackWatermark("2026-03-01T03:30:15Z", 6 * 3600).?;
    try testing.expectEqualStrings("2026-02-28T21:30:15Z", &floor);
}

test "lookbackWatermark rolls back into a leap day" {
    const floor = lookbackWatermark("2028-03-01T00:00:00Z", 1).?;
    try testing.expectEqualStrings("2028-02-29T23:59:59Z", &floor);
}

test "lookbackWatermark rolls back across a year boundary" {
    const floor = lookbackWatermark("2026-01-01T05:00:00Z", 6 * 3600).?;
    try testing.expectEqualStrings("2025-12-31T23:00:00Z", &floor);
}

test "lookbackWatermark with zero lookback returns the watermark" {
    const floor = lookbackWatermark("2026-10-04T19:47:09Z", 0).?;
    try testing.expectEqualStrings("2026-10-04T19:47:09Z", &floor);
}

test "lookbackWatermark clamps at the Unix epoch" {
    const floor = lookbackWatermark("1970-01-01T01:00:00Z", 6 * 3600).?;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", &floor);
}

test "lookbackWatermark rejects a timestamp not in the fixed form" {
    const malformed = [_][]const u8{
        "",
        "2026-10-04",
        "2026-10-04T19:47:09.123Z",
        "2026-10-04T19:47:09+00:00",
        "2026-13-04T19:47:09Z",
        "2026-02-30T19:47:09Z",
        "2026-10-04T24:00:00Z",
        "2026-10-04T19:60:00Z",
        "2026-1a-04T19:47:09Z",
        "1969-12-31T23:59:59Z",
    };
    for (malformed) |text| try testing.expectEqual(null, lookbackWatermark(text, 60));
}

test "lookbackWatermark result compares below the watermark byte-wise" {
    const floor = lookbackWatermark("2026-10-04T19:47:09Z", watermark_lookback_secs).?;
    try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &floor, "2026-10-04T19:47:09Z"));
    try testing.expectEqual(std.math.Order.gt, std.mem.order(u8, &floor, "2026-10-04T12:00:00Z"));
}

test "rerunImmediately when hydrate work is left after the first run" {
    try testing.expect(rerunImmediately(.{ .remaining = 30, .previous_remaining = null }));
}

test "rerunImmediately while the remaining count keeps falling" {
    try testing.expect(rerunImmediately(.{ .remaining = 30, .previous_remaining = 230 }));
}

test "rerunImmediately stops when a rerun made no progress" {
    try testing.expect(!rerunImmediately(.{ .remaining = 30, .previous_remaining = 30 }));
    try testing.expect(!rerunImmediately(.{ .remaining = 40, .previous_remaining = 30 }));
}

test "rerunImmediately stops when nothing is left" {
    try testing.expect(!rerunImmediately(.{ .remaining = 0, .previous_remaining = null }));
    try testing.expect(!rerunImmediately(.{ .remaining = 0, .previous_remaining = 30 }));
}

test "teamsDue when never synced or the viewer changed" {
    try testing.expect(teamsDue(.{ .teams_synced_at = 0, .now = 100, .viewer_changed = false }));
    try testing.expect(teamsDue(.{ .teams_synced_at = 100, .now = 101, .viewer_changed = true }));
}

test "teamsDue once the TTL has elapsed exactly" {
    try testing.expect(teamsDue(.{ .teams_synced_at = 1000, .now = 1000 + 86_400, .viewer_changed = false }));
    try testing.expect(!teamsDue(.{ .teams_synced_at = 1000, .now = 1000 + 86_399, .viewer_changed = false }));
}

fn testRefs(comptime count: usize) [count]types.NodeRef {
    var refs: [count]types.NodeRef = undefined;
    for (&refs, 0..) |*ref, i| ref.* = .{ .number = @intCast(i + 1), .node_id = "PR_x", .updated_at = "t" };
    return refs;
}

fn numbersOf(refs: []const types.NodeRef, out: []u32) []u32 {
    for (refs, out[0..refs.len]) |ref, *n| n.* = ref.number;
    return out[0..refs.len];
}

test "orderForHydrate puts priority numbers first in priority order, then the rest in order" {
    const refs = testRefs(5);
    const ordered = try orderForHydrate(testing.allocator, .{ .refs = &refs, .priority = &.{ 4, 2 } });
    defer testing.allocator.free(ordered);
    var buf: [5]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 4, 2, 1, 3, 5 }, numbersOf(ordered, &buf));
}

test "orderForHydrate ignores priority numbers not present in refs" {
    const refs = testRefs(3);
    const ordered = try orderForHydrate(testing.allocator, .{ .refs = &refs, .priority = &.{ 99, 3 } });
    defer testing.allocator.free(ordered);
    var buf: [3]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, numbersOf(ordered, &buf));
}

test "orderForHydrate does not duplicate a ref listed twice in priority" {
    const refs = testRefs(3);
    const ordered = try orderForHydrate(testing.allocator, .{ .refs = &refs, .priority = &.{ 2, 2 } });
    defer testing.allocator.free(ordered);
    var buf: [3]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 2, 1, 3 }, numbersOf(ordered, &buf));
}

test "hydrateBatches makes batches of 25" {
    const refs = testRefs(60);
    var plan = hydrateBatches(&refs);
    try testing.expectEqual(0, plan.remaining);
    try testing.expectEqual(25, plan.batches.next().?.len);
    try testing.expectEqual(25, plan.batches.next().?.len);
    const last = plan.batches.next().?;
    try testing.expectEqual(10, last.len);
    try testing.expectEqual(51, last[0].number);
    try testing.expectEqual(null, plan.batches.next());
}

test "hydrateBatches caps at 8 batches" {
    const refs = testRefs(230);
    var plan = hydrateBatches(&refs);
    try testing.expectEqual(30, plan.remaining);
    var count: usize = 0;
    var total: usize = 0;
    while (plan.batches.next()) |batch| {
        count += 1;
        total += batch.len;
    }
    try testing.expectEqual(8, count);
    try testing.expectEqual(200, total);
}

test "hydrateBatches with zero refs gives zero batches" {
    var plan = hydrateBatches(&.{});
    try testing.expectEqual(0, plan.remaining);
    try testing.expectEqual(null, plan.batches.next());
}
