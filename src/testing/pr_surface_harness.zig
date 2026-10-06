//! Offline harness for the PR sidebar surface and its flip. Drives the real
//! `App` (no tty: `initForRenderBench`), the real `SyncWorker` against the
//! sync fake `gh`, the real `PrefetchWorker` and review entry worker against
//! the review fake `gh` and a local bare origin. S* scenarios cover the
//! sidebar and sync; H*, M2 and R1 cover the flip.
//!
//! Run through scripts/test-infra/pr-sidebar/surface-harness.sh, which builds
//! the git world, the fake `gh` launchers and a temp HOME, exports the
//! SKIM_HARNESS_* environment and runs this binary from the clone:
//!
//!   pr_surface_harness [all|S1|...|S14|H0|...|H6]   PASS/FAIL line per scenario, exit 1 on any FAIL
//!   pr_surface_harness seed-only <stacked31|origin14>   seed $HOME/.skim/prs.db and exit (S12)
//!
//! Every scenario runs under its own `DebugAllocator`; a leak is a FAIL.
//!
//! The flip scenarios (H*, M2, R1) count subprocesses with two logs:
//! `GIT_TRACE` (git appends a line per invocation anywhere in the process
//! tree) and the review fake's `FAKE_GH_LOG`. "No spawn" = both byte-identical across the step, always
//! with the workers stopped. Each no-spawn window also touches
//! `$WORK/exec-marks/<id>-<n>-begin|end` (an `access` call), so the script's
//! optional strace audit can fail any execve inside the window. Flip scenarios
//! run only after H0 proved the review fake intercepts gh.

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
const flip = root.flip;
const surface_controller = root.surface_controller;
const pr_surface = root.surface;
const DiffKey = types.DiffKey;
const FileDiff = root.parser.FileDiff;
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
    /// Review fake `gh` (`ReviewSession.gh_bin`).
    review_gh: []const u8,
    /// `<dir>/<kind>/gh` launchers for the sync fake; `<dir>/<kind>/root/calls.log`.
    sync_dir: []const u8,
    gh_log: []const u8,
    /// File count of PR 9's diff, computed by the script from the origin.
    pr9_files: usize,
    /// `GIT_TRACE`: one block per git invocation in the process tree (flip scenarios).
    git_trace: []const u8,
    /// `FAKE_GH_FIXTURES`: review-N.json and the optional sleep-N files (H6).
    fixtures: []const u8,
    /// scripts/test-infra/pr-sidebar/flip-world.sh (H3, H4a, H4b, H5).
    flip_world: []const u8,
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
    /// Runs only after H0 passed: its no-gh assertions are vacuous otherwise.
    requires_gh_intercept: bool = false,
};

/// Log sizes at a point in time; `expectNoSpawn` compares against them.
const SpawnMark = struct {
    git: u64,
    gh: u64,
    seq: u32,
};

const WarmParams = struct {
    /// `PrefetchWorker.setFocus` before waiting; null keeps the App's focus.
    focus: ?u32 = null,
};

