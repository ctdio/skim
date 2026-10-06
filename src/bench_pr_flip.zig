//! PR sidebar + flip benchmark (NFR-1). Seeds a temp SQLite DB with
//! SKIM_BENCH_PRS open PRs, synthetic diffs and fresh review threads, then
//! measures what the user waits on: cold sidebar paint, flipping to a
//! prefetched PR through the real `pr_surface.planFlip` + `App.installPrDiff`
//! path (DB hit and in-memory LRU hit), sidebar reload + filter, and sidebar
//! draw. `SKIM_BENCH_ENFORCE=1` exits 1 when any p95 is over its (scaled)
//! budget.
//!
//! Every timed sample ends in `frame.render` + `vaxis.render` where the user
//! would see a frame. No subprocess runs: diffs, merge bases and threads are
//! all in the DB, and the threads are fresh, so `enterFromCache` never
//! refetches.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const frame = @import("rendering/frame.zig");
const pr_surface = @import("pr/surface.zig");
const store_mod = @import("pr/db/store.zig");
const types = @import("pr/db/types.zig");
const sidebar_controller = @import("pr/sidebar/controller.zig");
const sidebar_render = @import("pr/sidebar/render.zig");
const sidebar_state = @import("pr/sidebar/state.zig");
const sidebar_layout = @import("pr/sidebar/layout.zig");
const CiStatus = @import("pr/parse.zig").CiStatus;
const priority = @import("pr/prefetch/priority.zig");
const ParsedLru = @import("pr/prefetch/parsed_lru.zig").ParsedLru;
const bench = @import("testing/bench_support.zig");
const budget = @import("testing/bench_budget.zig");
const skim_io = @import("skim_io");

const App = app_mod.App;
const Store = store_mod.Store;
const DiffKey = types.DiffKey;
const PrRecord = types.PrRecord;
const Allocator = std.mem.Allocator;

const Config = struct {
    prs: usize,
    iterations: usize,
    warmup: usize,
    enforce: bool,
    budget_scale_pct: u64,
    width: u16,
    height: u16,
    distinct_diffs: usize,
    spec: bench.SyntheticSpec,
};

/// The seeded DB and what the bench needs to address it.
const Fixture = struct {
    allocator: Allocator,
    dir_path: []u8,
    db_path: []u8,
    /// `.pr` view DiffKey of PR `n` at index `n - 1`.
    keys: []DiffKey,

    fn destroy(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(skim_io.get(), self.dir_path) catch |err| {
            std.log.warn("bench fixture: {s} not removed: {}", .{ self.dir_path, err });
        };
        self.allocator.free(self.keys);
        self.allocator.free(self.db_path);
        self.allocator.free(self.dir_path);
    }

    fn keyOf(self: *const Fixture, number: u32) DiffKey {
        return self.keys[number - 1];
    }
};

/// The vaxis screen every sample paints into, writing to memory.
const Screen = struct {
    vx: vaxis.Vaxis,
    out: std.Io.Writer.Allocating,
    winsize: vaxis.Winsize,

    fn deinit(self: *Screen, allocator: Allocator) void {
        self.vx.screen.deinit(allocator);
        self.vx.screen_last.deinit(allocator);
        self.out.deinit();
    }

    /// Forget the last frame, so the next one paints every cell (first paint).
    fn forget(self: *Screen, allocator: Allocator) !void {
        try self.vx.resize(allocator, &self.out.writer, self.winsize);
        self.out.clearRetainingCapacity();
    }

    /// `frame.render` + `vaxis.render`: one frame the user sees.
    fn paint(self: *Screen, app: *App) !void {
        try frame.render(app, self.vx.window());
        try self.vx.render(&self.out.writer);
        try self.out.writer.flush();
    }
};

const MeasureParams = struct {
    allocator: Allocator,
    app: *App,
    screen: *Screen,
    fixture: *const Fixture,
    config: Config,
};

/// Samples of one measurement plus the frame sizes they emitted. Owned.
const Samples = struct {
    ns: []u64,
    bytes: []u64,

    fn alloc(allocator: Allocator, count: usize) !Samples {
        const ns = try allocator.alloc(u64, count);
        errdefer allocator.free(ns);
        return .{ .ns = ns, .bytes = try allocator.alloc(u64, count) };
    }

    fn free(self: Samples, allocator: Allocator) void {
        allocator.free(self.ns);
        allocator.free(self.bytes);
    }
};

