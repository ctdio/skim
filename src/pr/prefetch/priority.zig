//! Prefetch planning (pure): cursor-distance ordering, job selection, and the
//! (base_tip, head) pair whose merge base completes a `types.DiffKey`.

const std = @import("std");
// D4: plain types only. Importing store.zig here would drag SQLite into every
// pure test and into the wasm build through the sidebar.
const types = @import("../db/types.zig");

const Allocator = std.mem.Allocator;

pub const DiffKey = types.DiffKey;

/// One PR the sidebar currently shows, in display order. Strings are borrowed
/// from the caller (`PrefetchWorker.setTargets` deep-copies them).
pub const Target = struct {
    number: u32,
    /// For log lines only; the head is fetched via refs/pull/N/head.
    head_ref: []const u8,
    /// Branch to fetch when `base == .trunk`.
    base_ref: []const u8,
    head_oid: []const u8,
    /// `pr.updated_at`; thread_cache staleness.
    updated_at: []const u8,
    base: Base,
    /// Set on the tip of a stack of >= 2 PRs.
    whole_stack: ?WholeStack = null,
    /// Head the user last marked seen, when it differs from `head_oid`.
    seen_head_oid: ?[]const u8 = null,
};

pub const Base = union(enum) {
    /// `oid` is `pr.base_oid` ("" = unknown).
    trunk: struct { oid: []const u8 },
    parent_pr: struct { number: u32, head_oid: []const u8 },
};

/// The trunk under the bottom PR of a stack: the whole-stack diff is
/// `merge-base(trunk_oid, tip_head)..tip_head`.
pub const WholeStack = struct { trunk_ref: []const u8, trunk_oid: []const u8 };

pub const View = enum { pr, whole_stack, since_seen };

/// The two commits whose merge base, together with `head_oid`, is the DiffKey.
pub const KeyInputs = struct { base_tip_oid: []const u8, head_oid: []const u8 };

pub const JobKind = enum { diff, threads, whole_stack, since_seen };

// Every diff view other than `.pr` (which runs as `.diff`) is scheduled by a
// job of the same name and tracked by a JobState field of the same name.
comptime {
    for (std.meta.fieldNames(View)) |name| {
        if (std.mem.eql(u8, name, "pr")) continue;
        if (!@hasField(JobKind, name)) @compileError("View." ++ name ++ " has no JobKind: schedule it in nextJob");
        if (!@hasField(JobState, name)) @compileError("View." ++ name ++ " has no JobState field to track it");
    }
}

pub const Job = union(enum) {
    fetch_batch,
    run: struct { kind: JobKind, index: usize },
};

/// `evicted`: the diff's row is not cached because it does not fit in the
/// budget around the focus. Not a failure; a focus move can make it pending
/// again (see `prefetch.Round.moveFocus`).
pub const Outcome = enum { pending, done, failed, skipped, evicted };

/// Per-target progress for the current targets version. Reset when targets change.
pub const JobState = struct {
    fetch_attempted: bool = false,
    diff: Outcome = .pending,
    threads: Outcome = .pending,
    whole_stack: Outcome = .pending,
    since_seen: Outcome = .pending,
};

/// PRs nearest the cursor that get thread payloads, whole-stack and
/// since-seen diffs.
pub const thread_window = 10;
/// Most PRs whose commits one `git fetch` batch asks for.
pub const fetch_cap = 100;

