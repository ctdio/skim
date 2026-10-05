//! Offline end-to-end check of the PR sync engine: a temp SQLite DB, the
//! fake `gh` script, and a sequence of sync runs per scenario. Exit 0 when
//! every scenario passes. Run via `zig build harness-pr-sync`
//! (args: fake-gh path, captured dir).

const std = @import("std");
const skim_io = @import("skim_io");
const sync = @import("pr/sync/sync.zig");
const sync_parse = @import("pr/sync/sync_parse.zig");
const planner = @import("pr/sync/planner.zig");
const fixtures = @import("pr/sync/fixtures.zig");
const scenario = @import("pr/sync/scenario.zig");
const types = @import("pr/db/types.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectOk = scenario.expectOk;

const Scenario = struct {
    name: []const u8,
    run: *const fn (ctx: *Ctx) anyerror!void,
};

/// One scenario's `World` plus the captured responses it may replay.
const Ctx = struct {
    world: scenario.World,
    captured_dir: []const u8,

    /// `captured/<name>`, or null when the capture has not been run.
    fn readCaptured(self: *Ctx, name: []const u8) !?[]u8 {
        const a = self.world.arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.captured_dir, name });
        return std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }
};

const seed_now = scenario.World.seed_now;
/// Seed spacing that puts each next PR below the previous one's paging stop line.
const beyond_lookback_secs = planner.watermark_lookback_secs + 3600;

const auth_stderr_fallback = "To get started with GitHub CLI, please run:  gh auth login\n";
const network_stderr_fallback = "Post \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: no such host\n";

const scenarios = [_]Scenario{
    .{ .name = "first sync pages past 100", .run = firstSyncPagesPast100 },
    .{ .name = "incremental re-reads equal-timestamp PR", .run = incrementalEqualTimestamp },
    .{ .name = "equal timestamps across a page boundary", .run = equalTimestampPageBoundary },
    .{ .name = "closed and merged PRs leave the open set", .run = closedRemoval },
    .{ .name = "reconcile closes PRs the watermark missed", .run = reconcileClosesMissed },
    .{ .name = "hydrate only changed PRs", .run = hydrateOnlyChanged },
    .{ .name = "hydrate null node closes the PR", .run = hydrateNullNode },
    .{ .name = "auth failure leaves DB intact", .run = authFailureLeavesDb },
    .{ .name = "network failure mid-paging leaves watermark", .run = networkMidPaging },
    .{ .name = "gh not installed", .run = ghNotInstalled },
    .{ .name = "worker lifecycle", .run = workerLifecycle },
    .{ .name = "replay captured next.js responses", .run = replayCaptured },
    .{ .name = "teams cadence", .run = teamsCadence },
    .{ .name = "out-of-order rows are re-indexed", .run = outOfOrderRows },
    .{ .name = "gh failure mid-hydrate keeps earlier batches", .run = ghFailureMidHydrate },
    .{ .name = "an unresolved hydrate node is skipped until it changes", .run = unresolvedHydrateNode },
};

pub const std_options: std.Options = .{ .log_level = .err };

