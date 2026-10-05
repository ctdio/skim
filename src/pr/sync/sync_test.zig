//! `runOnce` and `SyncWorker` against a real temp SQLite DB and the real
//! fake `gh` script. Kept out of `sync.zig` because it imports
//! `test_support.zig` (and through it `pr_sync_options`), which only
//! `pr_sync_test_root.zig` provides; `sync.zig` itself is imported by roots
//! that do not have that module.

const std = @import("std");
const skim_io = @import("skim_io");
const github = @import("../github.zig");
const types = @import("../db/types.zig");
const sync = @import("sync.zig");
const planner = @import("planner.zig");
const fixtures = @import("fixtures.zig");
const scenario = @import("scenario.zig");
const test_support = @import("test_support.zig");

const testing = std.testing;

const auth_failure_stderr = @embedFile("sync_fixture_auth_failure_stderr");
const network_failure_stderr = @embedFile("sync_fixture_network_failure_stderr");
const not_found_repo = @embedFile("sync_fixture_not_found_repo");

const repo_key = scenario.repo_key;
const owner = scenario.owner;
const repo_name = scenario.repo_name;
const expectOk = scenario.expectOk;

/// Seed spacing that puts each next PR below the previous one's paging stop line.
const beyond_lookback_secs = planner.watermark_lookback_secs + 3600;

// =============================================================================
// runOnce
// =============================================================================

test "first sync pages until hasNextPage is false and stores all open PRs" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 150, .newest_offset = 10_000 });
    try step.fullSync(.{ .prs = prs, .page_size = 100 });
    try world.serve(&step);

    const outcome = try world.run(.{});
    try testing.expectEqual(sync.RunOutcome{ .ok = .{ .hydrate_remaining = 0 } }, outcome);

    var open = try world.store.listOpen(testing.allocator, world.repo_id);
    defer open.deinit();
    try testing.expectEqual(150, open.items.len);
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings(prs[0].updated_at, repo.row.open_watermark.?);
    try testing.expectEqual(2, try world.countCalls(.{ .step = 1, .op = "SkimSyncIndex" }));
}

test "first sync runs reconcile and one closed page" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try step.closed("first", .{ .rows = &.{}, .has_next = true, .end_cursor = "c2" });
    try world.serve(&step);

    try expectOk(try world.run(.{}));

    var calls = try world.calls();
    defer calls.deinit();
    try testing.expectEqual(1, calls.count("SkimSyncReconcile"));
    const closed = try calls.of("SkimSyncClosed");
    try testing.expectEqual(1, closed.len);
    try testing.expectEqualStrings("first", closed[0].key);
}

test "incremental sync stops at the page that ends below the lookback line" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 100_000, .spacing_secs = beyond_lookback_secs });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const newer: fixtures.SynthPr = .{ .number = 50, .updated_at = try step.ts(110_000) };
    try step.index("first", .{ .prs = &.{ newer, prs[2] }, .has_next = true, .end_cursor = "c2" });
    try step.quietTail();
    try step.nodes(&.{newer});
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try testing.expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    try testing.expectEqual(4, try world.openCount());
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings(newer.updated_at, repo.row.open_watermark.?);
}

test "incremental sync re-reads a PR updated in the same second as the watermark" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    var renamed = prs[0];
    renamed.title = "renamed in the same second";
    try step.index("first", .{ .prs = &.{renamed}, .has_next = false });
    try step.quietTail();
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    var open = try world.store.listOpen(testing.allocator, world.repo_id);
    defer open.deinit();
    try testing.expectEqualStrings("renamed in the same second", recordOf(open.items, renamed.number).?.title);
}

test "equal timestamps at a page boundary fetch the next page" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 100_000, .spacing_secs = beyond_lookback_secs });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const newest: fixtures.SynthPr = .{ .number = 60, .updated_at = try step.ts(100_100) };
    const tied: fixtures.SynthPr = .{ .number = 61, .updated_at = prs[0].updated_at };
    try step.index("first", .{ .prs = &.{ newest, prs[0] }, .has_next = true, .end_cursor = "c2" });
    try step.index("c2", .{ .prs = &.{tied}, .has_next = true, .end_cursor = "c3" });
    try step.index("c3", .{ .prs = &.{prs[1]}, .has_next = true, .end_cursor = "c4" });
    try step.quietTail();
    try step.nodes(&.{ newest, tied });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try testing.expectEqual(3, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    var open = try world.store.listOpen(testing.allocator, world.repo_id);
    defer open.deinit();
    try testing.expect(recordOf(open.items, tied.number) != null);
}

