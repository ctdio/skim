//! Streaming diff loader. Spawns `git diff` on a background thread and parses
//! file diffs incrementally as they arrive, so the TUI renders content while
//! git is still computing the rest of a large diff instead of freezing until
//! the whole diff is buffered.
//!
//! Mirrors the controller pattern in blame_controller.zig: a sub-state struct
//! held as one field on `State`, a detached worker thread, and a per-frame
//! poll on the main loop. The functional core (`IncrementalParser`) is a pure,
//! thread-free unit that turns a byte stream into `FileDiff`s at file
//! boundaries; the worker thread is a thin imperative shell around it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("diff.zig");
const parser = @import("parser.zig");

pub const DiffSource = diff.DiffSource;

/// Marks the start of a new file in a unified diff. A file header always begins
/// at column 0, while content lines carry a +/-/space prefix, so the leading
/// newline makes "\ndiff --git " an unambiguous separator between files.
const FILE_BOUNDARY = "\ndiff --git ";

pub const LoadMode = enum {
    /// Publish files as soon as each parses. Used for the initial load, where
    /// there is nothing on screen to preserve.
    incremental,
    /// Accumulate the full diff and hand it over once, on completion. Used for
    /// refresh so the current view is never replaced by a half-loaded diff.
    replace,
};

/// Streaming diff-load sub-state. One field on `State` (`state.diff_load`).
/// Defaults to idle; `requestStart` arms it and `startIfRequested` (called from
/// the event loop, where the App address is stable) spawns the worker.
pub const DiffLoad = struct {
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Files parsed by the worker, awaiting handoff to the main thread. Each is
    /// allocated with the App allocator (thread-safe) so the main thread can
    /// move it straight into `state.files`. Guarded by `mutex`.
    files: std.ArrayListUnmanaged(parser.FileDiff) = .{},
    /// How many of `files` the main thread has already taken.
    consumed: usize = 0,

    iparser: IncrementalParser = .{},
    mode: LoadMode = .incremental,

    // Set by requestStart, consumed by startIfRequested.
    pending_start: bool = false,
    pending_mode: LoadMode = .incremental,

    // Worker inputs, set before the thread is spawned.
    worker_allocator: Allocator = undefined,
    worker_source: DiffSource = undefined,

    /// True while a load is in flight (worker thread not yet joined). The main
    /// loop keeps ticking and the empty view shows a loading screen while true.
    pub fn isLoading(self: *const DiffLoad) bool {
        return self.thread != null;
    }

    /// Whether the worker has finished streaming (set `done`). The caller still
    /// drains any remaining files before joining via `finishAndJoin`.
    pub fn isDone(self: *const DiffLoad) bool {
        return self.done.load(.acquire);
    }

    pub fn hasFailed(self: *const DiffLoad) bool {
        return self.failed.load(.acquire);
    }
};

/// Turns a streamed byte sequence into `FileDiff`s at file boundaries. Pure and
/// thread-free: feed it chunks in order, then call `finish` at EOF. A file is
/// only emitted once the next file header (or EOF) proves it complete.
pub const IncrementalParser = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    parsed_up_to: usize = 0,
    /// How far `buf` has been examined for a file boundary. Every byte below
    /// this has already been read once and is never read again, so a stream
    /// that carries one very large file does not rescan its growing tail on
    /// every chunk (that made a big single-file diff cost O(n^2)).
    scanned_up_to: usize = 0,
    /// Absolute index of the newline starting the last boundary found but not
    /// yet emitted, or null when none is outstanding.
    last_boundary: ?usize = null,

    pub fn deinit(self: *IncrementalParser, allocator: Allocator) void {
        self.buf.deinit(allocator);
        self.* = .{};
    }

    /// Append `chunk` and emit any files that are now complete into `out`.
    pub fn feed(
        self: *IncrementalParser,
        allocator: Allocator,
        chunk: []const u8,
        out: *std.ArrayListUnmanaged(parser.FileDiff),
    ) !void {
        try self.buf.appendSlice(allocator, chunk);
        self.scanForBoundary();

        const boundary = self.last_boundary orelse return;
        // The boundary newline is the final byte of the preceding file, so the
        // complete range ends just after it.
        const end = boundary + 1;
        self.last_boundary = null;
        if (end <= self.parsed_up_to) return;

        try emitRange(allocator, self.buf.items[self.parsed_up_to..end], out);
        self.parsed_up_to = end;
    }

    /// Scan only the bytes that arrived since the last scan, and remember the
    /// last boundary in them. Re-reads the final `FILE_BOUNDARY.len - 1` bytes
    /// of the previous scan so a separator split across two chunks still
    /// matches.
    fn scanForBoundary(self: *IncrementalParser) void {
        const overlap = FILE_BOUNDARY.len - 1;
        var from = self.scanned_up_to -| overlap;
        // Never look back into bytes already emitted as complete files.
        if (from < self.parsed_up_to) from = self.parsed_up_to;

        const hay = self.buf.items[from..];
        var off: usize = 0;
        while (std.mem.indexOfPos(u8, hay, off, FILE_BOUNDARY)) |rel| {
            self.last_boundary = from + rel;
            off = rel + 1;
        }

        self.scanned_up_to = self.buf.items.len;
    }

    /// Emit the trailing (final) file once the stream has ended.
    pub fn finish(
        self: *IncrementalParser,
        allocator: Allocator,
        out: *std.ArrayListUnmanaged(parser.FileDiff),
    ) !void {
        if (self.parsed_up_to < self.buf.items.len) {
            try emitRange(allocator, self.buf.items[self.parsed_up_to..], out);
            self.parsed_up_to = self.buf.items.len;
        }
    }
};

