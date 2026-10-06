//! Decides which hunks get syntax-highlighted, in what order, and when a
//! landed result is worth a repaint.
//!
//! The policy used to live inline in `App.run`, where nothing could reach it.
//! It is the thing the user feels while paging: a `Ctrl-d` exposes a screen of
//! hunks that have never been parsed, and how quickly those turn from plain to
//! styled is entirely this file's decision.
//!
//! Two costs are in tension. Submitting too little leaves the visible page
//! unstyled, so the terminal paints those rows twice - once plain, once styled.
//! Submitting too much builds a backlog on the single worker thread, and since
//! nothing cancels a queued job, the page you are looking at waits behind pages
//! you have already left. The scheduler exists so both can be measured.

const std = @import("std");

const parser = @import("../git/parser.zig");
const line_map_mod = @import("../line_map.zig");
const state_helpers = @import("../state.zig");
const async_highlight = @import("async.zig");

const LineMap = line_map_mod.LineMap;
const StateHelpers = state_helpers.StateHelpers;
const HighlightWorker = async_highlight.HighlightWorker;
const HighlightJob = async_highlight.HighlightJob;
const HighlightResult = async_highlight.HighlightResult;

pub const HunkKey = struct {
    file_idx: usize,
    hunk_idx: usize,
};

/// Content handed to the worker by reference. The scheduler owns the bytes and
/// frees them when the matching result lands.
pub const PendingJob = struct {
    file_path: []const u8,
    content: []const u8,
    old_content: []const u8,
};

/// The window the scheduler schedules around.
pub const Viewport = struct {
    scroll_offset: usize,
    height: usize,
};

pub const SubmitParams = struct {
    files: []parser.FileDiff,
    line_map: *const LineMap,
    viewport: Viewport,
};

pub const ApplyParams = struct {
    files: []parser.FileDiff,
    current_file_idx: usize,
};

/// A job abandoned by `resetForNewDiff` whose bytes the worker may still be
/// reading. Freed when its (stale) result lands or `takeQueuedBefore` returns it.
const RetiredJob = struct {
    generation: u64,
    key: HunkKey,
    job: PendingJob,
};

/// Hunks handed to the worker in one pass. Enough to cover a screen without
/// burying it under a backlog the next keystroke invalidates.
const max_hunks_per_pass: usize = 8;