/// Per-scenario context. `fail` records the reason the runner prints.
const Ctx = struct {
    allocator: Allocator,
    env: Env,
    /// Scenario id, for exec-audit marker names.
    id: []const u8 = "",
    mark_seq: u32 = 0,
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
    params: BootParams,
    /// Virtual clock for `surface_controller.tick` (ms). Starts at the real clock and
    /// only moves forward; see `flipTo` for why it tracks real time.
    now_ms: i64,
    /// False after `deinit`, so a failed `restart` is not torn down twice.
    alive: bool = true,

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
        app.openPrSurface(.{ .gh_bin = launcher, .prefetch_gh_bin = ctx.env.review_gh });
        return .{
            .ctx = ctx,
            .app = app,
            .sync_launcher = launcher,
            .booted_at = booted_at,
            .params = params,
            .now_ms = skim_io.milliTimestamp(),
        };
    }

    /// `App.deinit` closes the surface (stops the worker, closes the store)
    /// and frees the sidebar; the runner's allocator check catches leaks.
    fn deinit(self: *Harness) void {
        if (!self.alive) return;
        self.alive = false;
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

    /// Step background work until no review entry, no diff load and no
    /// debounced preview is in flight.
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
        return self.app.state.diff_load.isLoading() or review.entry_in_flight or review_controller.entryPending(review) or self.app.state.flip.pending != null;
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

    /// Open the `/` prompt and replace its pre-filled text with `text`, then Enter.
    fn submitQuery(self: *Harness, text: []const u8) !void {
        try self.pressChar('/');
        const prompt = &(self.sidebar().prompt orelse return self.ctx.fail("`/` did not open the filter prompt", .{}));
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

    // --- Flip -----------------------------------------------------------

    /// `boot`, then stop both workers before they cache anything and empty
    /// diff_cache (pinned seen rows stay): every flip is a miss.
    fn bootCold(ctx: *Ctx, params: BootParams) !Harness {
        var h = try boot(ctx, params);
        errdefer h.deinit();
        pr_surface.stopWorkers(&h.app.state.pr_surface);
        _ = try (try h.uiStore()).evictDiffs(h.app.state.pr_surface.repo_id, 0);
        return h;
    }

    /// `deinit` (final notes save, surface close) then `boot` again with the
    /// same params on the same HOME and DB. The virtual clock restarts at the
    /// real clock.
    fn restart(self: *Harness) !void {
        const ctx = self.ctx;
        const params = self.params;
        self.deinit();
        self.* = try boot(ctx, params);
    }

    /// Step background work until the PrefetchWorker is idle for the current
    /// target list (and ordered by `params.focus` when given), then stop both
    /// workers. Afterwards nothing spawns unless the App itself does.
    fn warmCache(self: *Harness, params: WarmParams) !void {
        const worker = self.app.state.pr_surface.prefetch orelse return self.ctx.fail("warmCache: no prefetch worker running", .{});
        self.app.pollBackgroundWork();
        if (params.focus) |number| worker.setFocus(number);
        var timer = try skim_io.Timer.start();
        var status = worker.status();
        while (timer.read() < warm_deadline_ns) {
            self.app.pollBackgroundWork();
            status = worker.status();
            if (status.phase == .failed) return self.ctx.fail("warmCache: prefetch failed ({?s})", .{optTag(status.last_error)});
            const version = targetsVersion(worker);
            const focused = if (params.focus) |number| status.focus == number else true;
            if (version > 0 and status.targets_version == version and status.phase == .idle and focused) {
                self.app.pollBackgroundWork();
                pr_surface.stopWorkers(&self.app.state.pr_surface);
                return;
            }
            skim_io.sleep(poll_interval_ns);
        }
        return self.ctx.fail("warmCache: prefetch not idle after {d}s (phase {s}, version {d}/{d}, focus {d}, diffs {d}/{d}, failures {d})", .{
            warm_deadline_ns / std.time.ns_per_s, @tagName(status.phase), status.targets_version, targetsVersion(worker),
            status.focus,                         status.diffs_ready,     status.targets,         status.failures,
        });
    }

    /// Select `number` the way `j`/`k` would (sets `cursor_changed`), tick to
    /// arm the debounce, move the clock past it and tick again to fire the
    /// preview, then one `pollBackgroundWork`. A hit is installed on return; a
    /// miss is in flight (`settle` to land it).
    ///
    /// The fire is split from the arm because `surface_controller.tick` consumes the
    /// cursor change and runs `flip.tick` in one call, and the debounce is
    /// measured from the arm. After the fire, wait until the real clock
    /// reaches the virtual one: `installPrDiff` stamps the preview with the
    /// real clock, and a virtual clock far ahead of it would read as a 3s
    /// dwell on the next tick.
    fn flipTo(self: *Harness, number: u32) !void {
        if (!try sidebar_controller.selectNumber(self.sidebar(), self.ctx.allocator, number))
            return self.ctx.fail("flipTo: selectNumber(#{d}) found no row", .{number});
        self.tick();
        self.advance(flip.debounce_ms + 1);
        self.tick();
        self.app.pollBackgroundWork();
        self.catchUp();
    }

    /// Advance past the 3s dwell and tick: `.mark_seen` for the previewed PR.
    /// The virtual clock is then 3s ahead of the real one, so `restart` (which
    /// resets it) must come before the next `flipTo`.
    fn dwell(self: *Harness) void {
        self.advance(flip.dwell_ms + 1);
        self.tick();
    }

    fn tick(self: *Harness) void {
        surface_controller.tick(self.app.surfaceCtx(), self.now_ms);
    }

    fn advance(self: *Harness, ms: i64) void {
        self.now_ms = @max(self.now_ms, skim_io.milliTimestamp()) + ms;
    }

    fn catchUp(self: *Harness) void {
        while (skim_io.milliTimestamp() < self.now_ms) skim_io.sleep(std.time.ns_per_ms);
    }

    /// The App's UI-thread Store connection.
    fn uiStore(self: *Harness) !*Store {
        if (self.app.state.pr_surface.store) |*s| return s;
        return self.ctx.fail("the PR surface has no store open", .{});
    }

    fn repoId(self: *Harness) i64 {
        return self.app.state.pr_surface.repo_id;
    }

    /// The `.pr` view DiffKey of trunk PR `number` from targets.tsv and the
    /// worker's merge_base_cache (no git). Stacked PRs are not supported.
    fn diffKeyFor(self: *Harness, number: u32) !DiffKey {
        var arena_state = std.heap.ArenaAllocator.init(self.ctx.allocator);
        defer arena_state.deinit();
        const spec = try specFor(self.ctx, .{ .arena = arena_state.allocator(), .number = number });
        const merge_base = try (try self.uiStore()).getMergeBase(self.repoId(), .{ .base_tip_oid = spec.base_oid, .head_oid = spec.head_oid }) orelse
            return self.ctx.fail("no merge base cached for #{d} ({s}...{s})", .{ number, spec.base_oid[0..8], spec.head_oid[0..8] });
        return .{ .merge_base_oid = merge_base, .head_oid = try oidArray(self.ctx, spec.head_oid) };
    }

    /// Delete every diff_cache row except `keys` (pinned seen rows also stay).
    fn keepOnly(self: *Harness, keys: []const DiffKey) !void {
        const deleted = try (try self.uiStore()).evictDiffsRanked(self.ctx.allocator, .{
            .repo_id = self.repoId(),
            .budget_bytes = 0,
            .ranked = keys,
            .keep_nearest = keys.len,
        });
        self.ctx.allocator.free(deleted);
        for (keys) |key| {
            if (!try (try self.uiStore()).hasDiff(self.repoId(), key)) return self.ctx.fail("keepOnly: a kept key is not cached", .{});
        }
    }

    fn lruContains(self: *Harness, key: DiffKey) bool {
        if (self.app.state.flip.lru) |*lru| return lru.contains(key);
        return false;
    }

    /// Clear the status bar so a later error check sees only the next step.
    fn clearStatus(self: *Harness) void {
        self.app.state.status_message = null;
        self.app.state.status_message_severity = .info;
    }

    /// An error the user can see: a sidebar message other than the
    /// "Loading PR #N…" placeholder, or an error-severity status bar message.
    fn errorVisible(self: *Harness) bool {
        const message = self.sidebar().messageText();
        if (message.len > 0 and !std.mem.startsWith(u8, message, "Loading")) return true;
        return self.app.state.status_message != null and self.app.state.status_message_severity == .err;
    }

    fn hasThread(self: *Harness, id: []const u8) bool {
        for (self.app.state.review.threads.items) |thread| {
            if (std.mem.eql(u8, thread.data.id, id)) return true;
        }
        return false;
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
/// Flip: the PrefetchWorker caches all 14 origin14 PRs (diffs, merge bases,
/// threads for the nearest 10) well inside this.
const warm_deadline_ns = 30 * std.time.ns_per_s;
/// H6: the review fake holds its PR 9 answer this long (fixtures/sleep-9).
const slow_gh_secs = "2";
const stale_thread_id = "PRRT_STALE_10";
const stale_updated_at = "2000-01-01T00:00:00Z";
const orphan_heading = "Notes not anchored in this diff";
/// H2: A→B→A round trips after the asserted one.
const round_trips = 50;

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

/// Runs first for any flip target (see `main`).
const h0_scenario: Scenario = .{ .id = "H0", .what = "GIT_TRACE and the review fake's log see the miss path's subprocesses", .run = h0LogsSeeSubprocesses };

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
    // Flip. The world mutators (H3, H4a, H4b, H5) run last: they rewrite PRs 5,
    // 9 and 14 in the shared origin.
    h0_scenario,
    .{ .id = "H1", .what = "a cache hit spawns no git or gh; `r` re-diffs the refs", .run = h1HitSpawnsNothing, .requires_gh_intercept = true },
    .{ .id = "H2", .what = "A->B->A takes A's set back out of the LRU and restores the cursor; no aliasing", .run = h2RoundTrip, .requires_gh_intercept = true },
    .{ .id = "R1", .what = "rapid flips install only the last PR (hit and miss)", .run = r1RapidFlips, .requires_gh_intercept = true },
    .{ .id = "M2", .what = "a miss is written back by prefetch and the second visit is a hit", .run = m2MissWriteBack, .requires_gh_intercept = true },
    .{ .id = "H6", .what = "stale-thread hit during an in-flight miss refetches with gh only; gh failures degrade", .run = h6RefetchAfterJoin, .requires_gh_intercept = true },
    .{ .id = "H7", .what = "a miss whose diff load fails is never marked seen by the dwell", .run = h7FailedMissNotSeen, .requires_gh_intercept = true },
    .{ .id = "H8", .what = "a flip while a comment editor is open waits for it, then lands on the cursor's PR", .run = h8EditorDefersFlip, .requires_gh_intercept = true },
    .{ .id = "H3", .what = "notes stay per PR across flips and restarts; orphans go to the export", .run = h3NotesPerPr, .requires_gh_intercept = true },
    .{ .id = "H4a", .what = "force-push marks only the files whose own edits changed", .run = h4aForcePush, .requires_gh_intercept = true },
    .{ .id = "H4b", .what = "fast-forward shows the incremental diff with no UI git", .run = h4bFastForward, .requires_gh_intercept = true },
    .{ .id = "H5", .what = "the seen diff survives eviction; the sentinel merge base is backfilled", .run = h5SeenPin, .requires_gh_intercept = true },
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
    // null until H0 ran; H0 runs once, before the first scenario that needs it.
    var gh_intercepted: ?bool = null;
    for (scenarios) |scenario| {
        if (!std.mem.eql(u8, target, "all") and !std.mem.eql(u8, target, scenario.id)) continue;
        ran += 1;
        const is_h0 = std.mem.eql(u8, scenario.id, h0_scenario.id);
        if (is_h0 or scenario.requires_gh_intercept) {
            if (gh_intercepted == null) {
                gh_intercepted = try runScenario(.{ .scenario = h0_scenario, .env = env, .out = out });
                if (!gh_intercepted.?) failed += 1;
            }
            if (is_h0) continue;
            if (!gh_intercepted.?) {
                try out.print("FAIL {s}: not run: H0 failed, so gh is not intercepted and no-spawn checks would pass vacuously\n", .{scenario.id});
                try out.flush();
                failed += 1;
                continue;
            }
        }
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
        if (sb.active_preset != null or sb.query_len != 0) return ctx.fail("F after `mine`: active_preset = {?d}, query '{s}', expected the built-in `All open`", .{ sb.active_preset, sb.query[0..sb.query_len] });
        if (sb.rows.items.len != stacked31_rows) return ctx.fail("F to `All open`: {d} rows, expected {d}", .{ sb.rows.items.len, stacked31_rows });

        try cycleToReady(ctx, &h);
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
        if (sb.presets.len != 1 or !std.mem.eql(u8, sb.presets[0].name, "All open")) return ctx.fail("no config.json: {d} presets, expected the built-in `All open`", .{sb.presets.len});
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

    try cycleToReady(ctx, &h);
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
    const head9 = try headOidOwned(ctx, 9);
    defer ctx.allocator.free(head9);
    try expectTwoRefs(&h, .{ .ref1 = "origin/main", .ref2 = head9, .use_merge_base = true });

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

// --- Flip ----------------------------------------------------------------

fn h0LogsSeeSubprocesses(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.bootCold(ctx, .{ .sync = .network });
    defer h.deinit();
    const git_before = try fileSizeOrZero(ctx.env.git_trace);
    const gh_before = try fileSizeOrZero(ctx.env.gh_log);

    try h.flipTo(9);
    try h.settle();

    if (try fileSizeOrZero(ctx.env.git_trace) == git_before) return ctx.fail("git-trace.log did not grow on a miss: GIT_TRACE is not reaching git", .{});
    if (try fileSizeOrZero(ctx.env.gh_log) == gh_before or !try logHasSince(ctx, .{ .path = ctx.env.gh_log, .offset = gh_before, .needle = "number=9" }))
        return ctx.fail("gh not intercepted: the review fake logged no number=9 call for the miss", .{});
    // The miss diffs the oid its fetch landed, not the movable refs/skim/pr-9.
    const head = try headOidOwned(ctx, 9);
    defer ctx.allocator.free(head);
    try expectTwoRefs(&h, .{ .ref1 = "origin/main", .ref2 = head, .use_merge_base = true });
}

fn h1HitSpawnsNothing(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    try h.warmCache(.{ .focus = 10 });
    const app = h.app;
    const record10 = try recordFor(&h, 10);
    if (!try (try h.uiStore()).threadsFresh(h.repoId(), .{ .number = 10, .pr_updated_at = record10.updated_at }))
        return ctx.fail("setup: warm-up left no fresh thread_cache row for #10", .{});

    try h.flipTo(9);
    try h.settle();

    const mark = try spawnMark(ctx);
    try h.flipTo(10);
    try expectNoSpawn(ctx, .{ .mark = mark, .step = "flip to cached #10" });
    try expectFiles(&h, .{ .label = "hit #10", .number = 10 });
    const state = &app.state.flip;
    if (state.previewed != 10) return ctx.fail("flip.previewed = {?d}, expected 10", .{state.previewed});
    if (state.displayed_key == null) return ctx.fail("flip.displayed_key is null after a hit", .{});
    if (app.state.review.number != 10) return ctx.fail("review.number = {d}, expected 10", .{app.state.review.number});
    if (app.state.review.data_unavailable) return ctx.fail("review.data_unavailable after a hit with fresh cached threads", .{});
    if (app.mode != .pr_review) return ctx.fail("mode {s} after a preview, expected pr_review (focus stays on the sidebar)", .{@tagName(app.mode)});
    // The cached diff's own head, not refs/skim/pr-10: `r` re-diffs exactly
    // what is on screen even when the ref lags a locally present head.
    try expectTwoRefs(&h, .{ .ref1 = "origin/main", .ref2 = (try recordFor(&h, 10)).head_oid, .use_merge_base = true });

    const git_before = try fileSizeOrZero(ctx.env.git_trace);
    app.mode = .normal;
    try h.pressChar('r');
    app.mode = .pr_review;
    try h.settle();
    if (try fileSizeOrZero(ctx.env.git_trace) == git_before) return ctx.fail("`r` ran no git: refresh did not re-diff the refs", .{});
    try expectFiles(&h, .{ .label = "after `r`", .number = 10 });
    if (state.displayed_key != null) return ctx.fail("flip.displayed_key still set after `r` (a streamed set has no key)", .{});
}

fn h2RoundTrip(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    try h.warmCache(.{ .focus = 4 });
    const app = h.app;
    try h.flipTo(4);
    const key4 = try h.diffKeyFor(4);
    if (app.state.flip.displayed_key == null) return ctx.fail("setup: #4 was not a hit after warm-up", .{});

    const shared_idx = try fileIndex(&h, "shared.txt");
    const target = try firstAddLine(&h, shared_idx);
    if (target.global_line < 5) return ctx.fail("setup: shared.txt's add line is at {d}, need >= 5 rows above", .{target.global_line});
    app.state.global_cursor_line = target.global_line;
    app.state.global_scroll_offset = target.global_line - 5;
    const parked = app.state.files.ptr;

    try h.flipTo(11);
    if (!h.lruContains(key4)) return ctx.fail("#4's set was not parked in the LRU on the flip to #11", .{});

    const mark = try spawnMark(ctx);
    try h.flipTo(4);
    try expectNoSpawn(ctx, .{ .mark = mark, .step = "flip back to #4" });
    if (app.state.files.ptr != parked) return ctx.fail("#4's files came back at a different address: re-parsed, not taken from the LRU", .{});
    if (h.lruContains(key4)) return ctx.fail("#4's set is installed and still in the LRU (aliased)", .{});
    const at = try cursorLine(&h);
    if (!std.mem.eql(u8, at.path, "shared.txt") or at.new_lineno != target.new_lineno)
        return ctx.fail("cursor restored to {s}:{?d}, expected shared.txt:{?d}", .{ at.path, at.new_lineno, target.new_lineno });
    const rows_from_top = app.state.global_cursor_line -| app.state.global_scroll_offset;
    if (rows_from_top != 5) return ctx.fail("cursor is {d} rows from the top, expected 5", .{rows_from_top});

    for (0..round_trips) |i| {
        try h.flipTo(11);
        for (0..3) |_| app.pollBackgroundWork();
        try h.flipTo(4);
        for (0..3) |_| app.pollBackgroundWork();
        if (app.state.flip.previewed != 4 or app.state.flip.displayed_key == null)
            return ctx.fail("round trip {d}: previewed #{?d}, displayed_key set={}", .{ i, app.state.flip.previewed, app.state.flip.displayed_key != null });
    }
}

fn r1RapidFlips(ctx: *Ctx) !void {
    {
        try seed(ctx, .{ .fixture = .origin14 });
        var h = try Harness.boot(ctx, .{ .sync = .network });
        defer h.deinit();
        try h.warmCache(.{ .focus = 11 });
        const app = h.app;
        try h.flipTo(9);
        const key9 = try h.diffKeyFor(9);
        if (app.state.flip.previewed != 9) return ctx.fail("setup: #9 not previewed after warm-up", .{});

        for ([_]u32{ 10, 11, 12, 13 }) |number| {
            if (!try sidebar_controller.selectNumber(h.sidebar(), ctx.allocator, number)) return ctx.fail("selectNumber(#{d}) found no row", .{number});
            h.advance(10);
            h.tick();
            if (app.state.flip.previewed != 9) return ctx.fail("#{?d} previewed 10ms after moving to #{d}, inside the debounce", .{ app.state.flip.previewed, number });
        }
        h.advance(flip.debounce_ms + 1);
        h.tick();
        h.catchUp();
        if (app.state.flip.previewed != 13) return ctx.fail("after the debounce: previewed #{?d}, expected 13", .{app.state.flip.previewed});
        if (app.state.review.number != 13) return ctx.fail("review.number = {d}, expected 13", .{app.state.review.number});
        if (!h.lruContains(key9)) return ctx.fail("#9's set is not parked in the LRU", .{});
        for ([_]u32{ 10, 11, 12 }) |number| {
            if (h.lruContains(try h.diffKeyFor(number))) return ctx.fail("#{d} was installed during the burst (its set is in the LRU)", .{number});
        }
    }
    {
        try seed(ctx, .{ .fixture = .origin14 });
        var h = try Harness.bootCold(ctx, .{ .sync = .network });
        defer h.deinit();
        try h.settle();
        const io = skim_io.get();
        var sleep_paths: [2][]u8 = undefined;
        for ([_]u32{ 9, 10 }, &sleep_paths) |number, *path| {
            path.* = try std.fmt.allocPrint(ctx.allocator, "{s}/sleep-{d}", .{ ctx.env.fixtures, number });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path.*, .data = slow_gh_secs });
        }
        defer for (sleep_paths) |path| {
            std.Io.Dir.cwd().deleteFile(io, path) catch |err| std.log.err("removing {s}: {}", .{ path, err });
            ctx.allocator.free(path);
        };
        const gh_before = try fileSizeOrZero(ctx.env.gh_log);
        try h.flipTo(9);
        try waitLogLine(ctx, .{ .path = ctx.env.gh_log, .offset = gh_before, .needle = "number=9" });
        try h.flipTo(10);
        try h.flipTo(11);
        const review = &h.app.state.review;
        if (!review.entry_in_flight or review.entering_number != 9) return ctx.fail("miss burst: #9's slow entry is not in flight while #11 is selected (in flight: {}, #{d})", .{ review.entry_in_flight, review.entering_number });
        const parked = review.next_entry orelse return ctx.fail("miss burst: no entry parked behind #9's", .{});
        if (parked.number != 11) return ctx.fail("miss burst: #{d} parked behind #9, expected 11 (latest wins)", .{parked.number});
        try h.settle();
        if (h.app.state.review.number != 11) return ctx.fail("miss burst: review.number = {d}, expected 11", .{h.app.state.review.number});
        try expectFiles(&h, .{ .label = "miss burst", .number = 11 });
        const threads = h.app.state.review.threads.items;
        if (threads.len != 1 or !h.hasThread("PRRT_11")) return ctx.fail("miss burst: {d} session threads, expected exactly PRRT_11 (9's or 10's result leaked)", .{threads.len});
    }
}

fn m2MissWriteBack(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.bootCold(ctx, .{ .sync = .network });
    defer h.deinit();
    const app = h.app;
    const git_before = try fileSizeOrZero(ctx.env.git_trace);
    try h.flipTo(12);
    try h.settle();
    if (try fileSizeOrZero(ctx.env.git_trace) == git_before) return ctx.fail("first visit to #12 ran no git: not a miss", .{});
    if (app.state.flip.displayed_key != null) return ctx.fail("a miss-loaded set has a displayed_key", .{});

    const db_path = try dbPath(ctx.allocator, ctx.env);
    defer ctx.allocator.free(db_path);
    pr_surface.startPrefetch(&app.state.pr_surface, .{
        .allocator = app.allocator,
        .sidebar = h.sidebar(),
        .repo_root = ctx.env.repo,
        .db_path = db_path,
        .owner = fixture_owner,
        .name = fixture_name,
        .gh_bin = ctx.env.review_gh,
    });
    try h.warmCache(.{ .focus = 12 });

    try h.flipTo(13);
    try h.settle();
    const key12 = try h.diffKeyFor(12);
    if (h.lruContains(key12)) return ctx.fail("#12's miss-loaded set was parked in the LRU (it has no key)", .{});
    const mark = try spawnMark(ctx);
    try h.flipTo(12);
    try expectNoSpawn(ctx, .{ .mark = mark, .step = "second visit to #12" });
    if (app.state.flip.displayed_key == null) return ctx.fail("second visit to #12 was not a hit", .{});
    try expectFiles(&h, .{ .label = "second visit", .number = 12 });
}

fn h6RefetchAfterJoin(ctx: *Ctx) !void {
    const io = skim_io.get();
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const app = h.app;
    try h.warmCache(.{ .focus = 10 });
    const key10 = try h.diffKeyFor(10);
    try h.keepOnly(&.{key10});
    const stale_path = try std.fmt.allocPrint(ctx.allocator, "{s}/stale/review-10.json", .{ctx.env.work});
    defer ctx.allocator.free(stale_path);
    const stale_json = try std.Io.Dir.cwd().readFileAlloc(io, stale_path, ctx.allocator, .limited(1 << 20));
    defer ctx.allocator.free(stale_json);
    try (try h.uiStore()).putThreads(.{ .repo_id = h.repoId(), .number = 10, .pr_updated_at = stale_updated_at, .json = stale_json, .now = skim_io.timestamp() });

    const sleep_path = try std.fmt.allocPrint(ctx.allocator, "{s}/sleep-9", .{ctx.env.fixtures});
    defer ctx.allocator.free(sleep_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sleep_path, .data = slow_gh_secs });
    defer std.Io.Dir.cwd().deleteFile(io, sleep_path) catch |err| std.log.err("removing sleep-9: {}", .{err});

    {
        const gh_before = try fileSizeOrZero(ctx.env.gh_log);
        try h.flipTo(9);
        try waitLogLine(ctx, .{ .path = ctx.env.gh_log, .offset = gh_before, .needle = "number=9" });

        const mark = try spawnMark(ctx);
        try h.flipTo(10);
        try expectNoSpawn(ctx, .{ .mark = mark, .step = "stale-thread hit on #10 while #9 is in flight" });
        const review = &app.state.review;
        if (!review.refetch_after_join) return ctx.fail("review.refetch_after_join not set by a stale hit during an in-flight entry", .{});
        if (review.number != 10 or review.data_unavailable) return ctx.fail("stale threads not applied: number {d}, data_unavailable {}", .{ review.number, review.data_unavailable });
        if (!h.hasThread(stale_thread_id)) return ctx.fail("{s} not in the session after the stale hit", .{stale_thread_id});

        try awaitSupersededDrop(&h);
        try h.settle();
        const gh_lines = try countLinesSince(ctx, .{ .path = ctx.env.gh_log, .offset = mark.gh });
        if (gh_lines != 1 or !try logHasSince(ctx, .{ .path = ctx.env.gh_log, .offset = mark.gh, .needle = "number=10" }))
            return ctx.fail("gh.log gained {d} lines after the hit, expected exactly the number=10 refetch", .{gh_lines});
        if (try fileSizeOrZero(ctx.env.git_trace) != mark.git) return ctx.fail("git ran after the hit: the refetch must be gh only (see Test Environment Setup: refetch git config)", .{});
        if (review.number != 10) return ctx.fail("after settle review.number = {d}, expected 10", .{review.number});
        if (h.hasThread(stale_thread_id) or review.threads.items.len != 0)
            return ctx.fail("refetch did not replace the stale threads ({d} threads, stale present {})", .{ review.threads.items.len, h.hasThread(stale_thread_id) });
    }
    {
        const gh_before = try fileSizeOrZero(ctx.env.gh_log);
        try h.flipTo(9);
        try waitLogLine(ctx, .{ .path = ctx.env.gh_log, .offset = gh_before, .needle = "number=9" });
        try h.flipTo(11);
        try h.flipTo(10);
        try h.settle();
        try h.pollFor(200);
        if (try logHasSince(ctx, .{ .path = ctx.env.gh_log, .offset = gh_before, .needle = "number=11" }))
            return ctx.fail("parked entry for #11 started after the hit on #10 (next_entry not cleared)", .{});
        if (app.state.review.number != 10) return ctx.fail("parked variant: review.number = {d}, expected 10", .{app.state.review.number});
    }
    {
        const review12 = try std.fmt.allocPrint(ctx.allocator, "{s}/review-12.json", .{ctx.env.fixtures});
        defer ctx.allocator.free(review12);
        const review13 = try std.fmt.allocPrint(ctx.allocator, "{s}/review-13.json", .{ctx.env.fixtures});
        defer ctx.allocator.free(review13);
        const original12 = try std.Io.Dir.cwd().readFileAlloc(io, review12, ctx.allocator, .limited(1 << 20));
        defer ctx.allocator.free(original12);
        const original13 = try std.Io.Dir.cwd().readFileAlloc(io, review13, ctx.allocator, .limited(1 << 20));
        defer ctx.allocator.free(original13);
        try std.Io.Dir.cwd().deleteFile(io, review12);
        defer std.Io.Dir.cwd().writeFile(io, .{ .sub_path = review12, .data = original12 }) catch |err| std.log.err("restoring review-12.json: {}", .{err});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = review13, .data = "{not json" });
        defer std.Io.Dir.cwd().writeFile(io, .{ .sub_path = review13, .data = original13 }) catch |err| std.log.err("restoring review-13.json: {}", .{err});
        const rows = h.sidebar().rows.items.len;

        for ([_]u32{ 12, 13 }) |number| {
            h.clearStatus();
            try h.flipTo(number);
            try h.settle();
            const review = &app.state.review;
            if (review.number == number and !review.data_unavailable) return ctx.fail("#{d}: review data shown although gh failed", .{number});
            if (!h.errorVisible()) return ctx.fail("#{d}: gh failed and no error is visible (sidebar message and status bar empty)", .{number});
            if (h.sidebar().rows.items.len != rows) return ctx.fail("#{d}: sidebar has {d} rows after the failure, expected {d}", .{ number, h.sidebar().rows.items.len, rows });
        }
        try expectFiles(&h, .{ .label = "#13 with unparseable review JSON", .number = 13 });

        try h.flipTo(10);
        try h.settle();
        if (app.state.review.number != 10 or app.state.review.data_unavailable)
            return ctx.fail("hit on #10 after the failures: number {d}, data_unavailable {}", .{ app.state.review.number, app.state.review.data_unavailable });
    }
}