pub fn main(process_init: std.process.Init) !u8 {
    skim_io.init(process_init);
    const args = try process_init.minimal.args.toSlice(process_init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: harness_pr_sync <fake-gh> <captured-dir>\n", .{});
        return 2;
    }
    if (!fakeGhRunnable(process_init.arena.allocator())) {
        std.debug.print("SKIPPED: fake-gh needs bash and jq\n", .{});
        return 0;
    }

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    const work_dir = try makeWorkDir(process_init.arena.allocator());

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    for (scenarios, 0..) |entry, i| {
        const root = try std.fmt.allocPrint(process_init.arena.allocator(), "{s}/{d:0>2}", .{ work_dir, i + 1 });
        var ctx: Ctx = .{
            .world = setupWorld(.{ .allocator = allocator, .root = root, .fake_gh = args[1] }) catch |err| {
                failed += 1;
                std.debug.print("FAIL {s}: setup: {}\n", .{ entry.name, err });
                continue;
            },
            .captured_dir = args[2],
        };
        defer ctx.world.deinit();
        entry.run(&ctx) catch |err| switch (err) {
            error.Skipped => {
                skipped += 1;
                std.debug.print("SKIP {s}: captured/ is missing (run capture-sync.sh)\n", .{entry.name});
                continue;
            },
            else => {
                failed += 1;
                std.debug.print("FAIL {s}: {} (work dir kept: {s})\n", .{ entry.name, err, ctx.world.root });
                continue;
            },
        };
        passed += 1;
        std.debug.print("PASS {s}\n", .{entry.name});
    }

    if (debug_allocator.deinit() == .leak) {
        failed += 1;
        std.debug.print("FAIL memory: leaks reported above\n", .{});
    }
    std.debug.print("\n{d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
    if (failed > 0) return 1;
    std.Io.Dir.cwd().deleteTree(skim_io.get(), work_dir) catch |err| {
        std.debug.print("note: could not remove {s}: {}\n", .{ work_dir, err });
    };
    return 0;
}

// =============================================================================
// Scenarios
// =============================================================================

fn firstSyncPagesPast100(ctx: *Ctx) !void {
    const world = &ctx.world;
    const prs = try fixtures.synthPrs(world.arena.allocator(), .{ .count = 150, .newest_offset = 1000 });
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = prs[0..100], .has_next = true, .end_cursor = "c/1+=" });
    try step.index("c_1-.", .{ .prs = prs[100..] });
    const numbers = try world.arena.allocator().alloc(u32, prs.len);
    for (prs, numbers) |pr, *number| number.* = pr.number;
    try step.reconcile("first", .{ .numbers = numbers });
    try step.closed("first", .{ .rows = &.{} });
    try step.teams(null);
    try step.nodes(prs);
    try world.serve(&step);

    try expectOk(try world.run(.{}));

    try expectEqual(150, try world.openCount());
    var repo = try world.repo();
    defer repo.deinit();
    try expectEqualStrings(prs[0].updated_at, repo.row.open_watermark.?);
    try expectEqual(null, repo.row.last_sync_error);
    try expect(repo.row.last_sync_at > 0);

    const index_calls = try world.callsOf(.{ .step = 1, .op = "SkimSyncIndex" });
    try expectEqual(2, index_calls.len);
    try expectEqualStrings("first", index_calls[0].key);
    try expectEqualStrings("c_1-.", index_calls[1].key);

    const hydrates = try world.callsOf(.{ .step = 1, .op = "SkimSyncHydrate" });
    try expectEqual(6, hydrates.len);
    for (hydrates) |call| try expectEqual(25, call.ids.len);
    var stale = try world.store.needsHydrate(world.allocator, world.repo_id);
    defer stale.deinit();
    try expectEqual(0, stale.items.len);
}

fn incrementalEqualTimestamp(ctx: *Ctx) !void {
    const world = &ctx.world;
    const prs = try world.seed(.{ .count = 150, .newest_offset = 150 * beyond_lookback_secs, .spacing_secs = beyond_lookback_secs });
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    var retitled = prs[0];
    retitled.title = "retitled";
    try step.index("first", .{ .prs = &.{ retitled, prs[1] }, .has_next = true, .end_cursor = "c2" });
    try step.quietTail();
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    var open = try world.listOpen();
    defer open.deinit();
    try expectEqualStrings("retitled", recordOf(open.items, retitled.number).?.title);
    try expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    try expectEqual(0, try world.countCalls(.{ .step = 2, .op = "SkimSyncHydrate" }));
    var repo = try world.repo();
    defer repo.deinit();
    try expectEqualStrings(prs[0].updated_at, repo.row.open_watermark.?);
}

fn equalTimestampPageBoundary(ctx: *Ctx) !void {
    const world = &ctx.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 3 * beyond_lookback_secs, .spacing_secs = beyond_lookback_secs });
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    const tied_a: fixtures.SynthPr = .{ .number = 201, .updated_at = prs[0].updated_at };
    const tied_b: fixtures.SynthPr = .{ .number = 202, .updated_at = prs[0].updated_at };
    try step.index("first", .{ .prs = &.{ tied_a, prs[0] }, .has_next = true, .end_cursor = "c2" });
    try step.index("c2", .{ .prs = &.{ tied_b, prs[1] }, .has_next = true, .end_cursor = "c3" });
    try step.quietTail();
    try step.nodes(&.{ tied_a, tied_b });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try expectEqual(2, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    try expectEqual(types.PrState.open, (try world.stateOf(tied_b.number)).?);
}

fn closedRemoval(ctx: *Ctx) !void {
    const world = &ctx.world;
    _ = try world.seed(.{ .count = 10, .newest_offset = 1000 });
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    const newest_closed = try step.ts(2000);
    try step.index("first", .{ .prs = &.{} });
    try step.closed("first", .{ .rows = &.{
        .{ .number = 3, .state = "MERGED", .updated_at = newest_closed },
        .{ .number = 7, .state = "CLOSED", .updated_at = try step.ts(1999) },
        .{ .number = 999, .state = "CLOSED", .updated_at = try step.ts(1998) },
    } });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try expectEqual(8, try world.openCount());
    try expectEqual(types.PrState.merged, (try world.stateOf(3)).?);
    try expectEqual(types.PrState.closed, (try world.stateOf(7)).?);
    try expectEqual(null, try world.stateOf(999));
    var repo = try world.repo();
    defer repo.deinit();
    try expectEqualStrings(newest_closed, repo.row.closed_watermark.?);
}