pub const HighlightScheduler = struct {
    allocator: std.mem.Allocator,
    worker: ?*HighlightWorker = null,
    pending: std.AutoHashMap(HunkKey, PendingJob),
    // Bumped by `resetForNewDiff`; stamped on every submitted job so a result
    // for a previous diff is recognised and never applied.
    generation: u64 = 0,
    retired: std.ArrayList(RetiredJob) = .empty,

    pub fn init(allocator: std.mem.Allocator) HighlightScheduler {
        return .{
            .allocator = allocator,
            .worker = null,
            .pending = std.AutoHashMap(HunkKey, PendingJob).init(allocator),
        };
    }

    pub fn deinit(self: *HighlightScheduler) void {
        if (self.worker) |worker| worker.deinit();
        self.worker = null;
        self.deinitWithoutWorker();
    }

    /// Frees the queued job bytes without touching the worker.
    ///
    /// wasm has no threads, so the web build never starts a worker and must not
    /// reference one: naming `HighlightWorker.deinit` there drags `Thread.join`
    /// into a module that does not link libc and fails to compile.
    pub fn deinitWithoutWorker(self: *HighlightScheduler) void {
        var iter = self.pending.iterator();
        while (iter.next()) |entry| self.freeJob(entry.value_ptr.*);
        self.pending.deinit();
        for (self.retired.items) |retired| self.freeJob(retired.job);
        self.retired.deinit(self.allocator);
    }

    /// Abandon every in-flight job: the next diff's hunks share `HunkKey`s with
    /// the old diff's, so a late result must never be applied (or allowed to
    /// free the new diff's pending job). Call before replacing `files`.
    pub fn resetForNewDiff(self: *HighlightScheduler) void {
        const worker = self.worker orelse {
            var iter = self.pending.iterator();
            while (iter.next()) |entry| self.freeJob(entry.value_ptr.*);
            self.pending.clearRetainingCapacity();
            self.generation += 1;
            return;
        };

        var iter = self.pending.iterator();
        while (iter.next()) |entry| {
            // On OOM the job is leaked: the worker may still be reading it.
            self.retired.append(self.allocator, .{
                .generation = self.generation,
                .key = entry.key_ptr.*,
                .job = entry.value_ptr.*,
            }) catch {};
        }
        self.pending.clearRetainingCapacity();
        self.generation += 1;

        var dropped: std.ArrayList(HighlightJob) = .empty;
        defer dropped.deinit(worker.allocator);
        worker.takeQueuedBefore(self.generation, &dropped) catch {};
        for (dropped.items) |job| {
            self.releaseRetired(.{
                .generation = job.generation,
                .key = .{ .file_idx = job.file_idx, .hunk_idx = job.hunk_idx },
            });
        }
    }

    pub fn pendingCount(self: *const HighlightScheduler) usize {
        return self.pending.count();
    }

    /// Drains finished results onto their hunks. Returns true when a repaint is
    /// owed, which is only when a hunk the user can see just gained style.
    pub fn applyResults(self: *HighlightScheduler, params: ApplyParams) bool {
        const worker = self.worker orelse return false;

        var results: std.ArrayList(HighlightResult) = .empty;
        defer results.deinit(self.allocator);

        worker.pollResults(self.allocator, &results) catch {};

        var needs_render = false;
        for (results.items) |result| {
            const key = HunkKey{ .file_idx = result.file_idx, .hunk_idx = result.hunk_idx };
            if (result.generation != self.generation) {
                self.releaseRetired(.{ .generation = result.generation, .key = key });
                freeResult(worker, result);
                continue;
            }
            if (self.pending.fetchRemove(key)) |entry| self.freeJob(entry.value);

            const hunk = hunkAt(params.files, key) orelse {
                freeResult(worker, result);
                continue;
            };

            if (result.highlights) |highlights| hunk.highlights = highlights;
            if (result.old_highlights) |old_highlights| hunk.old_highlights = old_highlights;
            if (result.highlights == null and result.old_highlights == null) continue;

            StateHelpers.rebuildHunkHighlightCaches(self.allocator, hunk) catch |err| {
                std.log.warn("Failed to rebuild highlight cache: {any}", .{err});
            };

            if (key.file_idx == params.current_file_idx) needs_render = true;
        }

        return needs_render;
    }

    /// Queues un-highlighted hunks at and ahead of the viewport. Returns how
    /// many jobs were handed to the worker.
    pub fn submitVisible(self: *HighlightScheduler, params: SubmitParams) usize {
        if (params.files.len == 0) return 0;

        if (self.worker == null) {
            self.worker = HighlightWorker.init(self.allocator) catch return 0;
        }
        const worker = self.worker.?;

        const viewport = params.viewport;
        const visible_end = viewport.scroll_offset + viewport.height;
        const start_file_idx = params.line_map.getFileIndexForLine(viewport.scroll_offset) orelse 0;

        var submitted: usize = 0;
        var file_idx = start_file_idx;
        file_loop: while (file_idx < params.files.len) : (file_idx += 1) {
            if (params.line_map.getFileHeaderLine(file_idx)) |header_line| {
                // One screen of lookahead. Past that the user has not asked for
                // the content and the worker has better things to parse.
                if (header_line > visible_end + viewport.height) break;
            }

            const file = &params.files[file_idx];
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

            for (file.hunks, 0..) |*hunk, hunk_idx| {
                if (submitted >= max_hunks_per_pass) break :file_loop;

                const key = HunkKey{ .file_idx = file_idx, .hunk_idx = hunk_idx };
                if (hunk.highlights != null or self.pending.contains(key)) continue;

                if (self.submitOne(worker, .{ .key = key, .hunk = hunk, .file_path = file_path })) {
                    submitted += 1;
                }
            }
        }

        return submitted;
    }

    fn submitOne(
        self: *HighlightScheduler,
        worker: *HighlightWorker,
        params: struct { key: HunkKey, hunk: *const parser.Hunk, file_path: []const u8 },
    ) bool {
        const content = StateHelpers.buildHunkContent(self.allocator, params.hunk) catch return false;
        const old_content = StateHelpers.buildHunkOldContent(self.allocator, params.hunk) catch {
            self.allocator.free(content);
            return false;
        };
        const file_path = self.allocator.dupe(u8, params.file_path) catch {
            self.allocator.free(content);
            self.allocator.free(old_content);
            return false;
        };

        const job: PendingJob = .{ .file_path = file_path, .content = content, .old_content = old_content };

        self.pending.put(params.key, job) catch {
            self.freeJob(job);
            return false;
        };

        worker.submitJob(.{
            .file_path = file_path,
            .content = content,
            .old_content = old_content,
            .file_idx = params.key.file_idx,
            .hunk_idx = params.key.hunk_idx,
            .generation = self.generation,
        }) catch {
            if (self.pending.fetchRemove(params.key)) |entry| self.freeJob(entry.value);
            return false;
        };

        return true;
    }

    fn freeJob(self: *HighlightScheduler, job: PendingJob) void {
        self.allocator.free(job.file_path);
        self.allocator.free(job.content);
        self.allocator.free(job.old_content);
    }

    fn releaseRetired(self: *HighlightScheduler, params: struct { generation: u64, key: HunkKey }) void {
        for (self.retired.items, 0..) |retired, idx| {
            if (retired.generation != params.generation) continue;
            if (retired.key.file_idx != params.key.file_idx or retired.key.hunk_idx != params.key.hunk_idx) continue;
            self.freeJob(retired.job);
            _ = self.retired.swapRemove(idx);
            return;
        }
    }
};