fn h3NotesPerPr(ctx: *Ctx) !void {
    const io = skim_io.get();
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    try h.warmCache(.{ .focus = 9 });

    try h.flipTo(9);
    const note9 = try addNote(&h, "note-9");
    h.tick();
    try h.flipTo(12);
    if (h.app.state.comment_store.comments.items.len != 0) return ctx.fail("#12 shows {d} comments right after the flip from #9", .{h.app.state.comment_store.comments.items.len});
    const note12 = try addNote(&h, "note-12");
    h.tick();

    try h.flipTo(9);
    try expectOnlyNote(&h, .{ .label = "back on #9", .text = "note-9", .new_lineno = note9.new_lineno });

    try h.restart();
    try h.flipTo(12);
    try h.settle();
    try expectOnlyNote(&h, .{ .label = "#12 after restart", .text = "note-12", .new_lineno = note12.new_lineno });
    try expectNoteRow(&h, .{ .number = 9, .text = "note-9", .line_content = note9.line_content });
    try expectNoteRow(&h, .{ .number = 12, .text = "note-12", .line_content = note12.line_content });
    ctx.allocator.free(note9.line_content);
    ctx.allocator.free(note12.line_content);

    try runFlipWorld(ctx, "drop-file-pr9");
    try reseedOrigin14(&h);
    try h.restart();
    try h.warmCache(.{ .focus = 9 });
    try h.flipTo(9);
    try h.settle();
    const app = h.app;
    if (app.state.comment_store.comments.items.len != 0) return ctx.fail("orphan: #9 shows {d} comments after its file was dropped", .{app.state.comment_store.comments.items.len});
    if (app.state.flip.orphan_notes.items.len != 1) return ctx.fail("orphan: flip.orphan_notes has {d} entries, expected 1", .{app.state.flip.orphan_notes.items.len});
    var rows = try (try h.uiStore()).listNotes(ctx.allocator, .{ .repo_id = h.repoId(), .number = 9 });
    defer rows.deinit();
    if (rows.items.len != 1) return ctx.fail("orphan: the DB has {d} notes for #9, expected the row kept", .{rows.items.len});

    const clipboard_path = try std.fmt.allocPrint(ctx.allocator, "{s}/clipboard.txt", .{ctx.env.work});
    defer ctx.allocator.free(clipboard_path);
    std.Io.Dir.cwd().deleteFile(io, clipboard_path) catch {};
    try root.comment_controller.CommentController.yankAllCommentsToClipboard(app);
    const exported = try std.Io.Dir.cwd().readFileAlloc(io, clipboard_path, ctx.allocator, .limited(1 << 20));
    defer ctx.allocator.free(exported);
    const heading = std.mem.indexOf(u8, exported, orphan_heading) orelse return ctx.fail("export lacks '{s}'", .{orphan_heading});
    if (std.mem.indexOf(u8, exported[heading..], "note-9") == null) return ctx.fail("export has no note-9 under '{s}'", .{orphan_heading});
}