test "a PR newer than the watermark that sorts below a stop-worthy page is still stored" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 100_000, .spacing_secs = 3600 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const newer: fixtures.SynthPr = .{ .number = 70, .updated_at = try step.ts(105_000) };
    // GitHub's sort key lags updatedAt: #71 changed after the last run yet
    // sorts after prs[1], which is older than the watermark.
    const lagged: fixtures.SynthPr = .{ .number = 71, .updated_at = try step.ts(101_000), .title = "lagged" };
    try step.index("first", .{ .prs = &.{ newer, prs[0], prs[1] }, .has_next = true, .end_cursor = "c2" });
    try step.index("c2", .{ .prs = &.{ lagged, prs[2] } });
    try step.quietTail();
    try step.nodes(&.{ newer, lagged });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try testing.expectEqual(2, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    var open = try world.listOpen();
    defer open.deinit();
    try testing.expectEqualStrings("lagged", recordOf(open.items, lagged.number).?.title);
    try testing.expectEqual(lagged.number, recordOf(open.items, lagged.number).?.additions);
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings(newer.updated_at, repo.row.open_watermark.?);
}

test "a non-reconcile run does not page past the lookback line" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 100_000, .spacing_secs = beyond_lookback_secs });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try serveFarLaggedPr(&step, prs);
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try testing.expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    try testing.expectEqual(null, try world.stateOf(far_lagged_number));
}

test "a reconcile run re-reads the whole open index regardless of the watermark" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 100_000, .spacing_secs = beyond_lookback_secs });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try serveFarLaggedPr(&step, prs);
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 10 }));

    try testing.expectEqual(2, try world.countCalls(.{ .step = 2, .op = "SkimSyncIndex" }));
    try testing.expectEqual(types.PrState.open, (try world.stateOf(far_lagged_number)).?);
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings(prs[0].updated_at, repo.row.open_watermark.?);
}

test "closed page removes a stored open PR" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.closed("first", .{ .rows = &.{.{ .number = prs[1].number, .state = "MERGED", .updated_at = try step.ts(1500) }} });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    const open = try world.openNumbers();
    try testing.expectEqualSlices(u32, &.{ prs[0].number, prs[2].number }, open);
}

test "a malformed closed watermark reads one closed page and is replaced" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 3, .newest_offset = 1000 });
    try world.store.setWatermarks(world.repo_id, .{ .closed = "not-a-timestamp" });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const newest_closed = try step.ts(900);
    try step.index("first", .{ .prs = &.{} });
    try step.closed("first", .{ .rows = &.{.{ .number = 500, .updated_at = newest_closed }}, .has_next = true, .end_cursor = "c2" });
    try step.closed("c2", .{ .rows = &.{.{ .number = 400, .updated_at = try step.ts(1) }} });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 60 }));

    try testing.expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncClosed" }));
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings(newest_closed, repo.row.closed_watermark.?);
}

test "a malformed open watermark is replaced by the newest open row" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });
    try world.store.setWatermarks(world.repo_id, .{ .open = "not-a-timestamp" });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = prs });
    try step.quietTail();
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 60 }));

    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings(prs[0].updated_at, repo.row.open_watermark.?);
}

test "closed row for an unknown PR is ignored" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.closed("first", .{ .rows = &.{.{ .number = 999, .updated_at = try step.ts(1500) }} });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try testing.expectEqual(3, try world.openCount());
    try testing.expectEqual(3, try world.rowCount());
}

test "closed rows map MERGED to .merged and CLOSED to .closed in the stored state" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.closed("first", .{ .rows = &.{
        .{ .number = prs[0].number, .state = "MERGED", .updated_at = try step.ts(1500) },
        .{ .number = prs[1].number, .state = "CLOSED", .updated_at = try step.ts(1400) },
    } });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    try testing.expectEqual(types.PrState.merged, (try world.stateOf(prs[0].number)).?);
    try testing.expectEqual(types.PrState.closed, (try world.stateOf(prs[1].number)).?);
    try testing.expectEqual(types.PrState.open, (try world.stateOf(prs[2].number)).?);
}

test "reconcile on sync_index 10, not 9, closes PRs missing from the full open set" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.reconcile("first", .{ .numbers = &.{ prs[0].number, prs[2].number } });
    try step.closed("first", .{ .rows = &.{} });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 9 }));
    try testing.expectEqual(3, try world.openCount());

    try expectOk(try world.run(.{ .sync_index = 10 }));
    const open = try world.openNumbers();
    try testing.expectEqualSlices(u32, &.{ prs[0].number, prs[2].number }, open);
    try testing.expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncReconcile" }));
}

test "reconcile failure on page 2 closes nothing" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.reconcile("first", .{ .numbers = &.{prs[0].number}, .has_next = true, .end_cursor = "c2" });
    try step.fail("SkimSyncReconcile-c2", .{ .stderr = network_failure_stderr });
    try world.serve(&step);

    const outcome = try world.run(.{ .sync_index = 10 });

    try testing.expectEqual(sync.RunOutcome{ .failed = .network }, outcome);
    try testing.expectEqual(3, try world.openCount());
}

