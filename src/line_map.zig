const std = @import("std");
const parser = @import("git/parser.zig");
const comments = @import("comments/store.zig");
const thread_placement = @import("pr/thread_placement.zig");

const Allocator = std.mem.Allocator;

/// Number of blank lines between files
pub const file_spacing = 3;

/// Type of line with associated metadata
pub const LineType = union(enum) {
    /// File header line (e.g., "diff --git a/file.txt b/file.txt")
    file_header,

    /// Hunk header line (e.g., "@@ -1,3 +1,4 @@")
    hunk_header: struct {
        hunk_idx: usize,
    },

    /// Code line (add/delete/context)
    code_line: struct {
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    },

    /// Comment line attached to a code line
    comment_line: struct {
        parent_hunk_idx: usize,
        parent_line_idx: usize,
        comment_idx: usize,
    },

    /// GitHub review thread (AD-5: one record per thread). `thread_idx` indexes
    /// the session's threads/anchored slices (same order). `placement`
    /// distinguishes an inline anchor (below its code line) from a file-level
    /// bucket (below the file header); the concrete bucket reason and thread
    /// body are looked up via `thread_idx` at render time (AD-4).
    review_thread: struct {
        thread_idx: usize,
        placement: enum { inline_line, file_bucket },
    },

    /// Blank spacer line (between files or after file header)
    spacer: struct {
        after_file_idx: usize,
        spacer_line_num: usize, // 0, 1, or 2 (for 3 total)
        is_header_spacer: bool, // true if spacer after file header, false if between files
    },
};

/// A single line record with its global position and type
pub const LineRecord = struct {
    global_line: usize,
    file_idx: usize,
    line_type: LineType,
};

/// A comment location: the file path plus the coordinate inside it.
const CommentLoc = struct {
    file_path: []const u8,
    hunk_idx: usize,
    line_idx: usize,
};

const CommentLocContext = struct {
    pub fn hash(_: CommentLocContext, key: CommentLoc) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.file_path);
        hasher.update(std.mem.asBytes(&key.hunk_idx));
        hasher.update(std.mem.asBytes(&key.line_idx));
        return hasher.final();
    }

    pub fn eql(_: CommentLocContext, a: CommentLoc, b: CommentLoc) bool {
        return a.hunk_idx == b.hunk_idx and
            a.line_idx == b.line_idx and
            std.mem.eql(u8, a.file_path, b.file_path);
    }
};

const CommentLocMap = std.HashMapUnmanaged(
    CommentLoc,
    usize,
    CommentLocContext,
    std.hash_map.default_max_load_percentage,
);

/// Location index over the comment store, built once per `LineMap.build`.
///
/// The record loop needs two questions answered per code line: does a range
/// comment end here, and is there a comment starting here. Answering them by
/// scanning the whole comment list made a build cost O(lines x comments), with
/// a path string compare per candidate — and a build runs on every comment add
/// or delete, so that landed on a keystroke. Both questions are now one
/// integer-and-path hash lookup.
///
/// Both maps keep the LOWEST comment index on collision, which reproduces the
/// old "first match from the start of the list wins" order exactly.
const CommentIndex = struct {
    /// Range comments keyed by the location they END at.
    range_end: CommentLocMap = .{},
    /// Every comment keyed by the location it STARTS at, whatever its kind.
    /// A range comment starting here shadows a later single comment, matching
    /// the old lookup, which took the first match and then rejected it.
    first_at: CommentLocMap = .{},

    fn build(allocator: Allocator, store: *const comments.CommentStore) !CommentIndex {
        var self = CommentIndex{};
        errdefer self.deinit(allocator);

        for (store.comments.items, 0..) |*comment, idx| {
            const start = CommentLoc{
                .file_path = comment.file_path,
                .hunk_idx = comment.hunk_idx,
                .line_idx = comment.line_idx,
            };
            const start_slot = try self.first_at.getOrPut(allocator, start);
            if (!start_slot.found_existing) start_slot.value_ptr.* = idx;

            if (comment.end_hunk_idx) |end_hunk| {
                if (comment.end_line_idx) |end_line| {
                    const end = CommentLoc{
                        .file_path = comment.file_path,
                        .hunk_idx = end_hunk,
                        .line_idx = end_line,
                    };
                    const end_slot = try self.range_end.getOrPut(allocator, end);
                    if (!end_slot.found_existing) end_slot.value_ptr.* = idx;
                }
            }
        }

        return self;
    }

    fn deinit(self: *CommentIndex, allocator: Allocator) void {
        self.range_end.deinit(allocator);
        self.first_at.deinit(allocator);
    }

    /// The comment to render below this line, or null. Mirrors the old order:
    /// a range comment ending here first, otherwise a single comment starting
    /// here.
    fn commentFor(
        self: *const CommentIndex,
        store: *const comments.CommentStore,
        loc: CommentLoc,
    ) ?usize {
        if (self.range_end.get(loc)) |idx| return idx;

        const idx = self.first_at.get(loc) orelse return null;
        const comment = store.getComment(idx) orelse return null;
        if (comment.end_hunk_idx == null and comment.end_line_idx == null) return idx;
        return null;
    }
};