fn h4aForcePush(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const seen = try markSeenByDwell(&h, 5);

    try runFlipWorld(ctx, "rewrite-pr5");
    try reseedOrigin14(&h);
    try h.restart();
    try h.warmCache(.{ .focus = 5 });

    const mark = try spawnMark(ctx);
    try h.flipTo(5);
    try expectNoSpawn(ctx, .{ .mark = mark, .step = "flip to rewritten #5" });
    const app = h.app;
    const feat_idx = try fileIndex(&h, "feat_5.txt");
    const shared_idx = try fileIndex(&h, "shared.txt");
    const changed = app.state.flip.changed_files;
    if (changed.len != app.state.files.len) return ctx.fail("flip.changed_files has {d} entries for {d} files", .{ changed.len, app.state.files.len });
    if (!changed[feat_idx] or changed[shared_idx]) return ctx.fail("changed_files feat_5.txt={} shared.txt={}, expected true/false", .{ changed[feat_idx], changed[shared_idx] });

    const spec = try headOidOwned(ctx, 5);
    defer ctx.allocator.free(spec);
    const merge_base = try (try h.uiStore()).getMergeBase(h.repoId(), .{ .base_tip_oid = &seen.head_oid, .head_oid = spec }) orelse
        return ctx.fail("no .since_seen merge base for #5 after warm-up", .{});
    if (std.mem.eql(u8, &merge_base, &seen.head_oid)) return ctx.fail("merge base equals the seen head: the rewrite looks like a fast-forward", .{});

    try h.pressChar('c');
    const folds = &app.state.collapsed_folds;
    if (folds.count() != 1 or !folds.contains(root.line_map.LineMap.FoldKey.fileKey(shared_idx)))
        return ctx.fail("`c`: {d} folds, expected exactly shared.txt's file fold", .{folds.count()});
    try h.pressChar('c');
    if (folds.count() != 0) return ctx.fail("second `c` left {d} folds", .{folds.count()});
}

