//! Offline harness for the PR sidebar surface (Phase 6a). Drives the real
//! `App` (no tty: `initForRenderBench`), the real `SyncWorker` against Phase
//! 3's fake `gh`, and the real review entry worker against Phase 5's review
//! fake and a local bare origin. Scenario ids match verification-harness.md.
//!
//! Run through scripts/test-infra/pr-sidebar/surface-harness.sh, which builds
//! the git world, the fake `gh` launchers and a temp HOME, exports the
//! SKIM_HARNESS_* environment and runs this binary from the clone:
//!
//!   pr_surface_harness [all|S1|...|S14]   PASS/FAIL line per scenario, exit 1 on any FAIL
//!   pr_surface_harness seed-only <stacked31|origin14>   seed $HOME/.skim/prs.db and exit (S12)
//!
//! Every scenario runs under its own `DebugAllocator`; a leak is a FAIL.
//! 6b appends its flip scenarios to `scenarios` and reuses `Harness`.

const std = @import("std");
const skim_io = @import("skim_io");
const vaxis = @import("vaxis");
const root = @import("pr_surface_harness_root");

const App = root.App;
const Store = root.store.Store;
const types = root.types;
const sidebar_controller = root.sidebar_controller;
const sidebar_layout = root.sidebar_layout;
const review_controller = root.review_controller;
const SidebarState = root.sidebar_state.SidebarState;
const SidebarView = root.sidebar_render.View;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Key = vaxis.Key;
const CiStatus = @FieldType(types.PrRecord, "ci");

/// What the script exports. Strings live in the process arena.
const Env = struct {
    work: []const u8,
    home: []const u8,
    /// Clone with a github-looking origin; the process cwd.
    repo: []const u8,
    /// Clone whose origin is a local path (S8).
    repo_local: []const u8,
    /// `git config --get remote.origin.url` in `repo`: the surface's repo key.
    repo_key: []const u8,
    /// Phase 5 review fake (`ReviewSession.gh_bin`).
    review_gh: []const u8,
    /// `<dir>/<kind>/gh` launchers for Phase 3's sync fake; `<dir>/<kind>/root/calls.log`.
    sync_dir: []const u8,
    gh_log: []const u8,
    /// File count of PR 9's diff, computed by the script from the origin.
    pr9_files: usize,
};

/// `slow` holds every call for 8s, so a sync is in flight while a scenario acts.
const SyncKind = enum { network, unauthenticated, missing, slow };

const Fixture = enum { stacked31, origin14 };

/// One PR row for the seeded DB: an index row plus its hydrate fields.
const PrSpec = struct {
    number: u32,
    title: []const u8,
    author: []const u8 = "alice",
    head_ref: []const u8,
    base_ref: []const u8 = "main",
    head_oid: []const u8,
    base_oid: []const u8,
    updated_at: []const u8,
    is_draft: bool = false,
    ci: CiStatus = .none,
    review_decision: []const u8 = "",
    requested_users: []const u8 = "",
    my_review_state: []const u8 = "",
    my_review_oid: []const u8 = "",
};

const SeedParams = struct {
    /// Null seeds only the repo row (an empty PR list).
    fixture: ?Fixture,
    config_json: ?[]const u8 = null,
    sync_result: ?root.store.SyncResult = null,
};

const BootParams = struct {
    sync: SyncKind,
    boot_number: ?u32 = null,
};

const Scenario = struct {
    id: []const u8,
    what: []const u8,
    run: *const fn (ctx: *Ctx) anyerror!void,
};

/// Per-scenario context. `fail` records the reason the runner prints.
const Ctx = struct {
    allocator: Allocator,
    env: Env,
    reason_buf: [512]u8 = undefined,
    reason_len: usize = 0,

    fn fail(self: *Ctx, comptime fmt: []const u8, args: anytype) error{ScenarioFailed} {
        const text = std.fmt.bufPrint(&self.reason_buf, fmt, args) catch &self.reason_buf;
        self.reason_len = text.len;
        return error.ScenarioFailed;
    }

    fn reason(self: *const Ctx) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

/// A booted App with the PR surface open.
const Harness = struct {
    ctx: *Ctx,
    app: *App,
    sync_launcher: []u8,
    booted_at: i64,

    /// `initForRenderBench` (no tty), review entry routed to the review fake,
    /// optional `skim pr <n>` boot number, then `openPrSurface` with the sync
    /// launcher as `gh_bin`. No `pollBackgroundWork` has run on return.
    fn boot(ctx: *Ctx, params: BootParams) !Harness {
        const allocator = ctx.allocator;
        const launcher = try std.fmt.allocPrint(allocator, "{s}/{s}/gh", .{ ctx.env.sync_dir, @tagName(params.sync) });
        errdefer allocator.free(launcher);
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);
        app.* = try App.initForRenderBench(allocator, try allocator.alloc(root.parser.FileDiff, 0));
        app.state.review.gh_bin = ctx.env.review_gh;
        app.state.sidebar.boot_number = params.boot_number;
        const booted_at = skim_io.timestamp();
        app.openPrSurface(.{ .gh_bin = launcher });
        return .{ .ctx = ctx, .app = app, .sync_launcher = launcher, .booted_at = booted_at };
    }

    /// `App.deinit` closes the surface (stops the worker, closes the store)
    /// and frees the sidebar; the runner's allocator check catches leaks.
    fn deinit(self: *Harness) void {
        self.app.deinit();
        self.ctx.allocator.destroy(self.app);
        self.ctx.allocator.free(self.sync_launcher);
    }

    fn sidebar(self: *Harness) *SidebarState {
        return &self.app.state.sidebar;
    }

    /// Step background work until the sync worker finished its first run:
    /// not running and either an error or a success newer than boot. (A
    /// seeded `last_ok_at` alone is not a settle: it is there before the run.)
    /// Then one more poll so `sidebar.sync` reflects it.
    fn waitSyncSettled(self: *Harness) !void {
        const worker = self.app.state.pr_surface.sync orelse return self.ctx.fail("waitSyncSettled: no sync worker running", .{});
        var timer = try skim_io.Timer.start();
        while (timer.read() < sync_deadline_ns) {
            self.app.pollBackgroundWork();
            const status = worker.status();
            const ran = status.last_error != null or (status.last_ok_at orelse 0) >= self.booted_at;
            if (!status.running and ran) {
                self.app.pollBackgroundWork();
                return;
            }
            skim_io.sleep(poll_interval_ns);
        }
        return self.ctx.fail("sync worker did not settle within {d}s", .{sync_deadline_ns / std.time.ns_per_s});
    }

    /// Step background work until no review entry and no diff load is in flight.
    fn settle(self: *Harness) !void {
        var timer = try skim_io.Timer.start();
        while (timer.read() < settle_deadline_ns) {
            self.app.pollBackgroundWork();
            if (!self.busy()) return;
            skim_io.sleep(poll_interval_ns);
        }
        return self.ctx.fail("entry/diff load still in flight after {d}s", .{settle_deadline_ns / std.time.ns_per_s});
    }

    fn busy(self: *Harness) bool {
        const review = &self.app.state.review;
        return self.app.state.diff_load.isLoading() or review.entry_in_flight or review_controller.entryPending(review);
    }

    /// Step background work for `ms` milliseconds regardless of state.
    fn pollFor(self: *Harness, ms: u64) !void {
        var timer = try skim_io.Timer.start();
        while (timer.read() < ms * std.time.ns_per_ms) {
            self.app.pollBackgroundWork();
            skim_io.sleep(poll_interval_ns);
        }
    }

    /// One key through the real dispatch (`App.handleKey`).
    fn press(self: *Harness, key: Key) !void {
        try self.app.handleKey(key);
    }

    fn pressChar(self: *Harness, codepoint: u21) !void {
        try self.press(.{ .codepoint = codepoint });
    }

    fn pressCtrl(self: *Harness, codepoint: u21) !void {
        try self.press(.{ .codepoint = codepoint, .mods = .{ .ctrl = true } });
    }

    /// Type printable ASCII into whatever has focus (the filter prompt).
    fn typeText(self: *Harness, text: []const u8) !void {
        for (text, 0..) |c, i| try self.press(.{ .codepoint = c, .text = text[i .. i + 1] });
    }

    /// Open the `f` prompt and replace its pre-filled text with `text`, then Enter.
    fn submitQuery(self: *Harness, text: []const u8) !void {
        try self.pressChar('f');
        const prompt = &(self.sidebar().prompt orelse return self.ctx.fail("`f` did not open the filter prompt", .{}));
        var guard: usize = 0;
        while (prompt.len > 0 and guard < root.sidebar_state.query_cap) : (guard += 1) {
            try self.pressChar(Key.backspace);
        }
        if (prompt.len != 0) return self.ctx.fail("backspace did not clear the prompt ({d} bytes left)", .{prompt.len});
        try self.typeText(text);
        try self.pressChar(Key.enter);
    }

    /// Move the cursor to the row whose selected PR is `number` with `gg` + `j`.
    fn moveTo(self: *Harness, number: u32) !void {
        try self.pressChar('g');
        try self.pressChar('g');
        var steps: usize = 0;
        while (selectedNumber(self.sidebar()) != number and steps <= self.sidebar().rows.items.len) : (steps += 1) {
            try self.pressChar('j');
        }
        if (selectedNumber(self.sidebar()) != number) return self.ctx.fail("j never reached #{d}", .{number});
    }
};