const budgets = struct {
    const cold_paint: budget.Budget = .{ .label = "cold paint", .p95_limit_ns = 50 * std.time.ns_per_ms };
    const reload_filter: budget.Budget = .{ .label = "reload+filter", .p95_limit_ns = 2 * std.time.ns_per_ms };
    const draw: budget.Budget = .{ .label = "sidebar draw", .p95_limit_ns = 1 * std.time.ns_per_ms };
    const flip_db: budget.Budget = .{ .label = "flip (db hit)", .p95_limit_ns = 30 * std.time.ns_per_ms };
    const flip_lru: budget.Budget = .{ .label = "flip (lru hit)", .p95_limit_ns = 5 * std.time.ns_per_ms };
};

/// The AD-10 "ready" preset, applied on open as the default.
const ready_query = "-is:draft review:requested ci:!failure";

const bench_presets = [_]config.PrFilterPreset{
    .{ .name = "ready", .query = ready_query },
    .{ .name = "all", .query = "" },
};

const repo_key = "bench";
const viewer = "me";
const trunk_ref = "main";
const authors = [_][]const u8{ "alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi", "ivan", "judy", "mallory", "trent" };
const title_words = [_][]const u8{ "refactor", "sidebar", "flip", "cache", "diff", "render", "fix", "scroll", "parser", "review", "thread", "sync", "add", "remove", "prefetch", "query" };
const decisions = [_][]const u8{ "", "REVIEW_REQUIRED", "APPROVED", "CHANGES_REQUESTED" };

pub fn main(process_init: std.process.Init) !void {
    skim_io.init(process_init);
    // The release binary's allocator; see bench_scroll.zig.
    const allocator = std.heap.c_allocator;
    const config_values = readConfig(allocator);

    std.log.info("=== PR FLIP BENCH ===", .{});
    std.log.info("prs={d} diffs={d} lines/diff={d} size={d}x{d} warmup={d} iterations={d} enforce={} budget_scale={d}%", .{
        config_values.prs,
        config_values.distinct_diffs,
        config_values.spec.file_count * config_values.spec.hunks_per_file * config_values.spec.lines_per_hunk,
        config_values.width,
        config_values.height,
        config_values.warmup,
        config_values.iterations,
        config_values.enforce,
        config_values.budget_scale_pct,
    });
    const release = builtin.mode == .ReleaseFast;
    if (!release) std.log.warn("{s} build: numbers are meaningless and SKIM_BENCH_ENFORCE is ignored; use -Doptimize=ReleaseFast", .{@tagName(builtin.mode)});

    const over = try run(allocator, config_values);
    if (over > 0) std.log.warn("{d} measurement(s) over budget", .{over});
    // After `run` returned, so its fixture and App are already torn down.
    if (config_values.enforce and release and over > 0) std.process.exit(1);
}

// =============================================================================
// Measurements
// =============================================================================

/// Seed the fixture, take every measurement, and return how many p95s are
/// over their (scaled) budget.
fn run(allocator: Allocator, config_values: Config) !usize {
    var fixture = try createFixture(allocator, config_values);
    defer fixture.destroy();

    var app = try App.initForRenderBench(allocator, &.{});
    defer app.deinit();
    app.mode = .pr_review;
    app.state.flip.lru = ParsedLru.init(allocator);

    var screen = try initScreen(allocator, config_values);
    defer screen.deinit(allocator);

    const params: MeasureParams = .{ .allocator = allocator, .app = &app, .screen = &screen, .fixture = &fixture, .config = config_values };
    const limits = [_]budget.Budget{
        budget.scaled(budgets.cold_paint, config_values.budget_scale_pct),
        budget.scaled(budgets.reload_filter, config_values.budget_scale_pct),
        budget.scaled(budgets.draw, config_values.budget_scale_pct),
        budget.scaled(budgets.flip_db, config_values.budget_scale_pct),
        budget.scaled(budgets.flip_lru, config_values.budget_scale_pct),
    };
    const summaries = [_]budget.Summary{
        try report(allocator, .{ .samples = try measureColdPaint(params), .budget = limits[0] }),
        try report(allocator, .{ .samples = try measureReloadFilter(params), .budget = limits[1] }),
        try report(allocator, .{ .samples = try measureDraw(params), .budget = limits[2] }),
        try report(allocator, .{ .samples = try measureFlipDbHit(params), .budget = limits[3], .log_bytes = true }),
        try report(allocator, .{ .samples = try measureFlipLruHit(params), .budget = limits[4] }),
    };
    return budget.overCount(&summaries, &limits);
}

