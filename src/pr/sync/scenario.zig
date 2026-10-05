//! A fake `gh` scenario directory, shared by the sync tests and the sync
//! harness. Layout (see scripts/test-infra/pr-sidebar/sync/fake-gh):
//!
//!   <root>/gh             launcher: sets FAKE_GH_ROOT/SLEEP_MS, execs fake-gh
//!   <root>/step           current step number
//!   <root>/step-<n>/...   fixtures served during step n
//!   <root>/calls.log      one "<step> <op> <cursor-key> <ids...>" line per call
//!
//! The launcher is passed as `gh_bin`, so the fake needs no environment
//! changes in the parent process.
//!
//! `World` pairs one such directory with a `prs.db` and drives `runOnce`
//! against it.

const std = @import("std");
const skim_io = @import("skim_io");
const store_mod = @import("../db/store.zig");
const types = @import("../db/types.zig");
const fixtures = @import("fixtures.zig");
const sync = @import("sync.zig");

/// The repo every `World` registers.
pub const repo_key = "github.com/acme/widgets";
pub const owner = "acme";
pub const repo_name = "widgets";

pub const File = struct {
    /// Relative to `<root>/step-<n>/`, e.g. "SkimSyncIndex-first.json" or
    /// "nodes/PR_7.json".
    path: []const u8,
    bytes: []const u8,
};

pub const LauncherParams = struct {
    root: []const u8,
    fake_gh: []const u8,
    /// Delay before every fake `gh` reply.
    sleep_ms: u32 = 0,
};

pub const FilesParams = struct {
    root: []const u8,
    step: u32,
    files: []const File,
};

pub const Call = struct {
    step: u32,
    /// Operation name, e.g. "SkimSyncIndex".
    op: []const u8,
    /// "first", or the sanitized cursor.
    key: []const u8,
    ids: []const []const u8,
};

pub const Calls = struct {
    arena: std.heap.ArenaAllocator,
    items: []Call,

    pub fn deinit(self: *Calls) void {
        self.arena.deinit();
    }

    pub fn count(self: Calls, op: []const u8) usize {
        var n: usize = 0;
        for (self.items) |call| n += @intFromBool(std.mem.eql(u8, call.op, op));
        return n;
    }

    /// Calls of `op`, in order. Allocated from the `Calls` arena.
    pub fn of(self: *Calls, op: []const u8) ![]Call {
        var matching: std.ArrayList(Call) = .empty;
        for (self.items) |call| {
            if (std.mem.eql(u8, call.op, op)) try matching.append(self.arena.allocator(), call);
        }
        return matching.items;
    }
};

