//! Offline harness executable for the prefetch worker (Phase 5). Driven by
//! scripts/test-infra/pr-sidebar/prefetch/run-harness.sh: each subcommand does
//! one thing against a temp SQLite DB and prints tab-separated lines to
//! stdout. Errors go to stderr with exit 1; `run` exits 2 on timeout.
//! Build with `zig build harness-prefetch` (installs zig-out/bin/harness_prefetch).

const std = @import("std");
const skim_io = @import("skim_io");
const store_mod = @import("pr/db/store.zig");
const review_parse = @import("pr/review_parse.zig");
const prefetch = @import("pr/prefetch/prefetch.zig");
const priority = @import("pr/prefetch/priority.zig");

const Store = store_mod.Store;
const PrRecord = store_mod.PrRecord;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// One `targets.tsv` row: `number head_ref base_ref head_oid base_oid
/// updated_at parent_number` (parent_number 0 = based on trunk).
const TargetRow = struct {
    number: u32,
    head_ref: []const u8,
    base_ref: []const u8,
    head_oid: []const u8,
    base_oid: []const u8,
    updated_at: []const u8,
    parent_number: u32,
};

/// Stack shape of one TSV row, as indices into the same row slice. This is
/// what `priority.targetFor` takes as `parent`/`bottom`/`is_tip`.
const StackLinks = struct {
    parent: ?usize = null,
    bottom: ?usize = null,
    is_tip: bool = false,
};

/// The flags after the subcommand: `--name value` pairs, plus the bare
/// switches in `boolean_flags`. A repeated flag's last occurrence wins, so a
/// scenario can append an override to a shared argument list.
const Flags = struct {
    items: []const [:0]const u8,

    fn get(self: Flags, name: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        var i: usize = 0;
        while (i < self.items.len) {
            if (isBooleanFlag(self.items[i])) {
                i += 1;
                continue;
            }
            if (i + 1 < self.items.len and std.mem.eql(u8, self.items[i], name)) found = self.items[i + 1];
            i += 2;
        }
        return found;
    }

    /// Every value given for `name`, in order.
    fn all(self: Flags, arena: Allocator, name: []const u8) ![]const []const u8 {
        var found: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < self.items.len) {
            if (isBooleanFlag(self.items[i])) {
                i += 1;
                continue;
            }
            if (i + 1 < self.items.len and std.mem.eql(u8, self.items[i], name)) try found.append(arena, self.items[i + 1]);
            i += 2;
        }
        return found.items;
    }

    fn has(self: Flags, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.items.len) {
            if (!isBooleanFlag(self.items[i])) {
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, self.items[i], name)) return true;
            i += 1;
        }
        return false;
    }

    fn require(self: Flags, name: []const u8) ![]const u8 {
        return self.get(name) orelse {
            std.debug.print("missing required flag {s}\n", .{name});
            return error.MissingFlag;
        };
    }

    fn int(self: Flags, comptime T: type, name: []const u8) !T {
        return parseIntFlag(T, .{ .name = name, .text = try self.require(name) });
    }

    fn intOr(self: Flags, comptime T: type, params: struct { name: []const u8, default: T }) !T {
        const text = self.get(params.name) orelse return params.default;
        return parseIntFlag(T, .{ .name = params.name, .text = text });
    }
};

const Command = struct {
    name: []const u8,
    run: *const fn (ctx: *Ctx) anyerror!u8,
};

const Ctx = struct {
    arena: Allocator,
    flags: Flags,
    out: *Writer,
};

/// Flags that take no value.
const boolean_flags = [_][]const u8{ "--no-threads", "--wipe-diffs" };
const exit_timeout: u8 = 2;
/// Status poll interval while `run` waits for the worker to settle.
const poll_interval_ns = 10 * std.time.ns_per_ms;