fn h4bFastForward(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const seen = try markSeenByDwell(&h, 14);

    try runFlipWorld(ctx, "ff-pr14");
    try reseedOrigin14(&h);
    try h.restart();
    // #14 is the boot row: previewed during the warm-up, the real-clock
    // dwell would mark it seen at its new head before `c` compares.
    if (!try sidebar_controller.selectNumber(h.sidebar(), ctx.allocator, 13)) return ctx.fail("selectNumber(#13) found no row", .{});
    try h.warmCache(.{ .focus = 14 });
    const head = try headOidOwned(ctx, 14);
    defer ctx.allocator.free(head);
    const db = try h.uiStore();
    const merge_base = try db.getMergeBase(h.repoId(), .{ .base_tip_oid = &seen.head_oid, .head_oid = head }) orelse
        return ctx.fail("no .since_seen merge base for #14 after warm-up", .{});
    if (!std.mem.eql(u8, &merge_base, &seen.head_oid)) return ctx.fail("merge base {s} != seen head {s}: not detected as a fast-forward", .{ merge_base[0..8], seen.head_oid[0..8] });
    if (!try db.hasDiff(h.repoId(), .{ .merge_base_oid = seen.head_oid, .head_oid = try oidArray(ctx, head) }))
        return ctx.fail("the worker did not cache the seen..head diff", .{});

    try h.flipTo(14);
    const still_seen = try db.getSeen(h.repoId(), 14) orelse return ctx.fail("#14's seen row vanished", .{});
    if (!std.mem.eql(u8, &still_seen.head_oid, &seen.head_oid)) return ctx.fail("#14 was re-marked seen at {s} before `c`", .{still_seen.head_oid[0..8]});
    const mark = try spawnMark(ctx);
    try h.pressChar('c');
    try expectNoSpawn(ctx, .{ .mark = mark, .step = "`c` on fast-forwarded #14" });
    const app = h.app;
    if (app.state.flip.previewed_view != .since_seen) return ctx.fail("previewed_view = {s}, expected since_seen", .{@tagName(app.state.flip.previewed_view)});
    try expectPaths(&h, .{ .label = "since seen", .expected = &.{"inc.txt"} });
    try expectTwoRefs(&h, .{ .ref1 = &seen.head_oid, .ref2 = head, .use_merge_base = false });

    try h.pressChar('c');
    if (app.state.flip.previewed_view != .pr) return ctx.fail("second `c`: previewed_view = {s}, expected pr", .{@tagName(app.state.flip.previewed_view)});
    try expectFiles(&h, .{ .label = "back to the PR view", .number = 14 });
}