test "the first run of a worker session reconciles even with a watermark" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.reconcile("first", .{ .numbers = &.{ prs[1].number, prs[2].number } });
    try step.closed("first", .{ .rows = &.{} });
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 0 }));

    try testing.expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncReconcile" }));
    try testing.expectEqualSlices(u32, &.{ prs[1].number, prs[2].number }, try world.openNumbers());
}

test "hydrate requests only PRs whose updated_at changed" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    var bumped = prs[1];
    bumped.updated_at = try step.ts(1200);
    try step.index("first", .{ .prs = &.{bumped} });
    try step.quietTail();
    try step.nodes(&.{bumped});
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1 }));

    var calls = try world.calls();
    defer calls.deinit();
    const hydrates = try calls.of("SkimSyncHydrate");
    const last = hydrates[hydrates.len - 1];
    try testing.expectEqual(2, last.step);
    try testing.expectEqual(1, last.ids.len);
    try testing.expectEqualStrings("PR_synth2", last.ids[0]);
}

test "hydrate null node closes that PR" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs, .with_nodes = false });
    try step.nodes(&.{ prs[0], prs[2] });
    try world.serve(&step);

    try expectOk(try world.run(.{}));

    const open = try world.openNumbers();
    try testing.expectEqualSlices(u32, &.{ prs[0].number, prs[2].number }, open);
    try testing.expectEqual(types.PrState.closed, (try world.stateOf(prs[1].number)).?);
}

test "hydrate applies priority numbers first" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 30, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try world.serve(&step);

    try expectOk(try world.run(.{ .priority = &.{30} }));

    var calls = try world.calls();
    defer calls.deinit();
    const hydrates = try calls.of("SkimSyncHydrate");
    try testing.expectEqual(2, hydrates.len);
    try testing.expectEqual(25, hydrates[0].ids.len);
    try testing.expectEqualStrings("PR_synth30", hydrates[0].ids[0]);
    try testing.expectEqualStrings("PR_synth1", hydrates[0].ids[1]);
}

test "hydrate stops after 8 batches and reports remaining" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 250, .newest_offset = 10_000 });
    try step.fullSync(.{ .prs = prs, .page_size = 100 });
    try world.serve(&step);

    const outcome = try world.run(.{});

    try testing.expectEqual(sync.RunOutcome{ .ok = .{ .hydrate_remaining = 50 } }, outcome);
    try testing.expectEqual(8, try world.countCalls(.{ .step = 1, .op = "SkimSyncHydrate" }));
    var stale = try world.store.needsHydrate(testing.allocator, world.repo_id);
    defer stale.deinit();
    try testing.expectEqual(50, stale.items.len);
}

test "auth failure records last_sync_error and changes nothing else" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 3, .newest_offset = 1000 });
    var before_repo = try world.repo();
    defer before_repo.deinit();
    var before_open = try world.store.listOpen(testing.allocator, world.repo_id);
    defer before_open.deinit();

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.fail("SkimSyncIndex", .{ .stderr = auth_failure_stderr, .code = 4 });
    try world.serve(&step);

    const outcome = try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 600 });

    try testing.expectEqual(sync.RunOutcome{ .failed = .not_authenticated }, outcome);
    var after_repo = try world.repo();
    defer after_repo.deinit();
    try testing.expectEqualStrings("not_authenticated", after_repo.row.last_sync_error.?);
    try testing.expectEqual(scenario.World.seed_now, after_repo.row.last_sync_at);
    var expected = before_repo.row;
    expected.last_sync_error = after_repo.row.last_sync_error;
    try testing.expectEqualDeep(expected, after_repo.row);
    var after_open = try world.store.listOpen(testing.allocator, world.repo_id);
    defer after_open.deinit();
    try testing.expectEqualDeep(before_open.items, after_open.items);
}

test "network failure on index page 2 keeps page 1 rows and does not advance the watermark" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 100, .newest_offset = 1000 });
    try step.index("first", .{ .prs = prs, .has_next = true, .end_cursor = "c2" });
    try step.fail("SkimSyncIndex-c2", .{ .stderr = network_failure_stderr });
    try world.serve(&step);

    const outcome = try world.run(.{});

    try testing.expectEqual(sync.RunOutcome{ .failed = .network }, outcome);
    try testing.expectEqual(100, try world.openCount());
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqual(null, repo.row.open_watermark);
    try testing.expectEqual(0, repo.row.last_sync_at);
    try testing.expectEqualStrings("network", repo.row.last_sync_error.?);
}

test "teams failure does not fail the run" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try step.fail("SkimSyncTeams", .{ .stderr = "gh: Something went wrong\n" });
    try world.serve(&step);

    try expectOk(try world.run(.{}));

    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqual(0, repo.row.teams_synced_at);
    try testing.expectEqual(scenario.World.seed_now, repo.row.last_sync_at);
    try testing.expectEqual(null, repo.row.last_sync_error);
    try testing.expectEqual(1, try world.countCalls(.{ .step = 1, .op = "SkimSyncHydrate" }));
}