const usage =
    \\usage: harness_prefetch <command> [--flag value ...]
    \\
    \\  seed         --db D --repo-key K --owner O --name N --targets T.tsv
    \\  pin          --db D --repo-id R --number N --head H --merge-base M
    \\  put-diff     --db D --repo-id R --merge-base M --head H --file F --now T
    \\  run          --db D --repo-id R --repo-root P --owner O --name N --targets T.tsv
    \\               [--focus N] [--then-focus N]... [--budget BYTES] [--timeout-ms 30000]
    \\               [--gh-bin PATH] [--git-bin PATH] [--git-timeout-ms MS] [--keep-nearest N]
    \\               [--no-threads] [--wipe-diffs] [--stop-after-ms MS]
    \\  dump-diffs   --db D --repo-id R
    \\  dump-diff    --db D --repo-id R --merge-base M --head H
    \\  dump-key     --db D --repo-id R --base-tip B --head H
    \\  dump-threads --db D --repo-id R
    \\  plan-targets --db D --repo-id R --targets T.tsv
    \\  check-review --file F
    \\
;

const commands = [_]Command{
    .{ .name = "seed", .run = cmdSeed },
    .{ .name = "pin", .run = cmdPin },
    .{ .name = "put-diff", .run = cmdPutDiff },
    .{ .name = "run", .run = cmdRun },
    .{ .name = "dump-diffs", .run = cmdDumpDiffs },
    .{ .name = "dump-diff", .run = cmdDumpDiff },
    .{ .name = "dump-key", .run = cmdDumpKey },
    .{ .name = "dump-threads", .run = cmdDumpThreads },
    .{ .name = "plan-targets", .run = cmdPlanTargets },
    .{ .name = "check-review", .run = cmdCheckReview },
};

/// std.log goes to stderr (the default handler). H4 asserts the worker's
/// rejection of an invalid base name shows up there, so warn must be on.
pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(process_init: std.process.Init) !u8 {
    skim_io.init(process_init);
    const arena = process_init.arena.allocator();
    const argv = try process_init.minimal.args.toSlice(arena);
    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        return 1;
    }

    var out_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(skim_io.get(), &out_buffer);
    var ctx: Ctx = .{ .arena = arena, .flags = .{ .items = argv[2..] }, .out = &file_writer.interface };

    for (commands) |command| {
        if (!std.mem.eql(u8, command.name, argv[1])) continue;
        const code = command.run(&ctx) catch |err| {
            ctx.out.flush() catch {};
            std.debug.print("harness_prefetch {s}: {any}\n", .{ command.name, err });
            return 1;
        };
        try ctx.out.flush();
        return code;
    }
    std.debug.print("unknown command '{s}'\n{s}", .{ argv[1], usage });
    return 1;
}

// =============================================================================
// Commands
// =============================================================================

/// Upsert every TSV row as an OPEN `pr` row; prints the repo id. Idempotent:
/// re-run after editing the TSV to move the DB to the new heads.
fn cmdSeed(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    const repo_id = try store.ensureRepo(.{
        .key = try ctx.flags.require("--repo-key"),
        .owner = try ctx.flags.require("--owner"),
        .name = try ctx.flags.require("--name"),
    });

    const rows = try readTargets(ctx.arena, try ctx.flags.require("--targets"));
    const index_rows = try ctx.arena.alloc(store_mod.IndexRow, rows.len);
    for (rows, index_rows) |row, *index_row| {
        index_row.* = .{
            .number = row.number,
            .node_id = try std.fmt.allocPrint(ctx.arena, "PR_{d}", .{row.number}),
            .title = try std.fmt.allocPrint(ctx.arena, "PR {d}", .{row.number}),
            .author = "alice",
            .url = try std.fmt.allocPrint(ctx.arena, "https://github.com/fake/prefetch/pull/{d}", .{row.number}),
            .is_draft = false,
            .head_ref = row.head_ref,
            .base_ref = row.base_ref,
            .head_oid = row.head_oid,
            .base_oid = row.base_oid,
            .updated_at = row.updated_at,
            .labels = "",
        };
    }
    try store.upsertIndex(repo_id, index_rows);
    try ctx.out.print("{d}\n", .{repo_id});
    return 0;
}

/// Mark a PR seen at a DiffKey, which pins that diff_cache row for eviction.
fn cmdPin(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    try store.setSeen(.{
        .repo_id = try ctx.flags.int(i64, "--repo-id"),
        .number = try ctx.flags.int(u32, "--number"),
        .head_oid = try requireOid(ctx.flags, "--head"),
        .merge_base_oid = try requireOid(ctx.flags, "--merge-base"),
        .now = skim_io.timestamp(),
    });
    return 0;
}