/// Arm the loader so the next event-loop tick starts the worker. Called from
/// `App.init`, where the App is still a by-value local and its address is not
/// yet stable enough to hand a `*DiffLoad` to a thread.
pub fn requestStart(self: *DiffLoad, mode: LoadMode) void {
    self.pending_start = true;
    self.pending_mode = mode;
}

/// Start the worker if armed. `source` is borrowed for the worker's lifetime;
/// the caller must keep it alive until the load is joined (App owns it via
/// `state.diff_source`). Safe to call every tick.
pub fn startIfRequested(self: *DiffLoad, allocator: Allocator, source: DiffSource) void {
    if (!self.pending_start) return;
    self.pending_start = false;
    start(self, allocator, source, self.pending_mode);
}

/// Begin a fresh streaming load. Any in-flight load is canceled and joined
/// first so the new worker owns the state exclusively.
pub fn start(self: *DiffLoad, allocator: Allocator, source: DiffSource, mode: LoadMode) void {
    cancelAndJoin(self, allocator);

    // Drop anything a prior (possibly mid-flight, now-canceled) load left behind
    // so the new worker owns a clean queue and parse buffer.
    freeUnconsumed(self, allocator);
    self.files.clearRetainingCapacity();
    self.iparser.deinit(allocator);

    self.ready.store(false, .release);
    self.done.store(false, .release);
    self.cancel.store(false, .release);
    self.failed.store(false, .release);
    self.consumed = 0;
    self.mode = mode;
    self.worker_allocator = allocator;
    self.worker_source = source;

    self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
        std.log.err("failed to spawn diff loader: {any}", .{err});
        self.thread = null;
        return;
    };
}

/// Cancel any in-flight worker, join it, and free everything it produced.
/// Called from `App.deinit`.
pub fn deinitState(self: *DiffLoad, allocator: Allocator) void {
    cancelAndJoin(self, allocator);
    freeUnconsumed(self, allocator);
    self.files.deinit(allocator);
    self.iparser.deinit(allocator);
}

/// Move files parsed since the last drain into `out` (allocated by the caller's
/// allocator, which must match the worker's). Returns the count moved.
pub fn drainNewFiles(
    self: *DiffLoad,
    out: *std.ArrayListUnmanaged(parser.FileDiff),
    out_allocator: Allocator,
) !usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    const start_idx = self.consumed;
    const new_count = self.files.items.len - start_idx;
    if (new_count == 0) return 0;

    try out.appendSlice(out_allocator, self.files.items[start_idx..]);
    self.consumed = self.files.items.len;
    return new_count;
}

/// Count of files parsed so far (consumed + pending). Used to size an atomic
/// snapshot for `.replace` mode.
pub fn totalFileCount(self: *DiffLoad) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.files.items.len;
}

/// Clear the ready flag after the caller has drained. Returns its prior value.
pub fn takeReady(self: *DiffLoad) bool {
    return self.ready.swap(false, .acquire);
}

/// Join the finished worker thread and reset transient load state. Must only be
/// called once the worker has set `done` and the caller has drained all files.
pub fn finishAndJoin(self: *DiffLoad, allocator: Allocator) void {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    freeUnconsumed(self, allocator);
    self.files.clearRetainingCapacity();
    self.consumed = 0;
    self.iparser.deinit(allocator);
}

// --- helpers ---------------------------------------------------------------

fn workerMain(self: *DiffLoad) void {
    diff.streamDiff(self.worker_allocator, self.worker_source, self, onChunk, shouldCancel) catch |err| {
        if (err != error.Canceled) {
            self.failed.store(true, .release);
            std.log.err("diff load failed: {any}", .{err});
        }
        self.done.store(true, .release);
        self.ready.store(true, .release);
        return;
    };

    flushTrailing(self);
    if (!self.cancel.load(.acquire)) loadUntracked(self);

    self.done.store(true, .release);
    self.ready.store(true, .release);
}