test "a malformed teams body does not fail the run" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try step.add("SkimSyncTeams-first.json", "{\"data\":{\"viewer\":");
    try world.serve(&step);

    try expectOk(try world.run(.{}));

    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqual(0, repo.row.teams_synced_at);
    try testing.expectEqual(null, repo.row.last_sync_error);
    try testing.expectEqual(3, try world.openCount());
}

test "a FORBIDDEN hydrate node alone in its batch is marked hydrated and the run is ok" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    var bumped = prs[1];
    bumped.updated_at = try step.ts(1200);
    try step.index("first", .{ .prs = &.{bumped} });
    try step.quietTail();
    try step.forbidden(&.{bumped});
    try world.serve(&step);
    const now = scenario.World.seed_now + 60;

    try testing.expectEqual(sync.RunOutcome{ .ok = .{ .hydrate_remaining = 0 } }, try world.run(.{ .sync_index = 1, .now = now }));

    try testing.expectEqual(types.PrState.open, (try world.stateOf(bumped.number)).?);
    try testing.expectEqual(bumped.number, try world.additionsOf(bumped.number));
    var stale = try world.store.needsHydrate(testing.allocator, world.repo_id);
    defer stale.deinit();
    try testing.expectEqual(0, stale.items.len);
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqual(null, repo.row.last_sync_error);
    try testing.expectEqual(now, repo.row.last_sync_at);
}

test "a FORBIDDEN hydrate node does not fail the run and is not re-requested while unchanged" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const a = step.arena.allocator();
    var first = prs[0];
    first.updated_at = try step.ts(1200);
    var second = prs[1];
    second.updated_at = try step.ts(1199);
    try step.index("first", .{ .prs = &.{ first, second } });
    try step.quietTail();
    try step.add(
        try std.fmt.allocPrint(a, "nodes/{s}.json", .{try fixtures.nodeId(a, first.number)}),
        try fixtures.synthHydrateNode(a, .{ .number = first.number, .updated_at = first.updated_at, .additions = 777 }),
    );
    try step.forbidden(&.{second});

    for (1..4) |run| {
        try world.serve(&step);
        try expectOk(try world.run(.{ .sync_index = run, .now = scenario.World.seed_now + @as(i64, @intCast(run)) * 60 }));
    }

    try testing.expectEqual(777, try world.additionsOf(first.number));
    try testing.expectEqual(types.PrState.open, (try world.stateOf(second.number)).?);
    var stale = try world.store.needsHydrate(testing.allocator, world.repo_id);
    defer stale.deinit();
    try testing.expectEqual(0, stale.items.len);
    // Seeding was step 1, so the runs are steps 2-4; only run 1 hydrates.
    try testing.expectEqual(2, (try world.callsOf(.{ .step = 2, .op = "SkimSyncHydrate" }))[0].ids.len);
    try testing.expectEqual(0, try world.countCalls(.{ .step = 3, .op = "SkimSyncHydrate" }));
    try testing.expectEqual(0, try world.countCalls(.{ .step = 4, .op = "SkimSyncHydrate" }));
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqual(null, repo.row.last_sync_error);
    try testing.expectEqual(scenario.World.seed_now + 180, repo.row.last_sync_at);
}

test "an unresolved PR is re-requested once GitHub reports a new updated_at" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    var bumped = prs[1];
    bumped.updated_at = try step.ts(1200);
    try step.index("first", .{ .prs = &.{bumped} });
    try step.quietTail();
    try step.forbidden(&.{bumped});
    try world.serve(&step);
    try expectOk(try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 60 }));

    var changed = scenario.Step.init(testing.allocator);
    defer changed.deinit();
    const a = changed.arena.allocator();
    var rebumped = bumped;
    rebumped.updated_at = try changed.ts(1300);
    try changed.index("first", .{ .prs = &.{rebumped} });
    try changed.quietTail();
    try changed.add(
        try std.fmt.allocPrint(a, "nodes/{s}.json", .{try fixtures.nodeId(a, rebumped.number)}),
        try fixtures.synthHydrateNode(a, .{ .number = rebumped.number, .updated_at = rebumped.updated_at, .additions = 888 }),
    );
    try world.serve(&changed);
    try expectOk(try world.run(.{ .sync_index = 2, .now = scenario.World.seed_now + 120 }));

    const hydrates = try world.callsOf(.{ .step = 3, .op = "SkimSyncHydrate" });
    try testing.expectEqual(1, hydrates.len);
    try testing.expectEqual(1, hydrates[0].ids.len);
    try testing.expectEqualStrings("PR_synth2", hydrates[0].ids[0]);
    try testing.expectEqual(888, try world.additionsOf(rebumped.number));
    var stale = try world.store.needsHydrate(testing.allocator, world.repo_id);
    defer stale.deinit();
    try testing.expectEqual(0, stale.items.len);
}