const viewer_login = "me";
const fixture_owner = "skim-fixture";
const fixture_name = "repo";
const poll_interval_ns = 5 * std.time.ns_per_ms;
const sync_deadline_ns = 10 * std.time.ns_per_s;
const settle_deadline_ns = 15 * std.time.ns_per_s;
/// S14: closing must not wait out the 8s gh call. Esc also reloads the
/// working-tree diff, so the budget covers a small git diff too.
const close_budget_ms = 1000;

/// S2/S3 presets: `ready` first, `mine` the configured default (index 1).
const presets_config =
    \\{"pr_filters":{"default":"mine","presets":{"ready":"-is:draft review:requested","mine":"author:@me"}}}
;
const ready_query = "-is:draft review:requested";

/// stacked31 (see `stacked31Specs`): rows with every stack collapsed.
const stacked31_rows = 28;
const stacked31_expanded_rows = 31;
/// Row records shown by each preset, sorted. A collapsed stack's row record is
/// its review target (#813: #812 is approved by me at its head).
const mine_rows = [_]u32{ 703, 704, 705 };
const ready_rows = [_]u32{ 710, 712, 813 };
/// `visibleNumbers` for `ready`, sorted: collapsed stack members count.
const ready_visible = [_]u32{ 710, 712, 812, 813, 814 };

const scenarios = [_]Scenario{
    .{ .id = "S1", .what = "sidebar paints from the DB before any network", .run = s1PaintsBeforeNetwork },
    .{ .id = "S2", .what = "presets come from config.json; bad query keeps the last good rows", .run = s2Presets },
    .{ .id = "S3", .what = "sync hydrate priority follows the filter (FR-5)", .run = s3HydratePriority },
    .{ .id = "S4", .what = "navigation and collapse through the real key dispatch", .run = s4Navigation },
    .{ .id = "S5", .what = "offline keeps the list and shows it stale", .run = s5Offline },
    .{ .id = "S6", .what = "gh unauthenticated / missing degrade by row count", .run = s6GhUnavailable },
    .{ .id = "S7", .what = "corrupt DB is quarantined with a visible message (NFR-3)", .run = s7CorruptDb },
    .{ .id = "S8", .what = "non-GitHub origin starts nothing", .run = s8NotGithub },
    .{ .id = "S9", .what = "Enter loads the PR diff; focus keys", .run = s9EnterAndFocus },
    .{ .id = "S10", .what = "`skim pr <n>` boot selects and enters; unknown number degrades", .run = s10BootNumber },
    .{ .id = "S13", .what = "switching to the working tree closes the surface and restores comments", .run = s13LeaveForWorkingTree },
    .{ .id = "S14", .what = "Esc close and quit during an in-flight sync kill gh instead of waiting", .run = s14CloseDuringSync },
};

pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(process_init: std.process.Init) !u8 {
    skim_io.init(process_init);
    const arena = process_init.arena.allocator();
    const argv = try process_init.minimal.args.toSlice(arena);
    var out_buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(skim_io.get(), &out_buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    const env = loadEnv() catch |err| {
        try out.print("FAIL setup: {s} (run through scripts/test-infra/pr-sidebar/surface-harness.sh)\n", .{@errorName(err)});
        return 1;
    };
    const target: []const u8 = if (argv.len > 1) argv[1] else "all";

    if (std.mem.eql(u8, target, "seed-only")) {
        const name: []const u8 = if (argv.len > 2) argv[2] else "origin14";
        const fixture = std.meta.stringToEnum(Fixture, name) orelse {
            try out.print("FAIL seed-only: unknown fixture '{s}'\n", .{name});
            return 1;
        };
        var ctx: Ctx = .{ .allocator = std.heap.c_allocator, .env = env };
        seed(&ctx, .{ .fixture = fixture }) catch |err| {
            try out.print("FAIL seed-only: {s} {s}\n", .{ @errorName(err), ctx.reason() });
            return 1;
        };
        try out.print("seeded {s} into {s}/.skim/prs.db\n", .{ name, env.home });
        return 0;
    }

    var ran: usize = 0;
    var failed: usize = 0;
    for (scenarios) |scenario| {
        if (!std.mem.eql(u8, target, "all") and !std.mem.eql(u8, target, scenario.id)) continue;
        ran += 1;
        if (!try runScenario(.{ .scenario = scenario, .env = env, .out = out })) failed += 1;
    }
    if (ran == 0) {
        try out.print("FAIL setup: unknown scenario '{s}'\n", .{target});
        return 1;
    }
    return if (failed > 0) 1 else 0;
}

// =============================================================================
// Scenarios
// =============================================================================

fn s1PaintsBeforeNetwork(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .stacked31 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const sb = h.sidebar();

    if (!sb.open or !sb.visible) return ctx.fail("open={} visible={} after openPrSurface", .{ sb.open, sb.visible });
    if (h.app.mode != .pr_review) return ctx.fail("mode is {s}, expected pr_review", .{@tagName(h.app.mode)});
    if (sb.unavailable != .none) return ctx.fail("unavailable = {s}", .{@tagName(sb.unavailable)});
    const records = if (sb.records) |r| r.items.len else 0;
    if (records != 31) return ctx.fail("{d} records before any poll, expected 31", .{records});
    if (sb.rows.items.len != stacked31_rows) return ctx.fail("{d} rows, expected {d} (2 collapsed stacks + 26)", .{ sb.rows.items.len, stacked31_rows });
    if (h.app.state.pr_surface.sync == null) return ctx.fail("sync worker not started after the paint", .{});
}

fn s2Presets(ctx: *Ctx) !void {
    {
        try seed(ctx, .{ .fixture = .stacked31, .config_json = presets_config });
        var h = try Harness.boot(ctx, .{ .sync = .network });
        defer h.deinit();
        const sb = h.sidebar();

        if (sb.active_preset != 1) return ctx.fail("active_preset = {?d}, expected 1 (default `mine`)", .{sb.active_preset});
        try expectRowRecords(ctx, sb, .{ .label = "mine", .expected = &mine_rows });
        for (sb.rows.items) |row| {
            const author = sb.records.?.items[row.record].author;
            if (!std.mem.eql(u8, author, viewer_login)) return ctx.fail("mine row #{d} authored by {s}", .{ sb.records.?.items[row.record].number, author });
        }

        try h.pressChar('F');
        if (sb.active_preset != 0) return ctx.fail("F: active_preset = {?d}, expected 0 (wraps to `ready`)", .{sb.active_preset});
        try expectRowRecords(ctx, sb, .{ .label = "ready", .expected = &ready_rows });

        try h.submitQuery("revew:x");
        const parse_error = sb.parse_error orelse return ctx.fail("`revew:x` set no parse_error", .{});
        if (parse_error.reason != .unknown_qualifier) return ctx.fail("parse_error.reason = {s}", .{@tagName(parse_error.reason)});
        if (sb.prompt == null) return ctx.fail("prompt closed after a parse error", .{});
        try expectRowRecords(ctx, sb, .{ .label = "after parse error (last good)", .expected = &ready_rows });

        try h.pressChar(Key.escape);
        if (sb.prompt != null) return ctx.fail("Esc left the prompt open", .{});
        const query = sb.query[0..sb.query_len];
        if (!std.mem.eql(u8, query, ready_query)) return ctx.fail("query after Esc is '{s}', expected '{s}'", .{ query, ready_query });
    }
    {
        try seed(ctx, .{ .fixture = .stacked31 });
        var h = try Harness.boot(ctx, .{ .sync = .network });
        defer h.deinit();
        const sb = h.sidebar();
        if (sb.presets.len != 1 or !std.mem.eql(u8, sb.presets[0].name, "all")) return ctx.fail("no config.json: {d} presets, expected the built-in `all`", .{sb.presets.len});
        if (sb.rows.items.len != stacked31_rows) return ctx.fail("no config.json: {d} rows, expected {d}", .{ sb.rows.items.len, stacked31_rows });
    }
}

fn s3HydratePriority(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .stacked31, .config_json = presets_config });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    try h.waitSyncSettled();

    try expectPriorityMatchesView(ctx, &h, "mine (after boot)");
    try expectSortedEqual(ctx, .{ .label = "mine priority", .actual = try workerPriority(&h), .expected = &mine_rows });

    try h.pressChar('F');
    try expectPriorityMatchesView(ctx, &h, "ready (after F)");
    try expectSortedEqual(ctx, .{ .label = "ready priority", .actual = try workerPriority(&h), .expected = &ready_visible });

    try h.submitQuery("label:nope");
    const priority = try workerPriority(&h);
    defer ctx.allocator.free(priority);
    if (priority.len != 0) return ctx.fail("label:nope: worker priority has {d} PRs, expected none", .{priority.len});
    var frame = std.heap.ArenaAllocator.init(ctx.allocator);
    defer frame.deinit();
    const view = sidebarView(&h, frame.allocator());
    const empty = view.empty orelse return ctx.fail("label:nope: view().empty is null", .{});
    if (std.meta.activeTag(empty) != .no_match) return ctx.fail("label:nope: view().empty = {s}, expected no_match", .{@tagName(std.meta.activeTag(empty))});
}