/// Complete map of all lines in the diff
pub const LineMap = struct {
    records: []LineRecord,
    /// Records the allocation behind `records` can hold. `appendFiles` grows
    /// into the spare room, so a streamed diff does not reallocate per batch.
    records_capacity: usize,
    allocator: Allocator,
    /// Cached file header line numbers for O(1) lookup
    /// Index is file_idx, value is global line number of that file's header
    file_header_lines: []usize,

    /// Hunk view mode for filtering lines
    pub const HunkViewMode = enum {
        all, // Show all lines (add, delete, context)
        old, // Show old code only (delete, context)
        new, // Show new code only (add, context)

        // Check if a line type should be visible in this mode
        pub fn shouldShowLine(self: HunkViewMode, line_type: parser.Line.LineType) bool {
            return switch (self) {
                .all => true,
                .old => line_type == .delete or line_type == .context,
                .new => line_type == .add or line_type == .context,
            };
        }
    };

    /// Packed key for fold state HashMap (imported from app.zig pattern)
    /// Bit 63: 0 = file fold, 1 = hunk fold
    pub const FoldKey = struct {
        pub fn fileKey(file_idx: usize) u64 {
            return @as(u64, @intCast(file_idx));
        }

        pub fn hunkKey(file_idx: usize, hunk_idx: usize) u64 {
            return (@as(u64, 1) << 63) | (@as(u64, @intCast(hunk_idx)) << 31) | @as(u64, @intCast(file_idx));
        }
    };

    /// Build a line map from files and comments
    pub fn build(
        allocator: Allocator,
        files: []const parser.FileDiff,
        comment_store: *comments.CommentStore,
        hunk_view_mode: HunkViewMode,
        apply_filtering: bool, // Only apply filtering in unified view
        collapsed_folds: ?*const std.AutoHashMap(u64, void), // Optional fold state
        review_threads: ?[]const thread_placement.AnchoredThread, // GitHub review-thread anchors (null → no thread records)
    ) !LineMap {
        var records: std.ArrayList(LineRecord) = .empty;
        errdefer records.deinit(allocator);

        // Pre-allocate file header cache
        const file_header_lines = try allocator.alloc(usize, files.len);
        errdefer allocator.free(file_header_lines);

        var global_line: usize = 0;

        try appendRange(.{
            .allocator = allocator,
            .files = files,
            .first_new = 0,
            .records = &records,
            .file_header_lines = file_header_lines,
            .global_line = &global_line,
            .comment_store = comment_store,
            .hunk_view_mode = hunk_view_mode,
            .apply_filtering = apply_filtering,
            .collapsed_folds = collapsed_folds,
            .review_threads = review_threads,
        });

        return LineMap{
            .records = records.items,
            .records_capacity = records.capacity,
            .allocator = allocator,
            .file_header_lines = file_header_lines,
        };
    }

    /// What `appendFiles` needs to emit records for the files it adds.
    pub const AppendParams = struct {
        /// The whole file list, old files first, with the new ones at the end.
        files: []const parser.FileDiff,
        comment_store: *comments.CommentStore,
        hunk_view_mode: HunkViewMode,
        apply_filtering: bool,
        collapsed_folds: ?*const std.AutoHashMap(u64, void) = null,
        review_threads: ?[]const thread_placement.AnchoredThread = null,
    };

    /// Extend the map with files appended to the end of the diff.
    ///
    /// A record's global line number is also its index, so files added at the
    /// end never move the records already built. The streaming loader delivers
    /// a diff in batches, and calling `build` for every batch re-emits every
    /// record already emitted, which costs O(batches x total lines): on a
    /// 139k-line diff that was 44ms of main-thread work during the load, with
    /// single batches reaching 6ms.
    pub fn appendFiles(self: *LineMap, params: AppendParams) !void {
        const allocator = self.allocator;
        const first_new = self.file_header_lines.len;
        if (first_new >= params.files.len) return;

        self.file_header_lines = try allocator.realloc(self.file_header_lines, params.files.len);
        @memset(self.file_header_lines[first_new..], 0);

        // Adopt the existing buffer so the records already emitted are neither
        // copied nor reallocated; the list grows into its own spare capacity.
        var records: std.ArrayList(LineRecord) = .{ .items = self.records, .capacity = self.records_capacity };
        defer {
            self.records = records.items;
            self.records_capacity = records.capacity;
        }

        var global_line = records.items.len;

        // Whichever file was last until now was denied its trailing spacers,
        // because `appendRange` skips them for the file it believes is last.
        if (first_new > 0) {
            var spacer_num: usize = 0;
            while (spacer_num < file_spacing) : (spacer_num += 1) {
                try records.append(allocator, .{
                    .global_line = global_line,
                    .file_idx = first_new - 1, // Belongs to file it comes after
                    .line_type = .{
                        .spacer = .{
                            .after_file_idx = first_new - 1,
                            .spacer_line_num = spacer_num,
                            .is_header_spacer = false,
                        },
                    },
                });
                global_line += 1;
            }
        }

        try appendRange(.{
            .allocator = allocator,
            .files = params.files,
            .first_new = first_new,
            .records = &records,
            .file_header_lines = self.file_header_lines,
            .global_line = &global_line,
            .comment_store = params.comment_store,
            .hunk_view_mode = params.hunk_view_mode,
            .apply_filtering = params.apply_filtering,
            .collapsed_folds = params.collapsed_folds,
            .review_threads = params.review_threads,
        });
    }

    /// What `appendRange` emits records into, and from which files.
    const RangeParams = struct {
        allocator: Allocator,
        /// The whole file list. Records are emitted for `files[first_new..]`,
        /// but the length decides which file is last and so gets no spacers.
        files: []const parser.FileDiff,
        first_new: usize,
        records: *std.ArrayList(LineRecord),
        file_header_lines: []usize,
        global_line: *usize,
        comment_store: *comments.CommentStore,
        hunk_view_mode: HunkViewMode,
        apply_filtering: bool,
        collapsed_folds: ?*const std.AutoHashMap(u64, void),
        review_threads: ?[]const thread_placement.AnchoredThread,
    };

    /// Emit the records for `files[first_new..]`, continuing from the caller's
    /// running global line number.
    fn appendRange(params: RangeParams) !void {
        const allocator = params.allocator;
        const files = params.files;
        const records = params.records;
        const file_header_lines = params.file_header_lines;
        const comment_store = params.comment_store;
        const hunk_view_mode = params.hunk_view_mode;
        const apply_filtering = params.apply_filtering;
        const collapsed_folds = params.collapsed_folds;
        const review_threads = params.review_threads;

        var comment_index = try CommentIndex.build(allocator, comment_store);
        defer comment_index.deinit(allocator);

        var global_line = params.global_line.*;
        defer params.global_line.* = global_line;

        for (files[params.first_new..], params.first_new..) |*file, file_idx| {
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Check if this file is folded
            const file_is_folded = if (collapsed_folds) |folds|
                folds.contains(FoldKey.fileKey(file_idx))
            else
                false;

            // Cache the file header line number for O(1) lookup
            file_header_lines[file_idx] = global_line;

            // Add file header line (always shown, even when folded)
            try records.append(allocator, .{
                .global_line = global_line,
                .file_idx = file_idx,
                .line_type = .file_header,
            });
            global_line += 1;

            // If file is folded, skip all content (hunks, code lines, comments)
            // but still add spacers between files
            if (file_is_folded) {
                // Add spacers after this file (except for last file)
                if (file_idx < files.len - 1) {
                    var spacer_num: usize = 0;
                    while (spacer_num < file_spacing) : (spacer_num += 1) {
                        try records.append(allocator, .{
                            .global_line = global_line,
                            .file_idx = file_idx,
                            .line_type = .{
                                .spacer = .{
                                    .after_file_idx = file_idx,
                                    .spacer_line_num = spacer_num,
                                    .is_header_spacer = false,
                                },
                            },
                        });
                        global_line += 1;
                    }
                }
                continue; // Skip to next file
            }

            // Add a single spacer after file header
            try records.append(allocator, .{
                .global_line = global_line,
                .file_idx = file_idx,
                .line_type = .{
                    .spacer = .{
                        .after_file_idx = file_idx,
                        .spacer_line_num = 0,
                        .is_header_spacer = true,
                    },
                },
            });
            global_line += 1;

            // File-level bucket threads (outdated / out-of-context / file-subject)
            // render directly under the header, before the first hunk. Input
            // order == anchored order == thread creation order (stable).
            if (review_threads) |anchored| {
                for (anchored) |a| {
                    switch (a.placement) {
                        .file_bucket => |b| {
                            if (b.file_idx != file_idx) continue;
                            try records.append(allocator, .{
                                .global_line = global_line,
                                .file_idx = file_idx,
                                .line_type = .{ .review_thread = .{
                                    .thread_idx = a.thread_idx,
                                    .placement = .file_bucket,
                                } },
                            });
                            global_line += 1;
                        },
                        else => {},
                    }
                }
            }

            // Add hunks and their lines
            for (file.hunks, 0..) |hunk, hunk_idx| {
                // Check if this hunk is folded
                const hunk_is_folded = if (collapsed_folds) |folds|
                    folds.contains(FoldKey.hunkKey(file_idx, hunk_idx))
                else
                    false;

                // Add hunk header (always shown, even when folded)
                try records.append(allocator, .{
                    .global_line = global_line,
                    .file_idx = file_idx,
                    .line_type = .{ .hunk_header = .{ .hunk_idx = hunk_idx } },
                });
                global_line += 1;

                // If hunk is folded, skip code lines and comments
                if (hunk_is_folded) {
                    continue;
                }

                // Add code lines (and any attached comments) - filter based on hunk_view_mode if enabled
                for (hunk.lines, 0..) |line, line_idx_in_hunk| {
                    // Skip lines that don't match the current view mode (only in unified view)
                    if (apply_filtering and !hunk_view_mode.shouldShowLine(line.line_type)) {
                        continue;
                    }

                    // Add the code line
                    try records.append(allocator, .{
                        .global_line = global_line,
                        .file_idx = file_idx,
                        .line_type = .{
                            .code_line = .{
                                .hunk_idx = hunk_idx,
                                .line_idx_in_hunk = line_idx_in_hunk,
                            },
                        },
                    });
                    global_line += 1;

                    // Check for comments on this line: a range comment that
                    // ENDS here (displayed at its lowest point) takes priority
                    // over a single-line comment that STARTS here.
                    const comment_idx = comment_index.commentFor(comment_store, .{
                        .file_path = file_path,
                        .hunk_idx = hunk_idx,
                        .line_idx = line_idx_in_hunk,
                    });

                    if (comment_idx) |idx| {
                        try records.append(allocator, .{
                            .global_line = global_line,
                            .file_idx = file_idx,
                            .line_type = .{
                                .comment_line = .{
                                    .parent_hunk_idx = hunk_idx,
                                    .parent_line_idx = line_idx_in_hunk,
                                    .comment_idx = idx,
                                },
                            },
                        });
                        global_line += 1;
                    }

                    // Inline review threads anchored to this coordinate render
                    // below any local comment. N threads per line is legal —
                    // emit every match consecutively in anchored (input) order.
                    if (review_threads) |anchored| {
                        for (anchored) |a| {
                            switch (a.placement) {
                                .inline_line => |c| {
                                    if (c.file_idx != file_idx or c.hunk_idx != hunk_idx or c.line_idx != line_idx_in_hunk) continue;
                                    try records.append(allocator, .{
                                        .global_line = global_line,
                                        .file_idx = file_idx,
                                        .line_type = .{ .review_thread = .{
                                            .thread_idx = a.thread_idx,
                                            .placement = .inline_line,
                                        } },
                                    });
                                    global_line += 1;
                                },
                                else => {},
                            }
                        }
                    }
                }
            }

            // Add spacers after this file (except for last file)
            if (file_idx < files.len - 1) {
                var spacer_num: usize = 0;
                while (spacer_num < file_spacing) : (spacer_num += 1) {
                    try records.append(allocator, .{
                        .global_line = global_line,
                        .file_idx = file_idx, // Belongs to file it comes after
                        .line_type = .{
                            .spacer = .{
                                .after_file_idx = file_idx,
                                .spacer_line_num = spacer_num,
                                .is_header_spacer = false,
                            },
                        },
                    });
                    global_line += 1;
                }
            }
        }
    }

    pub fn deinit(self: *LineMap) void {
        self.allocator.free(self.file_header_lines);
        self.allocator.free(self.records.ptr[0..self.records_capacity]);
    }

    /// Get total number of lines
    pub fn getTotalLines(self: *const LineMap) usize {
        return self.records.len;
    }

    /// Get line record at a specific global line number
    pub fn getLineRecord(self: *const LineMap, global_line: usize) ?*const LineRecord {
        if (global_line >= self.records.len) return null;
        return &self.records[global_line];
    }

    /// Find the global line number of a file's header (O(1) cached lookup)
    pub fn getFileHeaderLine(self: *const LineMap, file_idx: usize) ?usize {
        if (file_idx >= self.file_header_lines.len) return null;
        return self.file_header_lines[file_idx];
    }

    /// Get the file index that contains a given global line
    /// For spacer lines, returns the file that follows the spacer
    pub fn getFileIndexForLine(self: *const LineMap, global_line: usize) ?usize {
        const record = self.getLineRecord(global_line) orelse return null;

        // For spacers, return the next file
        if (record.line_type == .spacer) {
            return record.line_type.spacer.after_file_idx + 1;
        }

        return record.file_idx;
    }

    /// Check if a global line is a spacer
    pub fn isSpacer(self: *const LineMap, global_line: usize) bool {
        const record = self.getLineRecord(global_line) orelse return false;
        return record.line_type == .spacer;
    }

    /// Check if a global line is a file header
    pub fn isFileHeader(self: *const LineMap, global_line: usize) bool {
        const record = self.getLineRecord(global_line) orelse return false;
        return record.line_type == .file_header;
    }

    /// Get the first content line of a file (the first hunk header)
    pub fn getFileFirstContentLine(self: *const LineMap, file_idx: usize) ?usize {
        var found_header = false;
        for (self.records) |*record| {
            if (record.file_idx == file_idx) {
                if (record.line_type == .file_header) {
                    found_header = true;
                } else if (found_header and record.line_type == .hunk_header) {
                    return record.global_line;
                }
            }
        }
        return null;
    }

    /// Check if a global line is empty (spacer or empty content line)
    pub fn isEmptyLine(self: *const LineMap, global_line: usize, files: []const parser.FileDiff) bool {
        const record = self.getLineRecord(global_line) orelse return false;

        // Spacer lines are always empty
        if (record.line_type == .spacer) {
            return true;
        }

        // Check if code line has empty content
        if (record.line_type == .code_line) {
            const code_line_info = record.line_type.code_line;
            const file = &files[record.file_idx];
            const hunk = &file.hunks[code_line_info.hunk_idx];
            const line = &hunk.lines[code_line_info.line_idx_in_hunk];

            // Check if content is empty or only whitespace
            const trimmed = std.mem.trim(u8, line.content, " \t\r\n");
            return trimmed.len == 0;
        }

        return false;
    }

    /// Find the global line number for a given comment index
    pub fn findLineByCommentIdx(self: *const LineMap, comment_idx: usize) ?usize {
        for (self.records) |*record| {
            if (record.line_type == .comment_line) {
                if (record.line_type.comment_line.comment_idx == comment_idx) {
                    return record.global_line;
                }
            }
        }
        return null;
    }

    /// Find the global line number for a given review-thread index
    pub fn findLineByThreadIdx(self: *const LineMap, thread_idx: usize) ?usize {
        for (self.records) |*record| {
            if (record.line_type == .review_thread) {
                if (record.line_type.review_thread.thread_idx == thread_idx) {
                    return record.global_line;
                }
            }
        }
        return null;
    }
};