/// Write an arbitrary diff_cache row (simulates a stale row from an earlier run).
fn cmdPutDiff(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    const bytes = try readFile(ctx.arena, try ctx.flags.require("--file"));
    try store.putDiff(.{
        .repo_id = try ctx.flags.int(i64, "--repo-id"),
        .key = try requireKey(ctx.flags),
        .bytes = bytes,
        .now = try ctx.flags.int(i64, "--now"),
    });
    return 0;
}

/// Run the real PrefetchWorker over the TSV targets until it reports idle for
/// the version it was given, then stop it and print its status. With
/// `--then-focus N` the first settle is printed as an `initial` line, the
/// cursor moves to N within the same targets version, and `status` is the
/// settle after that move. `--then-focus` repeats: the worker settles at
/// each focus in turn, and every settle but the last is printed as a
/// `focus-<N>` line. `--wipe-diffs` deletes every diff_cache row of the repo
/// through the harness's own connection after the first settle, as another
/// skim process sharing the DB could.
fn cmdRun(ctx: *Ctx) !u8 {
    const repo_id = try ctx.flags.int(i64, "--repo-id");
    const db_path = try absoluteFlag(ctx, "--db");
    const repo_root = try absoluteFlag(ctx, "--repo-root");
    const owner = try ctx.flags.require("--owner");
    const name = try ctx.flags.require("--name");
    const focus = try ctx.flags.intOr(u32, .{ .name = "--focus", .default = 0 });
    const then_foci = try ctx.flags.all(ctx.arena, "--then-focus");
    const budget = try ctx.flags.intOr(u64, .{ .name = "--budget", .default = 500 * 1024 * 1024 });
    const timeout_ms = try ctx.flags.intOr(u64, .{ .name = "--timeout-ms", .default = 30_000 });
    const gh_bin = ctx.flags.get("--gh-bin") orelse "gh";
    const git_bin = ctx.flags.get("--git-bin") orelse "git";
    const child_timeout_ms = try ctx.flags.intOr(u64, .{ .name = "--git-timeout-ms", .default = prefetch.default_child_timeout_ns / std.time.ns_per_ms });
    const keep_nearest = try ctx.flags.intOr(usize, .{ .name = "--keep-nearest", .default = priority.thread_window });

    var store = try Store.open(ctx.arena, db_path);
    defer store.close();
    var plan = try loadTargetPlan(ctx.arena, .{ .store = &store, .repo_id = repo_id, .targets_path = try ctx.flags.require("--targets") });
    defer plan.records.deinit();

    const targets = try ctx.arena.alloc(priority.Target, plan.rows.len);
    for (plan.links, targets, 0..) |links, *target, i| target.* = priority.targetFor(.{
        .rec = plan.record(i),
        .parent = if (links.parent) |p| plan.record(p) else null,
        .bottom = if (links.bottom) |b| plan.record(b) else null,
        .is_tip = links.is_tip,
    });

    // The worker allocates from its own thread; the process arena is not thread-safe.
    var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    const worker = try prefetch.start(debug_allocator.allocator(), .{
        .repo_root = repo_root,
        .db_path = db_path,
        .repo_id = repo_id,
        .owner = owner,
        .name = name,
        .budget_bytes = budget,
        .keep_nearest = keep_nearest,
        .gh_bin = gh_bin,
        .git_bin = git_bin,
        .threads_enabled = !ctx.flags.has("--no-threads"),
        .child_timeout_ns = child_timeout_ms * std.time.ns_per_ms,
    });
    // Focus first so the worker's first look at the new targets already orders by it.
    worker.setFocus(focus);
    const version = try worker.setTargets(targets);
    if (ctx.flags.get("--stop-after-ms") != null) {
        return stopMidRun(ctx, worker, try ctx.flags.int(u64, "--stop-after-ms"));
    }

    var status = (try waitForSettled(worker, .{ .version = version, .timeout_ms = timeout_ms })) orelse {
        worker.stop();
        std.debug.print("harness_prefetch run: worker did not go idle within {d}ms\n", .{timeout_ms});
        return exit_timeout;
    };
    if (ctx.flags.has("--wipe-diffs")) {
        var wipe = try store.db.prepare("DELETE FROM diff_cache WHERE repo_id = ?");
        defer wipe.finalize();
        try wipe.bind(1, repo_id);
        _ = try wipe.step();
    }
    for (then_foci, 0..) |text, i| {
        const label = if (i == 0) "initial" else try std.fmt.allocPrint(ctx.arena, "focus-{d}", .{status.focus});
        try printStatus(ctx, .{ .label = label, .status = status });
        const next_focus = try parseIntFlag(u32, .{ .name = "--then-focus", .text = text });
        worker.setFocus(next_focus);
        status = (try waitForSettled(worker, .{ .version = version, .focus = next_focus, .timeout_ms = timeout_ms })) orelse {
            worker.stop();
            std.debug.print("harness_prefetch run: worker did not go idle on focus {d} within {d}ms\n", .{ next_focus, timeout_ms });
            return exit_timeout;
        };
    }
    const generation = worker.generation();
    worker.stop();

    try printStatus(ctx, .{ .label = "status", .status = status });
    try ctx.out.print("generation\t{d}\n", .{generation});

    if (debug_allocator.deinit() == .leak) {
        std.debug.print("harness_prefetch run: worker leaked memory\n", .{});
        return 1;
    }
    return 0;
}