fn s4Navigation(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .stacked31 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();

    try expectCursor(ctx, &h, .{ .step = "initial (collapsed 3-stack header -> target)", .number = 813, .rows = stacked31_rows });
    try h.pressChar('j');
    try expectCursor(ctx, &h, .{ .step = "j over the collapsed 3-stack", .number = 790, .rows = stacked31_rows });
    try h.pressChar('k');
    try expectCursor(ctx, &h, .{ .step = "k back to the 3-stack", .number = 813, .rows = stacked31_rows });
    try h.pressChar('J');
    try expectCursor(ctx, &h, .{ .step = "J expands and lands on the target member", .number = 813, .rows = stacked31_expanded_rows });
    try h.pressChar('J');
    try expectCursor(ctx, &h, .{ .step = "J to the next member", .number = 812, .rows = stacked31_expanded_rows });
    try h.pressChar('J');
    try expectCursor(ctx, &h, .{ .step = "J at the last member stays", .number = 812, .rows = stacked31_expanded_rows });
    try h.pressChar('h');
    try expectCursor(ctx, &h, .{ .step = "h collapses onto the header", .number = 813, .rows = stacked31_rows });
    try h.pressChar(' ');
    try expectCursor(ctx, &h, .{ .step = "space expands", .number = 813, .rows = stacked31_expanded_rows });
    try h.pressChar(' ');
    try expectCursor(ctx, &h, .{ .step = "space collapses", .number = 813, .rows = stacked31_rows });
    try h.pressChar('G');
    try expectCursor(ctx, &h, .{ .step = "G to the last row", .number = 725, .rows = stacked31_rows });
    try h.pressChar('g');
    try h.pressChar('g');
    try expectCursor(ctx, &h, .{ .step = "gg to the first row", .number = 813, .rows = stacked31_rows });
    try h.pressChar(' ');
    try h.pressCtrl('n');
    try expectCursor(ctx, &h, .{ .step = "Ctrl-n skips the expanded members", .number = 790, .rows = stacked31_expanded_rows });
}

fn s5Offline(ctx: *Ctx) !void {
    const last_ok = skim_io.timestamp() - 3 * 3600;
    try seed(ctx, .{ .fixture = .stacked31, .sync_result = .{ .at = last_ok, .err_tag = null } });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    try h.waitSyncSettled();
    const sb = h.sidebar();

    if (sb.sync.last_error != .network) return ctx.fail("sync.last_error = {?s}, expected network", .{optTag(sb.sync.last_error)});
    if (sb.sync.last_ok_at != last_ok) return ctx.fail("sync.last_ok_at = {?d}, expected {d} (seeded, 3h old)", .{ sb.sync.last_ok_at, last_ok });
    if (sb.rows.items.len != stacked31_rows) return ctx.fail("{d} rows while offline, expected {d}", .{ sb.rows.items.len, stacked31_rows });
    if (sb.unavailable != .none) return ctx.fail("unavailable = {s} with rows", .{@tagName(sb.unavailable)});
    var frame = std.heap.ArenaAllocator.init(ctx.allocator);
    defer frame.deinit();
    const view = sidebarView(&h, frame.allocator());
    if (view.sync_tone != .stale) return ctx.fail("sync_tone = {s}, expected stale", .{@tagName(view.sync_tone)});
    if (!std.mem.startsWith(u8, view.sync_line, "offline")) return ctx.fail("sync_line '{s}' does not start with 'offline'", .{view.sync_line});
}

fn s6GhUnavailable(ctx: *Ctx) !void {
    {
        try seed(ctx, .{ .fixture = null });
        var h = try Harness.boot(ctx, .{ .sync = .unauthenticated });
        defer h.deinit();
        try h.waitSyncSettled();
        const sb = h.sidebar();
        if (sb.sync.last_error != .not_authenticated) return ctx.fail("empty DB, unauthenticated: last_error = {?s}", .{optTag(sb.sync.last_error)});
        if (sb.unavailable != .gh_unauthenticated) return ctx.fail("empty DB, unauthenticated: unavailable = {s}", .{@tagName(sb.unavailable)});
        var frame = std.heap.ArenaAllocator.init(ctx.allocator);
        defer frame.deinit();
        const message = unavailableMessage(sidebarView(&h, frame.allocator()));
        if (std.mem.indexOf(u8, message, "gh auth login") == null) return ctx.fail("empty-state message '{s}' lacks `gh auth login`", .{message});
    }
    {
        try seed(ctx, .{ .fixture = .stacked31 });
        var h = try Harness.boot(ctx, .{ .sync = .unauthenticated });
        defer h.deinit();
        try h.waitSyncSettled();
        const sb = h.sidebar();
        if (sb.unavailable != .none) return ctx.fail("rows + unauthenticated: unavailable = {s}, expected none", .{@tagName(sb.unavailable)});
        if (sb.rows.items.len != stacked31_rows) return ctx.fail("rows + unauthenticated: {d} rows", .{sb.rows.items.len});
        var frame = std.heap.ArenaAllocator.init(ctx.allocator);
        defer frame.deinit();
        const view = sidebarView(&h, frame.allocator());
        if (!std.mem.startsWith(u8, view.sync_line, "gh:") or std.mem.indexOf(u8, view.sync_line, "not authenticated") == null)
            return ctx.fail("rows + unauthenticated: sync_line '{s}'", .{view.sync_line});
    }
    {
        try seed(ctx, .{ .fixture = null });
        var h = try Harness.boot(ctx, .{ .sync = .missing });
        defer h.deinit();
        try h.waitSyncSettled();
        const sb = h.sidebar();
        if (sb.sync.last_error != .not_installed) return ctx.fail("gh missing: last_error = {?s}", .{optTag(sb.sync.last_error)});
        if (sb.unavailable != .gh_missing) return ctx.fail("gh missing: unavailable = {s}", .{@tagName(sb.unavailable)});
    }
}

fn s7CorruptDb(ctx: *Ctx) !void {
    const io = skim_io.get();
    try resetHome(ctx.env);
    const garbage = [_]u8{0xAB} ** 4096;
    const db_path = try dbPath(ctx.allocator, ctx.env);
    defer ctx.allocator.free(db_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = db_path, .data = &garbage });

    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const sb = h.sidebar();

    const quarantined = try findQuarantined(ctx);
    defer ctx.allocator.free(quarantined);
    const moved = try std.Io.Dir.cwd().readFileAlloc(io, quarantined, ctx.allocator, .limited(1 << 20));
    defer ctx.allocator.free(moved);
    if (!std.mem.eql(u8, moved, &garbage)) return ctx.fail("{s} does not hold the garbage bytes", .{quarantined});

    var fresh = Store.open(ctx.allocator, db_path) catch |err| return ctx.fail("fresh prs.db does not open: {s}", .{@errorName(err)});
    fresh.close();

    const message = sb.message[0..sb.message_len];
    const basename = std.fs.path.basename(quarantined);
    if (std.mem.indexOf(u8, message, "corrupt") == null or std.mem.indexOf(u8, message, basename) == null)
        return ctx.fail("sidebar.message '{s}' does not name {s}", .{ message, basename });
    if (sb.unavailable != .none) return ctx.fail("unavailable = {s}, expected none", .{@tagName(sb.unavailable)});
    if (h.app.state.pr_surface.sync == null) return ctx.fail("sync not started after quarantine", .{});
}