/// Build a Target from DB rows. `parent` is the PR whose head_ref equals
/// `rec.base_ref` (stack analysis); `bottom` is the stack's bottom PR and
/// `is_tip` marks the top of a stack of >= 2 members.
pub fn targetFor(params: struct {
    rec: *const types.PrRecord,
    parent: ?*const types.PrRecord = null,
    bottom: ?*const types.PrRecord = null,
    is_tip: bool = false,
}) Target {
    const rec = params.rec;
    const base: Base = if (params.parent) |parent|
        .{ .parent_pr = .{ .number = parent.number, .head_oid = parent.head_oid } }
    else
        .{ .trunk = .{ .oid = rec.base_oid } };
    const stack_bottom = if (params.is_tip) params.bottom else null;
    const whole_stack: ?WholeStack = if (stack_bottom) |bottom|
        .{ .trunk_ref = bottom.base_ref, .trunk_oid = bottom.base_oid }
    else
        null;
    return .{
        .number = rec.number,
        .head_ref = rec.head_ref,
        .base_ref = rec.base_ref,
        .head_oid = rec.head_oid,
        .updated_at = rec.updated_at,
        .base = base,
        .whole_stack = whole_stack,
        .seen_head_oid = seenHead(rec),
    };
}

/// Indices into `targets`, nearest to the focused PR first. Ties (equal
/// distance) go to the row below the cursor first: `j` is the common motion.
/// Unknown focus (0 or not present) is treated as index 0. Caller owns.
pub fn order(params: struct { allocator: Allocator, targets: []const Target, focus_number: u32 }) ![]usize {
    const targets = params.targets;
    const ordered = try params.allocator.alloc(usize, targets.len);
    if (targets.len == 0) return ordered;
    const focus = focusIndex(targets, params.focus_number);
    ordered[0] = focus;
    var filled: usize = 1;
    var distance: usize = 1;
    while (filled < targets.len) : (distance += 1) {
        if (focus + distance < targets.len) {
            ordered[filled] = focus + distance;
            filled += 1;
        }
        if (distance <= focus) {
            ordered[filled] = focus - distance;
            filled += 1;
        }
    }
    return ordered;
}

pub fn focusIndex(targets: []const Target, focus_number: u32) usize {
    for (targets, 0..) |target, i| {
        if (target.number == focus_number) return i;
    }
    return 0;
}

pub fn capBatch(ordered: []const usize, cap: usize) []const usize {
    return ordered[0..@min(ordered.len, cap)];
}

/// The (base tip, head) pair for a view of a target, or null when it can't be
/// keyed (unknown base oid, no whole-stack view). The DiffKey is
/// `{ merge_base(base_tip_oid, head_oid), head_oid }`; the worker resolves and
/// records the merge base in `merge_base_cache`.
pub fn diffKeyFor(target: Target, view: View) ?KeyInputs {
    const base_tip_oid = switch (view) {
        .pr => switch (target.base) {
            .trunk => |trunk| trunk.oid,
            .parent_pr => |parent| parent.head_oid,
        },
        .whole_stack => if (target.whole_stack) |stack| stack.trunk_oid else return null,
        .since_seen => target.seen_head_oid orelse return null,
    };
    if (base_tip_oid.len == 0) return null;
    return .{ .base_tip_oid = base_tip_oid, .head_oid = target.head_oid };
}

/// Next job, given the current cursor-ordered indices. Policy:
///   1. a fetch batch while any target in the first `fetch_cap` of `ordered`
///      hasn't had a fetch attempt this version;
///   2. diffs for the nearest `thread_window`, then their threads, then their
///      whole-stack diffs, then their since-seen diffs;
///   3. diffs for everything else, nearest first.
/// Diff jobs wait for the target's fetch attempt: a target past the cap would
/// only fail on objects that were never asked for. It gets its fetch once the
/// cursor moves close enough to bring it inside the cap.
/// Re-reading the focus between jobs and calling this again is what makes
/// cursor moves reprioritize without restarting the worker.
pub fn nextJob(params: struct {
    targets: []const Target,
    ordered: []const usize,
    states: []const JobState,
    threads_enabled: bool,
}) ?Job {
    const states = params.states;
    for (capBatch(params.ordered, fetch_cap)) |i| {
        if (!states[i].fetch_attempted) return .fetch_batch;
    }

    const near = params.ordered[0..@min(params.ordered.len, thread_window)];
    for (near) |i| {
        if (states[i].fetch_attempted and states[i].diff == .pending) return runJob(.diff, i);
    }
    if (params.threads_enabled) {
        for (near) |i| {
            if (states[i].threads == .pending) return runJob(.threads, i);
        }
    }
    for (near) |i| {
        if (!states[i].fetch_attempted or params.targets[i].whole_stack == null) continue;
        if (states[i].whole_stack == .pending) return runJob(.whole_stack, i);
    }
    for (near) |i| {
        if (!states[i].fetch_attempted or params.targets[i].seen_head_oid == null) continue;
        if (states[i].since_seen == .pending) return runJob(.since_seen, i);
    }
    for (params.ordered[near.len..]) |i| {
        if (states[i].fetch_attempted and states[i].diff == .pending) return runJob(.diff, i);
    }
    return null;
}