test "an unresolved hydrate node does not stop later batches" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 30, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs, .with_nodes = false });
    try step.nodes(prs[0..1]);
    try step.nodes(prs[2..]);
    try step.forbidden(prs[1..2]);
    try world.serve(&step);

    try testing.expectEqual(sync.RunOutcome{ .ok = .{ .hydrate_remaining = 0 } }, try world.run(.{}));

    try testing.expectEqual(2, try world.countCalls(.{ .step = 1, .op = "SkimSyncHydrate" }));
    try testing.expectEqual(30, try world.additionsOf(30));
    try testing.expectEqual(0, try world.additionsOf(prs[1].number));
    var stale = try world.store.needsHydrate(testing.allocator, world.repo_id);
    defer stale.deinit();
    try testing.expectEqual(0, stale.items.len);
    try testing.expectEqual(30, try world.openCount());
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqual(null, repo.row.last_sync_error);
    try testing.expectEqualStrings(prs[0].updated_at, repo.row.open_watermark.?);
}

test "viewer login change triggers a teams refresh" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{}, .viewer_login = "someone-else" });
    try step.closed("first", .{ .rows = &.{} });
    try step.teams(&.{"Infra"});
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 1 }));

    try testing.expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncTeams" }));
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings("someone-else", repo.row.viewer_login.?);
    try testing.expectEqualStrings("acme/infra", repo.row.viewer_teams);
}

test "teams are not refetched for the same viewer within the TTL" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.quietTail();
    try world.serve(&step);

    try expectOk(try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 60 }));

    try testing.expectEqual(0, try world.countCalls(.{ .step = 2, .op = "SkimSyncTeams" }));
}

test "first sync stores the viewer and its teams" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 1, .newest_offset = 1000 });

    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings("ctdio", repo.row.viewer_login.?);
    try testing.expectEqualStrings("acme/core", repo.row.viewer_teams);
    try testing.expectEqual(scenario.World.seed_now, repo.row.teams_synced_at);
}

test "a repository that no longer resolves fails the run as not_found" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.add("SkimSyncIndex-first.json", not_found_repo);
    try world.serve(&step);

    try testing.expectEqual(sync.RunOutcome{ .failed = .not_found }, try world.run(.{}));
}

test "a malformed index body fails the run as other and is recorded" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.add("SkimSyncIndex-first.json", "{\"data\":{\"viewer\":");
    try world.serve(&step);

    try testing.expectEqual(sync.RunOutcome{ .failed = .other }, try world.run(.{}));
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings("other", repo.row.last_sync_error.?);
}

test "hydrate failure keeps earlier batches and leaves the watermark advanced" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 30, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try world.serve(&step);
    try testing.expectEqual(sync.RunOutcome{ .ok = .{ .hydrate_remaining = 0 } }, try world.run(.{}));

    var step2 = scenario.Step.init(testing.allocator);
    defer step2.deinit();
    const bumped = try fixtures.synthPrs(step2.arena.allocator(), .{ .count = 30, .newest_offset = 2000 });
    try step2.index("first", .{ .prs = bumped });
    try step2.quietTail();
    try step2.fail("SkimSyncHydrate", .{ .stderr = network_failure_stderr });
    try world.serve(&step2);

    const outcome = try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 60 });

    try testing.expectEqual(sync.RunOutcome{ .failed = .network }, outcome);
    var stale = try world.store.needsHydrate(testing.allocator, world.repo_id);
    defer stale.deinit();
    try testing.expectEqual(30, stale.items.len);
    var repo = try world.repo();
    defer repo.deinit();
    try testing.expectEqualStrings(bumped[0].updated_at, repo.row.open_watermark.?);
    try testing.expectEqual(scenario.World.seed_now, repo.row.last_sync_at);
}

test "a repo id that does not exist is an error" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.RepoMissing, sync.runOnce(.{
        .store = &world.store,
        .repo_id = world.repo_id + 100,
        .owner = owner,
        .name = repo_name,
        .sync_index = 0,
        .arena = arena.allocator(),
        .now = scenario.World.seed_now,
    }));
}

test "on_commit fires once per committed group" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try step.closed("first", .{ .rows = &.{.{ .number = 999, .updated_at = try step.ts(1) }} });
    try world.serve(&step);

    var commits: usize = 0;
    try expectOk(try world.run(.{ .commits = &commits }));

    // index page, teams, one hydrate batch, sync result. Reconcile closed
    // nothing and #999 is not stored, so neither of those commits counts.
    try testing.expectEqual(4, commits);
}

test "on_commit does not fire for pages that change no rows" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = prs });
    try step.reconcile("first", .{ .numbers = &.{ prs[0].number, prs[1].number, prs[2].number } });
    try step.closed("first", .{ .rows = &.{.{ .number = 999, .updated_at = try step.ts(1) }} });
    try world.serve(&step);

    var commits: usize = 0;
    try expectOk(try world.run(.{ .sync_index = 10, .now = scenario.World.seed_now + 60, .commits = &commits }));

    // Only the sync result: the index page re-read identical rows.
    try testing.expectEqual(1, commits);
    try testing.expectEqual(1, try world.countCalls(.{ .step = 2, .op = "SkimSyncReconcile" }));
}