fn h5SeenPin(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    {
        var h = try Harness.boot(ctx, .{ .sync = .network });
        defer h.deinit();
        const seen = try markSeenByDwell(&h, 5);
        const seen_key: DiffKey = .{ .merge_base_oid = seen.merge_base_oid, .head_oid = seen.head_oid };
        try runFlipWorld(ctx, "rewrite-pr5");
        try reseedOrigin14(&h);

        const db = try h.uiStore();
        _ = try db.evictDiffs(h.repoId(), 1);
        if (!try db.hasDiff(h.repoId(), seen_key)) return ctx.fail("the seen diff of #5 was evicted under a 1-byte budget", .{});
        const bytes = try db.getDiff(ctx.allocator, .{ .repo_id = h.repoId(), .key = seen_key, .now = skim_io.timestamp() }) orelse
            return ctx.fail("getDiff(seen key) returned null after hasDiff", .{});
        defer ctx.allocator.free(bytes);
        const size = try db.diffCacheSize(h.repoId());
        if (size != bytes.len) return ctx.fail("diff_cache holds {d} bytes after eviction, expected only the seen row ({d})", .{ size, bytes.len });

        h.deinit();
        h = try Harness.bootCold(ctx, .{ .sync = .network });
        try h.flipTo(5);
        try h.settle();
        const changed = h.app.state.flip.changed_files;
        const feat_idx = try fileIndex(&h, "feat_5.txt");
        const shared_idx = try fileIndex(&h, "shared.txt");
        if (changed.len != h.app.state.files.len) return ctx.fail("miss on #5: changed_files has {d} entries for {d} files (seen side not read from the pinned row)", .{ changed.len, h.app.state.files.len });
        if (!changed[feat_idx] or changed[shared_idx]) return ctx.fail("miss on #5: changed_files feat_5.txt={} shared.txt={}", .{ changed[feat_idx], changed[shared_idx] });
    }
    {
        var h = try Harness.boot(ctx, .{ .sync = .network });
        defer h.deinit();
        const head13 = try headOidOwned(ctx, 13);
        defer ctx.allocator.free(head13);
        try (try h.uiStore()).setSeen(.{ .repo_id = h.repoId(), .number = 13, .head_oid = head13, .merge_base_oid = &pr_surface.unknown_merge_base, .now = skim_io.timestamp() });
        try h.restart();
        try h.warmCache(.{ .focus = 13 });
        const db = try h.uiStore();
        const row = try db.getSeen(h.repoId(), 13) orelse return ctx.fail("sentinel seen row for #13 disappeared", .{});
        const key13 = try h.diffKeyFor(13);
        if (!std.mem.eql(u8, &row.merge_base_oid, &key13.merge_base_oid))
            return ctx.fail("seen merge base for #13 is {s}, expected the backfilled {s}", .{ row.merge_base_oid[0..8], key13.merge_base_oid[0..8] });
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Run one scenario under its own leak-checking allocator and print its line.
fn runScenario(params: struct { scenario: Scenario, env: Env, out: *Writer }) !bool {
    const scenario = params.scenario;
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var ctx: Ctx = .{ .allocator = debug_allocator.allocator(), .env = params.env, .id = scenario.id };
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
        .git_trace = try requireEnv("GIT_TRACE"),
        .fixtures = try requireEnv("FAKE_GH_FIXTURES"),
        .flip_world = try requireEnv("SKIM_HARNESS_FLIP_WORLD"),
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
    try upsertSpecs(.{ .arena = arena, .store = &store, .repo_id = repo_id, .specs = specs });
}

/// Index + hydrate rows for `specs`: what a sync that saw them would write.
fn upsertSpecs(params: struct { arena: Allocator, store: *Store, repo_id: i64, specs: []const PrSpec }) !void {
    const arena = params.arena;
    const specs = params.specs;
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
    try params.store.upsertIndex(params.repo_id, index_rows);
    try params.store.applyHydrate(params.repo_id, hydrate_rows);
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

/// Rows from the review fixture targets.tsv (`number head_ref base_ref head_oid
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
    if (specs.items.len < 14) return error.BadTargets;
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

/// Press F until `ready` (configured preset 0) is active again. F walks the
/// menu's list: the configured presets, then the built-ins they do not
/// duplicate, so from `mine` it takes five presses.
fn cycleToReady(ctx: *Ctx, h: *Harness) !void {
    const sb = h.sidebar();
    for (0..8) |_| {
        try h.pressChar('F');
        if (sb.active_preset == 0) return;
    }
    return ctx.fail("F never wrapped back to `ready` (active_preset = {?d})", .{sb.active_preset});
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

// --- Flip helpers ---------------------------------------------------------

/// Snapshot both subprocess logs and open an exec-audit window.
fn spawnMark(ctx: *Ctx) !SpawnMark {
    ctx.mark_seq += 1;
    touchExecMarker(ctx, .{ .seq = ctx.mark_seq, .edge = "begin" });
    return .{
        .git = try fileSizeOrZero(ctx.env.git_trace),
        .gh = try fileSizeOrZero(ctx.env.gh_log),
        .seq = ctx.mark_seq,
    };
}

/// Close the exec-audit window; FAIL when either log grew since `mark`.
fn expectNoSpawn(ctx: *Ctx, params: struct { mark: SpawnMark, step: []const u8 }) !void {
    touchExecMarker(ctx, .{ .seq = params.mark.seq, .edge = "end" });
    const git = try fileSizeOrZero(ctx.env.git_trace);
    const gh = try fileSizeOrZero(ctx.env.gh_log);
    if (git != params.mark.git or gh != params.mark.gh)
        return ctx.fail("{s}: spawned a subprocess (git-trace.log +{d} bytes, gh.log +{d} bytes)", .{ params.step, git -| params.mark.git, gh -| params.mark.gh });
}

/// `access()` on a path that never exists: strace logs it with the path, so
/// the audit can bracket the window. The result is irrelevant.
fn touchExecMarker(ctx: *Ctx, params: struct { seq: u32, edge: []const u8 }) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/exec-marks/{s}-{d}-{s}", .{ ctx.env.work, ctx.id, params.seq, params.edge }) catch return;
    _ = fileExists(path);
}

fn fileSizeOrZero(path: []const u8) !u64 {
    return fileSize(path) catch |err| switch (err) {
        error.FileNotFound => 0,
        else => err,
    };
}

/// Lines appended to `path` after byte `offset`.
fn countLinesSince(ctx: *Ctx, params: struct { path: []const u8, offset: u64 }) !usize {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(skim_io.get(), params.path, ctx.allocator, .limited(16 << 20));
    defer ctx.allocator.free(bytes);
    if (params.offset > bytes.len) return 0;
    return std.mem.count(u8, bytes[@intCast(params.offset)..], "\n");
}

/// Wait until a line containing `needle` lands after `offset` (the review
/// fake logs before it sleeps, so this means "the call is in flight").
fn waitLogLine(ctx: *Ctx, params: struct { path: []const u8, offset: u64, needle: []const u8 }) !void {
    var timer = try skim_io.Timer.start();
    while (timer.read() < settle_deadline_ns) {
        if (try fileSizeOrZero(params.path) > params.offset and
            try logHasSince(ctx, .{ .path = params.path, .offset = params.offset, .needle = params.needle })) return;
        skim_io.sleep(poll_interval_ns);
    }
    return ctx.fail("no '{s}' line in {s} within {d}s", .{ params.needle, params.path, settle_deadline_ns / std.time.ns_per_s });
}

fn targetsVersion(worker: *root.prefetch.PrefetchWorker) u64 {
    worker.targets_mutex.lockUncancelable(skim_io.get());
    defer worker.targets_mutex.unlock(skim_io.get());
    return worker.targets_version;
}

/// `bash flip-world.sh <op>`; the script finds the world via SKIM_HARNESS_WORK.
fn runFlipWorld(ctx: *Ctx, op: []const u8) !void {
    const result = try std.process.run(ctx.allocator, skim_io.get(), .{ .argv = &.{ "bash", ctx.env.flip_world, op } });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return ctx.fail("flip-world.sh {s} failed: {s}", .{ op, result.stderr[0..@min(result.stderr.len, 200)] });
}

/// Re-apply targets.tsv to the App's DB without resetting it (what a sync
/// after a push would write). Seen rows, notes and caches stay.
fn reseedOrigin14(h: *Harness) !void {
    var arena_state = std.heap.ArenaAllocator.init(h.ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try upsertSpecs(.{ .arena = arena, .store = try h.uiStore(), .repo_id = h.repoId(), .specs = try origin14Specs(arena, h.ctx.env) });
}

fn specFor(ctx: *Ctx, params: struct { arena: Allocator, number: u32 }) !PrSpec {
    for (try origin14Specs(params.arena, ctx.env)) |spec| {
        if (spec.number == params.number) return spec;
    }
    return ctx.fail("#{d} is not in targets.tsv", .{params.number});
}

/// PR `number`'s current head oid from targets.tsv. Caller frees.
fn headOidOwned(ctx: *Ctx, number: u32) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const spec = try specFor(ctx, .{ .arena = arena_state.allocator(), .number = number });
    return ctx.allocator.dupe(u8, spec.head_oid);
}

fn oidArray(ctx: *Ctx, oid: []const u8) ![40]u8 {
    if (oid.len != 40) return ctx.fail("oid '{s}' is not 40 chars", .{oid});
    return oid[0..40].*;
}

fn recordFor(h: *Harness, number: u32) !*const types.PrRecord {
    const records = h.sidebar().records orelse return h.ctx.fail("sidebar has no records", .{});
    for (records.items) |*record| {
        if (record.number == number) return record;
    }
    return h.ctx.fail("#{d} is not in the sidebar records", .{number});
}

/// Warm with focus on `number`, preview it and dwell 3s: the App writes the
/// seen row. Returns it after checking it is at the current head with a
/// resolved merge base. Leaves the virtual clock ahead: restart next.
fn h7FailedMissNotSeen(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.bootCold(ctx, .{ .sync = .network });
    defer h.deinit();
    try h.settle();
    const db = try h.uiStore();
    try db.db.exec("UPDATE pr SET base_ref = '-evil' WHERE number = 12");
    try pr_surface.reload(&h.app.state.pr_surface, .{ .allocator = h.app.allocator, .sidebar = h.sidebar() });
    if (!std.mem.eql(u8, (try recordFor(&h, 12)).base_ref, "-evil")) return ctx.fail("setup: #12's base_ref is not '-evil'", .{});

    try h.flipTo(12);
    try h.settle();
    if (h.app.state.flip.previewed != 12) return ctx.fail("previewed #{?d} after the failed load, expected 12", .{h.app.state.flip.previewed});
    if (h.app.state.files.len != 0) return ctx.fail("{d} files loaded for a diff against origin/-evil", .{h.app.state.files.len});
    h.dwell();
    if (try db.getSeen(h.repoId(), 12)) |row| return ctx.fail("#12 marked seen at {s} after a failed load", .{row.head_oid[0..8]});
}

fn h8EditorDefersFlip(ctx: *Ctx) !void {
    try seed(ctx, .{ .fixture = .origin14 });
    var h = try Harness.boot(ctx, .{ .sync = .network });
    defer h.deinit();
    const app = h.app;
    try h.warmCache(.{ .focus = 9 });
    try h.settle();
    try h.flipTo(9);
    try h.settle();
    if (app.state.flip.previewed != 9) return ctx.fail("setup: #9 not previewed", .{});
    app.mode = .normal;
    app.state.global_cursor_line = (try firstAddLine(&h, 0)).global_line;
    try root.comment_controller.CommentController.startCommentInput(app);
    if (app.state.active_comment_input == null) return ctx.fail("setup: no comment editor opened on #9", .{});

    try h.flipTo(10);
    if (app.state.flip.previewed != 9) return ctx.fail("previewed #{?d} with the editor open, expected 9", .{app.state.flip.previewed});
    if (app.state.flip.loading_number != null) return ctx.fail("a miss for #{?d} started with the editor open", .{app.state.flip.loading_number});
    if (app.state.flip.pending == null) return ctx.fail("the deferred preview was dropped", .{});
    if (!try sidebar_controller.selectNumber(h.sidebar(), ctx.allocator, 11)) return ctx.fail("selectNumber(#11) found no row", .{});
    h.tick();

    try h.pressCtrl('w');
    if (app.state.active_comment_input != null) return ctx.fail("Ctrl-w did not close the editor", .{});
    h.advance(flip.debounce_ms + 1);
    h.tick();
    try h.settle();
    if (app.state.flip.previewed != 11) return ctx.fail("after the editor closed: previewed #{?d}, expected the cursor's #11", .{app.state.flip.previewed});
    try expectFiles(&h, .{ .label = "deferred flip", .number = 11 });
}

/// Poll the review entry alone until the superseded one in flight is
/// dropped, then require that drop to have requested a render: the status
/// line's 'refreshing…' depends on it.
fn awaitSupersededDrop(h: *Harness) !void {
    const app = h.app;
    const review = &app.state.review;
    if (!(review.entry_in_flight and review.entry.generation != review.generation))
        return h.ctx.fail("superseded entry already dropped before the check", .{});
    var timer = try skim_io.Timer.start();
    while (review.entry_in_flight and review.entry.generation != review.generation) {
        if (timer.read() >= settle_deadline_ns) return h.ctx.fail("superseded entry still in flight after {d}s", .{settle_deadline_ns / std.time.ns_per_s});
        skim_io.sleep(poll_interval_ns);
        app.needs_render = false;
        app.pollReviewEntry();
    }
    if (!app.needs_render) return h.ctx.fail("dropping the superseded entry did not request a render", .{});
}

fn markSeenByDwell(h: *Harness, number: u32) !root.store.SeenRow {
    const ctx = h.ctx;
    try h.warmCache(.{ .focus = number });
    // The boot preview may be this very row, loaded before the cache was
    // warm: flip away and back so the dwell runs on a settled cache hit.
    try h.settle();
    try h.flipTo(if (number == 13) 12 else 13);
    try h.settle();
    try h.flipTo(number);
    try h.settle();
    const state = &h.app.state.flip;
    if (state.previewed != number or state.loading_number != null or state.displayed_key == null)
        return ctx.fail("setup: #{d} not previewed from the cache after warm-up (previewed #{?d}, loading #{?d})", .{ number, state.previewed, state.loading_number });
    h.app.needs_render = false;
    h.dwell();
    // The Δ markers clear on this tick; without a render they stay until a key.
    if (!h.app.needs_render) return ctx.fail("the dwell marked #{d} seen without requesting a render", .{number});
    const row = try (try h.uiStore()).getSeen(h.repoId(), number) orelse return ctx.fail("no seen row for #{d} after a 3s dwell", .{number});
    const head = try headOidOwned(ctx, number);
    defer ctx.allocator.free(head);
    if (!std.mem.eql(u8, &row.head_oid, head)) return ctx.fail("seen head for #{d} is {s}, expected {s}", .{ number, row.head_oid[0..8], head[0..8] });
    if (std.mem.eql(u8, &row.merge_base_oid, &pr_surface.unknown_merge_base)) return ctx.fail("seen row for #{d} kept the sentinel merge base after warm-up", .{number});
    return row;
}

/// Path a file is shown under (new path; old path for a deletion).
fn diffPath(file: FileDiff) []const u8 {
    if (file.new_path.len == 0 or std.mem.eql(u8, file.new_path, "/dev/null")) return file.old_path;
    return file.new_path;
}

fn fileIndex(h: *Harness, path: []const u8) !usize {
    for (h.app.state.files, 0..) |file, i| {
        if (std.mem.eql(u8, diffPath(file), path)) return i;
    }
    return h.ctx.fail("{s} is not in the installed diff ({d} files)", .{ path, h.app.state.files.len });
}

/// `app.state.files` paths equal `$WORK/files-<number>.txt` (git's order).
fn expectFiles(h: *Harness, params: struct { label: []const u8, number: u32 }) !void {
    const ctx = h.ctx;
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/files-{d}.txt", .{ ctx.env.work, params.number });
    defer ctx.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, ctx.allocator, .limited(1 << 20));
    defer ctx.allocator.free(bytes);
    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(ctx.allocator);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| try expected.append(ctx.allocator, line);
    try expectPaths(h, .{ .label = params.label, .expected = expected.items });
}

fn expectPaths(h: *Harness, params: struct { label: []const u8, expected: []const []const u8 }) !void {
    const files = h.app.state.files;
    var matches = files.len == params.expected.len;
    for (files, 0..) |file, i| {
        if (i < params.expected.len and !std.mem.eql(u8, diffPath(file), params.expected[i])) matches = false;
    }
    if (matches) return;
    var shown: [256]u8 = undefined;
    var writer: Writer = .fixed(&shown);
    for (files) |file| writer.print("{s} ", .{diffPath(file)}) catch break;
    return h.ctx.fail("{s}: installed files [{s}], expected {d}: {s}", .{ params.label, writer.buffered(), params.expected.len, if (params.expected.len > 0) params.expected[0] else "" });
}

fn expectTwoRefs(h: *Harness, params: struct { ref1: []const u8, ref2: []const u8, use_merge_base: bool }) !void {
    switch (h.app.state.diff_source) {
        .two_refs => |refs| {
            if (!std.mem.eql(u8, refs.ref1, params.ref1) or !std.mem.eql(u8, refs.ref2, params.ref2) or refs.use_merge_base != params.use_merge_base)
                return h.ctx.fail("diff_source two_refs{{{s}, {s}, {}}}, expected {{{s}, {s}, {}}}", .{ refs.ref1, refs.ref2, refs.use_merge_base, params.ref1, params.ref2, params.use_merge_base });
        },
        else => return h.ctx.fail("diff_source is {s}, expected two_refs", .{@tagName(h.app.state.diff_source)}),
    }
}

const LinePosition = struct { global_line: usize, new_lineno: ?u32 };

/// The first `+` line of file `file_idx` in the LineMap.
fn firstAddLine(h: *Harness, file_idx: usize) !LinePosition {
    const file = h.app.state.files[file_idx];
    for (h.app.state.line_map.records) |record| {
        if (record.file_idx != file_idx) continue;
        switch (record.line_type) {
            .code_line => |code| {
                const line = file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk];
                if (line.line_type == .add) return .{ .global_line = record.global_line, .new_lineno = line.new_lineno };
            },
            else => {},
        }
    }
    return h.ctx.fail("{s} has no added line in the LineMap", .{diffPath(file)});
}

/// File path and new line number under the diff cursor.
fn cursorLine(h: *Harness) !struct { path: []const u8, new_lineno: ?u32 } {
    const record = h.app.state.line_map.getLineRecord(h.app.state.global_cursor_line) orelse
        return h.ctx.fail("cursor line {d} has no LineMap record", .{h.app.state.global_cursor_line});
    const file = h.app.state.files[record.file_idx];
    return switch (record.line_type) {
        .code_line => |code| .{ .path = diffPath(file), .new_lineno = file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk].new_lineno },
        else => h.ctx.fail("cursor line {d} is a {s}, not a code line", .{ h.app.state.global_cursor_line, @tagName(record.line_type) }),
    };
}