fn runJob(kind: JobKind, index: usize) Job {
    return .{ .run = .{ .kind = kind, .index = index } };
}

/// A seen head worth diffing against: set, not the current head, and not the
/// all-zero merge-base sentinel a corrupt row could carry into this column.
fn seenHead(rec: *const types.PrRecord) ?[]const u8 {
    const seen = rec.seen_head_oid orelse return null;
    if (seen.len == 0 or std.mem.eql(u8, seen, rec.head_oid)) return null;
    for (seen) |c| {
        if (c != '0') return seen;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const oid_base = "b" ** 40;
const oid_parent = "1" ** 40;
const oid_head = "2" ** 40;

fn trunkTarget(number: u32) Target {
    return .{
        .number = number,
        .head_ref = "feature",
        .base_ref = "main",
        .head_oid = oid_head,
        .updated_at = "2026-01-01T00:00:00Z",
        .base = .{ .trunk = .{ .oid = oid_base } },
    };
}

fn trunkTargets(comptime n: usize) [n]Target {
    var targets: [n]Target = undefined;
    for (&targets, 0..) |*target, i| target.* = trunkTarget(@intCast(i + 1));
    return targets;
}

fn record(params: struct { number: u32, head_ref: []const u8, base_ref: []const u8, head_oid: []const u8, base_oid: []const u8, seen_head_oid: ?[]const u8 = null }) types.PrRecord {
    return .{
        .number = params.number,
        .node_id = "PR_x",
        .state = .open,
        .title = "t",
        .author = "a",
        .url = "u",
        .is_draft = false,
        .head_ref = params.head_ref,
        .base_ref = params.base_ref,
        .head_oid = params.head_oid,
        .base_oid = params.base_oid,
        .updated_at = "2026-01-02T00:00:00Z",
        .hydrated_at_update = null,
        .additions = 0,
        .deletions = 0,
        .changed_files = 0,
        .review_decision = "",
        .ci = .none,
        .labels = "",
        .requested_users = "",
        .requested_teams = "",
        .my_review_state = "",
        .my_review_oid = "",
        .seen_head_oid = params.seen_head_oid,
        .seen_merge_base_oid = null,
    };
}

fn expectOrder(params: struct { expected: []const usize, targets: []const Target, focus_number: u32 }) !void {
    const ordered = try order(.{ .allocator = testing.allocator, .targets = params.targets, .focus_number = params.focus_number });
    defer testing.allocator.free(ordered);
    try testing.expectEqualSlices(usize, params.expected, ordered);
}

fn expectRun(params: struct { kind: JobKind, index: usize, job: ?Job }) !void {
    const run = params.job.?.run;
    try testing.expectEqual(params.kind, run.kind);
    try testing.expectEqual(params.index, run.index);
}

fn identityOrder(comptime n: usize) [n]usize {
    var ordered: [n]usize = undefined;
    for (&ordered, 0..) |*slot, i| slot.* = i;
    return ordered;
}

test "order puts the focused PR first, then alternates below-then-above" {
    const targets = trunkTargets(7);
    try expectOrder(.{ .expected = &.{ 3, 4, 2, 5, 1, 6, 0 }, .targets = &targets, .focus_number = 4 });
}

test "order at the top of the list is just display order" {
    const targets = trunkTargets(5);
    try expectOrder(.{ .expected = &.{ 0, 1, 2, 3, 4 }, .targets = &targets, .focus_number = 1 });
}

test "order at the bottom of the list walks upward" {
    const targets = trunkTargets(4);
    try expectOrder(.{ .expected = &.{ 3, 2, 1, 0 }, .targets = &targets, .focus_number = 4 });
}

test "order treats an unknown focus number as the first row" {
    const targets = trunkTargets(4);
    try expectOrder(.{ .expected = &.{ 0, 1, 2, 3 }, .targets = &targets, .focus_number = 9999 });
    try expectOrder(.{ .expected = &.{ 0, 1, 2, 3 }, .targets = &targets, .focus_number = 0 });
}

test "order of an empty target list is empty" {
    try expectOrder(.{ .expected = &.{}, .targets = &.{}, .focus_number = 3 });
}

test "focusIndex finds the focused number" {
    const targets = trunkTargets(5);
    try testing.expectEqual(@as(usize, 2), focusIndex(&targets, 3));
    try testing.expectEqual(@as(usize, 0), focusIndex(&targets, 77));
}

test "capBatch limits to the cap" {
    const many = identityOrder(150);
    try testing.expectEqual(@as(usize, 100), capBatch(&many, fetch_cap).len);
    const few = identityOrder(5);
    try testing.expectEqual(@as(usize, 5), capBatch(&few, fetch_cap).len);
}

test "diffKeyFor trunk PR uses the PR's base_oid" {
    const inputs = diffKeyFor(trunkTarget(1), .pr).?;
    try testing.expectEqualStrings(oid_base, inputs.base_tip_oid);
    try testing.expectEqualStrings(oid_head, inputs.head_oid);
}

test "diffKeyFor trunk PR with unknown base_oid is null" {
    var target = trunkTarget(1);
    target.base = .{ .trunk = .{ .oid = "" } };
    try testing.expectEqual(@as(?KeyInputs, null), diffKeyFor(target, .pr));
}

test "diffKeyFor stacked PR uses the parent's head" {
    var target = trunkTarget(2);
    target.base = .{ .parent_pr = .{ .number = 1, .head_oid = oid_parent } };
    const inputs = diffKeyFor(target, .pr).?;
    try testing.expectEqualStrings(oid_parent, inputs.base_tip_oid);
    try testing.expectEqualStrings(oid_head, inputs.head_oid);
}

test "diffKeyFor whole_stack on a stack tip uses the trunk oid" {
    var target = trunkTarget(3);
    target.base = .{ .parent_pr = .{ .number = 2, .head_oid = oid_parent } };
    target.whole_stack = .{ .trunk_ref = "main", .trunk_oid = oid_base };
    const inputs = diffKeyFor(target, .whole_stack).?;
    try testing.expectEqualStrings(oid_base, inputs.base_tip_oid);
    try testing.expectEqualStrings(oid_head, inputs.head_oid);
}

test "diffKeyFor whole_stack on a non-tip is null" {
    try testing.expectEqual(@as(?KeyInputs, null), diffKeyFor(trunkTarget(1), .whole_stack));
}

test "diffKeyFor whole_stack with an unknown trunk oid is null" {
    var target = trunkTarget(3);
    target.whole_stack = .{ .trunk_ref = "main", .trunk_oid = "" };
    try testing.expectEqual(@as(?KeyInputs, null), diffKeyFor(target, .whole_stack));
}

test "targetFor builds a trunk base from the record" {
    const rec = record(.{ .number = 1, .head_ref = "a", .base_ref = "main", .head_oid = oid_parent, .base_oid = oid_base });
    const target = targetFor(.{ .rec = &rec });
    try testing.expectEqual(@as(u32, 1), target.number);
    try testing.expectEqualStrings("main", target.base_ref);
    try testing.expectEqualStrings(oid_parent, target.head_oid);
    try testing.expectEqualStrings("2026-01-02T00:00:00Z", target.updated_at);
    try testing.expectEqualStrings(oid_base, target.base.trunk.oid);
    try testing.expectEqual(@as(?WholeStack, null), target.whole_stack);
}

test "targetFor builds a parent_pr base when a parent is given" {
    const parent = record(.{ .number = 1, .head_ref = "a", .base_ref = "main", .head_oid = oid_parent, .base_oid = oid_base });
    const child = record(.{ .number = 2, .head_ref = "b", .base_ref = "a", .head_oid = oid_head, .base_oid = oid_parent });
    const target = targetFor(.{ .rec = &child, .parent = &parent });
    try testing.expectEqual(@as(u32, 1), target.base.parent_pr.number);
    try testing.expectEqualStrings(oid_parent, target.base.parent_pr.head_oid);
}

test "targetFor sets whole_stack only on a tip with a bottom" {
    const bottom = record(.{ .number = 1, .head_ref = "a", .base_ref = "main", .head_oid = oid_parent, .base_oid = oid_base });
    const tip = record(.{ .number = 2, .head_ref = "b", .base_ref = "a", .head_oid = oid_head, .base_oid = oid_parent });

    const as_tip = targetFor(.{ .rec = &tip, .parent = &bottom, .bottom = &bottom, .is_tip = true });
    try testing.expectEqualStrings("main", as_tip.whole_stack.?.trunk_ref);
    try testing.expectEqualStrings(oid_base, as_tip.whole_stack.?.trunk_oid);

    const not_tip = targetFor(.{ .rec = &tip, .parent = &bottom, .bottom = &bottom });
    try testing.expectEqual(@as(?WholeStack, null), not_tip.whole_stack);

    const no_bottom = targetFor(.{ .rec = &tip, .parent = &bottom, .is_tip = true });
    try testing.expectEqual(@as(?WholeStack, null), no_bottom.whole_stack);
}

test "nextJob returns fetch_batch while a capped target has no fetch attempt" {
    const targets = trunkTargets(3);
    const states = [_]JobState{.{}} ** 3;
    const ordered = identityOrder(3);
    const job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true });
    try testing.expect(job.? == .fetch_batch);
}