fn onChunk(self: *DiffLoad, chunk: []const u8) void {
    var produced: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer produced.deinit(self.worker_allocator);

    self.iparser.feed(self.worker_allocator, chunk, &produced) catch {
        self.failed.store(true, .release);
        return;
    };
    pushFiles(self, produced.items);
}

fn shouldCancel(self: *DiffLoad) bool {
    return self.cancel.load(.acquire);
}

fn flushTrailing(self: *DiffLoad) void {
    var produced: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer produced.deinit(self.worker_allocator);

    self.iparser.finish(self.worker_allocator, &produced) catch {
        self.failed.store(true, .release);
        return;
    };
    pushFiles(self, produced.items);
}

/// Append the synthetic diffs for untracked files (working-directory, unstaged
/// mode only), matching `getDiffWithUntracked`'s trailing pass.
fn loadUntracked(self: *DiffLoad) void {
    const include = switch (self.worker_source) {
        .working_dir => |wd| !wd.staged,
        else => false,
    };
    if (!include) return;

    const allocator = self.worker_allocator;
    const untracked = diff.getUntrackedFiles(allocator) catch return;
    defer {
        for (untracked) |p| allocator.free(p);
        allocator.free(untracked);
    }

    for (untracked) |path| {
        if (self.cancel.load(.acquire)) return;

        const text = diff.getUntrackedFileDiff(allocator, path) catch continue;
        defer allocator.free(text);
        if (text.len == 0) continue;

        const files = parser.parse(allocator, text) catch continue;
        defer allocator.free(files);
        for (files) |f| {
            var owned = f;
            owned.is_untracked = true;
            pushFiles(self, &[_]parser.FileDiff{owned});
        }
    }
}

/// Move worker-parsed files into the shared queue under the mutex and signal
/// the main loop. On OOM the file is freed rather than leaked.
fn pushFiles(self: *DiffLoad, files: []const parser.FileDiff) void {
    if (files.len == 0) return;

    self.mutex.lock();
    for (files) |f| {
        self.files.append(self.worker_allocator, f) catch {
            var owned = f;
            owned.deinit(self.worker_allocator);
        };
    }
    self.mutex.unlock();
    self.ready.store(true, .release);
}

fn cancelAndJoin(self: *DiffLoad, allocator: Allocator) void {
    if (self.thread) |t| {
        self.cancel.store(true, .release);
        t.join();
        self.thread = null;
    }
    _ = allocator;
}

fn freeUnconsumed(self: *DiffLoad, allocator: Allocator) void {
    if (self.consumed >= self.files.items.len) return;
    for (self.files.items[self.consumed..]) |f| {
        var owned = f;
        owned.deinit(allocator);
    }
}

fn emitRange(
    allocator: Allocator,
    slice: []const u8,
    out: *std.ArrayListUnmanaged(parser.FileDiff),
) !void {
    const files = try parser.parse(allocator, slice);
    defer allocator.free(files);
    for (files) |f| {
        out.append(allocator, f) catch |err| {
            var owned = f;
            owned.deinit(allocator);
            return err;
        };
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const SAMPLE_TWO_FILES =
    \\diff --git a/foo.txt b/foo.txt
    \\index 111..222 100644
    \\--- a/foo.txt
    \\+++ b/foo.txt
    \\@@ -1,2 +1,3 @@
    \\ line one
    \\+added line
    \\ line two
    \\diff --git a/bar.txt b/bar.txt
    \\index 333..444 100644
    \\--- a/bar.txt
    \\+++ b/bar.txt
    \\@@ -1 +1 @@
    \\-old
    \\+new
    \\
;

fn feedAllAtOnce(allocator: Allocator, text: []const u8, out: *std.ArrayListUnmanaged(parser.FileDiff)) !void {
    var ip = IncrementalParser{};
    defer ip.deinit(allocator);
    try ip.feed(allocator, text, out);
    try ip.finish(allocator, out);
}

fn feedByteByByte(allocator: Allocator, text: []const u8, out: *std.ArrayListUnmanaged(parser.FileDiff)) !void {
    var ip = IncrementalParser{};
    defer ip.deinit(allocator);
    for (text) |c| {
        try ip.feed(allocator, &[_]u8{c}, out);
    }
    try ip.finish(allocator, out);
}

fn freeFiles(allocator: Allocator, files: *std.ArrayListUnmanaged(parser.FileDiff)) void {
    for (files.items) |f| {
        var owned = f;
        owned.deinit(allocator);
    }
    files.deinit(allocator);
}

test "incremental parse yields all files regardless of chunking" {
    const allocator = testing.allocator;

    var whole: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &whole);
    try feedAllAtOnce(allocator, SAMPLE_TWO_FILES, &whole);

    var streamed: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &streamed);
    try feedByteByByte(allocator, SAMPLE_TWO_FILES, &streamed);

    try testing.expectEqual(@as(usize, 2), whole.items.len);
    try testing.expectEqual(whole.items.len, streamed.items.len);
    try testing.expectEqualStrings("foo.txt", streamed.items[0].new_path);
    try testing.expectEqualStrings("bar.txt", streamed.items[1].new_path);
}