fn reconcileClosesMissed(ctx: *Ctx) !void {
    const world = &ctx.world;
    _ = try world.seed(.{ .count = 120, .newest_offset = 1000 });
    for (1..10) |sync_index| {
        try world.serveQuiet();
        try expectOk(try world.run(.{ .sync_index = sync_index }));
    }

    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    try serveReconcileWithout(&step, &.{42});
    try world.serve(&step);
    try expectOk(try world.run(.{ .sync_index = 10 }));

    var all = try world.calls();
    defer all.deinit();
    for (all.items) |call| {
        if (!std.mem.eql(u8, call.op, "SkimSyncReconcile")) continue;
        try expect(call.step == 1 or call.step == 11);
    }
    try expectEqual(2, try world.countCalls(.{ .step = 11, .op = "SkimSyncReconcile" }));
    try expectEqual(null, std.mem.indexOfScalar(u32, try world.openNumbers(), 42));
    try expectEqual(119, try world.openCount());

    // Page 1 now also omits 43, so a partial apply would close it.
    var failing = scenario.Step.init(world.allocator);
    defer failing.deinit();
    try serveReconcileWithout(&failing, &.{ 42, 43 });
    try failing.fail("SkimSyncReconcile-c2", .{ .stderr = "gh: Something went wrong\n" });
    try world.serve(&failing);
    try expectEqual(sync.RunOutcome{ .failed = .other }, try world.run(.{ .sync_index = 20 }));
    try expectEqual(119, try world.openCount());
    var repo = try world.repo();
    defer repo.deinit();
    try expectEqualStrings("other", repo.row.last_sync_error.?);
}

fn hydrateOnlyChanged(ctx: *Ctx) !void {
    const world = &ctx.world;
    _ = try world.seed(.{ .count = 60, .newest_offset = 1000 });
    const a = world.arena.allocator();

    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    const bumped = [_]fixtures.SynthPr{
        .{ .number = 60, .updated_at = try step.ts(5000) },
        .{ .number = 17, .updated_at = try step.ts(4999) },
    };
    try step.index("first", .{ .prs = &bumped });
    try step.quietTail();
    try step.nodes(bumped[0..1]);
    try step.add("nodes/PR_synth17.json", try fixtures.synthHydrateNode(a, .{ .number = 17, .updated_at = bumped[1].updated_at, .additions = 777 }));
    try world.serve(&step);
    try expectOk(try world.run(.{ .sync_index = 1 }));

    const hydrates = try world.callsOf(.{ .step = 2, .op = "SkimSyncHydrate" });
    try expectEqual(1, hydrates.len);
    try expectEqual(2, hydrates[0].ids.len);
    try expectEqualStrings("PR_synth60", hydrates[0].ids[0]);
    try expectEqualStrings("PR_synth17", hydrates[0].ids[1]);
    try expectEqual(777, try world.additionsOf(17));

    // Priority puts 17 ahead of the newer 60.
    var prioritized = scenario.Step.init(world.allocator);
    defer prioritized.deinit();
    const again = [_]fixtures.SynthPr{
        .{ .number = 60, .updated_at = try prioritized.ts(6000) },
        .{ .number = 17, .updated_at = try prioritized.ts(5999) },
    };
    try prioritized.index("first", .{ .prs = &again });
    try prioritized.quietTail();
    try prioritized.nodes(&again);
    try world.serve(&prioritized);
    try expectOk(try world.run(.{ .sync_index = 2, .priority = &.{17} }));
    const ordered = try world.callsOf(.{ .step = 3, .op = "SkimSyncHydrate" });
    try expectEqualStrings("PR_synth17", ordered[0].ids[0]);

    // 230 changed PRs: 8 batches now, the last 30 on the next run.
    var many = scenario.Step.init(world.allocator);
    defer many.deinit();
    const new_prs = try fixtures.synthPrs(a, .{ .count = 230, .first_number = 1001, .newest_offset = 9000 });
    try many.indexPages(.{ .prs = new_prs });
    try many.quietTail();
    try many.nodes(new_prs);
    try world.serve(&many);
    try expectEqual(sync.RunOutcome{ .ok = .{ .hydrate_remaining = 30 } }, try world.run(.{ .sync_index = 3 }));
    try expectEqual(8, try world.countCalls(.{ .step = 4, .op = "SkimSyncHydrate" }));
    try expectEqual(sync.RunOutcome{ .ok = .{ .hydrate_remaining = 0 } }, try world.run(.{ .sync_index = 4 }));
    try expectEqual(10, try world.countCalls(.{ .step = 4, .op = "SkimSyncHydrate" }));
    try expectEqual(60 + 230, try world.openCount());
}