/// `skim pr` opening on a warm DB: open + migrate the store, register the
/// repo, install the presets (applying the default query), load the
/// snapshot, and paint every cell of the first frame. Untimed per sample:
/// closing the store and resetting the sidebar and screen.
fn measureColdPaint(params: MeasureParams) !Samples {
    const app = params.app;
    const surface = &app.state.pr_surface;
    const sidebar = &app.state.sidebar;
    const filters: config.PrFilters = .{ .default = "ready", .presets = &bench_presets };

    var samples = try Samples.alloc(params.allocator, params.config.iterations);
    errdefer samples.free(params.allocator);
    for (0..params.config.warmup + params.config.iterations) |iteration| {
        pr_surface.close(surface);
        sidebar_controller.deinitState(sidebar, params.allocator);
        sidebar.* = .{ .open = true, .visible = true };
        try params.screen.forget(params.allocator);

        var timer = try skim_io.Timer.start();
        pr_surface.openAt(surface, .{
            .allocator = params.allocator,
            .sidebar = sidebar,
            .db_path = params.fixture.db_path,
            .repo_key = repo_key,
            .owner = "o",
            .name = "r",
            .filters = &filters,
        });
        if (surface.store == null or sidebar.unavailable != .none) return error.BenchOpenFailed;
        try params.screen.paint(app);
        record(&samples, .{ .iteration = iteration, .warmup = params.config.warmup, .ns = timer.read(), .bytes = params.screen.out.written().len });
    }
    return samples;
}

/// A sync landing (reload from the DB) followed by a filter change.
fn measureReloadFilter(params: MeasureParams) !Samples {
    const app = params.app;
    const reload_params: pr_surface.ReloadParams = .{ .allocator = params.allocator, .sidebar = &app.state.sidebar };

    var samples = try Samples.alloc(params.allocator, params.config.iterations);
    errdefer samples.free(params.allocator);
    for (0..params.config.warmup + params.config.iterations) |iteration| {
        var timer = try skim_io.Timer.start();
        try pr_surface.reload(&app.state.pr_surface, reload_params);
        if (!try sidebar_controller.applyQuery(&app.state.sidebar, params.allocator, ready_query)) return error.BenchQueryRejected;
        record(&samples, .{ .iteration = iteration, .warmup = params.config.warmup, .ns = timer.read(), .bytes = 0 });
    }
    return samples;
}

/// `view` + `draw` of the sidebar column, as `frame.render` does it, over
/// the unfiltered list (the most rows). The cursor moves one row per sample
/// so the window scrolls like a held `j`.
fn measureDraw(params: MeasureParams) !Samples {
    const app = params.app;
    const sidebar = &app.state.sidebar;
    if (!try sidebar_controller.applyQuery(sidebar, params.allocator, "")) return error.BenchQueryRejected;
    defer _ = sidebar_controller.applyQuery(sidebar, params.allocator, ready_query) catch false;

    var frame_arena = std.heap.ArenaAllocator.init(params.allocator);
    defer frame_arena.deinit();

    const win = params.screen.vx.window();
    const split = sidebar_layout.split(.{ .width = win.width, .visible = true, .sidebar_focused = true });
    const sidebar_win = win.child(.{ .x_off = 0, .y_off = 0, .width = split.sidebar_cols, .height = win.height -| 1 });
    const list_rows = sidebar_render.listRows(sidebar_win.height, sidebar.parse_error != null);

    var samples = try Samples.alloc(params.allocator, params.config.iterations);
    errdefer samples.free(params.allocator);
    for (0..params.config.warmup + params.config.iterations) |iteration| {
        _ = frame_arena.reset(.retain_capacity);
        if (sidebar.cursor + 1 >= sidebar.rows.items.len) sidebar_controller.moveToEdge(sidebar, .top) else sidebar_controller.move(sidebar, 1);

        var timer = try skim_io.Timer.start();
        sidebar_controller.clampScroll(sidebar, list_rows);
        sidebar_render.draw(sidebar_win, sidebar_controller.view(sidebar, .{
            .focused = true,
            .now_secs = skim_io.timestamp(),
            .frame_allocator = frame_arena.allocator(),
            .visible_rows = list_rows,
        }));
        record(&samples, .{ .iteration = iteration, .warmup = params.config.warmup, .ns = timer.read(), .bytes = 0 });
    }
    return samples;
}