test "incremental parse emits first file before second arrives" {
    const allocator = testing.allocator;

    var out: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &out);

    var ip = IncrementalParser{};
    defer ip.deinit(allocator);

    // First file plus the header of the second: only the first is complete.
    // The cut must clear the whole "\ndiff --git " separator, which ends 11
    // bytes past the start of the second header; a shorter prefix leaves the
    // separator incomplete and no file can be recognised as finished.
    const first_boundary = std.mem.indexOf(u8, SAMPLE_TWO_FILES, "diff --git a/bar").?;
    const cut = first_boundary + 12;
    try ip.feed(allocator, SAMPLE_TWO_FILES[0..cut], &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("foo.txt", out.items[0].new_path);

    // Remainder completes the second file.
    try ip.feed(allocator, SAMPLE_TWO_FILES[cut..], &out);
    try ip.finish(allocator, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "single file only emitted at finish" {
    const allocator = testing.allocator;

    const single =
        "diff --git a/only.txt b/only.txt\n" ++
        "index 1..2 100644\n" ++
        "--- a/only.txt\n" ++
        "+++ b/only.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-a\n" ++
        "+b\n";

    var out: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &out);

    var ip = IncrementalParser{};
    defer ip.deinit(allocator);

    try ip.feed(allocator, single, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len); // not complete until EOF

    try ip.finish(allocator, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("only.txt", out.items[0].new_path);
}

test "empty diff yields no files" {
    const allocator = testing.allocator;

    var out: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &out);

    try feedAllAtOnce(allocator, "", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "boundary scan does not revisit bytes it has already examined" {
    const allocator = testing.allocator;

    var out: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &out);

    var ip = IncrementalParser{};
    defer ip.deinit(allocator);

    // One huge file arrives in many chunks, so no boundary ever shows up. The
    // scan cursor must still reach the buffer end on every feed; if it lags,
    // the next feed rescans the whole grown tail and the load turns O(n^2).
    try ip.feed(allocator, "diff --git a/big.txt b/big.txt\n@@ -1 +1 @@\n", &out);
    var chunk: usize = 0;
    while (chunk < 64) : (chunk += 1) {
        try ip.feed(allocator, "+aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", &out);
        try testing.expectEqual(ip.buf.items.len, ip.scanned_up_to);
    }
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "boundary split across a chunk edge is still found" {
    const allocator = testing.allocator;

    var out: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &out);

    var ip = IncrementalParser{};
    defer ip.deinit(allocator);

    // Split the stream in the middle of the "\ndiff --git " separator. A
    // forward scan that forgets to overlap the previous chunk loses this file.
    const cut = std.mem.indexOf(u8, SAMPLE_TWO_FILES, "diff --git a/bar").? + 5;
    try ip.feed(allocator, SAMPLE_TWO_FILES[0..cut], &out);
    try ip.feed(allocator, SAMPLE_TWO_FILES[cut..], &out);
    try ip.finish(allocator, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("foo.txt", out.items[0].new_path);
    try testing.expectEqualStrings("bar.txt", out.items[1].new_path);
}

test "DiffLoad streams the working-dir diff end to end" {
    const allocator = testing.allocator;

    var dl = DiffLoad{};
    defer deinitState(&dl, allocator); // joins the worker, frees queue + parser

    start(&dl, allocator, .{ .working_dir = .{ .staged = false } }, .incremental);

    // Structs drained here are freed via `out`; deinitState only frees the
    // (empty) unconsumed tail, so ownership never overlaps.
    var out: std.ArrayListUnmanaged(parser.FileDiff) = .{};
    defer freeFiles(allocator, &out);

    var spins: usize = 0;
    while (!dl.isDone() and spins < 5000) : (spins += 1) {
        _ = drainNewFiles(&dl, &out, allocator) catch {};
        std.Thread.sleep(std.time.ns_per_ms);
    }
    _ = drainNewFiles(&dl, &out, allocator) catch {};

    // Output depends on the repo's working tree; the point is the full
    // spawn → stream → parse → drain → join path runs without leaking.
    try testing.expect(dl.isDone());
}