fn hunkAt(files: []parser.FileDiff, key: HunkKey) ?*parser.Hunk {
    if (key.file_idx >= files.len) return null;
    const file = &files[key.file_idx];
    if (key.hunk_idx >= file.hunks.len) return null;
    return @constCast(&file.hunks[key.hunk_idx]);
}

fn freeResult(worker: *HighlightWorker, result: HighlightResult) void {
    if (result.highlights) |highlights| worker.highlighter.freeHighlights(highlights);
    if (result.old_highlights) |old_highlights| worker.highlighter.freeHighlights(old_highlights);
}

const testing = std.testing;
const comments = @import("../comments/store.zig");
const skim_io = @import("skim_io");

/// Parses `diff_text` into the pieces `submitVisible` needs. Caller deinits both.
fn testDiff(allocator: std.mem.Allocator, diff_text: []const u8) !struct {
    files: []parser.FileDiff,
    store: *comments.CommentStore,
    map: LineMap,
} {
    const files = try parser.parse(allocator, diff_text);
    const store = try allocator.create(comments.CommentStore);
    store.* = comments.CommentStore.init(allocator);
    const map = try LineMap.build(allocator, .{ .files = files, .comment_store = store, .hunk_view_mode = .all, .apply_filtering = true });
    return .{ .files = files, .store = store, .map = map };
}

const two_hunk_diff =
    \\diff --git a/a.zig b/a.zig
    \\--- a/a.zig
    \\+++ b/a.zig
    \\@@ -1,2 +1,2 @@ one
    \\ const a = 1;
    \\+const b = 2;
    \\@@ -20,2 +20,2 @@ two
    \\ const c = 3;
    \\+const d = 4;
    \\
;

test "submitVisible queues every un-highlighted hunk it can see" {
    const allocator = testing.allocator;
    var fixture = try testDiff(allocator, two_hunk_diff);
    defer {
        for (fixture.files) |*file| file.deinit(allocator);
        allocator.free(fixture.files);
        fixture.store.deinit();
        allocator.destroy(fixture.store);
        fixture.map.deinit();
    }

    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinit();

    const submitted = scheduler.submitVisible(.{
        .files = fixture.files,
        .line_map = &fixture.map,
        .viewport = .{ .scroll_offset = 0, .height = 40 },
    });

    try testing.expectEqual(@as(usize, 2), submitted);
    try testing.expectEqual(@as(usize, 2), scheduler.pendingCount());
}