/// Flip to a PR whose diff is only in the DB: merge base and cached bytes
/// from SQLite, `parser.parse`, then the install and the frame. PRs are
/// visited in order, so the target was never displayed in the last
/// `ParsedLru.capacity` flips. Includes installPrDiff parking the outgoing
/// set and, once the LRU is full, evicting the oldest, as a real flip does.
fn measureFlipDbHit(params: MeasureParams) !Samples {
    const app = params.app;
    const records = (app.state.sidebar.records orelse return error.BenchNoRecords).items;
    if (records.len <= ParsedLru.capacity + 1) return error.BenchTooFewPrs;

    var samples = try Samples.alloc(params.allocator, params.config.iterations);
    errdefer samples.free(params.allocator);
    for (0..params.config.warmup + params.config.iterations) |iteration| {
        const target = &records[iteration % records.len];
        if (app.state.flip.lru.?.contains(params.fixture.keyOf(target.number))) return error.BenchUnexpectedLruHit;
        params.screen.out.clearRetainingCapacity();

        var timer = try skim_io.Timer.start();
        try flipTo(params, target);
        try params.screen.paint(app);
        const ns = timer.read();
        try expectShown(params, target);
        record(&samples, .{ .iteration = iteration, .warmup = params.config.warmup, .ns = ns, .bytes = params.screen.out.written().len });
    }
    return samples;
}

/// Flip back and forth between two PRs: each flip takes the target's parsed
/// set from the LRU, and `installPrDiff` parks the outgoing one there.
fn measureFlipLruHit(params: MeasureParams) !Samples {
    const app = params.app;
    const records = (app.state.sidebar.records orelse return error.BenchNoRecords).items;
    if (records.len < 2) return error.BenchTooFewPrs;
    const pair = [2]*const PrRecord{ &records[0], &records[records.len / 2] };
    try flipTo(params, pair[0]);
    try flipTo(params, pair[1]);

    var samples = try Samples.alloc(params.allocator, params.config.iterations);
    errdefer samples.free(params.allocator);
    for (0..params.config.warmup + params.config.iterations) |iteration| {
        const target = pair[iteration % 2];
        if (!app.state.flip.lru.?.contains(params.fixture.keyOf(target.number))) return error.BenchLruMiss;
        params.screen.out.clearRetainingCapacity();

        var timer = try skim_io.Timer.start();
        try flipTo(params, target);
        try params.screen.paint(app);
        const ns = timer.read();
        try expectShown(params, target);
        record(&samples, .{ .iteration = iteration, .warmup = params.config.warmup, .ns = ns, .bytes = params.screen.out.written().len });
    }
    return samples;
}

/// `App.previewPr`'s hit path without the debounce: plan from the cache,
/// then install. A miss means the fixture did not cache this PR; the bench
/// fails rather than time (or spawn) the streaming fallback.
fn flipTo(params: MeasureParams, target: *const PrRecord) !void {
    const app = params.app;
    var plan = try pr_surface.planFlip(&app.state.pr_surface, .{
        .allocator = params.allocator,
        .sidebar = &app.state.sidebar,
        .record = target,
        .view = .pr,
        .lru = &app.state.flip.lru.?,
        .now = skim_io.timestamp(),
    });
    const hit = switch (plan) {
        .miss => return error.BenchMiss,
        .hit => |*hit| hit,
    };
    defer if (hit.threads) |threads| threads.deinit(params.allocator);
    if (!hit.threads_fresh) return error.BenchStaleThreads;
    try app.installPrDiff(.{
        .record = target,
        .files = hit.files,
        .key = hit.key,
        .view = .pr,
        .threads_json = if (hit.threads) |threads| threads.json else null,
        .threads_fresh = hit.threads_fresh,
        .stack_base_ref = hit.stack_base_ref,
    });
}

/// Untimed check that a flip put `target`'s whole diff and its review
/// threads on screen, so a sample cannot pass by doing less than a real flip.
fn expectShown(params: MeasureParams, target: *const PrRecord) !void {
    const app = params.app;
    if (app.state.flip.previewed != target.number) return error.BenchNotPreviewed;
    if (app.state.files.len != params.config.spec.file_count) return error.BenchWrongFiles;
    const want_threads: usize = if (target.number % 2 == 1) 1 else 0;
    if (app.state.review.threads.items.len != want_threads) return error.BenchWrongThreads;
}