test "nextJob does not fetch targets beyond the fetch cap" {
    const targets = trunkTargets(120);
    var states = [_]JobState{.{}} ** 120;
    for (states[0..fetch_cap]) |*state| state.fetch_attempted = true;
    const ordered = identityOrder(120);
    const job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true });
    try expectRun(.{ .kind = .diff, .index = 0, .job = job });
}

test "nextJob never diffs a target whose fetch was not attempted" {
    var targets = trunkTargets(130);
    targets[110].whole_stack = .{ .trunk_ref = "main", .trunk_oid = oid_base };
    var states = [_]JobState{.{}} ** 130;
    for (states[0..fetch_cap]) |*state| state.* = .{ .fetch_attempted = true, .diff = .done, .threads = .done };
    const top = identityOrder(130);
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &targets, .ordered = &top, .states = &states, .threads_enabled = true }));

    // Focus moves past the cap: the unfetched targets now sit inside it.
    const bottom = try order(.{ .allocator = testing.allocator, .targets = &targets, .focus_number = 130 });
    defer testing.allocator.free(bottom);
    try testing.expect(nextJob(.{ .targets = &targets, .ordered = bottom, .states = &states, .threads_enabled = true }).? == .fetch_batch);

    for (states[100..]) |*state| state.fetch_attempted = true;
    try expectRun(.{ .kind = .diff, .index = 129, .job = nextJob(.{ .targets = &targets, .ordered = bottom, .states = &states, .threads_enabled = true }) });
}