fn hydrateNullNode(ctx: *Ctx) !void {
    const world = &ctx.world;
    _ = try world.seed(.{ .count = 10, .newest_offset = 1000 });
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    const bumped = [_]fixtures.SynthPr{
        .{ .number = 4, .updated_at = try step.ts(3000) },
        .{ .number = 5, .updated_at = try step.ts(2999) },
    };
    try step.index("first", .{ .prs = &bumped });
    try step.quietTail();
    try addNodes(&step, .{ .prs = bumped[0..1], .additions = 404 });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try expectEqual(404, try world.additionsOf(4));
    try expectEqual(null, std.mem.indexOfScalar(u32, try world.openNumbers(), 5));
    try expectEqual(types.PrState.closed, (try world.stateOf(5)).?);
    var stale = try world.store.needsHydrate(world.allocator, world.repo_id);
    defer stale.deinit();
    try expectEqual(0, stale.items.len);
}

fn authFailureLeavesDb(ctx: *Ctx) !void {
    const world = &ctx.world;
    _ = try world.seed(.{ .count = 150, .newest_offset = 1000 });
    var before_open = try world.listOpen();
    defer before_open.deinit();
    var before_repo = try world.repo();
    defer before_repo.deinit();

    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    const stderr = (try ctx.readCaptured("auth-failure.stderr")) orelse auth_stderr_fallback;
    try step.fail("SkimSyncIndex", .{ .stderr = stderr, .code = 4 });
    try world.serve(&step);

    try expectEqual(sync.RunOutcome{ .failed = .not_authenticated }, try world.run(.{ .sync_index = 1, .now = seed_now + 60 }));

    var after_open = try world.listOpen();
    defer after_open.deinit();
    try std.testing.expectEqualDeep(before_open.items, after_open.items);
    var after_repo = try world.repo();
    defer after_repo.deinit();
    try expectEqualStrings("not_authenticated", after_repo.row.last_sync_error.?);
    try expectEqualStrings(before_repo.row.open_watermark.?, after_repo.row.open_watermark.?);
    try expectEqual(before_repo.row.closed_watermark, after_repo.row.closed_watermark);
    try expectEqual(before_repo.row.last_sync_at, after_repo.row.last_sync_at);

    try world.serveQuiet();
    try expectOk(try world.run(.{ .sync_index = 2, .now = seed_now + 120 }));
    var recovered = try world.repo();
    defer recovered.deinit();
    try expectEqual(null, recovered.row.last_sync_error);
    try expectEqual(seed_now + 120, recovered.row.last_sync_at);
}

fn networkMidPaging(ctx: *Ctx) !void {
    const world = &ctx.world;
    const seeded = try world.seed(.{ .count = 3, .newest_offset = 100 });
    const new_prs = try fixtures.synthPrs(world.arena.allocator(), .{ .count = 100, .first_number = 1001, .newest_offset = 300 });

    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    const stderr = (try ctx.readCaptured("network-failure.stderr")) orelse network_stderr_fallback;
    try step.index("first", .{ .prs = new_prs, .has_next = true, .end_cursor = "c2" });
    try step.fail("SkimSyncIndex-c2", .{ .stderr = stderr });
    try step.quietTail();
    try step.nodes(new_prs);
    try world.serve(&step);

    try expectEqual(sync.RunOutcome{ .failed = .network }, try world.run(.{ .sync_index = 1 }));
    try expectEqual(103, try world.openCount());
    var repo = try world.repo();
    defer repo.deinit();
    try expectEqualStrings(seeded[0].updated_at, repo.row.open_watermark.?);
    try expectEqual(0, try world.countCalls(.{ .step = 2, .op = "SkimSyncClosed" }));
    try expectEqual(0, try world.countCalls(.{ .step = 2, .op = "SkimSyncReconcile" }));

    var retry = scenario.Step.init(world.allocator);
    defer retry.deinit();
    try retry.index("first", .{ .prs = new_prs, .has_next = true, .end_cursor = "c2" });
    try retry.index("c2", .{ .prs = seeded });
    try retry.quietTail();
    try retry.nodes(new_prs);
    try world.serve(&retry);
    try expectOk(try world.run(.{ .sync_index = 2 }));
    var recovered = try world.repo();
    defer recovered.deinit();
    try expectEqualStrings(new_prs[0].updated_at, recovered.row.open_watermark.?);
    try expectEqual(null, recovered.row.last_sync_error);
}

fn ghNotInstalled(ctx: *Ctx) !void {
    const world = &ctx.world;
    _ = try world.seed(.{ .count = 3, .newest_offset = 1000 });
    var before = try world.repo();
    defer before.deinit();
    const missing = try std.fmt.allocPrint(world.arena.allocator(), "{s}/missing-gh", .{world.root});

    try expectEqual(sync.RunOutcome{ .failed = .not_installed }, try world.run(.{ .sync_index = 1, .gh_bin = missing }));

    try expectEqual(3, try world.openCount());
    var after = try world.repo();
    defer after.deinit();
    try expectEqualStrings("not_installed", after.row.last_sync_error.?);
    var expected = before.row;
    expected.last_sync_error = after.row.last_sync_error;
    try std.testing.expectEqualDeep(expected, after.row);
}