const AddedNote = struct {
    new_lineno: ?u32,
    /// Owned by ctx.allocator.
    line_content: []u8,
};

/// A local comment on the first `+` line of the first file, added the way
/// `saveCurrentComment` adds one.
fn addNote(h: *Harness, text: []const u8) !AddedNote {
    const app = h.app;
    if (app.state.files.len == 0) return h.ctx.fail("addNote: no diff installed", .{});
    const file = app.state.files[0];
    for (file.hunks, 0..) |hunk, hunk_idx| {
        for (hunk.lines, 0..) |line, line_idx| {
            if (line.line_type != .add) continue;
            _ = try app.state.comment_store.add(.{
                .file_path = diffPath(file),
                .hunk_idx = hunk_idx,
                .line_idx = line_idx,
                .text = text,
                .line_type = .add,
                .line_content = line.content,
                .old_lineno = line.old_lineno,
                .new_lineno = line.new_lineno,
            });
            return .{ .new_lineno = line.new_lineno, .line_content = try h.ctx.allocator.dupe(u8, line.content) };
        }
    }
    return h.ctx.fail("addNote: {s} has no added line", .{diffPath(file)});
}

fn expectOnlyNote(h: *Harness, params: struct { label: []const u8, text: []const u8, new_lineno: ?u32 }) !void {
    const items = h.app.state.comment_store.comments.items;
    if (items.len != 1) return h.ctx.fail("{s}: {d} comments, expected only {s}", .{ params.label, items.len, params.text });
    if (!std.mem.eql(u8, items[0].text, params.text)) return h.ctx.fail("{s}: comment '{s}', expected {s}", .{ params.label, items[0].text, params.text });
    if (items[0].new_lineno != params.new_lineno) return h.ctx.fail("{s}: {s} anchored at line {?d}, expected {?d}", .{ params.label, params.text, items[0].new_lineno, params.new_lineno });
}

fn expectNoteRow(h: *Harness, params: struct { number: u32, text: []const u8, line_content: []const u8 }) !void {
    var rows = try (try h.uiStore()).listNotes(h.ctx.allocator, .{ .repo_id = h.repoId(), .number = params.number });
    defer rows.deinit();
    if (rows.items.len != 1) return h.ctx.fail("#{d}: {d} local_note rows, expected 1", .{ params.number, rows.items.len });
    const row = rows.items[0];
    if (!std.mem.eql(u8, row.text, params.text) or !std.mem.eql(u8, row.line_content, params.line_content))
        return h.ctx.fail("#{d}: note row '{s}' on '{s}', expected '{s}' on '{s}'", .{ params.number, row.text, row.line_content, params.text, params.line_content });
}