/// `--stop-after-ms`: let the worker run that long (into a git or gh child
/// that hangs), then stop it and print `stopped <ms stop took>`. A stop that
/// gives up on the thread leaves it freeing itself through the allocator, so
/// there is no leak check here.
fn stopMidRun(ctx: *Ctx, worker: *prefetch.PrefetchWorker, stop_after_ms: u64) !u8 {
    skim_io.sleep(stop_after_ms * std.time.ns_per_ms);
    var timer = try skim_io.Timer.start();
    worker.stop();
    try ctx.out.print("stopped\t{d}\n", .{timer.read() / std.time.ns_per_ms});
    return 0;
}

/// `merge_base_oid head_oid size last_used_at sha256(bytes)` per row, insertion order.
fn cmdDumpDiffs(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    var stmt = try store.db.prepare(
        "SELECT merge_base_oid, head_oid, size, last_used_at, bytes FROM diff_cache WHERE repo_id = ? ORDER BY rowid",
    );
    defer stmt.finalize();
    try stmt.bind(1, try ctx.flags.int(i64, "--repo-id"));
    while (try stmt.step()) {
        try ctx.out.print("{s}\t{s}\t{d}\t{d}\t{s}\n", .{
            try stmt.columnText(0),
            try stmt.columnText(1),
            stmt.columnInt(2),
            stmt.columnInt(3),
            &sha256Hex(stmt.columnBlob(4)),
        });
    }
    return 0;
}

/// Raw cached bytes for one key; exit 1 when there is no row. Reads with a
/// plain SELECT rather than `Store.getDiff` so dumping never bumps
/// last_used_at (that would reorder the LRU that H6 tests).
fn cmdDumpDiff(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    const key = try requireKey(ctx.flags);
    var stmt = try store.db.prepare(
        "SELECT bytes FROM diff_cache WHERE repo_id = ? AND merge_base_oid = ? AND head_oid = ?",
    );
    defer stmt.finalize();
    try stmt.bindAll(.{ try ctx.flags.int(i64, "--repo-id"), &key.merge_base_oid, &key.head_oid });
    if (!try stmt.step()) {
        std.debug.print("no diff_cache row for {s} {s}\n", .{ &key.merge_base_oid, &key.head_oid });
        return 1;
    }
    try ctx.out.writeAll(stmt.columnBlob(0));
    return 0;
}

/// merge_base_cache lookup: the merge base oid, or `none`.
fn cmdDumpKey(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    const merge_base = try store.getMergeBase(try ctx.flags.int(i64, "--repo-id"), .{
        .base_tip_oid = try ctx.flags.require("--base-tip"),
        .head_oid = try ctx.flags.require("--head"),
    });
    if (merge_base) |oid| {
        try ctx.out.print("{s}\n", .{&oid});
    } else {
        try ctx.out.writeAll("none\n");
    }
    return 0;
}