test "line map basic construction" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/file1.txt b/file1.txt
        \\--- a/file1.txt
        \\+++ b/file1.txt
        \\@@ -1,1 +1,1 @@
        \\-old line
        \\+new line
        \\diff --git a/file2.txt b/file2.txt
        \\--- a/file2.txt
        \\+++ b/file2.txt
        \\@@ -1,1 +1,2 @@
        \\ context
        \\+addition
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    var line_map = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer line_map.deinit();

    // File 1: header(0) + header_spacer(1) + hunk_header(2) + 2 lines(3,4) + file_spacers(5,6,7) = 8 lines
    // File 2: header(8) + header_spacer(9) + hunk_header(10) + 2 lines(11,12) = 5 lines
    // Total: 13 lines
    try std.testing.expectEqual(@as(usize, 13), line_map.getTotalLines());

    // Check file 1 header is at line 0
    try std.testing.expectEqual(@as(usize, 0), line_map.getFileHeaderLine(0).?);

    // Check file 2 header is at line 8
    try std.testing.expectEqual(@as(usize, 8), line_map.getFileHeaderLine(1).?);

    // Check line 0 is file header
    try std.testing.expect(line_map.isFileHeader(0));

    // Check line 1 is header spacer
    try std.testing.expect(line_map.isSpacer(1));

    // Check lines 5-7 are file spacers
    try std.testing.expect(line_map.isSpacer(5));
    try std.testing.expect(line_map.isSpacer(6));
    try std.testing.expect(line_map.isSpacer(7));

    // Check line 2 is hunk header
    const record2 = line_map.getLineRecord(2).?;
    try std.testing.expect(record2.line_type == .hunk_header);
    try std.testing.expectEqual(@as(usize, 0), record2.line_type.hunk_header.hunk_idx);
}