fn s8NotGithub(ctx: *Ctx) !void {
    const io = skim_io.get();
    try resetHome(ctx.env);
    try std.process.setCurrentPath(io, ctx.env.repo_local);
    defer std.process.setCurrentPath(io, ctx.env.repo) catch |err| std.log.err("restoring cwd: {}", .{err});
    const calls_before = try syncCallCount(ctx, .network);

    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    for (0..10) |_| h.app.pollBackgroundWork();
    const sb = h.sidebar();

    if (sb.unavailable != .not_github) return ctx.fail("unavailable = {s}, expected not_github", .{@tagName(sb.unavailable)});
    if (h.app.state.pr_surface.sync != null) return ctx.fail("a sync worker started for a non-GitHub origin", .{});
    if (h.app.state.pr_surface.store != null) return ctx.fail("a store was opened for a non-GitHub origin", .{});
    const calls_after = try syncCallCount(ctx, .network);
    if (calls_after != calls_before) return ctx.fail("sync fake was called ({d} -> {d} bytes of call log)", .{ calls_before, calls_after });
    const db_path = try dbPath(ctx.allocator, ctx.env);
    defer ctx.allocator.free(db_path);
    if (fileExists(db_path)) return ctx.fail("{s} was created for a non-GitHub origin", .{db_path});
}

fn s9EnterAndFocus(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const app = h.app;
    const sb = h.sidebar();
    const gh_log_before = try fileSize(ctx.env.gh_log);

    try h.moveTo(9);
    try h.pressChar(Key.enter);
    try h.settle();

    if (app.mode != .normal) return ctx.fail("mode after Enter is {s}, expected normal", .{@tagName(app.mode)});
    if (app.state.files.len != ctx.env.pr9_files) return ctx.fail("{d} files loaded, PR 9 touches {d}", .{ app.state.files.len, ctx.env.pr9_files });
    if (app.state.review.number != 9) return ctx.fail("review.number = {d}, expected 9", .{app.state.review.number});
    if (!try logHasSince(ctx, .{ .path = ctx.env.gh_log, .offset = gh_log_before, .needle = "number=9" }))
        return ctx.fail("review fake log has no number=9 call: the entry worker did not use gh_bin", .{});
    if (sb.message_len != 0) return ctx.fail("sidebar.message = '{s}' after a good entry", .{sb.message[0..sb.message_len]});
    switch (app.state.diff_source) {
        .two_refs => |refs| {
            if (!std.mem.eql(u8, refs.ref1, "origin/main") or !std.mem.eql(u8, refs.ref2, "refs/skim/pr-9") or !refs.use_merge_base)
                return ctx.fail("diff_source two_refs{{{s}, {s}, {}}}", .{ refs.ref1, refs.ref2, refs.use_merge_base });
        },
        else => return ctx.fail("diff_source is {s}, expected two_refs", .{@tagName(app.state.diff_source)}),
    }

    try h.pressChar(Key.tab);
    if (app.mode != .pr_review) return ctx.fail("Tab from the diff: mode {s}, expected pr_review", .{@tagName(app.mode)});
    try h.pressChar('l');
    if (app.mode != .normal) return ctx.fail("l from the sidebar: mode {s}, expected normal", .{@tagName(app.mode)});
    try h.pressCtrl('b');
    if (sb.visible) return ctx.fail("Ctrl-b did not hide the sidebar", .{});
    const hidden = sidebar_layout.split(.{ .width = 160, .visible = sb.visible, .sidebar_focused = false });
    if (hidden.sidebar_cols != 0) return ctx.fail("hidden sidebar still gets {d} cols", .{hidden.sidebar_cols});
    try h.pressCtrl('b');
    if (!sb.visible) return ctx.fail("second Ctrl-b did not show the sidebar", .{});
    try h.pressCtrl('w');
    try h.pressChar('h');
    if (app.mode != .pr_review) return ctx.fail("Ctrl-w h: mode {s}, expected pr_review", .{@tagName(app.mode)});
    try h.pressChar('l');
    try h.pressChar('h');
    if (app.mode != .normal) return ctx.fail("h in the diff changed focus to {s} (AD-8: previous file)", .{@tagName(app.mode)});
    const hunk_mode = app.state.hunk_view_mode;
    try h.press(.{ .codepoint = Key.tab, .mods = .{ .shift = true } });
    if (app.state.hunk_view_mode == hunk_mode) return ctx.fail("Shift-Tab did not change the hunk view mode", .{});
    if (app.mode != .normal) return ctx.fail("Shift-Tab moved focus to {s}", .{@tagName(app.mode)});
}

fn s10BootNumber(ctx: *Ctx) !void {
    {
        try seed(ctx, .{ .fixture = .origin14 });
        var h = try Harness.boot(ctx, .{ .sync = .network, .boot_number = 10 });
        defer h.deinit();
        try h.settle();
        if (selectedNumber(h.sidebar()) != 10) return ctx.fail("boot 10: selected #{?d}", .{selectedNumber(h.sidebar())});
        if (h.app.state.review.number != 10) return ctx.fail("boot 10: review.number = {d}", .{h.app.state.review.number});
        if (h.app.state.files.len == 0) return ctx.fail("boot 10: no files loaded", .{});
    }
    {
        try seed(ctx, .{ .fixture = .origin14 });
        var h = try Harness.boot(ctx, .{ .sync = .network, .boot_number = 999 });
        defer h.deinit();
        try h.settle();
        const sb = h.sidebar();
        if (h.app.state.files.len != 0) return ctx.fail("boot 999: {d} files loaded for a PR that does not exist", .{h.app.state.files.len});
        if (std.meta.activeTag(h.app.state.diff_source) == .two_refs) return ctx.fail("boot 999: a PR diff source was installed", .{});
        if (!std.mem.eql(u8, sb.messageText(), "PR #999 not found on GitHub")) return ctx.fail("boot 999: sidebar message \"{s}\"", .{sb.messageText()});
        const records = if (sb.records) |r| r.items.len else 0;
        if (records != 14) return ctx.fail("boot 999: list has {d} records, expected 14", .{records});
    }
}