/// The files of one scenario step, built in an arena.
pub const Step = struct {
    arena: std.heap.ArenaAllocator,
    files: std.ArrayList(File) = .empty,

    pub const FullSyncParams = struct {
        prs: []const fixtures.SynthPr,
        page_size: usize = 100,
        with_nodes: bool = true,
    };

    pub const IndexPagesParams = struct {
        prs: []const fixtures.SynthPr,
        page_size: usize = 100,
        viewer_login: []const u8 = "ctdio",
    };

    pub const FailParams = struct {
        stderr: []const u8,
        code: u8 = 1,
    };

    pub fn init(allocator: std.mem.Allocator) Step {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Step) void {
        self.arena.deinit();
    }

    /// A later file with the same path replaces an earlier one.
    pub fn add(self: *Step, path: []const u8, bytes: []const u8) !void {
        try self.files.append(self.arena.allocator(), .{ .path = path, .bytes = bytes });
    }

    pub fn ts(self: *Step, offset: u64) ![]u8 {
        return fixtures.ts(self.arena.allocator(), offset);
    }

    pub fn index(self: *Step, key: []const u8, params: fixtures.IndexPageParams) !void {
        const a = self.arena.allocator();
        try self.add(try std.fmt.allocPrint(a, "SkimSyncIndex-{s}.json", .{key}), try fixtures.synthIndexPage(a, params));
    }

    pub fn closed(self: *Step, key: []const u8, params: fixtures.ClosedPageParams) !void {
        const a = self.arena.allocator();
        try self.add(try std.fmt.allocPrint(a, "SkimSyncClosed-{s}.json", .{key}), try fixtures.synthClosedPage(a, params));
    }

    pub fn reconcile(self: *Step, key: []const u8, params: fixtures.ReconcilePageParams) !void {
        const a = self.arena.allocator();
        try self.add(try std.fmt.allocPrint(a, "SkimSyncReconcile-{s}.json", .{key}), try fixtures.synthReconcilePage(a, params));
    }

    pub fn teams(self: *Step, slugs: ?[]const []const u8) !void {
        try self.add("SkimSyncTeams-first.json", try fixtures.synthTeams(self.arena.allocator(), slugs));
    }

    /// A hydrate node for every PR, carrying the PR's `updated_at`.
    pub fn nodes(self: *Step, prs: []const fixtures.SynthPr) !void {
        const a = self.arena.allocator();
        for (prs) |pr| {
            const path = try std.fmt.allocPrint(a, "nodes/{s}.json", .{try fixtures.nodeId(a, pr.number)});
            try self.add(path, try fixtures.synthHydrateNode(a, .{ .number = pr.number, .updated_at = pr.updated_at, .additions = pr.number }));
        }
    }

    /// The fake answers each PR's hydrate slot with `null` and a FORBIDDEN
    /// error at `["nodes", i]`, and exits 1.
    pub fn forbidden(self: *Step, prs: []const fixtures.SynthPr) !void {
        const a = self.arena.allocator();
        for (prs) |pr| {
            try self.add(try std.fmt.allocPrint(a, "forbidden/{s}", .{try fixtures.nodeId(a, pr.number)}), "");
        }
    }

    /// `fail-<name>`: the fake prints `stderr` and exits `code`.
    pub fn fail(self: *Step, name: []const u8, params: FailParams) !void {
        const a = self.arena.allocator();
        try self.add(try std.fmt.allocPrint(a, "fail-{s}", .{name}), params.stderr);
        try self.add(try std.fmt.allocPrint(a, "fail-{s}.code", .{name}), try std.fmt.allocPrint(a, "{d}\n", .{params.code}));
    }

    /// `prs` split into index pages of `page_size`: "first", then cursors
    /// "c2", "c3", ...
    pub fn indexPages(self: *Step, params: IndexPagesParams) !void {
        const a = self.arena.allocator();
        var offset: usize = 0;
        var page: usize = 1;
        while (true) : (page += 1) {
            const end = @min(offset + params.page_size, params.prs.len);
            const has_next = end < params.prs.len;
            const key = if (page == 1) "first" else try std.fmt.allocPrint(a, "c{d}", .{page});
            const next_cursor = if (has_next) try std.fmt.allocPrint(a, "c{d}", .{page + 1}) else null;
            try self.index(key, .{ .prs = params.prs[offset..end], .has_next = has_next, .end_cursor = next_cursor, .viewer_login = params.viewer_login });
            offset = end;
            if (!has_next) break;
        }
    }

    /// Everything a first sync asks for: index pages of `page_size`, one
    /// reconcile page with every number, an empty closed page, team "core",
    /// and (optionally) a hydrate node per PR.
    pub fn fullSync(self: *Step, params: FullSyncParams) !void {
        const a = self.arena.allocator();
        try self.indexPages(.{ .prs = params.prs, .page_size = params.page_size });
        const numbers = try a.alloc(u32, params.prs.len);
        for (params.prs, numbers) |pr, *number| number.* = pr.number;
        try self.reconcile("first", .{ .numbers = numbers });
        try self.closed("first", .{ .rows = &.{} });
        try self.teams(&.{"core"});
        if (params.with_nodes) try self.nodes(params.prs);
    }

    /// The passes after index on an incremental run with nothing to report:
    /// an empty closed page.
    pub fn quietTail(self: *Step) !void {
        try self.closed("first", .{ .rows = &.{} });
    }
};