// =============================================================================
// Fixture
// =============================================================================

/// A temp dir holding a DB seeded the way sync + prefetch leave it: open PRs
/// (index + hydrate passes), a cached `.pr` diff and merge base for every PR,
/// fresh review threads, and every third PR seen at its head. Deterministic
/// (PRNG seed 42).
fn createFixture(allocator: Allocator, config_values: Config) !Fixture {
    const dir_path = try std.fmt.allocPrint(allocator, "/tmp/skim-bench-pr-flip-{d}", .{std.c.getpid()});
    errdefer allocator.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(skim_io.get(), dir_path);
    errdefer std.Io.Dir.cwd().deleteTree(skim_io.get(), dir_path) catch {};
    const db_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, Store.default_file_name });
    errdefer allocator.free(db_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var timer = try skim_io.Timer.start();
    var surface: pr_surface.Surface = .{ .store = try Store.open(allocator, db_path) };
    defer pr_surface.close(&surface);
    const db = &surface.store.?;
    surface.repo_id = try db.ensureRepo(.{ .key = repo_key, .owner = "o", .name = "r" });
    const repo_id = surface.repo_id;
    try db.setViewer(repo_id, viewer);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const prs = try seedPrs(a, .{ .random = random, .count = config_values.prs });
    try db.upsertIndex(repo_id, prs.index);
    try db.applyHydrate(repo_id, prs.hydrate);

    // Keys come from the sidebar's own stack analysis, the same inputs
    // `planFlip` resolves.
    var scratch: sidebar_state.SidebarState = .{};
    defer sidebar_controller.deinitState(&scratch, allocator);
    try pr_surface.reload(&surface, .{ .allocator = allocator, .sidebar = &scratch });
    const records = scratch.records.?.items;
    if (records.len != config_values.prs) return error.BenchSeedMismatch;

    const diffs = try a.alloc([]const u8, @max(config_values.distinct_diffs, 1));
    for (diffs, 0..) |*diff, i| diff.* = try buildDiff(a, .{ .spec = config_values.spec, .index = i });

    const keys = try allocator.alloc(DiffKey, config_values.prs);
    errdefer allocator.free(keys);
    const now = skim_io.timestamp();
    for (records, 0..) |*rec, index| {
        const place = sidebar_controller.stackPlace(&scratch, index);
        const target = priority.targetFor(.{
            .rec = rec,
            .parent = if (place.parent) |parent| &records[parent] else null,
            .bottom = if (place.bottom) |bottom| &records[bottom] else null,
            .is_tip = if (place.tip) |tip| tip == index else false,
        });
        const inputs = priority.diffKeyFor(target, .pr) orelse return error.BenchNoKeyInputs;
        const merge_base = randomOid(random);
        try db.putMergeBase(repo_id, .{ .base_tip_oid = inputs.base_tip_oid, .head_oid = inputs.head_oid, .merge_base_oid = &merge_base });
        const key: DiffKey = .{ .merge_base_oid = merge_base, .head_oid = rec.head_oid[0..40].* };
        keys[rec.number - 1] = key;
        const diff_index = (rec.number - 1) % diffs.len;
        try db.putDiff(.{ .repo_id = repo_id, .key = key, .bytes = diffs[diff_index], .now = now });
        try db.putThreads(.{
            .repo_id = repo_id,
            .number = rec.number,
            .pr_updated_at = rec.updated_at,
            .json = try reviewJson(a, .{ .record = rec, .diff_index = diff_index }),
            .now = now,
        });
        if (rec.number % 3 == 0) {
            try db.setSeen(.{ .repo_id = repo_id, .number = rec.number, .head_oid = rec.head_oid, .merge_base_oid = &merge_base, .now = now });
        }
    }
    std.log.info("fixture: {s} seeded in {d}ms", .{ db_path, timer.read() / std.time.ns_per_ms });
    return .{ .allocator = allocator, .dir_path = dir_path, .db_path = db_path, .keys = keys };
}

const SeededPrs = struct {
    index: []types.IndexRow,
    hydrate: []types.HydrateRow,
};