test "nextJob runs the focused PR's diff first" {
    const targets = trunkTargets(5);
    const states = [_]JobState{.{ .fetch_attempted = true }} ** 5;
    const ordered = [_]usize{ 2, 3, 1, 4, 0 };
    const job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true });
    try expectRun(.{ .kind = .diff, .index = 2, .job = job });
}

test "nextJob does threads for the nearest 10 only after their diffs" {
    const targets = trunkTargets(15);
    var states = [_]JobState{.{ .fetch_attempted = true }} ** 15;
    const ordered = identityOrder(15);

    for (states[0..9]) |*state| state.diff = .done;
    try expectRun(.{ .kind = .diff, .index = 9, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });

    states[9].diff = .failed;
    try expectRun(.{ .kind = .threads, .index = 0, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });

    for (states[0..10]) |*state| state.threads = .done;
    try expectRun(.{ .kind = .diff, .index = 10, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });

    for (states[10..]) |*state| state.diff = .done;
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }));
}

test "nextJob skips threads when disabled" {
    const targets = trunkTargets(3);
    var states = [_]JobState{.{ .fetch_attempted = true, .diff = .done }} ** 3;
    const ordered = identityOrder(3);
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = false }));
    states[1].threads = .done;
    try expectRun(.{ .kind = .threads, .index = 0, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });
}