test "on_commit fires for a closed page that closes a stored PR" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    const prs = try world.seed(.{ .count = 3, .newest_offset = 1000 });

    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    try step.index("first", .{ .prs = &.{} });
    try step.closed("first", .{ .rows = &.{.{ .number = prs[1].number, .updated_at = try step.ts(1500) }} });
    try world.serve(&step);

    var commits: usize = 0;
    try expectOk(try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 60, .commits = &commits }));

    // closed page, sync result
    try testing.expectEqual(2, commits);
}

test "a canceled run stops before the next gh call" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try world.serve(&step);

    var cancel: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Canceled, world.run(.{ .cancel = &cancel }));
    try testing.expectEqual(0, try world.countCalls(.{ .step = 1, .op = "SkimSyncIndex" }));
}

// =============================================================================
// SyncWorker
// =============================================================================

test "start runs an initial sync and bumps generation" {
    var root = try test_support.TmpRoot.init();
    defer root.deinit();
    const gh = try serveQuietRepo(.{ .root = &root });
    defer testing.allocator.free(gh);
    const db_path = try test_support.tmpDbPath(testing.allocator, &root);
    defer testing.allocator.free(db_path);

    const worker = try sync.SyncWorker.start(workerOptions(db_path, gh));
    defer worker.stop();

    try waitFor(worker, lastOkSet);
    try testing.expect(worker.generation() > 0);
    try testing.expectEqual(null, worker.status().last_error);
}

test "requestSync during a run coalesces into one follow-up run" {
    var root = try test_support.TmpRoot.init();
    defer root.deinit();
    const gh = try serveQuietRepo(.{ .root = &root, .sleep_ms = 150 });
    defer testing.allocator.free(gh);
    const db_path = try test_support.tmpDbPath(testing.allocator, &root);
    defer testing.allocator.free(db_path);

    const worker = try sync.SyncWorker.start(workerOptions(db_path, gh));
    defer worker.stop();

    try waitForCalls(.{ .root = root.path, .at_least = 1 });
    for (0..5) |_| worker.requestSync();
    try waitForCalls(.{ .root = root.path, .op = "SkimSyncIndex", .at_least = 2 });
    try waitFor(worker, idle);
    skim_io.sleep(500 * std.time.ns_per_ms);

    var calls = try scenario.readCalls(testing.allocator, root.path);
    defer calls.deinit();
    try testing.expectEqual(2, calls.count("SkimSyncIndex"));
}

test "stop returns within one gh call" {
    var root = try test_support.TmpRoot.init();
    defer root.deinit();
    const gh = try serveQuietRepo(.{ .root = &root, .sleep_ms = 500 });
    defer testing.allocator.free(gh);
    const db_path = try test_support.tmpDbPath(testing.allocator, &root);
    defer testing.allocator.free(db_path);

    const worker = try sync.SyncWorker.start(workerOptions(db_path, gh));
    try waitForCalls(.{ .root = root.path, .at_least = 1 });

    var timer = try skim_io.Timer.start();
    worker.stop();
    try testing.expect(timer.read() < 3 * std.time.ns_per_s);

    var calls = try scenario.readCalls(testing.allocator, root.path);
    defer calls.deinit();
    try testing.expect(calls.items.len <= 2);
}

test "status reports last_error after a failing run and clears it after a good one" {
    var root = try test_support.TmpRoot.init();
    defer root.deinit();
    const gh = try serveQuietRepo(.{ .root = &root });
    defer testing.allocator.free(gh);
    try scenario.writeFiles(testing.allocator, .{ .root = root.path, .step = 2, .files = &.{
        .{ .path = "fail-SkimSyncIndex", .bytes = network_failure_stderr },
    } });
    try scenario.setStep(testing.allocator, root.path, 2);
    const db_path = try test_support.tmpDbPath(testing.allocator, &root);
    defer testing.allocator.free(db_path);

    const worker = try sync.SyncWorker.start(workerOptions(db_path, gh));
    defer worker.stop();

    try waitFor(worker, lastErrorSet);
    try testing.expectEqual(github.GhErrorKind.network, worker.status().last_error.?);
    try testing.expectEqual(null, worker.status().last_ok_at);

    try scenario.setStep(testing.allocator, root.path, 1);
    worker.requestSync();
    try waitFor(worker, lastOkSet);
    try testing.expectEqual(null, worker.status().last_error);
}

