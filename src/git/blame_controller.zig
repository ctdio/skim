//! Controller for the git-blame gutter data. Owns the blame sub-state
//! (`Blame`): the file->blame cache, the in-flight request set, and the
//! thread-safe queue of completed async fetches. App keeps only thin
//! forwarders (toggle, viewport prefetch, per-frame poll) that hand this
//! sub-state to the free functions below.

const std = @import("std");
const Allocator = std.mem.Allocator;

const blame = @import("blame.zig");
const parser = @import("parser.zig");
const line_map = @import("../line_map.zig");

/// A completed async blame fetch handed from a worker thread back to the main
/// loop. `path` and the ArrayList backing store use c_allocator so they survive
/// the thread boundary independent of the App allocator.
const PendingBlameResult = struct {
    path: []const u8, // Owned by c_allocator
    blame_data: ?blame.BlameData,
    duration_ns: u64,
};

/// Context passed to a detached blame worker thread.
const BlameFetchContext = struct {
    controller: *Blame,
    path: []const u8, // Owned by c_allocator

    pub fn deinit(self: *BlameFetchContext) void {
        std.heap.c_allocator.free(self.path);
        std.heap.c_allocator.destroy(self);
    }
};

/// Viewport description needed to decide which files to prefetch blame for.
pub const ViewportParams = struct {
    show_blame: bool,
    pager_mode: bool,
    files: []parser.FileDiff,
    viewport_height: usize,
    global_scroll_offset: usize,
    line_map: *const line_map.LineMap,
};

/// Blame sub-state: the file->blame cache plus the async fetch machinery.
pub const Blame = struct {
    allocator: Allocator,
    cache: std.StringHashMap(blame.BlameData), // file_path -> blame data
    pending_results: std.ArrayListUnmanaged(PendingBlameResult),
    pending_mutex: std.Thread.Mutex,
    pending_ready: std.atomic.Value(bool),
    requests_in_flight: std.StringHashMapUnmanaged(void),

    pub fn init(allocator: Allocator) Blame {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(blame.BlameData).init(allocator),
            .pending_results = .{},
            .pending_mutex = .{},
            .pending_ready = std.atomic.Value(bool).init(false),
            .requests_in_flight = .{},
        };
    }

    pub fn deinit(self: *Blame) void {
        var cache_iter = self.cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.deinit();

        drainPending(self);
        self.pending_results.deinit(std.heap.c_allocator);

        var in_flight_iter = self.requests_in_flight.keyIterator();
        while (in_flight_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.requests_in_flight.deinit(self.allocator);
    }

    /// True while an async blame fetch is queued or in flight (keeps the event
    /// loop polling instead of blocking).
    pub fn isActive(self: *Blame) bool {
        return self.pending_ready.load(.acquire) or self.requests_in_flight.count() > 0;
    }

    /// Get blame info for a specific file line (returns null if not available).
    pub fn getForLine(self: *const Blame, file_path: []const u8, lineno: u32) ?*const blame.BlameLine {
        const data = self.cache.get(file_path) orelse return null;
        return data.getLine(lineno);
    }
};

/// Submit async blame requests for files near the current viewport.
pub fn requestBlameForViewport(self: *Blame, vp: ViewportParams) void {
    if (!vp.show_blame or vp.pager_mode or vp.files.len == 0) return;

    const viewport_height = @max(vp.viewport_height, 1);
    const scroll_line = vp.global_scroll_offset;
    const visible_end = scroll_line + viewport_height;
    const start_file_idx = vp.line_map.getFileIndexForLine(scroll_line) orelse 0;
    const buffer_lines = viewport_height;
    const max_files_per_pass: usize = 2;

    var submitted: usize = 0;
    var file_idx = start_file_idx;
    while (file_idx < vp.files.len) : (file_idx += 1) {
        if (submitted >= max_files_per_pass) break;

        if (vp.line_map.getFileHeaderLine(file_idx)) |file_header_line| {
            if (file_header_line > visible_end + buffer_lines) break;
        }

        const file = &vp.files[file_idx];
        if (file.is_untracked) continue;

        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        if (self.cache.contains(file_path) or self.requests_in_flight.contains(file_path)) continue;

        startAsyncBlameFetch(self, file_path) catch continue;
        submitted += 1;
    }
}