test "nextJob does whole-stack diffs for the nearest 10 before far diffs" {
    var targets = trunkTargets(12);
    targets[4].whole_stack = .{ .trunk_ref = "main", .trunk_oid = oid_base };
    var states = [_]JobState{.{ .fetch_attempted = true }} ** 12;
    for (states[0..10]) |*state| state.* = .{ .fetch_attempted = true, .diff = .done, .threads = .done };
    const ordered = identityOrder(12);
    try expectRun(.{ .kind = .whole_stack, .index = 4, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });

    states[4].whole_stack = .skipped;
    try expectRun(.{ .kind = .diff, .index = 10, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });
}

test "nextJob never schedules a whole-stack job for a target without a stack" {
    const targets = trunkTargets(2);
    const states = [_]JobState{.{ .fetch_attempted = true, .diff = .done, .threads = .done }} ** 2;
    const ordered = identityOrder(2);
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }));
}

test "nextJob returns null when every job is done, failed or skipped" {
    var targets = trunkTargets(3);
    targets[2].whole_stack = .{ .trunk_ref = "main", .trunk_oid = oid_base };
    const states = [_]JobState{
        .{ .fetch_attempted = true, .diff = .done, .threads = .failed },
        .{ .fetch_attempted = true, .diff = .failed, .threads = .skipped },
        .{ .fetch_attempted = true, .diff = .skipped, .threads = .done, .whole_stack = .done },
    };
    const ordered = identityOrder(3);
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }));
}

test "nextJob issues no diff or whole-stack job for an evicted view" {
    var targets = trunkTargets(12);
    targets[0].whole_stack = .{ .trunk_ref = "main", .trunk_oid = oid_base };
    var states = [_]JobState{.{ .fetch_attempted = true, .diff = .evicted, .threads = .done }} ** 12;
    states[0].whole_stack = .evicted;
    const ordered = identityOrder(12);
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }));
}

test "nextJob returns null for an empty target list" {
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &.{}, .ordered = &.{}, .states = &.{}, .threads_enabled = true }));
}

test "nextJob follows a moved focus without any state reset" {
    const targets = trunkTargets(20);
    var states = [_]JobState{.{ .fetch_attempted = true }} ** 20;
    states[0].diff = .done;

    const near_top = try order(.{ .allocator = testing.allocator, .targets = &targets, .focus_number = 1 });
    defer testing.allocator.free(near_top);
    try expectRun(.{ .kind = .diff, .index = 1, .job = nextJob(.{ .targets = &targets, .ordered = near_top, .states = &states, .threads_enabled = true }) });

    const moved = try order(.{ .allocator = testing.allocator, .targets = &targets, .focus_number = 18 });
    defer testing.allocator.free(moved);
    try expectRun(.{ .kind = .diff, .index = 17, .job = nextJob(.{ .targets = &targets, .ordered = moved, .states = &states, .threads_enabled = true }) });
}

const oid_seen = "5" ** 40;