/// A scenario directory with a registered repo in `<root>/prs.db` and the
/// `<root>/gh` launcher. Steps are served in order: the first `serve` is step
/// 1, the next step 2, and so on.
pub const World = struct {
    allocator: std.mem.Allocator,
    /// Absolute, created and removed by the caller.
    root: []const u8,
    fake_gh: []const u8,
    db_path: []u8,
    /// The `<root>/gh` launcher.
    gh: []u8,
    store: store_mod.Store,
    repo_id: i64,
    /// The step the fake currently serves; 0 before the first `serve`.
    step: u32 = 0,
    /// World-lifetime allocations: `seed` results, `callsOf`, `openNumbers`.
    arena: std.heap.ArenaAllocator,

    pub const seed_now: i64 = 1_767_300_000;

    pub const InitParams = struct {
        allocator: std.mem.Allocator,
        root: []const u8,
        fake_gh: []const u8,
    };

    pub const RunOptions = struct {
        sync_index: u64 = 0,
        priority: []const u32 = &.{},
        now: i64 = seed_now,
        /// Incremented once per `on_commit`.
        commits: ?*usize = null,
        cancel: ?*const std.atomic.Value(bool) = null,
        /// Overrides the launcher.
        gh_bin: ?[]const u8 = null,
    };

    pub const StepCallsParams = struct { step: u32, op: []const u8 };

    pub fn init(params: InitParams) !World {
        const allocator = params.allocator;
        const db_path = try std.fmt.allocPrint(allocator, "{s}/prs.db", .{params.root});
        errdefer allocator.free(db_path);
        const gh = try writeLauncher(allocator, .{ .root = params.root, .fake_gh = params.fake_gh });
        errdefer allocator.free(gh);
        var store = try store_mod.Store.open(allocator, db_path);
        errdefer store.close();
        const repo_id = try store.ensureRepo(.{ .key = repo_key, .owner = owner, .name = repo_name });
        return .{
            .allocator = allocator,
            .root = params.root,
            .fake_gh = params.fake_gh,
            .db_path = db_path,
            .gh = gh,
            .store = store,
            .repo_id = repo_id,
            .arena = .init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.arena.deinit();
        self.store.close();
        self.allocator.free(self.gh);
        self.allocator.free(self.db_path);
    }

    /// Write `step`'s files as the next step number and make the fake serve them.
    pub fn serve(self: *World, step: *Step) !void {
        self.step += 1;
        try writeFiles(self.allocator, .{ .root = self.root, .step = self.step, .files = step.files.items });
        try setStep(self.allocator, self.root, self.step);
    }

    /// Delay every later fake `gh` reply by `sleep_ms`.
    pub fn setSleep(self: *World, sleep_ms: u32) !void {
        const gh = try writeLauncher(self.allocator, .{ .root = self.root, .fake_gh = self.fake_gh, .sleep_ms = sleep_ms });
        self.allocator.free(gh);
    }

    pub fn run(self: *World, options: RunOptions) !sync.RunOutcome {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var ignored: usize = 0;
        return sync.runOnce(.{
            .store = &self.store,
            .repo_id = self.repo_id,
            .owner = owner,
            .name = repo_name,
            .gh_bin = options.gh_bin orelse self.gh,
            .sync_index = options.sync_index,
            .priority = options.priority,
            .arena = arena.allocator(),
            .on_commit = countCommit,
            .on_commit_ctx = options.commits orelse &ignored,
            .now = options.now,
            .cancel = options.cancel,
        });
    }

    /// The next step: a full first sync of `params`' hydrated open PRs, viewer
    /// "ctdio" in team "core". Returns the PRs, newest first.
    pub fn seed(self: *World, params: fixtures.SynthPrsParams) ![]fixtures.SynthPr {
        var step = Step.init(self.allocator);
        defer step.deinit();
        const prs = try fixtures.synthPrs(self.arena.allocator(), params);
        try step.fullSync(.{ .prs = prs });
        try self.serve(&step);
        try expectOk(try self.run(.{}));
        return prs;
    }

    /// The next step: an incremental run with nothing new.
    pub fn serveQuiet(self: *World) !void {
        var step = Step.init(self.allocator);
        defer step.deinit();
        try step.index("first", .{ .prs = &.{} });
        try step.quietTail();
        try self.serve(&step);
    }

    /// Every call so far; the caller deinits.
    pub fn calls(self: *World) !Calls {
        return readCalls(self.allocator, self.root);
    }

    pub fn countCalls(self: *World, params: StepCallsParams) !usize {
        return (try self.callsOf(params)).len;
    }

    /// Calls of `op` during `step`, from the world arena.
    pub fn callsOf(self: *World, params: StepCallsParams) ![]Call {
        const all = try readCalls(self.arena.allocator(), self.root);
        var matching: std.ArrayList(Call) = .empty;
        for (all.items) |call| {
            if (call.step == params.step and std.mem.eql(u8, call.op, params.op)) try matching.append(self.arena.allocator(), call);
        }
        return matching.items;
    }

    /// The caller deinits.
    pub fn repo(self: *World) !types.OwnedRepo {
        return (try self.store.getRepo(self.allocator, self.repo_id)) orelse error.RepoMissing;
    }

    /// The caller deinits.
    pub fn listOpen(self: *World) !types.RecordList {
        return self.store.listOpen(self.allocator, self.repo_id);
    }

    pub fn openCount(self: *World) !usize {
        var open = try self.listOpen();
        defer open.deinit();
        return open.items.len;
    }

    /// Open PR numbers, ascending, from the world arena.
    pub fn openNumbers(self: *World) ![]u32 {
        var open = try self.listOpen();
        defer open.deinit();
        const numbers = try self.arena.allocator().alloc(u32, open.items.len);
        for (open.items, numbers) |record, *number| number.* = record.number;
        std.mem.sort(u32, numbers, {}, std.sort.asc(u32));
        return numbers;
    }

    /// Rows of the repo in any state.
    pub fn rowCount(self: *World) !i64 {
        var stmt = try self.store.db.prepare("SELECT COUNT(*) FROM pr WHERE repo_id = ?");
        defer stmt.finalize();
        try stmt.bind(1, self.repo_id);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    /// The stored state of PR `number`, or null when there is no row.
    pub fn stateOf(self: *World, number: u32) !?types.PrState {
        var stmt = try self.store.db.prepare("SELECT state FROM pr WHERE repo_id = ? AND number = ?");
        defer stmt.finalize();
        try stmt.bindAll(.{ self.repo_id, number });
        if (!try stmt.step()) return null;
        const text = try stmt.columnText(0);
        var lower: [16]u8 = undefined;
        if (text.len > lower.len) return error.UnknownState;
        return std.meta.stringToEnum(types.PrState, std.ascii.lowerString(&lower, text)) orelse error.UnknownState;
    }

    /// `additions` of open PR `number`.
    pub fn additionsOf(self: *World, number: u32) !u32 {
        var open = try self.listOpen();
        defer open.deinit();
        for (open.items) |record| {
            if (record.number == number) return record.additions;
        }
        return error.NotOpen;
    }
};

/// Fail with `error.RunFailed` (after printing the kind) unless `outcome` is `.ok`.
pub fn expectOk(outcome: sync.RunOutcome) !void {
    switch (outcome) {
        .ok => {},
        .failed => |kind| {
            std.debug.print("expected .ok, got .failed = {s}\n", .{@tagName(kind)});
            return error.RunFailed;
        },
    }
}

/// Write `<root>/gh` (mode 0755) and return its path (caller frees).
pub fn writeLauncher(allocator: std.mem.Allocator, params: LauncherParams) ![]u8 {
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nFAKE_GH_ROOT='{s}' SLEEP_MS='{d}' exec '{s}' \"$@\"\n",
        .{ params.root, params.sleep_ms, params.fake_gh },
    );
    defer allocator.free(script);
    const path = try std.fmt.allocPrint(allocator, "{s}/gh", .{params.root});
    errdefer allocator.free(path);
    try writeAbsolute(.{ .path = path, .bytes = script, .mode = 0o755 });
    return path;
}

/// Write every file under `<root>/step-<step>/`, creating subdirectories.
pub fn writeFiles(allocator: std.mem.Allocator, params: FilesParams) !void {
    for (params.files) |file| {
        const path = try std.fmt.allocPrint(allocator, "{s}/step-{d}/{s}", .{ params.root, params.step, file.path });
        defer allocator.free(path);
        try std.Io.Dir.cwd().createDirPath(skim_io.get(), std.fs.path.dirname(path).?);
        try writeAbsolute(.{ .path = path, .bytes = file.bytes, .mode = 0o644 });
    }
}

/// Make the fake serve `<root>/step-<step>/` from its next call on.
pub fn setStep(allocator: std.mem.Allocator, root: []const u8, step: u32) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/step", .{root});
    defer allocator.free(path);
    var buf: [16]u8 = undefined;
    try writeAbsolute(.{ .path = path, .bytes = try std.fmt.bufPrint(&buf, "{d}\n", .{step}), .mode = 0o644 });
}