test "start seeds status from the last stored sync result" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 1, .newest_offset = 1000 });
    const db_path = world.db_path;

    const worker = try sync.SyncWorker.start(.{
        .repo_key = repo_key,
        .owner = owner,
        .name = repo_name,
        .db_path = db_path,
        .gh_bin = "/nonexistent/gh",
        .interval_ms = 60_000,
    });
    const seeded = worker.status();
    worker.stop();

    try testing.expectEqual(scenario.World.seed_now, seeded.last_ok_at.?);
}

test "start keeps the last success time when the latest run failed" {
    var tw = try test_support.TestWorld.init();
    defer tw.deinit();
    const world = &tw.world;
    _ = try world.seed(.{ .count = 1, .newest_offset = 1000 });
    try testing.expectEqual(sync.RunOutcome{ .failed = .not_installed }, try world.run(.{ .sync_index = 1, .now = scenario.World.seed_now + 60, .gh_bin = "/nonexistent/gh" }));
    const db_path = world.db_path;

    const worker = try sync.SyncWorker.start(.{
        .repo_key = repo_key,
        .owner = owner,
        .name = repo_name,
        .db_path = db_path,
        .gh_bin = "/nonexistent/gh",
    });
    const seeded = worker.status();
    worker.stop();

    try testing.expectEqual(scenario.World.seed_now, seeded.last_ok_at.?);
    try testing.expectEqual(github.GhErrorKind.not_installed, seeded.last_error.?);
}

test "the worker stops rerunning at once when a rerun makes no hydrate progress" {
    var root = try test_support.TmpRoot.init();
    defer root.deinit();
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const a = step.arena.allocator();
    const prs = try fixtures.synthPrs(a, .{ .count = 230, .newest_offset = 10_000 });
    try step.fullSync(.{ .prs = prs, .with_nodes = false });
    // Every node reports an updatedAt the index never had, so no hydrate
    // clears its PR from needsHydrate and every run leaves 30 behind.
    const stuck_at = try step.ts(1);
    for (prs) |pr| {
        const path = try std.fmt.allocPrint(a, "nodes/{s}.json", .{try fixtures.nodeId(a, pr.number)});
        try step.add(path, try fixtures.synthHydrateNode(a, .{ .number = pr.number, .updated_at = stuck_at }));
    }
    try scenario.setStep(testing.allocator, root.path, 1);
    const gh = try test_support.writeScenario(testing.allocator, .{ .root = root.path, .step = 1, .files = step.files.items });
    defer testing.allocator.free(gh);
    const db_path = try test_support.tmpDbPath(testing.allocator, &root);
    defer testing.allocator.free(db_path);

    const worker = try sync.SyncWorker.start(workerOptions(db_path, gh));
    defer worker.stop();

    // Two runs (the first, plus one immediate rerun) of 3 index pages each.
    try waitForCalls(.{ .root = root.path, .op = "SkimSyncIndex", .at_least = 6, .deadline_ns = 60 * std.time.ns_per_s });
    try waitForCalls(.{ .root = root.path, .op = "SkimSyncHydrate", .at_least = 16, .deadline_ns = 60 * std.time.ns_per_s });
    try waitFor(worker, lastOkSet);
    skim_io.sleep(1000 * std.time.ns_per_ms);

    var calls = try scenario.readCalls(testing.allocator, root.path);
    defer calls.deinit();
    try testing.expectEqual(6, calls.count("SkimSyncIndex"));
    try testing.expectEqual(16, calls.count("SkimSyncHydrate"));
}

test "the worker reports a sync with an inaccessible PR as ok and does not rerun for it" {
    var root = try test_support.TmpRoot.init();
    defer root.deinit();
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 3, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs, .with_nodes = false });
    try step.nodes(&.{ prs[0], prs[2] });
    try step.forbidden(&.{prs[1]});
    try scenario.setStep(testing.allocator, root.path, 1);
    const gh = try test_support.writeScenario(testing.allocator, .{ .root = root.path, .step = 1, .files = step.files.items });
    defer testing.allocator.free(gh);
    const db_path = try test_support.tmpDbPath(testing.allocator, &root);
    defer testing.allocator.free(db_path);

    const worker = try sync.SyncWorker.start(workerOptions(db_path, gh));
    defer worker.stop();

    try waitFor(worker, lastOkSet);
    try testing.expectEqual(null, worker.status().last_error);
    skim_io.sleep(1000 * std.time.ns_per_ms);

    var calls = try scenario.readCalls(testing.allocator, root.path);
    defer calls.deinit();
    try testing.expectEqual(1, calls.count("SkimSyncIndex"));
    try testing.expectEqual(1, calls.count("SkimSyncHydrate"));
}

