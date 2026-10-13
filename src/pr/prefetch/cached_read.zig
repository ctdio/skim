//! Reads a cached PR diff out of the DB and parses it on its own thread, so
//! a flip to a large PR never stalls the UI on SQLite or the parser. One
//! read per thread, on its own connection (the UI connection is not shared
//! across threads). The UI thread polls `isDone`, then `finish` hands over
//! the parsed files.

const std = @import("std");
const parser = @import("../../git/parser.zig");
const store_mod = @import("../db/store.zig");
const types = @import("../db/types.zig");

const Allocator = std.mem.Allocator;
const DiffKey = types.DiffKey;

pub const Params = struct {
    /// Must be thread-safe: the parsed files are allocated on the reader's
    /// thread and freed by the App.
    allocator: Allocator,
    db_path: []const u8,
    repo_id: i64,
    key: DiffKey,
    /// The PR whose diff this is.
    number: u32,
    /// Unix seconds; bumps the row's last_used_at.
    now: i64,
};

pub const Outcome = union(enum) {
    /// Owned by the caller.
    files: []parser.FileDiff,
    /// The row was evicted after the flip planned the read.
    missing,
    failed: anyerror,
};

pub const CachedRead = struct {
    allocator: Allocator,
    db_path: []u8,
    repo_id: i64,
    key: DiffKey,
    number: u32,
    now: i64,
    thread: std.Thread,
    done: std.atomic.Value(bool) = .init(false),
    /// Written by the reader before it sets `done`.
    outcome: Outcome = .missing,
};

/// Start reading `params.key` on a new thread. The caller must `finish` it.
pub fn start(params: Params) !*CachedRead {
    const read = try params.allocator.create(CachedRead);
    errdefer params.allocator.destroy(read);
    const db_path = try params.allocator.dupe(u8, params.db_path);
    errdefer params.allocator.free(db_path);
    read.* = .{
        .allocator = params.allocator,
        .db_path = db_path,
        .repo_id = params.repo_id,
        .key = params.key,
        .number = params.number,
        .now = params.now,
        .thread = undefined,
    };
    read.thread = try std.Thread.spawn(.{}, run, .{read});
    return read;
}

pub fn isDone(read: *const CachedRead) bool {
    return read.done.load(.acquire);
}

/// Wait for the reader, free it, and return what it read.
pub fn finish(read: *CachedRead) Outcome {
    read.thread.join();
    const outcome = read.outcome;
    read.allocator.free(read.db_path);
    read.allocator.destroy(read);
    return outcome;
}

fn run(read: *CachedRead) void {
    read.outcome = readAndParse(read) catch |err| .{ .failed = err };
    read.done.store(true, .release);
}

fn readAndParse(read: *const CachedRead) !Outcome {
    var db = try store_mod.Store.open(read.allocator, read.db_path);
    defer db.close();
    const bytes = (try db.getDiff(read.allocator, .{ .repo_id = read.repo_id, .key = read.key, .now = read.now })) orelse return .missing;
    defer read.allocator.free(bytes);
    return .{ .files = try parser.parse(read.allocator, bytes) };
}