test "submitVisible does not queue a hunk twice while its job is in flight" {
    const allocator = testing.allocator;
    var fixture = try testDiff(allocator, two_hunk_diff);
    defer {
        for (fixture.files) |*file| file.deinit(allocator);
        allocator.free(fixture.files);
        fixture.store.deinit();
        allocator.destroy(fixture.store);
        fixture.map.deinit();
    }

    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinit();

    const params: SubmitParams = .{
        .files = fixture.files,
        .line_map = &fixture.map,
        .viewport = .{ .scroll_offset = 0, .height = 40 },
    };

    _ = scheduler.submitVisible(params);
    try testing.expectEqual(@as(usize, 0), scheduler.submitVisible(params));
}

test "scheduler: resetForNewDiff drops pending and stale results" {
    const allocator = testing.allocator;
    var fixture = try testDiff(allocator, two_hunk_diff);
    defer {
        for (fixture.files) |*file| file.deinit(allocator);
        allocator.free(fixture.files);
        fixture.store.deinit();
        allocator.destroy(fixture.store);
        fixture.map.deinit();
    }

    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinit();

    _ = scheduler.submitVisible(.{
        .files = fixture.files,
        .line_map = &fixture.map,
        .viewport = .{ .scroll_offset = 0, .height = 40 },
    });
    try testing.expectEqual(@as(usize, 2), scheduler.pendingCount());

    scheduler.resetForNewDiff();

    try testing.expectEqual(@as(usize, 0), scheduler.pendingCount());
    try testing.expectEqual(@as(u64, 1), scheduler.generation);
}

test "scheduler: a stale result never frees the new diff's pending job" {
    const allocator = testing.allocator;
    var fixture = try testDiff(allocator, two_hunk_diff);
    defer {
        for (fixture.files) |*file| file.deinit(allocator);
        allocator.free(fixture.files);
        fixture.store.deinit();
        allocator.destroy(fixture.store);
        fixture.map.deinit();
    }

    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.worker = try HighlightWorker.init(allocator);

    scheduler.resetForNewDiff();

    // The new diff's job for {0,0}, put straight into `pending` so the worker
    // never sees it and cannot race the assertions below.
    const key = HunkKey{ .file_idx = 0, .hunk_idx = 0 };
    try scheduler.pending.put(key, try testJob(allocator));

    const worker = scheduler.worker.?;
    worker.mutex.lockUncancelable(skim_io.get());
    try worker.result_queue.append(allocator, .{
        .file_idx = 0,
        .hunk_idx = 0,
        .highlights = null,
        .old_highlights = null,
        .failed = true,
        .generation = 0,
    });
    worker.mutex.unlock(skim_io.get());

    _ = scheduler.applyResults(.{ .files = fixture.files, .current_file_idx = 0 });

    try testing.expect(scheduler.pending.contains(key));
    try testing.expect(fixture.files[0].hunks[0].highlights == null);
}

test "scheduler: resetForNewDiff without a worker frees pending directly" {
    const allocator = testing.allocator;
    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.pending.put(.{ .file_idx = 0, .hunk_idx = 0 }, try testJob(allocator));
    scheduler.resetForNewDiff();

    try testing.expectEqual(@as(usize, 0), scheduler.pendingCount());
    try testing.expectEqual(@as(usize, 0), scheduler.retired.items.len);
}