fn s13LeaveForWorkingTree(ctx: *Ctx) !void {
    const io = skim_io.get();
    try seed(ctx, .{ .fixture = .origin14 });
    const tracked = try std.fmt.allocPrint(ctx.allocator, "{s}/base.txt", .{ctx.env.repo});
    defer ctx.allocator.free(tracked);
    const original = try std.Io.Dir.cwd().readFileAlloc(io, tracked, ctx.allocator, .limited(1 << 20));
    defer ctx.allocator.free(original);
    defer std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tracked, .data = original }) catch |err| std.log.err("restoring base.txt: {}", .{err});
    var appender = try skim_io.AppendFile.open(tracked);
    try appender.write("working-tree change for S13\n");
    appender.close();

    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const app = h.app;
    const sb = h.sidebar();
    _ = try app.state.comment_store.add(.{
        .file_path = "base.txt",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "WT-NOTE",
        .line_type = .add,
        .line_content = "working-tree change for S13",
    });

    try h.waitSyncSettled();
    try h.moveTo(9);
    try h.pressChar(Key.enter);
    try h.settle();
    const parked = app.state.pr_surface_parking.comments orelse return ctx.fail("entering #9 did not park the working-tree comments", .{});
    if (countNotes(&parked) != 1) return ctx.fail("parked store holds {d} WT-NOTE comments, expected 1", .{countNotes(&parked)});
    if (countNotes(&app.state.comment_store) != 0) return ctx.fail("WT-NOTE is visible on the PR diff", .{});

    try app.switchDiffMode(.working);
    try h.settle();
    if (app.state.pr_surface.sync != null) return ctx.fail("sync worker still running after leaving for the working tree", .{});
    if (app.state.pr_surface.store != null) return ctx.fail("UI store still open after leaving", .{});
    if (sb.open or sb.visible) return ctx.fail("sidebar open={} visible={} after leaving", .{ sb.open, sb.visible });
    if (app.mode != .normal) return ctx.fail("mode {s} after leaving, expected normal", .{@tagName(app.mode)});
    if (app.state.pr_surface_parking.comments != null or app.state.pr_surface_parking.pending())
        return ctx.fail("parking not cleared after the working diff installed", .{});
    if (app.state.comment_store.comments.items.len != 1 or countNotes(&app.state.comment_store) != 1)
        return ctx.fail("comment_store holds {d} comments ({d} WT-NOTE), expected exactly WT-NOTE", .{ app.state.comment_store.comments.items.len, countNotes(&app.state.comment_store) });

    const gh_log_before = try fileSize(ctx.env.gh_log);
    const sync_calls_before = try syncCallCount(ctx, .network);
    try h.pollFor(200);
    if (try fileSize(ctx.env.gh_log) != gh_log_before) return ctx.fail("review fake called after leaving the surface", .{});
    if (try syncCallCount(ctx, .network) != sync_calls_before) return ctx.fail("sync fake called after leaving the surface", .{});
}

fn s14CloseDuringSync(ctx: *Ctx) !void {
    {
        try seed(ctx, .{ .fixture = .stacked31 });
        const calls_before = try syncCallCount(ctx, .slow);
        var h = try Harness.boot(ctx, .{ .sync = .slow });
        defer h.deinit();
        try waitSyncCall(ctx, .{ .kind = .slow, .past = calls_before });

        var timer = try skim_io.Timer.start();
        try h.pressChar(Key.escape);
        const elapsed_ms = timer.read() / std.time.ns_per_ms;
        if (h.app.state.pr_surface.sync != null) return ctx.fail("Esc left the sync worker running", .{});
        if (elapsed_ms > close_budget_ms) return ctx.fail("Esc took {d}ms with gh in flight, budget {d}ms", .{ elapsed_ms, close_budget_ms });
    }
    {
        try seed(ctx, .{ .fixture = .stacked31 });
        const calls_before = try syncCallCount(ctx, .slow);
        var h = try Harness.boot(ctx, .{ .sync = .slow });
        h.app.state.sidebar.pr_only = true;
        waitSyncCall(ctx, .{ .kind = .slow, .past = calls_before }) catch |err| {
            h.deinit();
            return err;
        };

        try h.pressCtrl('c');
        if (!h.app.should_quit) {
            h.deinit();
            return ctx.fail("Ctrl-C in `skim pr` did not quit", .{});
        }
        var timer = try skim_io.Timer.start();
        h.deinit();
        const elapsed_ms = timer.read() / std.time.ns_per_ms;
        if (elapsed_ms > close_budget_ms) return ctx.fail("quit teardown took {d}ms with gh in flight, budget {d}ms", .{ elapsed_ms, close_budget_ms });
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Run one scenario under its own leak-checking allocator and print its line.
fn runScenario(params: struct { scenario: Scenario, env: Env, out: *Writer }) !bool {
    const scenario = params.scenario;
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var ctx: Ctx = .{ .allocator = debug_allocator.allocator(), .env = params.env };
    const result = scenario.run(&ctx);
    const leaked = debug_allocator.deinit() == .leak;

    result catch |err| {
        switch (err) {
            error.ScenarioFailed => try params.out.print("FAIL {s}: {s}\n", .{ scenario.id, ctx.reason() }),
            else => try params.out.print("FAIL {s}: error.{s} {s}\n", .{ scenario.id, @errorName(err), ctx.reason() }),
        }
        try params.out.flush();
        return false;
    };
    if (leaked) {
        try params.out.print("FAIL {s}: leak (allocation traces on stderr)\n", .{scenario.id});
        try params.out.flush();
        return false;
    }
    try params.out.print("PASS {s}: {s}\n", .{ scenario.id, scenario.what });
    try params.out.flush();
    return true;
}

fn loadEnv() !Env {
    const pr9 = try requireEnv("SKIM_HARNESS_PR9_FILES");
    return .{
        .work = try requireEnv("SKIM_HARNESS_WORK"),
        .home = try requireEnv("HOME"),
        .repo = try requireEnv("SKIM_HARNESS_REPO"),
        .repo_local = try requireEnv("SKIM_HARNESS_REPO_LOCAL"),
        .repo_key = try requireEnv("SKIM_HARNESS_REPO_KEY"),
        .review_gh = try requireEnv("SKIM_HARNESS_REVIEW_GH"),
        .sync_dir = try requireEnv("SKIM_HARNESS_SYNC_DIR"),
        .gh_log = try requireEnv("FAKE_GH_LOG"),
        .pr9_files = std.fmt.parseInt(usize, pr9, 10) catch return error.BadPr9Files,
    };
}

fn requireEnv(name: []const u8) ![]const u8 {
    const value = skim_io.getEnv(name) orelse {
        std.debug.print("pr_surface_harness: {s} is not set\n", .{name});
        return error.MissingEnv;
    };
    return value;
}

/// Delete `$HOME/.skim/prs.db*` and `config.json`, then seed through the real
/// Store API: the repo row (key = the clone's origin URL, viewer `me`), the
/// fixture's index + hydrate rows, an optional sync result and config.json.
fn seed(ctx: *Ctx, params: SeedParams) !void {
    const io = skim_io.get();
    try resetHome(ctx.env);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (params.config_json) |json| {
        const config_path = try std.fmt.allocPrint(arena, "{s}/.skim/config.json", .{ctx.env.home});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = json });
    }

    var store = try Store.open(ctx.allocator, try dbPath(arena, ctx.env));
    defer store.close();
    const repo_id = try store.ensureRepo(.{ .key = ctx.env.repo_key, .owner = fixture_owner, .name = fixture_name });
    try store.setViewer(repo_id, viewer_login);
    if (params.sync_result) |result| try store.setSyncResult(repo_id, result);
    const fixture = params.fixture orelse return;

    const specs = switch (fixture) {
        .stacked31 => try stacked31Specs(arena),
        .origin14 => try origin14Specs(arena, ctx.env),
    };
    const index_rows = try arena.alloc(types.IndexRow, specs.len);
    const hydrate_rows = try arena.alloc(types.HydrateRow, specs.len);
    for (specs, index_rows, hydrate_rows) |spec, *index_row, *hydrate_row| {
        index_row.* = .{
            .number = spec.number,
            .node_id = try std.fmt.allocPrint(arena, "PR_{d}", .{spec.number}),
            .title = spec.title,
            .author = spec.author,
            .url = try std.fmt.allocPrint(arena, "https://github.com/{s}/{s}/pull/{d}", .{ fixture_owner, fixture_name, spec.number }),
            .is_draft = spec.is_draft,
            .head_ref = spec.head_ref,
            .base_ref = spec.base_ref,
            .head_oid = spec.head_oid,
            .base_oid = spec.base_oid,
            .updated_at = spec.updated_at,
            .labels = "",
        };
        hydrate_row.* = .{
            .number = spec.number,
            .updated_at = spec.updated_at,
            .additions = 1,
            .deletions = 0,
            .changed_files = 1,
            .review_decision = spec.review_decision,
            .ci = spec.ci,
            .requested_users = spec.requested_users,
            .requested_teams = "",
            .my_review_state = spec.my_review_state,
            .my_review_oid = spec.my_review_oid,
        };
    }
    try store.upsertIndex(repo_id, index_rows);
    try store.applyHydrate(repo_id, hydrate_rows);
}