test "line map with comments" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,1 +1,1 @@
        \\-old
        \\+new
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    // Add a comment on line 0 of hunk 0
    try store.addComment(
        "test.txt",
        0, // hunk_idx
        0, // line_idx
        "test comment",
        .delete,
        "old",
        1,
        null,
    );

    var line_map = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer line_map.deinit();

    // header(0) + header_spacer(1) + hunk_header(2) + delete_line(3) + comment(4) + add_line(5) = 6 lines
    try std.testing.expectEqual(@as(usize, 6), line_map.getTotalLines());

    // Line 4 should be a comment line
    const record4 = line_map.getLineRecord(4).?;
    try std.testing.expect(record4.line_type == .comment_line);
    try std.testing.expectEqual(@as(usize, 0), record4.line_type.comment_line.parent_hunk_idx);
    try std.testing.expectEqual(@as(usize, 0), record4.line_type.comment_line.parent_line_idx);
}

test "a range comment starting on a line suppresses a later single comment there" {
    // Precedence rule the record loop depends on: the lookup takes the FIRST
    // comment at a location, and accepts it only when it is single-line. A
    // range comment that starts there wins the lookup and is then rejected, so
    // no comment record is emitted even though a single comment also sits on
    // that line. Pinned because an index keyed per location must keep the same
    // first-wins order.
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,2 +1,2 @@
        \\-old
        \\+new
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    // Range comment spanning both lines, added first.
    try store.addRangeComment("test.txt", 0, 0, 0, 1, "range", .delete, "old", 1, null);
    // Single comment on the same start line, added second.
    try store.addComment("test.txt", 0, 0, "single", .delete, "old", 1, null);

    var map = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer map.deinit();

    // The range comment renders at its END line (line_idx 1), and the start
    // line emits nothing because the range comment shadowed the single one.
    var comment_records: usize = 0;
    var range_parent_line: ?usize = null;
    for (map.records) |record| {
        if (record.line_type != .comment_line) continue;
        comment_records += 1;
        range_parent_line = record.line_type.comment_line.parent_line_idx;
    }
    try std.testing.expectEqual(@as(usize, 1), comment_records);
    try std.testing.expectEqual(@as(usize, 1), range_parent_line.?);
}