/// Every call the fake has logged so far. No log yet means no calls.
pub fn readCalls(allocator: std.mem.Allocator, root: []const u8) !Calls {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const path = try std.fmt.allocPrint(a, "{s}/calls.log", .{root});
    const log = std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    var calls: std.ArrayList(Call) = .empty;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| try calls.append(a, try parseCall(a, line));
    return .{ .arena = arena, .items = calls.items };
}

fn parseCall(a: std.mem.Allocator, line: []const u8) !Call {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const step = try std.fmt.parseInt(u32, fields.next() orelse return error.BadCallLine, 10);
    const op = fields.next() orelse return error.BadCallLine;
    const key = fields.next() orelse return error.BadCallLine;
    var ids: std.ArrayList([]const u8) = .empty;
    while (fields.next()) |id| try ids.append(a, id);
    return .{ .step = step, .op = op, .key = key, .ids = ids.items };
}

fn countCommit(ctx: *anyopaque) void {
    const commits: *usize = @ptrCast(@alignCast(ctx));
    commits.* += 1;
}

fn writeAbsolute(params: struct { path: []const u8, bytes: []const u8, mode: u32 }) !void {
    const io = skim_io.get();
    const file = try std.Io.Dir.createFileAbsolute(io, params.path, .{ .truncate = true, .permissions = .fromMode(params.mode) });
    defer file.close(io);
    try file.setPermissions(io, .fromMode(params.mode));
    try file.writeStreamingAll(io, params.bytes);
}