/// 3-PR stack #812 <- #813 <- #814 (tip #814), 2-PR stack #790 <- #791, and
/// 26 standalones #700..#725, newest first in that order (listOpen sorts by
/// updated_at DESC, so the rows are: 3-stack, 2-stack, #700 ... #725).
/// #812 is approved by me at its head, so the 3-stack's review target is #813;
/// #812, #813, #710, #711, #712 request me; #703-#705 are mine; drafts are
/// #705, #711, #720. Synthetic oids: these PRs are not in the origin.
fn stacked31Specs(arena: Allocator) ![]PrSpec {
    var specs: std.ArrayList(PrSpec) = .empty;
    const stacks = [_]struct { number: u32, head: []const u8, base: []const u8 }{
        .{ .number = 814, .head = "s3-c", .base = "s3-b" },
        .{ .number = 813, .head = "s3-b", .base = "s3-a" },
        .{ .number = 812, .head = "s3-a", .base = "main" },
        .{ .number = 791, .head = "s2-b", .base = "s2-a" },
        .{ .number = 790, .head = "s2-a", .base = "main" },
    };
    for (stacks) |s| {
        try specs.append(arena, .{
            .number = s.number,
            .title = try std.fmt.allocPrint(arena, "Stacked change {d}", .{s.number}),
            .head_ref = s.head,
            .base_ref = s.base,
            .head_oid = try syntheticOid(arena, s.number),
            .base_oid = try syntheticOid(arena, 1),
            .updated_at = "",
        });
    }
    for (700..726) |n| {
        const number: u32 = @intCast(n);
        try specs.append(arena, .{
            .number = number,
            .title = try std.fmt.allocPrint(arena, "Standalone change {d}", .{number}),
            .head_ref = try std.fmt.allocPrint(arena, "feat-{d}", .{number}),
            .head_oid = try syntheticOid(arena, number),
            .base_oid = try syntheticOid(arena, 1),
            .updated_at = "",
            .ci = switch (number % 4) {
                0 => .success,
                1 => .failure,
                2 => .pending,
                else => .none,
            },
        });
    }
    for (specs.items, 0..) |*spec, i| {
        spec.updated_at = try std.fmt.allocPrint(arena, "2026-03-01T00:{d:0>2}:00Z", .{59 - i});
        switch (spec.number) {
            812 => {
                spec.requested_users = viewer_login;
                spec.my_review_state = "APPROVED";
                spec.my_review_oid = spec.head_oid;
            },
            813 => spec.requested_users = "me\nbob",
            703, 704 => spec.author = viewer_login,
            705 => {
                spec.author = viewer_login;
                spec.is_draft = true;
            },
            710, 712 => spec.requested_users = viewer_login,
            711 => {
                spec.requested_users = viewer_login;
                spec.is_draft = true;
            },
            720 => spec.is_draft = true,
            else => {},
        }
    }
    return specs.items;
}

/// Rows from Phase 5's targets.tsv (`number head_ref base_ref head_oid
/// base_oid updated_at parent_number`): real refs and oids in the origin, so
/// Enter can fetch and diff them.
fn origin14Specs(arena: Allocator, env: Env) ![]PrSpec {
    const tsv_path = try std.fmt.allocPrint(arena, "{s}/targets.tsv", .{env.work});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(skim_io.get(), tsv_path, arena, .limited(1 << 20));
    var specs: std.ArrayList(PrSpec) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields: [7][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, '\t');
        for (&fields) |*field| field.* = it.next() orelse return error.BadTargets;
        const number = try std.fmt.parseInt(u32, fields[0], 10);
        try specs.append(arena, .{
            .number = number,
            .title = try std.fmt.allocPrint(arena, "PR {d}", .{number}),
            .head_ref = fields[1],
            .base_ref = fields[2],
            .head_oid = fields[3],
            .base_oid = fields[4],
            .updated_at = fields[5],
        });
    }
    if (specs.items.len != 14) return error.BadTargets;
    return specs.items;
}

fn syntheticOid(arena: Allocator, n: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{x:0>40}", .{n});
}