/// `count` open PRs numbered 1..count: titles of 20-70 chars, 12 authors,
/// ~10% drafts, and runs of 2-4 PRs stacked branch-on-branch.
fn seedPrs(a: Allocator, params: struct { random: std.Random, count: usize }) !SeededPrs {
    const random = params.random;
    const index = try a.alloc(types.IndexRow, params.count);
    const hydrate = try a.alloc(types.HydrateRow, params.count);
    const trunk_oid = randomOid(random);

    var stack_left: usize = 0;
    for (index, hydrate, 0..) |*row, *hyd, i| {
        const number: u32 = @intCast(i + 1);
        const head_ref = try std.fmt.allocPrint(a, "bench/pr-{d}", .{number});
        const head_oid = try a.dupe(u8, &randomOid(random));
        // Continue the current stack on top of the previous PR, or start one
        // (~1 in 12 PRs) of 2-4 members.
        const stacked = stack_left > 0;
        if (stacked) {
            stack_left -= 1;
        } else if (i + 1 < params.count and random.uintLessThan(u8, 12) == 0) {
            stack_left = random.intRangeAtMost(usize, 1, 3);
        }
        const updated_at = try std.fmt.allocPrint(a, "2026-09-{d:0>2}T{d:0>2}:{d:0>2}:00Z", .{ 1 + i % 28, i % 24, i % 60 });
        row.* = .{
            .number = number,
            .node_id = try std.fmt.allocPrint(a, "PR_bench{d}", .{number}),
            .title = try randomTitle(a, random),
            .author = authors[random.uintLessThan(usize, authors.len)],
            .url = try std.fmt.allocPrint(a, "https://github.com/o/r/pull/{d}", .{number}),
            .is_draft = random.uintLessThan(u8, 10) == 0,
            .head_ref = head_ref,
            .base_ref = if (stacked) index[i - 1].head_ref else trunk_ref,
            .head_oid = head_oid,
            .base_oid = if (stacked) index[i - 1].head_oid else try a.dupe(u8, &trunk_oid),
            .updated_at = updated_at,
            .labels = if (random.uintLessThan(u8, 5) == 0) "bug\nui" else "",
        };
        const additions = random.intRangeAtMost(u32, 1, 900);
        hyd.* = .{
            .number = number,
            .updated_at = updated_at,
            .additions = additions,
            .deletions = random.uintAtMost(u32, additions),
            .changed_files = random.intRangeAtMost(u32, 1, 40),
            .review_decision = decisions[random.uintLessThan(usize, decisions.len)],
            .ci = random.enumValue(CiStatus),
            .requested_users = if (random.uintLessThan(u8, 4) == 0) viewer else "",
            .requested_teams = "",
            .my_review_state = "",
            .my_review_oid = "",
        };
    }
    return .{ .index = index, .hydrate = hydrate };
}

fn randomTitle(a: Allocator, random: std.Random) ![]const u8 {
    const target_len = random.intRangeAtMost(usize, 20, 70);
    var title: std.ArrayList(u8) = .empty;
    while (title.items.len < target_len) {
        if (title.items.len > 0) try title.append(a, ' ');
        try title.appendSlice(a, title_words[random.uintLessThan(usize, title_words.len)]);
    }
    return title.items[0..target_len];
}