test "diffKeyFor since_seen with a seen head keys off the seen head" {
    var target = trunkTarget(1);
    target.seen_head_oid = oid_seen;
    const inputs = diffKeyFor(target, .since_seen).?;
    try testing.expectEqualStrings(oid_seen, inputs.base_tip_oid);
    try testing.expectEqualStrings(oid_head, inputs.head_oid);
}

test "diffKeyFor since_seen without a seen head is null" {
    try testing.expectEqual(@as(?KeyInputs, null), diffKeyFor(trunkTarget(1), .since_seen));
}

test "targetFor copies a seen head that differs from the current head" {
    const rec = record(.{ .number = 1, .head_ref = "a", .base_ref = "main", .head_oid = oid_head, .base_oid = oid_base, .seen_head_oid = oid_seen });
    try testing.expectEqualStrings(oid_seen, targetFor(.{ .rec = &rec }).seen_head_oid.?);
}

test "targetFor drops a seen head equal to the current head" {
    const rec = record(.{ .number = 1, .head_ref = "a", .base_ref = "main", .head_oid = oid_head, .base_oid = oid_base, .seen_head_oid = oid_head });
    try testing.expectEqual(@as(?[]const u8, null), targetFor(.{ .rec = &rec }).seen_head_oid);
}

test "targetFor never turns the 40-zero sentinel into a seen head" {
    const rec = record(.{ .number = 1, .head_ref = "a", .base_ref = "main", .head_oid = oid_head, .base_oid = oid_base, .seen_head_oid = "0" ** 40 });
    try testing.expectEqual(@as(?[]const u8, null), targetFor(.{ .rec = &rec }).seen_head_oid);
}

test "targetFor drops an empty seen head" {
    const rec = record(.{ .number = 1, .head_ref = "a", .base_ref = "main", .head_oid = oid_head, .base_oid = oid_base, .seen_head_oid = "" });
    try testing.expectEqual(@as(?[]const u8, null), targetFor(.{ .rec = &rec }).seen_head_oid);
}

test "nextJob runs since_seen after whole_stack within thread_window" {
    var targets = trunkTargets(12);
    targets[3].whole_stack = .{ .trunk_ref = "main", .trunk_oid = oid_base };
    targets[3].seen_head_oid = oid_seen;
    targets[2].seen_head_oid = oid_seen;
    var states = [_]JobState{.{ .fetch_attempted = true, .diff = .done, .threads = .done }} ** 12;
    const ordered = identityOrder(12);
    try expectRun(.{ .kind = .whole_stack, .index = 3, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });

    states[3].whole_stack = .done;
    try expectRun(.{ .kind = .since_seen, .index = 2, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });

    states[2].since_seen = .done;
    try expectRun(.{ .kind = .since_seen, .index = 3, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });
}

test "nextJob runs since_seen before far diffs" {
    var targets = trunkTargets(12);
    targets[0].seen_head_oid = oid_seen;
    var states = [_]JobState{.{ .fetch_attempted = true }} ** 12;
    for (states[0..10]) |*state| state.* = .{ .fetch_attempted = true, .diff = .done, .threads = .done };
    const ordered = identityOrder(12);
    try expectRun(.{ .kind = .since_seen, .index = 0, .job = nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }) });
}

test "nextJob never schedules since_seen beyond thread_window" {
    var targets = trunkTargets(12);
    targets[11].seen_head_oid = oid_seen;
    const states = [_]JobState{.{ .fetch_attempted = true, .diff = .done, .threads = .done }} ** 12;
    const ordered = identityOrder(12);
    try testing.expectEqual(@as(?Job, null), nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }));
}

test "nextJob never schedules since_seen without a fetch attempt" {
    var targets = trunkTargets(1);
    targets[0].seen_head_oid = oid_seen;
    const states = [_]JobState{.{ .fetch_attempted = false, .diff = .done, .threads = .done }};
    const ordered = identityOrder(1);
    try testing.expect(nextJob(.{ .targets = &targets, .ordered = &ordered, .states = &states, .threads_enabled = true }).? == .fetch_batch);
}