/// Remove every `prs.db*` file and `config.json` under `$HOME/.skim`.
fn resetHome(env: Env) !void {
    const io = skim_io.get();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const skim_dir = try std.fmt.bufPrint(&path_buf, "{s}/.skim", .{env.home});
    var dir = try std.Io.Dir.openDirAbsolute(io, skim_dir, .{ .iterate = true });
    defer dir.close(io);
    var names: [64][std.fs.max_name_bytes]u8 = undefined;
    var name_lens: [64]usize = undefined;
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "prs.db") and !std.mem.eql(u8, entry.name, "config.json")) continue;
        if (count == names.len) return error.TooManyFiles;
        @memcpy(names[count][0..entry.name.len], entry.name);
        name_lens[count] = entry.name.len;
        count += 1;
    }
    for (names[0..count], name_lens[0..count]) |*name, len| try dir.deleteFile(io, name[0..len]);
}

fn dbPath(allocator: Allocator, env: Env) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.skim/prs.db", .{env.home});
}

/// Absolute path of the single `prs.db.corrupt-*` file; fails unless exactly one.
fn findQuarantined(ctx: *Ctx) ![]u8 {
    const io = skim_io.get();
    const skim_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/.skim", .{ctx.env.home});
    defer ctx.allocator.free(skim_dir);
    var dir = try std.Io.Dir.openDirAbsolute(io, skim_dir, .{ .iterate = true });
    defer dir.close(io);
    var found: ?[]u8 = null;
    errdefer if (found) |path| ctx.allocator.free(path);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "prs.db.corrupt-")) continue;
        count += 1;
        if (found == null) found = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ skim_dir, entry.name });
    }
    if (count != 1) return ctx.fail("{d} prs.db.corrupt-* files, expected exactly 1", .{count});
    return found.?;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(skim_io.get(), path, .{}) catch return false;
    return true;
}

fn fileSize(path: []const u8) !u64 {
    const stat = try std.Io.Dir.cwd().statFile(skim_io.get(), path, .{});
    return stat.size;
}

/// Bytes in the sync launcher's call log (one line per fake `gh` call).
/// Wait until the `kind` sync fake's call log grows past `past` bytes: the
/// current boot's gh is running.
fn waitSyncCall(ctx: *Ctx, params: struct { kind: SyncKind, past: u64 }) !void {
    var timer = try skim_io.Timer.start();
    while (timer.read() < sync_deadline_ns) {
        if (try syncCallCount(ctx, params.kind) > params.past) return;
        skim_io.sleep(poll_interval_ns);
    }
    return ctx.fail("the {s} sync fake was never called", .{@tagName(params.kind)});
}

fn syncCallCount(ctx: *Ctx, kind: SyncKind) !u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/root/calls.log", .{ ctx.env.sync_dir, @tagName(kind) });
    return fileSize(path);
}

/// Whether the log gained a line containing `needle` after byte `offset`.
fn logHasSince(ctx: *Ctx, params: struct { path: []const u8, offset: u64, needle: []const u8 }) !bool {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(skim_io.get(), params.path, ctx.allocator, .limited(16 << 20));
    defer ctx.allocator.free(bytes);
    if (params.offset > bytes.len) return false;
    return std.mem.indexOf(u8, bytes[@intCast(params.offset)..], params.needle) != null;
}

fn selectedNumber(sb: *const SidebarState) ?u32 {
    const record = sidebar_controller.selectedPr(sb) orelse return null;
    return record.number;
}

fn sidebarView(h: *Harness, frame_allocator: Allocator) SidebarView {
    return sidebar_controller.view(&h.app.state.sidebar, .{
        .focused = h.app.mode == .pr_review,
        .now_secs = skim_io.timestamp(),
        .frame_allocator = frame_allocator,
        .visible_rows = h.app.state.sidebar.rows.items.len,
    });
}

fn unavailableMessage(view: SidebarView) []const u8 {
    const empty = view.empty orelse return "";
    return switch (empty) {
        .unavailable => |message| message,
        else => "",
    };
}

fn optTag(value: anytype) ?[]const u8 {
    return if (value) |v| @tagName(v) else null;
}

fn countNotes(store: *const root.comments.CommentStore) usize {
    var count: usize = 0;
    for (store.comments.items) |comment| {
        if (std.mem.eql(u8, comment.text, "WT-NOTE")) count += 1;
    }
    return count;
}

/// The sync worker's hydrate priority list, copied under its mutex. Caller frees.
fn workerPriority(h: *Harness) ![]u32 {
    const worker = h.app.state.pr_surface.sync orelse return h.ctx.fail("no sync worker running", .{});
    worker.mutex.lockUncancelable(skim_io.get());
    defer worker.mutex.unlock(skim_io.get());
    return h.ctx.allocator.dupe(u32, worker.priority.items);
}

/// The worker's priority list equals `visibleNumbers` for the current view.
fn expectPriorityMatchesView(ctx: *Ctx, h: *Harness, label: []const u8) !void {
    const visible = try sidebar_controller.visibleNumbers(h.sidebar(), ctx.allocator);
    defer ctx.allocator.free(visible);
    const priority = try workerPriority(h);
    defer ctx.allocator.free(priority);
    if (!std.mem.eql(u32, priority, visible))
        return ctx.fail("{s}: worker priority {any} != visibleNumbers {any}", .{ label, priority, visible });
}

/// Sorts and frees `actual`, then compares it with sorted `expected`.
fn expectSortedEqual(ctx: *Ctx, params: struct { label: []const u8, actual: []u32, expected: []const u32 }) !void {
    defer ctx.allocator.free(params.actual);
    std.mem.sort(u32, params.actual, {}, std.sort.asc(u32));
    if (!std.mem.eql(u32, params.actual, params.expected))
        return ctx.fail("{s}: {any}, expected {any}", .{ params.label, params.actual, params.expected });
}

/// The record number behind every row (a header row's record is its stack's
/// review target), sorted, equals `expected`.
fn expectRowRecords(ctx: *Ctx, sb: *const SidebarState, params: struct { label: []const u8, expected: []const u32 }) !void {
    const records = sb.records orelse return ctx.fail("{s}: no records", .{params.label});
    const numbers = try ctx.allocator.alloc(u32, sb.rows.items.len);
    for (sb.rows.items, numbers) |row, *number| number.* = records.items[row.record].number;
    try expectSortedEqual(ctx, .{ .label = params.label, .actual = numbers, .expected = params.expected });
}

fn expectCursor(ctx: *Ctx, h: *Harness, params: struct { step: []const u8, number: u32, rows: usize }) !void {
    const sb = h.sidebar();
    const selected = selectedNumber(sb);
    if (selected != params.number) return ctx.fail("{s}: selected #{?d}, expected #{d}", .{ params.step, selected, params.number });
    if (sb.rows.items.len != params.rows) return ctx.fail("{s}: {d} rows, expected {d}", .{ params.step, sb.rows.items.len, params.rows });
}