/// Drain completed async blame fetches into the cache. Returns true when any
/// results were consumed (so the caller can flag a re-render).
pub fn pollPending(self: *Blame, profile_render: bool) bool {
    if (!self.pending_ready.load(.acquire)) return false;

    self.pending_mutex.lock();
    var results = self.pending_results;
    self.pending_results = .{};
    self.pending_mutex.unlock();
    self.pending_ready.store(false, .release);

    defer results.deinit(std.heap.c_allocator);

    for (results.items) |result| {
        if (self.requests_in_flight.fetchRemove(result.path)) |entry| {
            self.allocator.free(entry.key);
        }

        if (result.blame_data) |blame_data| {
            if (self.cache.contains(result.path)) {
                var data = blame_data;
                data.deinit();
                std.heap.c_allocator.free(result.path);
                continue;
            }

            const owned_key = self.allocator.dupe(u8, result.path) catch {
                var data = blame_data;
                data.deinit();
                std.heap.c_allocator.free(result.path);
                continue;
            };

            self.cache.put(owned_key, blame_data) catch {
                self.allocator.free(owned_key);
                var data = blame_data;
                data.deinit();
                std.heap.c_allocator.free(result.path);
                continue;
            };

            if (profile_render) {
                std.log.scoped(.profile_blame).debug(
                    "loaded blame: path={s} duration_ns={d} cached={d} in_flight={d}",
                    .{ result.path, result.duration_ns, self.cache.count(), self.requests_in_flight.count() },
                );
            }
        }

        std.heap.c_allocator.free(result.path);
    }
    return true;
}

fn startAsyncBlameFetch(self: *Blame, file_path: []const u8) !void {
    const key = try self.allocator.dupe(u8, file_path);
    errdefer self.allocator.free(key);

    try self.requests_in_flight.put(self.allocator, key, {});
    errdefer if (self.requests_in_flight.fetchRemove(file_path)) |entry| {
        self.allocator.free(entry.key);
    };

    const ctx = try std.heap.c_allocator.create(BlameFetchContext);
    errdefer std.heap.c_allocator.destroy(ctx);

    ctx.* = .{
        .controller = self,
        .path = std.heap.c_allocator.dupe(u8, file_path) catch {
            if (self.requests_in_flight.fetchRemove(file_path)) |entry| {
                self.allocator.free(entry.key);
            }
            return error.OutOfMemory;
        },
    };
    errdefer ctx.deinit();

    const thread = try std.Thread.spawn(.{}, blameFetchWorker, .{ctx});
    thread.detach();
}

fn blameFetchWorker(ctx: *BlameFetchContext) void {
    var timer = std.time.Timer.start() catch null;
    const blame_data = blame.getBlame(std.heap.c_allocator, ctx.path, null) catch null;
    const duration_ns: u64 = if (timer) |*t| t.read() else 0;

    const result = PendingBlameResult{
        .path = ctx.path,
        .blame_data = blame_data,
        .duration_ns = duration_ns,
    };

    const controller = ctx.controller;
    controller.pending_mutex.lock();
    controller.pending_results.append(std.heap.c_allocator, result) catch {
        controller.pending_mutex.unlock();
        if (result.blame_data) |data| {
            var owned_data = data;
            owned_data.deinit();
        }
        ctx.deinit();
        return;
    };
    controller.pending_mutex.unlock();
    controller.pending_ready.store(true, .release);

    std.heap.c_allocator.destroy(ctx);
}

fn drainPending(self: *Blame) void {
    self.pending_mutex.lock();
    defer self.pending_mutex.unlock();

    for (self.pending_results.items) |result| {
        if (result.blame_data) |data| {
            var owned_data = data;
            owned_data.deinit();
        }
        std.heap.c_allocator.free(result.path);
    }
    self.pending_results.clearRetainingCapacity();
    self.pending_ready.store(false, .release);
}