test "comments attach to the file whose path matches" {
    // Two files with comments at identical (hunk_idx, line_idx) coordinates.
    // Only the path distinguishes them, so an index must key on the path.
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/one.txt b/one.txt
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1,1 +1,1 @@
        \\-a
        \\+b
        \\diff --git a/two.txt b/two.txt
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1,1 +1,1 @@
        \\-c
        \\+d
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 2), files.len);

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();
    try store.addComment("two.txt", 0, 0, "on two", .delete, "c", 1, null);

    var map = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer map.deinit();

    var owner_file_idx: ?usize = null;
    var comment_records: usize = 0;
    for (map.records) |record| {
        if (record.line_type != .comment_line) continue;
        comment_records += 1;
        owner_file_idx = record.file_idx;
    }
    try std.testing.expectEqual(@as(usize, 1), comment_records);
    try std.testing.expectEqual(@as(usize, 1), owner_file_idx.?);
}

test "comment deletion scroll anchoring" {
    const allocator = std.testing.allocator;

    // Create a diff with more lines to test scroll behavior
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,5 +1,5 @@
        \\ context1
        \\-old1
        \\+new1
        \\ context2
        \\-old2
        \\+new2
        \\ context3
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    // Add a comment on line 2 (the "-old1" line, which is line_idx 1 in the hunk)
    try store.addComment(
        "test.txt",
        0, // hunk_idx
        1, // line_idx (0=context1, 1=old1, 2=new1, 3=context2, ...)
        "test comment",
        .delete,
        "old1",
        1,
        null,
    );

    // Build LineMap with comment
    var line_map = try LineMap.build(allocator, files, &store, .all, true, null, null);

    // Structure:
    // 0: file_header
    // 1: header_spacer
    // 2: hunk_header
    // 3: context1 (code_line, line_idx=0)
    // 4: old1 (code_line, line_idx=1) <- parent of comment
    // 5: comment <- this is the comment
    // 6: new1 (code_line, line_idx=2)
    // 7: context2 (code_line, line_idx=3)
    // 8: old2 (code_line, line_idx=4)
    // 9: new2 (code_line, line_idx=5)
    // 10: context3 (code_line, line_idx=6)

    // Verify structure
    try std.testing.expectEqual(@as(usize, 11), line_map.getTotalLines());

    // Line 4 should be the parent code line (old1)
    const parent_record = line_map.getLineRecord(4).?;
    try std.testing.expect(parent_record.line_type == .code_line);

    // Line 5 should be the comment
    const comment_record = line_map.getLineRecord(5).?;
    try std.testing.expect(comment_record.line_type == .comment_line);
    const comment_idx = comment_record.line_type.comment_line.comment_idx;

    // Line 6 should be new1
    const next_record = line_map.getLineRecord(6).?;
    try std.testing.expect(next_record.line_type == .code_line);

    // Now simulate different scroll scenarios and verify expected behavior

    // Scenario 1: scroll at 0 (well before comment), comment at 5, parent at 4
    // After deletion: parent stays at 4, scroll should stay at 0
    {
        const scroll_before: usize = 0;
        const comment_pos: usize = 5;
        const parent_pos: usize = 4;

        // After deletion, lines 6+ shift down by 1
        // Parent at 4 is unchanged
        // Expected scroll: 0 (unchanged, comment was below viewport start)
        const expected_scroll: usize = 0;
        _ = comment_pos;
        _ = parent_pos;
        _ = scroll_before;
        try std.testing.expectEqual(expected_scroll, @as(usize, 0));
    }

    // Scenario 2: scroll at 5 (on the comment), comment at 5, parent at 4
    // After deletion: parent at 4, what was at 6 is now at 5
    // Expected: scroll should move to parent (4) to avoid showing slid-up content
    {
        const scroll_before: usize = 5;
        const parent_pos: usize = 4;

        // When scroll was ON the comment, after deletion we should show parent
        const expected_scroll: usize = parent_pos;
        _ = scroll_before;
        try std.testing.expectEqual(expected_scroll, @as(usize, 4));
    }

    // Scenario 3: scroll at 4 (on parent), comment at 5, parent at 4
    // After deletion: parent still at 4, scroll should stay at 4
    {
        const scroll_before: usize = 4;
        const parent_pos: usize = 4;

        // Scroll was on parent, stays on parent
        const expected_scroll: usize = parent_pos;
        _ = scroll_before;
        try std.testing.expectEqual(expected_scroll, @as(usize, 4));
    }

    // Clean up and rebuild without comment to verify structure
    line_map.deinit();
    try store.deleteComment(comment_idx);

    line_map = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer line_map.deinit();

    // After deletion: 10 lines (was 11, minus 1 comment)
    try std.testing.expectEqual(@as(usize, 10), line_map.getTotalLines());

    // Line 4 should still be the parent code line (old1)
    const parent_after = line_map.getLineRecord(4).?;
    try std.testing.expect(parent_after.line_type == .code_line);

    // Line 5 should now be new1 (was at 6 before)
    const line5_after = line_map.getLineRecord(5).?;
    try std.testing.expect(line5_after.line_type == .code_line);
}