test "a first sync with one inaccessible PR reruns at once for the hydrate work left" {
    var root = try test_support.TmpRoot.init();
    defer root.deinit();
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 230, .newest_offset = 10_000 });
    try step.fullSync(.{ .prs = prs, .with_nodes = false });
    try step.nodes(prs[0..5]);
    try step.nodes(prs[6..]);
    try step.forbidden(prs[5..6]);
    try scenario.setStep(testing.allocator, root.path, 1);
    const gh = try test_support.writeScenario(testing.allocator, .{ .root = root.path, .step = 1, .files = step.files.items });
    defer testing.allocator.free(gh);
    const db_path = try test_support.tmpDbPath(testing.allocator, &root);
    defer testing.allocator.free(db_path);

    const worker = try sync.SyncWorker.start(workerOptions(db_path, gh));
    defer worker.stop();

    // 8 capped batches (200 PRs) in the first run, then the last 30 in an
    // immediate rerun.
    try waitForCalls(.{ .root = root.path, .op = "SkimSyncHydrate", .at_least = 10, .deadline_ns = 60 * std.time.ns_per_s });
    try waitFor(worker, lastOkSet);
    skim_io.sleep(1000 * std.time.ns_per_ms);

    var calls = try scenario.readCalls(testing.allocator, root.path);
    defer calls.deinit();
    try testing.expectEqual(6, calls.count("SkimSyncIndex"));
    try testing.expectEqual(10, calls.count("SkimSyncHydrate"));
    try testing.expectEqual(null, worker.status().last_error);
}

test "start with an unopenable db path returns an error and spawns no thread" {
    try testing.expect(std.meta.isError(sync.SyncWorker.start(.{
        .repo_key = repo_key,
        .owner = owner,
        .name = repo_name,
        .db_path = "/nonexistent-dir/skim/prs.db",
    })));
}

// =============================================================================
// Helpers
// =============================================================================

/// Step 1 of a one-PR repo that every run can complete. Returns the launcher.
fn serveQuietRepo(params: struct { root: *const test_support.TmpRoot, sleep_ms: u32 = 0 }) ![]u8 {
    var step = scenario.Step.init(testing.allocator);
    defer step.deinit();
    const prs = try fixtures.synthPrs(step.arena.allocator(), .{ .count = 1, .newest_offset = 1000 });
    try step.fullSync(.{ .prs = prs });
    try scenario.setStep(testing.allocator, params.root.path, 1);
    return test_support.writeScenario(testing.allocator, .{
        .root = params.root.path,
        .step = 1,
        .files = step.files.items,
        .sleep_ms = params.sleep_ms,
    });
}

const far_lagged_number = 88;

/// An incremental step whose first page ends below the lookback line, with
/// PR `far_lagged_number` (newer than the watermark, sorted more than the
/// lookback late) on page 2, plus a reconcile page holding every number.
fn serveFarLaggedPr(step: *scenario.Step, seeded: []const fixtures.SynthPr) !void {
    const lagged: fixtures.SynthPr = .{ .number = far_lagged_number, .updated_at = try step.ts(100_500) };
    try step.index("first", .{ .prs = &.{ seeded[0], seeded[1] }, .has_next = true, .end_cursor = "c2" });
    try step.index("c2", .{ .prs = &.{ lagged, seeded[2] } });
    try step.reconcile("first", .{ .numbers = &.{ seeded[0].number, seeded[1].number, seeded[2].number, far_lagged_number } });
    try step.quietTail();
    try step.nodes(&.{lagged});
}

fn workerOptions(db_path: []const u8, gh: []const u8) sync.Options {
    return .{ .repo_key = repo_key, .owner = owner, .name = repo_name, .db_path = db_path, .gh_bin = gh };
}

const wait_deadline_ns = 10 * std.time.ns_per_s;
const poll_ns = 20 * std.time.ns_per_ms;

fn waitFor(worker: *sync.SyncWorker, comptime ready: fn (sync.SyncStatus) bool) !void {
    var timer = try skim_io.Timer.start();
    while (!ready(worker.status())) {
        if (timer.read() > wait_deadline_ns) return error.Timeout;
        skim_io.sleep(poll_ns);
    }
}

/// Wait until the fake has logged `at_least` calls of `op` (any op when null).
fn waitForCalls(params: struct { root: []const u8, op: ?[]const u8 = null, at_least: usize, deadline_ns: u64 = wait_deadline_ns }) !void {
    var timer = try skim_io.Timer.start();
    while (true) {
        var calls = try scenario.readCalls(testing.allocator, params.root);
        const n = if (params.op) |op| calls.count(op) else calls.items.len;
        calls.deinit();
        if (n >= params.at_least) return;
        if (timer.read() > params.deadline_ns) return error.Timeout;
        skim_io.sleep(poll_ns);
    }
}

fn lastOkSet(status: sync.SyncStatus) bool {
    return status.last_ok_at != null and !status.running;
}

fn lastErrorSet(status: sync.SyncStatus) bool {
    return status.last_error != null and !status.running;
}

fn idle(status: sync.SyncStatus) bool {
    return !status.running;
}

fn recordOf(records: []const types.PrRecord, number: u32) ?types.PrRecord {
    for (records) |record| {
        if (record.number == number) return record;
    }
    return null;
}