/// `number pr_updated_at fetched_at sha256(json)` per thread_cache row, by number.
fn cmdDumpThreads(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    var stmt = try store.db.prepare(
        "SELECT number, pr_updated_at, fetched_at, json FROM thread_cache WHERE repo_id = ? ORDER BY number",
    );
    defer stmt.finalize();
    try stmt.bind(1, try ctx.flags.int(i64, "--repo-id"));
    while (try stmt.step()) {
        try ctx.out.print("{d}\t{s}\t{d}\t{s}\n", .{
            stmt.columnInt(0),
            try stmt.columnText(1),
            stmt.columnInt(2),
            &sha256Hex(stmt.columnBlob(3)),
        });
    }
    return 0;
}

/// What `run` will hand to `priority.targetFor`, one line per TSV row:
/// `number parent bottom is_tip base_tip_oid` (0 = none; base_tip_oid is the
/// parent's head for stacked rows, else base_oid, `-` when blank). Lets the
/// scripts compute expected keys without re-deriving stacks in bash.
fn cmdPlanTargets(ctx: *Ctx) !u8 {
    var store = try openStore(ctx);
    defer store.close();
    var plan = try loadTargetPlan(ctx.arena, .{
        .store = &store,
        .repo_id = try ctx.flags.int(i64, "--repo-id"),
        .targets_path = try ctx.flags.require("--targets"),
    });
    defer plan.records.deinit();

    for (plan.rows, plan.links, 0..) |row, links, i| {
        const rec = plan.record(i);
        const base_tip = if (links.parent) |p| plan.record(p).head_oid else rec.base_oid;
        try ctx.out.print("{d}\t{d}\t{d}\t{d}\t{s}\n", .{
            row.number,
            if (links.parent) |p| plan.rows[p].number else 0,
            if (links.bottom) |b| plan.rows[b].number else 0,
            @intFromBool(links.is_tip),
            if (base_tip.len == 0) "-" else base_tip,
        });
    }
    return 0;
}

/// Validate a fixture payload with the same parser the worker uses before
/// it writes thread_cache.
fn cmdCheckReview(ctx: *Ctx) !u8 {
    const bytes = try readFile(ctx.arena, try ctx.flags.require("--file"));
    var data = try review_parse.parsePrDetails(ctx.arena, bytes);
    defer data.deinit();
    try ctx.out.print("ok\t{d} threads\n", .{data.details.threads.len});
    return 0;
}

// =============================================================================
// Helpers
// =============================================================================

/// TSV rows joined with their DB records and stack links, in display order.
const TargetPlan = struct {
    rows: []TargetRow,
    links: []StackLinks,
    records: store_mod.RecordList,
    /// `records.items` index per row.
    record_index: []usize,

    fn record(self: *const TargetPlan, row: usize) *const PrRecord {
        return &self.records.items[self.record_index[row]];
    }
};

fn loadTargetPlan(arena: Allocator, params: struct { store: *Store, repo_id: i64, targets_path: []const u8 }) !TargetPlan {
    const rows = try readTargets(arena, params.targets_path);
    var records = try params.store.listOpen(arena, params.repo_id);
    errdefer records.deinit();

    const record_index = try arena.alloc(usize, rows.len);
    for (rows, record_index) |row, *slot| {
        slot.* = for (records.items, 0..) |rec, i| {
            if (rec.number == row.number) break i;
        } else {
            std.debug.print("PR {d} is in the TSV but not in the DB (run seed first)\n", .{row.number});
            return error.TargetNotSeeded;
        };
    }
    return .{ .rows = rows, .links = try stackLinks(arena, rows), .records = records, .record_index = record_index };
}

/// parent = row whose number is `parent_number`; bottom = the first row of the
/// chain (set for every stacked row); is_tip = stacked and nobody's parent.
fn stackLinks(arena: Allocator, rows: []const TargetRow) ![]StackLinks {
    const links = try arena.alloc(StackLinks, rows.len);
    for (rows, links) |row, *link| {
        link.* = .{};
        if (row.parent_number == 0) continue;
        link.parent = rowIndex(rows, row.parent_number) orelse {
            std.debug.print("PR {d}: parent_number {d} is not in the TSV\n", .{ row.number, row.parent_number });
            return error.UnknownParent;
        };
        var bottom = link.parent.?;
        var hops: usize = 0;
        while (rows[bottom].parent_number != 0) : (hops += 1) {
            if (hops > rows.len) return error.StackCycle;
            bottom = rowIndex(rows, rows[bottom].parent_number) orelse return error.UnknownParent;
        }
        link.bottom = bottom;
        link.is_tip = for (rows) |other| {
            if (other.parent_number == row.number) break false;
        } else true;
    }
    return links;
}

