//! The last `capacity` parsed diffs, keyed by DiffKey. Main thread only: no
//! locking. Owns every stored `[]FileDiff` (allocated with `allocator`) and
//! frees it on eviction, on replacement, and in `deinit`. Ownership moves in
//! with `put` and out with `take`, because the App installs taken files as its
//! diff and frees them on the next swap.

const std = @import("std");
const parser = @import("../../git/parser.zig");
const types = @import("../db/types.zig");

const Allocator = std.mem.Allocator;
const DiffKey = types.DiffKey;

pub const ParsedLru = struct {
    allocator: Allocator,
    entries: [capacity]?Entry = @splat(null),
    tick: u64 = 0,

    pub const capacity = 8;

    const Entry = struct { key: DiffKey, files: []parser.FileDiff, last_put: u64 };

    pub fn init(allocator: Allocator) ParsedLru {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ParsedLru) void {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| freeFiles(self.allocator, entry.files);
            slot.* = null;
        }
    }

    /// Remove and return the files for `key`; the caller now owns them.
    pub fn take(self: *ParsedLru, key: DiffKey) ?[]parser.FileDiff {
        const slot = self.find(key) orelse return null;
        const files = slot.*.?.files;
        slot.* = null;
        return files;
    }

    /// Store `files` (ownership moves in). Replaces and frees an existing entry
    /// for `key`; otherwise fills a free slot or evicts (and frees) the least
    /// recently put entry. Never allocates.
    pub fn put(self: *ParsedLru, key: DiffKey, files: []parser.FileDiff) void {
        self.tick += 1;
        const slot = self.find(key) orelse self.freeSlot() orelse self.oldestSlot();
        if (slot.*) |old| {
            if (old.files.ptr != files.ptr) freeFiles(self.allocator, old.files);
        }
        slot.* = .{ .key = key, .files = files, .last_put = self.tick };
    }

    pub fn contains(self: *const ParsedLru, key: DiffKey) bool {
        for (self.entries) |slot| {
            const entry = slot orelse continue;
            if (keyEql(entry.key, key)) return true;
        }
        return false;
    }

    fn find(self: *ParsedLru, key: DiffKey) ?*?Entry {
        for (&self.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (keyEql(entry.key, key)) return slot;
        }
        return null;
    }

    fn freeSlot(self: *ParsedLru) ?*?Entry {
        for (&self.entries) |*slot| {
            if (slot.* == null) return slot;
        }
        return null;
    }

    /// Only called when every slot is full.
    fn oldestSlot(self: *ParsedLru) *?Entry {
        var oldest = &self.entries[0];
        for (self.entries[1..]) |*slot| {
            if (slot.*.?.last_put < oldest.*.?.last_put) oldest = slot;
        }
        return oldest;
    }
};

fn keyEql(a: DiffKey, b: DiffKey) bool {
    return std.mem.eql(u8, &a.merge_base_oid, &b.merge_base_oid) and std.mem.eql(u8, &a.head_oid, &b.head_oid);
}

fn freeFiles(allocator: Allocator, files: []parser.FileDiff) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const sample_diff =
    \\diff --git a/a.txt b/a.txt
    \\index 1111111..2222222 100644
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,2 +1,2 @@
    \\ keep
    \\-old
    \\+new
    \\diff --git a/b.txt b/b.txt
    \\index 3333333..4444444 100644
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -1 +1 @@
    \\-x
    \\+y
    \\
;

fn testKey(comptime c: u8) DiffKey {
    return .{ .merge_base_oid = .{c} ** 40, .head_oid = .{'f'} ** 40 };
}

fn parsedSample() ![]parser.FileDiff {
    return parser.parse(testing.allocator, sample_diff);
}

fn freeTaken(files: []parser.FileDiff) void {
    for (files) |*file| file.deinit(testing.allocator);
    testing.allocator.free(files);
}

const keys = [_]DiffKey{
    testKey('0'), testKey('1'), testKey('2'), testKey('3'), testKey('4'),
    testKey('5'), testKey('6'), testKey('7'), testKey('8'),
};

test "take returns null for an unknown key" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    try testing.expectEqual(@as(?[]parser.FileDiff, null), lru.take(testKey('a')));
}

test "put then take returns the same files and removes the entry" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    const files = try parsedSample();
    try testing.expectEqual(@as(usize, 2), files.len);
    lru.put(keys[0], files);
    try testing.expect(lru.contains(keys[0]));

    const taken = lru.take(keys[0]).?;
    defer freeTaken(taken);
    try testing.expectEqual(files.ptr, taken.ptr);
    try testing.expect(!lru.contains(keys[0]));
    try testing.expectEqual(@as(?[]parser.FileDiff, null), lru.take(keys[0]));
}

test "putting a ninth key evicts and frees the least recently put" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    for (keys) |key| lru.put(key, try parsedSample());
    try testing.expect(!lru.contains(keys[0]));
    for (keys[1..]) |key| try testing.expect(lru.contains(key));
}

test "put on an existing key frees the old files" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    lru.put(keys[0], try parsedSample());
    const replacement = try parsedSample();
    lru.put(keys[0], replacement);

    const taken = lru.take(keys[0]).?;
    defer freeTaken(taken);
    try testing.expectEqual(replacement.ptr, taken.ptr);
}

test "putting the same files back under their key keeps them alive" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    const files = try parsedSample();
    lru.put(keys[0], files);
    lru.put(keys[0], files);

    const taken = lru.take(keys[0]).?;
    defer freeTaken(taken);
    try testing.expectEqual(files.ptr, taken.ptr);
    try testing.expectEqualStrings("a.txt", taken[0].new_path);
}

test "re-putting an existing key makes it most recent" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    for (keys[0..8]) |key| lru.put(key, try parsedSample());
    lru.put(keys[0], try parsedSample());
    lru.put(keys[8], try parsedSample());
    try testing.expect(lru.contains(keys[0]));
    try testing.expect(!lru.contains(keys[1]));
}

test "take refreshes nothing: a taken key that is put back is most recent" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    for (keys[0..8]) |key| lru.put(key, try parsedSample());
    const taken = lru.take(keys[0]).?;
    lru.put(keys[0], taken);
    lru.put(keys[8], try parsedSample());
    try testing.expect(lru.contains(keys[0]));
    try testing.expect(!lru.contains(keys[1]));
}

test "a taken slot is reused before anything is evicted" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    for (keys[0..8]) |key| lru.put(key, try parsedSample());
    freeTaken(lru.take(keys[3]).?);
    lru.put(keys[8], try parsedSample());
    for ([_]usize{ 0, 1, 2, 4, 5, 6, 7, 8 }) |i| try testing.expect(lru.contains(keys[i]));
}

test "an empty file list is stored and returned" {
    var lru: ParsedLru = .init(testing.allocator);
    defer lru.deinit();
    const empty = try testing.allocator.alloc(parser.FileDiff, 0);
    lru.put(keys[0], empty);
    const taken = lru.take(keys[0]).?;
    defer testing.allocator.free(taken);
    try testing.expectEqual(@as(usize, 0), taken.len);
}

test "deinit frees every stored entry" {
    var lru: ParsedLru = .init(testing.allocator);
    for (keys[0..8]) |key| lru.put(key, try parsedSample());
    lru.deinit();
}