fn workerLifecycle(ctx: *Ctx) !void {
    const world = &ctx.world;
    const prs = try fixtures.synthPrs(world.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    try step.fullSync(.{ .prs = prs });
    try world.serve(&step);
    try world.setSleep(300);

    const options: sync.Options = .{
        .repo_key = scenario.repo_key,
        .owner = scenario.owner,
        .name = scenario.repo_name,
        .db_path = world.db_path,
        .gh_bin = world.gh,
        .interval_ms = 60_000,
    };
    const worker = try sync.SyncWorker.start(options);
    var stopped = false;
    defer if (!stopped) worker.stop();

    try waitForCalls(.{ .world = world, .op = "SkimSyncIndex", .at_least = 1, .deadline_ms = 5_000 });
    for (0..5) |_| worker.requestSync();
    try waitForCalls(.{ .world = world, .op = "SkimSyncIndex", .at_least = 2, .deadline_ms = 10_000 });
    try waitForIdle(worker);
    skim_io.sleep(700 * std.time.ns_per_ms);
    try expectEqual(2, try world.countCalls(.{ .step = 1, .op = "SkimSyncIndex" }));
    try expect(worker.generation() > 0);
    try expectEqual(null, worker.status().last_error);
    try expect(worker.status().last_ok_at != null);

    var timer = try skim_io.Timer.start();
    worker.stop();
    stopped = true;
    try expect(timer.read() < 2 * std.time.ns_per_s);

    // A second lifecycle on the same DB, stopped while a call is in flight.
    const again = try sync.SyncWorker.start(options);
    try waitForCalls(.{ .world = world, .op = "SkimSyncIndex", .at_least = 3, .deadline_ms = 5_000 });
    var second = try skim_io.Timer.start();
    again.stop();
    try expect(second.read() < 2 * std.time.ns_per_s);
}

fn replayCaptured(ctx: *Ctx) !void {
    const world = &ctx.world;
    const a = world.arena.allocator();
    const index_bytes = (try ctx.readCaptured("index-page1.json")) orelse return error.Skipped;
    const closed_bytes = (try ctx.readCaptured("closed-page1.json")) orelse return error.Skipped;
    const hydrate_bytes = (try ctx.readCaptured("hydrate-batch.json")) orelse return error.Skipped;
    const teams_bytes = (try ctx.readCaptured("teams-null-org.json")) orelse return error.Skipped;

    const index = try sync_parse.parseIndexPage(a, index_bytes);
    const closed = try sync_parse.parseClosedPage(a, closed_bytes);
    const rows = index.rows;
    try expectEqual(100, rows.len);
    try world.store.setWatermarks(world.repo_id, .{ .open = rows[0].updated_at });

    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    try step.add("SkimSyncIndex-first.json", index_bytes);
    try step.add("SkimSyncClosed-first.json", closed_bytes);
    try step.add("SkimSyncTeams-first.json", teams_bytes);
    const hydrate_nodes = try capturedNodes(a, hydrate_bytes);
    for (hydrate_nodes, rows[0..hydrate_nodes.len]) |node, row| {
        const path = try std.fmt.allocPrint(a, "nodes/{s}.json", .{row.node_id});
        try step.add(path, try std.json.Stringify.valueAlloc(a, node, .{}));
    }
    try world.serve(&step);

    // sync_index 1: a session's first run re-reads the whole index, and only
    // page 1 was captured.
    try expectOk(try world.run(.{ .sync_index = 1 }));
    try expectEqual(1, try world.countCalls(.{ .step = 1, .op = "SkimSyncIndex" }));

    var expected: std.ArrayList(u32) = .empty;
    for (rows[0..hydrate_nodes.len]) |row| {
        if (!containsClosed(closed.rows, row.number)) try expected.append(a, row.number);
    }
    std.mem.sort(u32, expected.items, {}, std.sort.asc(u32));
    try expectEqualSlices(u32, expected.items, try world.openNumbers());

    const refs = try a.alloc(types.NodeRef, hydrate_nodes.len);
    for (rows[0..hydrate_nodes.len], refs) |row, *ref| ref.* = .{ .number = row.number, .node_id = row.node_id, .updated_at = row.updated_at };
    const batch = try sync_parse.parseHydrate(a, .{ .bytes = hydrate_bytes, .refs = refs, .viewer_login = index.viewer_login });
    for (batch.rows) |row| {
        if (containsClosed(closed.rows, row.number)) continue;
        try expectEqual(row.additions, try world.additionsOf(row.number));
    }
}

fn teamsCadence(ctx: *Ctx) !void {
    const world = &ctx.world;
    const prs = try fixtures.synthPrs(world.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    var first = scenario.Step.init(world.allocator);
    defer first.deinit();
    try first.fullSync(.{ .prs = prs });
    try first.teams(&.{ "Core", "infra" });
    try world.serve(&first);
    try expectOk(try world.run(.{}));
    try expectEqual(1, try world.countCalls(.{ .step = 1, .op = "SkimSyncTeams" }));
    var repo = try world.repo();
    try expectEqualStrings("acme/core\nacme/infra", repo.row.viewer_teams);
    repo.deinit();

    try world.serveQuiet();
    try expectOk(try world.run(.{ .sync_index = 1, .now = seed_now + 60 }));
    try expectEqual(0, try world.countCalls(.{ .step = 2, .op = "SkimSyncTeams" }));

    var switched = scenario.Step.init(world.allocator);
    defer switched.deinit();
    try switched.index("first", .{ .prs = &.{}, .viewer_login = "someone-else" });
    try switched.quietTail();
    try switched.teams(&.{"platform"});
    try world.serve(&switched);
    try expectOk(try world.run(.{ .sync_index = 2, .now = seed_now + 120 }));
    try expectEqual(1, try world.countCalls(.{ .step = 3, .op = "SkimSyncTeams" }));
    repo = try world.repo();
    try expectEqualStrings("acme/platform", repo.row.viewer_teams);
    repo.deinit();

    var failing = scenario.Step.init(world.allocator);
    defer failing.deinit();
    try failing.index("first", .{ .prs = &.{}, .viewer_login = "someone-else" });
    try failing.quietTail();
    try failing.fail("SkimSyncTeams", .{ .stderr = "gh: Something went wrong\n" });
    try world.serve(&failing);
    try expectOk(try world.run(.{ .sync_index = 3, .now = seed_now + 3 * 86_400 }));
    try expectEqual(1, try world.countCalls(.{ .step = 4, .op = "SkimSyncTeams" }));
    repo = try world.repo();
    defer repo.deinit();
    try expectEqualStrings("acme/platform", repo.row.viewer_teams);
    try expectEqual(null, repo.row.last_sync_error);
}

fn outOfOrderRows(ctx: *Ctx) !void {
    const world = &ctx.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 100_000, .spacing_secs = 3600 });

    // #71 changed after the last run but sorts below #2, which is older than
    // the watermark yet inside the lookback, so page 2 is still read.
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    const newer: fixtures.SynthPr = .{ .number = 70, .updated_at = try step.ts(105_000) };
    const lagged: fixtures.SynthPr = .{ .number = 71, .updated_at = try step.ts(101_000), .title = "lagged" };
    try step.index("first", .{ .prs = &.{ newer, prs[0], prs[1] }, .has_next = true, .end_cursor = "c2" });
    try step.index("c2", .{ .prs = &.{ lagged, prs[2] } });
    try step.quietTail();
    try step.nodes(&.{ newer, lagged });
    try world.serve(&step);
    try expectOk(try world.run(.{ .sync_index = 1 }));
    try expectEqual(2, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    {
        var open = try world.listOpen();
        defer open.deinit();
        try expectEqualStrings("lagged", recordOf(open.items, lagged.number).?.title);
    }

    // #88 sorts more than the lookback late: an ordinary run stops above it,
    // the next reconcile run (sync_index 10) re-reads the whole index.
    const far: fixtures.SynthPr = .{ .number = 88, .updated_at = try step.ts(104_000) };
    const old: fixtures.SynthPr = .{ .number = 89, .updated_at = try step.ts(1000) };
    var far_step = scenario.Step.init(world.allocator);
    defer far_step.deinit();
    try far_step.index("first", .{ .prs = &.{ newer, old }, .has_next = true, .end_cursor = "c2" });
    try far_step.index("c2", .{ .prs = &.{far} });
    try far_step.reconcile("first", .{ .numbers = &.{ 1, 2, 3, 70, 71, 88, 89 } });
    try far_step.quietTail();
    try far_step.nodes(&.{ old, far });
    try world.serve(&far_step);
    try expectOk(try world.run(.{ .sync_index = 2 }));
    try expectEqual(1, try world.countCalls(.{ .step = 3, .op = "SkimSyncIndex" }));
    try expectEqual(null, try world.stateOf(far.number));

    try world.serve(&far_step);
    try expectOk(try world.run(.{ .sync_index = 10 }));
    try expectEqual(2, try world.countCalls(.{ .step = 4, .op = "SkimSyncIndex" }));
    try expectEqual(types.PrState.open, (try world.stateOf(far.number)).?);
    var repo = try world.repo();
    defer repo.deinit();
    try expectEqualStrings(newer.updated_at, repo.row.open_watermark.?);
}

fn ghFailureMidHydrate(ctx: *Ctx) !void {
    const world = &ctx.world;
    _ = try world.seed(.{ .count = 60, .newest_offset = 1000 });
    const bumped = try fixtures.synthPrs(world.arena.allocator(), .{ .count = 60, .newest_offset = 5000 });

    // Batch 1 is PRs 1..25 (newest first); PR 30's node is not JSON, so
    // the fake's jq fails the batch-2 call the way a crashed `gh` would.
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    try step.indexPages(.{ .prs = bumped });
    try step.quietTail();
    try addNodes(&step, .{ .prs = bumped, .additions = 1000 });
    try step.add("nodes/PR_synth30.json", "not json");
    try world.serve(&step);

    try expectEqual(sync.RunOutcome{ .failed = .other }, try world.run(.{ .sync_index = 1, .now = seed_now + 60 }));
    try expectEqual(2, try world.countCalls(.{ .step = 2, .op = "SkimSyncHydrate" }));
    try expectEqual(1000, try world.additionsOf(1));
    try expectEqual(1000, try world.additionsOf(25));
    try expectEqual(26, try world.additionsOf(26));
    {
        var stale = try world.store.needsHydrate(world.allocator, world.repo_id);
        defer stale.deinit();
        try expectEqual(35, stale.items.len);
        var failed_repo = try world.repo();
        defer failed_repo.deinit();
        try expectEqualStrings("other", failed_repo.row.last_sync_error.?);
        try expectEqualStrings(bumped[0].updated_at, failed_repo.row.open_watermark.?);
        try expectEqual(seed_now, failed_repo.row.last_sync_at);
    }

    var retry = scenario.Step.init(world.allocator);
    defer retry.deinit();
    try retry.index("first", .{ .prs = &.{} });
    try retry.quietTail();
    try addNodes(&retry, .{ .prs = bumped, .additions = 1000 });
    try world.serve(&retry);
    try expectOk(try world.run(.{ .sync_index = 2, .now = seed_now + 120 }));
    try expectEqual(1000, try world.additionsOf(30));
    var after = try world.store.needsHydrate(world.allocator, world.repo_id);
    defer after.deinit();
    try expectEqual(0, after.items.len);
    var repo = try world.repo();
    defer repo.deinit();
    try expectEqual(null, repo.row.last_sync_error);
}

fn unresolvedHydrateNode(ctx: *Ctx) !void {
    const world = &ctx.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    // #1 and #2 changed; GitHub answers #2's slot with null + FORBIDDEN.
    var step = scenario.Step.init(world.allocator);
    defer step.deinit();
    var first = prs[0];
    first.updated_at = try step.ts(1200);
    var second = prs[1];
    second.updated_at = try step.ts(1199);
    try step.index("first", .{ .prs = &.{ first, second } });
    try step.quietTail();
    try addNodes(&step, .{ .prs = &.{first}, .additions = 777 });
    try step.forbidden(&.{second});
    for (1..4) |run| {
        try world.serve(&step);
        try expectOk(try world.run(.{ .sync_index = run, .now = seed_now + @as(i64, @intCast(run)) * 60 }));
    }
    try expectEqual(777, try world.additionsOf(first.number));
    try expectEqual(2, try world.additionsOf(second.number));
    try expectEqual(types.PrState.open, (try world.stateOf(second.number)).?);
    try expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncHydrate" }));
    try expectEqual(0, try world.countCalls(.{ .step = 3, .op = "SkimSyncHydrate" }));
    try expectEqual(0, try world.countCalls(.{ .step = 4, .op = "SkimSyncHydrate" }));
    {
        var stale = try world.store.needsHydrate(world.allocator, world.repo_id);
        defer stale.deinit();
        try expectEqual(0, stale.items.len);
        var repo = try world.repo();
        defer repo.deinit();
        try expectEqual(null, repo.row.last_sync_error);
        try expectEqual(seed_now + 180, repo.row.last_sync_at);
    }

    // A worker on the same state (its first run reconciles, as every
    // worker's does) syncs ok without asking for #2 again.
    try step.reconcile("first", .{ .numbers = &.{ 1, 2, 3 } });
    try step.teams(&.{"core"});
    try world.serve(&step);
    {
        const worker = try sync.SyncWorker.start(.{
            .repo_key = scenario.repo_key,
            .owner = scenario.owner,
            .name = scenario.repo_name,
            .db_path = world.db_path,
            .gh_bin = world.gh,
            .interval_ms = 60_000,
        });
        defer worker.stop();
        try waitForCalls(.{ .world = world, .op = "SkimSyncIndex", .at_least = 5, .deadline_ms = 5_000 });
        try waitForIdle(worker);
        skim_io.sleep(1000 * std.time.ns_per_ms);
        try expectEqual(1, try world.countCalls(.{ .step = 5, .op = "SkimSyncIndex" }));
        try expectEqual(0, try world.countCalls(.{ .step = 5, .op = "SkimSyncHydrate" }));
        try expectEqual(null, worker.status().last_error);
        try expect(worker.status().last_ok_at != null);
    }

    // #2 changes on GitHub and is accessible again: it is asked for and hydrates.
    var changed = scenario.Step.init(world.allocator);
    defer changed.deinit();
    var rebumped = second;
    rebumped.updated_at = try changed.ts(1300);
    try changed.index("first", .{ .prs = &.{rebumped} });
    try changed.quietTail();
    try addNodes(&changed, .{ .prs = &.{rebumped}, .additions = 888 });
    try world.serve(&changed);
    try expectOk(try world.run(.{ .sync_index = 5, .now = seed_now + 600 }));
    const hydrates = try world.callsOf(.{ .step = 6, .op = "SkimSyncHydrate" });
    try expectEqual(1, hydrates.len);
    try expectEqual(1, hydrates[0].ids.len);
    try expectEqualStrings("PR_synth2", hydrates[0].ids[0]);
    try expectEqual(888, try world.additionsOf(second.number));
    var after = try world.store.needsHydrate(world.allocator, world.repo_id);
    defer after.deinit();
    try expectEqual(0, after.items.len);
}

// =============================================================================
// Helpers
// =============================================================================

/// A hydrate node per PR carrying the PR's `updated_at` and `additions`.
fn addNodes(step: *scenario.Step, params: struct { prs: []const fixtures.SynthPr, additions: u32 }) !void {
    const a = step.arena.allocator();
    for (params.prs) |pr| {
        const path = try std.fmt.allocPrint(a, "nodes/{s}.json", .{try fixtures.nodeId(a, pr.number)});
        try step.add(path, try fixtures.synthHydrateNode(a, .{ .number = pr.number, .updated_at = pr.updated_at, .additions = params.additions }));
    }
}

/// Create `params.root` and open a `World` in it.
fn setupWorld(params: scenario.World.InitParams) !scenario.World {
    try std.Io.Dir.cwd().createDirPath(skim_io.get(), params.root);
    return scenario.World.init(params);
}

/// Index, closed and a two-page reconcile (100 + the rest of PRs 1..120)
/// that leaves out `omit`.
fn serveReconcileWithout(step: *scenario.Step, omit: []const u32) !void {
    const a = step.arena.allocator();
    var numbers: std.ArrayList(u32) = .empty;
    for (1..121) |n| {
        const number: u32 = @intCast(n);
        if (std.mem.indexOfScalar(u32, omit, number) == null) try numbers.append(a, number);
    }
    try step.index("first", .{ .prs = &.{} });
    try step.quietTail();
    try step.reconcile("first", .{ .numbers = numbers.items[0..100], .has_next = true, .end_cursor = "c2" });
    try step.reconcile("c2", .{ .numbers = numbers.items[100..] });
}

/// The `data.nodes` elements of a captured hydrate response.
fn capturedNodes(a: std.mem.Allocator, bytes: []const u8) ![]const std.json.Value {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const data = root.object.get("data") orelse return error.MissingField;
    const nodes = data.object.get("nodes") orelse return error.MissingField;
    return nodes.array.items;
}

fn containsClosed(rows: []const types.ClosedRow, number: u32) bool {
    for (rows) |row| {
        if (row.number == number) return true;
    }
    return false;
}

fn recordOf(records: []const types.PrRecord, number: u32) ?types.PrRecord {
    for (records) |record| {
        if (record.number == number) return record;
    }
    return null;
}

fn waitForCalls(params: struct { world: *scenario.World, op: []const u8, at_least: usize, deadline_ms: u64 }) !void {
    var timer = try skim_io.Timer.start();
    while (true) {
        var all = try params.world.calls();
        const n = all.count(params.op);
        all.deinit();
        if (n >= params.at_least) return;
        if (timer.read() > params.deadline_ms * std.time.ns_per_ms) return error.Timeout;
        skim_io.sleep(20 * std.time.ns_per_ms);
    }
}

fn waitForIdle(worker: *sync.SyncWorker) !void {
    var timer = try skim_io.Timer.start();
    while (worker.status().running) {
        if (timer.read() > 10 * std.time.ns_per_s) return error.Timeout;
        skim_io.sleep(20 * std.time.ns_per_ms);
    }
}

/// `bash -c 'command -v jq'` succeeds, so the fake can run.
fn fakeGhRunnable(allocator: std.mem.Allocator) bool {
    const result = std.process.run(allocator, skim_io.get(), .{ .argv = &.{ "bash", "-c", "command -v jq" } }) catch return false;
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// `.zig-cache/tmp/harness-pr-sync-<hex>`, absolute and created.
fn makeWorkDir(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [6]u8 = undefined;
    skim_io.get().random(&bytes);
    const relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/harness-pr-sync-{x}", .{&bytes});
    try std.Io.Dir.cwd().createDirPath(skim_io.get(), relative);
    return skim_io.absolutePathAlloc(allocator, relative);
}