fn randomOid(random: std.Random) [40]u8 {
    var bytes: [20]u8 = undefined;
    random.bytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Synthetic diff `index`, with its own file paths and line text, so a flip
/// between two of them repaints the whole diff pane as a real one does.
fn buildDiff(a: Allocator, params: struct { spec: bench.SyntheticSpec, index: usize }) ![]const u8 {
    const text = try bench.buildDiffText(a, params.spec);
    const dir = try std.fmt.allocPrint(a, "src/bench{d}/", .{params.index});
    const renamed = try std.mem.replaceOwned(u8, a, text, "src/bench/", dir);
    const ident = try std.fmt.allocPrint(a, "pr{d}_value_", .{params.index});
    return std.mem.replaceOwned(u8, a, renamed, "value_", ident);
}

/// The `review_query` payload `gh` returns: one unresolved thread on odd
/// PRs (anchored in the diff's first file), none on even ones.
fn reviewJson(a: Allocator, params: struct { record: *const PrRecord, diff_index: usize }) ![]const u8 {
    const rec = params.record;
    const threads = if (rec.number % 2 == 1) try std.fmt.allocPrint(a,
        \\{{"totalCount":1,"pageInfo":{{"hasNextPage":false}},"nodes":[{{"id":"PRRT_{d}","isResolved":false,"isOutdated":false,"line":2,"startLine":null,"originalLine":2,"diffSide":"RIGHT","startDiffSide":null,"path":"src/bench{d}/file_0.zig","subjectType":"LINE","comments":{{"pageInfo":{{"hasNextPage":false}},"nodes":[{{"id":"PRRC_{d}","databaseId":{d},"author":{{"login":"alice"}},"body":"Bench thread on #{d}","createdAt":"{s}","diffHunk":"@@ -1,50 +1,50 @@","pullRequestReview":{{"id":"PRR_{d}","state":"COMMENTED"}},"replyTo":null}}]}}}}]}}
    , .{ rec.number, params.diff_index, rec.number, 1000 + rec.number, rec.number, rec.updated_at, rec.number }) else
        \\{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}
    ;
    return std.fmt.allocPrint(a,
        \\{{"data":{{"viewer":{{"login":"{s}"}},"repository":{{"pullRequest":{{"id":"{s}","number":{d},"title":"PR {d}","body":"","author":{{"login":"{s}"}},"isDraft":false,"baseRefName":"{s}","headRefName":"{s}","headRefOid":"{s}","updatedAt":"{s}","reviewDecision":"","statusCheckRollup":null,"commits":{{"nodes":[]}},"reviews":{{"pageInfo":{{"hasNextPage":false}},"nodes":[]}},"reviewThreads":{s}}}}}}}}}
    , .{ viewer, rec.node_id, rec.number, rec.number, rec.author, rec.base_ref, rec.head_ref, rec.head_oid, rec.updated_at, threads });
}

// =============================================================================
// Setup + reporting
// =============================================================================

fn readConfig(allocator: Allocator) Config {
    const scale = bench.envUsize(allocator, "SKIM_BENCH_BUDGET_SCALE", 100);
    return .{
        .prs = @max(bench.envUsize(allocator, "SKIM_BENCH_PRS", 300), ParsedLru.capacity + 2),
        .iterations = @max(bench.envUsize(allocator, "SKIM_BENCH_ITERS", 200), 1),
        .warmup = bench.envUsize(allocator, "SKIM_BENCH_WARMUP", 20),
        .enforce = bench.envBool(allocator, "SKIM_BENCH_ENFORCE", false),
        .budget_scale_pct = if (scale == 0) 100 else scale,
        .width = bench.envU16(allocator, "SKIM_BENCH_WIDTH", 190),
        .height = bench.envU16(allocator, "SKIM_BENCH_HEIGHT", 60),
        .distinct_diffs = @max(bench.envUsize(allocator, "SKIM_BENCH_DIFFS", 32), 1),
        .spec = .{
            .file_count = bench.envUsize(allocator, "SKIM_BENCH_FILES", 10),
            .hunks_per_file = bench.envUsize(allocator, "SKIM_BENCH_HUNKS", 4),
            .lines_per_hunk = bench.envUsize(allocator, "SKIM_BENCH_LINES", 50),
        },
    };
}

fn initScreen(allocator: Allocator, config_values: Config) !Screen {
    var screen: Screen = .{
        .vx = try vaxis.init(skim_io.get(), allocator, skim_io.environMap(), .{}),
        .out = .init(allocator),
        .winsize = .{ .rows = config_values.height, .cols = config_values.width, .x_pixel = 0, .y_pixel = 0 },
    };
    // The alt screen, as in the real TUI (see bench_scroll.zig).
    screen.vx.state.alt_screen = true;
    try screen.forget(allocator);
    return screen;
}

fn record(samples: *Samples, params: struct { iteration: usize, warmup: usize, ns: u64, bytes: usize }) void {
    if (params.iteration < params.warmup) return;
    const slot = params.iteration - params.warmup;
    samples.ns[slot] = params.ns;
    samples.bytes[slot] = params.bytes;
}

/// Log one measurement line (and its frame size when asked), free the
/// samples, and return the summary the exit decision uses.
fn report(allocator: Allocator, params: struct { samples: Samples, budget: budget.Budget, log_bytes: bool = false }) !budget.Summary {
    defer params.samples.free(allocator);
    const summary = budget.summarize(params.samples.ns);

    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try budget.formatLine(&line.writer, .{ .label = params.budget.label, .summary = summary, .budget = params.budget });
    std.log.info("{s}", .{line.written()});

    if (params.log_bytes) {
        const bytes = budget.summarize(params.samples.bytes);
        std.log.info("{s: <15} : bytes/frame p50={d} avg={d}", .{ params.budget.label, bytes.p50, bytes.avg });
    }
    return summary;
}