test "scheduler: a stale result frees the retired job it belonged to" {
    const allocator = testing.allocator;
    var fixture = try testDiff(allocator, two_hunk_diff);
    defer {
        for (fixture.files) |*file| file.deinit(allocator);
        allocator.free(fixture.files);
        fixture.store.deinit();
        allocator.destroy(fixture.store);
        fixture.map.deinit();
    }

    var worker = idleWorker(allocator);
    defer worker.job_queue.deinit(allocator);
    defer worker.result_queue.deinit(allocator);

    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinitWithoutWorker();
    scheduler.worker = &worker;

    // Already dequeued by the worker (not in job_queue), so resetForNewDiff
    // must keep its bytes alive until the result lands.
    const key = HunkKey{ .file_idx = 0, .hunk_idx = 0 };
    try scheduler.pending.put(key, try testJob(allocator));
    scheduler.resetForNewDiff();
    try testing.expectEqual(@as(usize, 1), scheduler.retired.items.len);

    try worker.result_queue.append(allocator, .{
        .file_idx = 0,
        .hunk_idx = 0,
        .highlights = null,
        .old_highlights = null,
        .failed = true,
        .generation = 0,
    });
    _ = scheduler.applyResults(.{ .files = fixture.files, .current_file_idx = 0 });

    try testing.expectEqual(@as(usize, 0), scheduler.retired.items.len);
}

test "scheduler: resetForNewDiff frees jobs the worker has not started" {
    const allocator = testing.allocator;
    var fixture = try testDiff(allocator, two_hunk_diff);
    defer {
        for (fixture.files) |*file| file.deinit(allocator);
        allocator.free(fixture.files);
        fixture.store.deinit();
        allocator.destroy(fixture.store);
        fixture.map.deinit();
    }

    var worker = idleWorker(allocator);
    defer worker.job_queue.deinit(allocator);
    defer worker.result_queue.deinit(allocator);

    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinitWithoutWorker();
    scheduler.worker = &worker;

    _ = scheduler.submitVisible(.{
        .files = fixture.files,
        .line_map = &fixture.map,
        .viewport = .{ .scroll_offset = 0, .height = 40 },
    });
    try testing.expectEqual(@as(usize, 2), worker.job_queue.items.len);

    scheduler.resetForNewDiff();

    try testing.expectEqual(@as(usize, 0), worker.job_queue.items.len);
    try testing.expectEqual(@as(usize, 0), scheduler.retired.items.len);
}

test "scheduler: a result submitted after resetForNewDiff still applies" {
    const allocator = testing.allocator;
    var fixture = try testDiff(allocator, two_hunk_diff);
    defer {
        for (fixture.files) |*file| file.deinit(allocator);
        allocator.free(fixture.files);
        fixture.store.deinit();
        allocator.destroy(fixture.store);
        fixture.map.deinit();
    }

    var worker = idleWorker(allocator);
    defer worker.job_queue.deinit(allocator);
    defer worker.result_queue.deinit(allocator);

    var scheduler = HighlightScheduler.init(allocator);
    defer scheduler.deinitWithoutWorker();
    scheduler.worker = &worker;

    scheduler.resetForNewDiff();
    _ = scheduler.submitVisible(.{
        .files = fixture.files,
        .line_map = &fixture.map,
        .viewport = .{ .scroll_offset = 0, .height = 40 },
    });
    try testing.expectEqual(@as(u64, 1), worker.job_queue.items[0].generation);

    const job = worker.job_queue.orderedRemove(0);
    try worker.result_queue.append(allocator, .{
        .file_idx = job.file_idx,
        .hunk_idx = job.hunk_idx,
        .highlights = null,
        .old_highlights = null,
        .failed = true,
        .generation = job.generation,
    });
    _ = scheduler.applyResults(.{ .files = fixture.files, .current_file_idx = 0 });

    try testing.expectEqual(@as(usize, 1), scheduler.pendingCount());
}

/// A worker whose thread is never started: only `mutex` and the two queues are
/// touched, so tests can drive results by hand. Callers deinit both queues.
fn idleWorker(allocator: std.mem.Allocator) HighlightWorker {
    return .{
        .allocator = allocator,
        .thread = undefined,
        .job_queue = .empty,
        .result_queue = .empty,
        .mutex = std.Io.Mutex.init,
        .should_stop = false,
        .highlighter = undefined,
    };
}

fn testJob(allocator: std.mem.Allocator) !PendingJob {
    const file_path = try allocator.dupe(u8, "a.zig");
    errdefer allocator.free(file_path);
    const content = try allocator.dupe(u8, "const a = 1;\n");
    errdefer allocator.free(content);
    return .{ .file_path = file_path, .content = content, .old_content = try allocator.dupe(u8, "") };
}