fn rowIndex(rows: []const TargetRow, number: u32) ?usize {
    for (rows, 0..) |row, i| {
        if (row.number == number) return i;
    }
    return null;
}

/// Lines starting with '#' and blank lines are skipped. Strings borrow from
/// the file bytes (arena).
fn readTargets(arena: Allocator, path: []const u8) ![]TargetRow {
    const bytes = try readFile(arena, path);
    var rows: std.ArrayList(TargetRow) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (line.len == 0 or line[0] == '#') continue;
        var fields: [7][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, '\t');
        for (&fields) |*field| {
            field.* = it.next() orelse {
                std.debug.print("{s}:{d}: expected 7 tab-separated fields\n", .{ path, line_no });
                return error.BadTargets;
            };
        }
        if (it.next() != null) {
            std.debug.print("{s}:{d}: more than 7 fields\n", .{ path, line_no });
            return error.BadTargets;
        }
        try rows.append(arena, .{
            .number = try parseIntFlag(u32, .{ .name = "number", .text = fields[0] }),
            .head_ref = fields[1],
            .base_ref = fields[2],
            .head_oid = fields[3],
            .base_oid = fields[4],
            .updated_at = fields[5],
            .parent_number = try parseIntFlag(u32, .{ .name = "parent_number", .text = fields[6] }),
        });
    }
    return rows.items;
}

/// `<label> phase diffs_ready failures last_error`, tab-separated.
fn printStatus(ctx: *Ctx, params: struct { label: []const u8, status: prefetch.Status }) !void {
    const status = params.status;
    try ctx.out.print("{s}\t{s}\t{d}\t{d}\t{s}\n", .{
        params.label,
        @tagName(status.phase),
        status.diffs_ready,
        status.failures,
        if (status.last_error) |err| @tagName(err) else "none",
    });
}

/// Poll until the worker reports idle or failed for `version` (and, when
/// given, after ordering by `focus`); null on timeout.
fn waitForSettled(worker: *prefetch.PrefetchWorker, params: struct { version: u64, focus: ?u32 = null, timeout_ms: u64 }) !?prefetch.Status {
    var timer = try skim_io.Timer.start();
    while (timer.read() < params.timeout_ms * std.time.ns_per_ms) {
        const status = worker.status();
        const settled = status.phase == .idle or status.phase == .failed;
        const focused = if (params.focus) |focus| status.focus == focus else true;
        if (settled and focused and status.targets_version == params.version) return status;
        skim_io.sleep(poll_interval_ns);
    }
    return null;
}

fn openStore(ctx: *Ctx) !Store {
    return Store.open(ctx.arena, try absoluteFlag(ctx, "--db"));
}

/// Store.open needs an absolute path (it creates the file with an absolute API).
fn absoluteFlag(ctx: *Ctx, name: []const u8) ![]const u8 {
    const path = try ctx.flags.require(name);
    if (std.fs.path.isAbsolute(path)) return path;
    return skim_io.absolutePathAlloc(ctx.arena, path);
}

fn readFile(arena: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, arena, .limited(256 * 1024 * 1024));
}

fn requireKey(flags: Flags) !store_mod.DiffKey {
    return .{
        .merge_base_oid = (try requireOid(flags, "--merge-base"))[0..40].*,
        .head_oid = (try requireOid(flags, "--head"))[0..40].*,
    };
}

fn requireOid(flags: Flags, name: []const u8) ![]const u8 {
    const oid = try flags.require(name);
    if (oid.len != 40) {
        std.debug.print("{s}: expected a 40-char oid, got '{s}'\n", .{ name, oid });
        return error.InvalidOid;
    }
    return oid;
}

fn parseIntFlag(comptime T: type, field: struct { name: []const u8, text: []const u8 }) !T {
    return std.fmt.parseInt(T, field.text, 10) catch |err| {
        std.debug.print("{s}: expected an integer, got '{s}'\n", .{ field.name, field.text });
        return err;
    };
}

fn isBooleanFlag(item: []const u8) bool {
    for (boolean_flags) |flag| {
        if (std.mem.eql(u8, item, flag)) return true;
    }
    return false;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