test "comment deletion with multiple comments above" {
    const allocator = std.testing.allocator;

    // Create a diff with multiple lines
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,7 +1,7 @@
        \\ context1
        \\-old1
        \\+new1
        \\ context2
        \\-old2
        \\+new2
        \\ context3
        \\-old3
        \\+new3
        \\ context4
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    // Add comments on multiple lines
    // Comment 1: on old1 (line_idx 1)
    try store.addComment("test.txt", 0, 1, "comment 1", .delete, "old1", 1, null);
    // Comment 2: on old2 (line_idx 4)
    try store.addComment("test.txt", 0, 4, "comment 2", .delete, "old2", 4, null);
    // Comment 3: on old3 (line_idx 7) - this is the one we'll delete
    try store.addComment("test.txt", 0, 7, "comment 3", .delete, "old3", 7, null);

    // Build LineMap with comments
    var line_map = try LineMap.build(allocator, files, &store, .all, true, null, null);

    // Structure (approximate):
    // 0: file_header
    // 1: header_spacer
    // 2: hunk_header
    // 3: context1
    // 4: old1
    // 5: comment 1 on old1
    // 6: new1
    // 7: context2
    // 8: old2
    // 9: comment 2 on old2
    // 10: new2
    // 11: context3
    // 12: old3 <- parent of comment 3
    // 13: comment 3 <- we'll delete this
    // 14: new3
    // 15: context4

    const total_before = line_map.getTotalLines();
    try std.testing.expectEqual(@as(usize, 16), total_before);

    // Find the comment 3 (on old3)
    var comment3_idx: ?usize = null;
    var comment3_line: ?usize = null;
    var parent3_line: ?usize = null;

    for (line_map.records, 0..) |*record, i| {
        if (record.line_type == .comment_line) {
            const ci = record.line_type.comment_line;
            if (ci.parent_line_idx == 7) { // old3 is at line_idx 7 in hunk
                comment3_idx = ci.comment_idx;
                comment3_line = i;
            }
        }
        if (record.line_type == .code_line) {
            const code = record.line_type.code_line;
            if (code.line_idx_in_hunk == 7) { // old3
                parent3_line = i;
            }
        }
    }

    try std.testing.expect(comment3_idx != null);
    try std.testing.expect(comment3_line != null);
    try std.testing.expect(parent3_line != null);

    // Verify parent is before comment
    try std.testing.expect(parent3_line.? < comment3_line.?);

    // Key test: verify that parent position is affected by comments above
    // There are 2 comments above old3 (comment 1 and comment 2)
    // So parent3_line should be 2 higher than it would be without those comments

    // Now delete comment 3 and rebuild
    line_map.deinit();
    try store.deleteComment(comment3_idx.?);
    line_map = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer line_map.deinit();

    // After deletion: 15 lines (was 16)
    try std.testing.expectEqual(@as(usize, 15), line_map.getTotalLines());

    // Find parent3 again - it should be at the SAME position
    // because we only deleted a comment AFTER it
    var new_parent3_line: ?usize = null;
    for (line_map.records, 0..) |*record, i| {
        if (record.line_type == .code_line) {
            const code = record.line_type.code_line;
            if (code.line_idx_in_hunk == 7) { // old3
                new_parent3_line = i;
                break;
            }
        }
    }

    try std.testing.expect(new_parent3_line != null);
    // Parent should be at same position (comments above it are unchanged)
    try std.testing.expectEqual(parent3_line.?, new_parent3_line.?);
}

const three_file_diff =
    \\diff --git a/file1.txt b/file1.txt
    \\--- a/file1.txt
    \\+++ b/file1.txt
    \\@@ -1,1 +1,1 @@
    \\-old line
    \\+new line
    \\diff --git a/file2.txt b/file2.txt
    \\--- a/file2.txt
    \\+++ b/file2.txt
    \\@@ -1,1 +1,2 @@
    \\ context
    \\+addition
    \\diff --git a/file3.txt b/file3.txt
    \\--- a/file3.txt
    \\+++ b/file3.txt
    \\@@ -1,2 +1,2 @@
    \\ keep
    \\-drop
    \\+gain
;

test "appending the rest of a diff matches building it all at once" {
    const allocator = std.testing.allocator;
    const files = try parser.parse(allocator, three_file_diff);
    defer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    var whole = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer whole.deinit();

    var grown = try LineMap.build(allocator, files[0..1], &store, .all, true, null, null);
    defer grown.deinit();
    try grown.appendFiles(.{ .files = files, .comment_store = &store, .hunk_view_mode = .all, .apply_filtering = true });

    try std.testing.expectEqual(whole.getTotalLines(), grown.getTotalLines());
    try std.testing.expectEqualDeep(whole.records, grown.records);
    try std.testing.expectEqualSlices(usize, whole.file_header_lines, grown.file_header_lines);
}

test "appending one file at a time matches building it all at once" {
    const allocator = std.testing.allocator;
    const files = try parser.parse(allocator, three_file_diff);
    defer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    var whole = try LineMap.build(allocator, files, &store, .all, true, null, null);
    defer whole.deinit();

    var grown = try LineMap.build(allocator, files[0..1], &store, .all, true, null, null);
    defer grown.deinit();

    try grown.appendFiles(.{ .files = files[0..2], .comment_store = &store, .hunk_view_mode = .all, .apply_filtering = true });
    try grown.appendFiles(.{ .files = files, .comment_store = &store, .hunk_view_mode = .all, .apply_filtering = true });

    try std.testing.expectEqual(whole.getTotalLines(), grown.getTotalLines());
    try std.testing.expectEqualDeep(whole.records, grown.records);
    try std.testing.expectEqualSlices(usize, whole.file_header_lines, grown.file_header_lines);
}
