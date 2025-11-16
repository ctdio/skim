const std = @import("std");
const syntax = @import("../syntax.zig");

const Allocator = std.mem.Allocator;

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []Hunk,
    highlights: ?[]syntax.Highlight, // Cached syntax highlights for the new file (add/context lines)
    old_highlights: ?[]syntax.Highlight, // Cached syntax highlights for the old file (delete/context lines)

    pub fn deinit(self: *const FileDiff, allocator: Allocator) void {
        allocator.free(self.old_path);
        allocator.free(self.new_path);
        for (self.hunks) |*hunk| {
            hunk.deinit(allocator);
        }
        allocator.free(self.hunks);
        if (self.highlights) |highlights| {
            // Free each category string (they were duplicated during parsing)
            for (highlights) |h| {
                allocator.free(h.category);
            }
            allocator.free(highlights);
        }
        if (self.old_highlights) |old_highlights| {
            // Free each category string (they were duplicated during parsing)
            for (old_highlights) |h| {
                allocator.free(h.category);
            }
            allocator.free(old_highlights);
        }
    }
};

pub const Hunk = struct {
    header: HunkHeader,
    lines: []Line,

    pub fn deinit(self: *const Hunk, allocator: Allocator) void {
        allocator.free(self.header.context);
        for (self.lines) |*line| {
            line.deinit(allocator);
        }
        allocator.free(self.lines);
    }
};

pub const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    context: []const u8,
};

pub const Line = struct {
    line_type: LineType,
    content: []const u8,
    old_lineno: ?u32,
    new_lineno: ?u32,

    pub const LineType = enum {
        add,
        delete,
        context,
    };

    pub fn deinit(self: *const Line, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

/// Parse unified diff format into structured data
pub fn parse(allocator: Allocator, diff_text: []const u8) ![]FileDiff {
    var files = std.ArrayList(FileDiff).init(allocator);
    errdefer {
        for (files.items) |*file| {
            file.deinit(allocator);
        }
        files.deinit();
    }

    var lines = std.mem.tokenizeScalar(u8, diff_text, '\n');

    var current_file: ?PartialFileDiff = null;
    var current_hunk: ?PartialHunk = null;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        if (std.mem.startsWith(u8, line, "diff --git ")) {
            // Save previous file if exists
            if (current_file) |*file| {
                if (current_hunk) |*hunk| {
                    try file.hunks.append(try hunk.finalize());
                    current_hunk = null;
                }
                try files.append(try file.finalize(allocator));
            }

            // Start new file
            current_file = PartialFileDiff.init(allocator);
        } else if (std.mem.startsWith(u8, line, "--- ")) {
            if (current_file) |*file| {
                const path = parsePath(line[4..]);
                file.old_path = try allocator.dupe(u8, path);
            }
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            if (current_file) |*file| {
                const path = parsePath(line[4..]);
                file.new_path = try allocator.dupe(u8, path);
            }
        } else if (std.mem.startsWith(u8, line, "@@ ")) {
            // Save previous hunk if exists
            if (current_hunk) |*hunk| {
                if (current_file) |*file| {
                    try file.hunks.append(try hunk.finalize());
                }
            }

            // Parse hunk header
            current_hunk = try parseHunkHeader(allocator, line);
        } else if (current_hunk != null) {
            // Parse hunk line
            if (line.len == 0) continue;

            var hunk = &current_hunk.?;
            const line_type: Line.LineType = switch (line[0]) {
                '+' => .add,
                '-' => .delete,
                ' ' => .context,
                else => continue,
            };

            const content = if (line.len > 1) line[1..] else "";

            const old_lineno: ?u32 = if (line_type != .add) hunk.old_lineno else null;
            const new_lineno: ?u32 = if (line_type != .delete) hunk.new_lineno else null;

            try hunk.lines.append(.{
                .line_type = line_type,
                .content = try allocator.dupe(u8, content),
                .old_lineno = old_lineno,
                .new_lineno = new_lineno,
            });

            // Update line numbers
            switch (line_type) {
                .add => hunk.new_lineno += 1,
                .delete => hunk.old_lineno += 1,
                .context => {
                    hunk.old_lineno += 1;
                    hunk.new_lineno += 1;
                },
            }
        }
    }

    // Finalize last hunk and file
    if (current_hunk) |*hunk| {
        if (current_file) |*file| {
            try file.hunks.append(try hunk.finalize());
        }
    }
    if (current_file) |*file| {
        try files.append(try file.finalize(allocator));
    }

    return files.toOwnedSlice();
}

const PartialFileDiff = struct {
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    hunks: std.ArrayList(Hunk),

    fn init(allocator: Allocator) PartialFileDiff {
        return .{
            .old_path = null,
            .new_path = null,
            .hunks = std.ArrayList(Hunk).init(allocator),
        };
    }

    fn finalize(self: *PartialFileDiff, allocator: Allocator) !FileDiff {
        return FileDiff{
            .old_path = self.old_path orelse try allocator.dupe(u8, ""),
            .new_path = self.new_path orelse try allocator.dupe(u8, ""),
            .hunks = try self.hunks.toOwnedSlice(),
            .highlights = null, // Will be populated on first render
            .old_highlights = null, // Will be populated on first render
        };
    }
};

const PartialHunk = struct {
    header: HunkHeader,
    lines: std.ArrayList(Line),
    old_lineno: u32,
    new_lineno: u32,

    fn finalize(self: *PartialHunk) !Hunk {
        return Hunk{
            .header = self.header,
            .lines = try self.lines.toOwnedSlice(),
        };
    }
};

fn parsePath(path_with_prefix: []const u8) []const u8 {
    // Remove a/ or b/ prefix
    if (std.mem.startsWith(u8, path_with_prefix, "a/") or
        std.mem.startsWith(u8, path_with_prefix, "b/"))
    {
        return path_with_prefix[2..];
    }
    // Handle /dev/null for new/deleted files
    if (std.mem.eql(u8, path_with_prefix, "/dev/null")) {
        return "";
    }
    return path_with_prefix;
}

fn parseHunkHeader(allocator: Allocator, line: []const u8) !PartialHunk {
    // Format: @@ -old_start,old_count +new_start,new_count @@ context
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');

    const first = tokens.next() orelse return error.InvalidHunkHeader;
    if (!std.mem.eql(u8, first, "@@")) return error.InvalidHunkHeader;

    const old_token = tokens.next() orelse return error.InvalidHunkHeader;
    const new_token = tokens.next() orelse return error.InvalidHunkHeader;

    const second = tokens.next() orelse return error.InvalidHunkHeader;
    if (!std.mem.eql(u8, second, "@@")) return error.InvalidHunkHeader;

    const old_range = try parseDiffRange(old_token, '-');
    const new_range = try parseDiffRange(new_token, '+');

    const first_idx = std.mem.indexOf(u8, line, "@@") orelse return error.InvalidHunkHeader;
    const second_idx = std.mem.indexOfPos(u8, line, first_idx + 2, "@@") orelse return error.InvalidHunkHeader;
    const context_slice = std.mem.trim(u8, line[second_idx + 2 ..], " \t");

    return PartialHunk{
        .header = .{
            .old_start = old_range.start,
            .old_count = old_range.count,
            .new_start = new_range.start,
            .new_count = new_range.count,
            .context = try allocator.dupe(u8, context_slice),
        },
        .lines = std.ArrayList(Line).init(allocator),
        .old_lineno = old_range.start,
        .new_lineno = new_range.start,
    };
}

fn parseDiffRange(token: []const u8, expected_prefix: u8) !struct { start: u32, count: u32 } {
    if (token.len < 2 or token[0] != expected_prefix) return error.InvalidHunkHeader;

    const payload = token[1..];
    if (payload.len == 0) return error.InvalidHunkHeader;

    const comma_index = std.mem.indexOfScalar(u8, payload, ',');
    const start_slice = if (comma_index) |idx| payload[0..idx] else payload;
    if (start_slice.len == 0) return error.InvalidHunkHeader;
    const start = try std.fmt.parseInt(u32, start_slice, 10);

    const count = if (comma_index) |idx| blk: {
        const remainder = payload[idx + 1 ..];
        if (remainder.len == 0) return error.InvalidHunkHeader;
        break :blk try std.fmt.parseInt(u32, remainder, 10);
    } else 1;

    return .{ .start = start, .count = count };
}

test "parse simple diff" {
    const allocator = std.testing.allocator;

    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,3 +1,4 @@
        \\ context line
        \\-removed line
        \\+added line
        \\+another added line
    ;

    const files = try parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("test.txt", files[0].new_path);
    try std.testing.expectEqual(@as(usize, 1), files[0].hunks.len);

    const hunk = files[0].hunks[0];
    try std.testing.expectEqual(@as(u32, 1), hunk.header.old_start);
    try std.testing.expectEqual(@as(u32, 3), hunk.header.old_count);
    try std.testing.expectEqual(@as(u32, 1), hunk.header.new_start);
    try std.testing.expectEqual(@as(u32, 4), hunk.header.new_count);

    try std.testing.expectEqual(@as(usize, 4), hunk.lines.len);
    try std.testing.expectEqual(Line.LineType.context, hunk.lines[0].line_type);
    try std.testing.expectEqual(Line.LineType.delete, hunk.lines[1].line_type);
    try std.testing.expectEqual(Line.LineType.add, hunk.lines[2].line_type);
    try std.testing.expectEqual(Line.LineType.add, hunk.lines[3].line_type);
}

test "parse diff with implicit counts" {
    const allocator = std.testing.allocator;

    const diff =
        \\diff --git a/foo.txt b/foo.txt
        \\--- a/foo.txt
        \\+++ b/foo.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;

    const files = try parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(usize, 1), files[0].hunks.len);

    const header = files[0].hunks[0].header;
    try std.testing.expectEqual(@as(u32, 1), header.old_start);
    try std.testing.expectEqual(@as(u32, 1), header.old_count);
    try std.testing.expectEqual(@as(u32, 1), header.new_start);
    try std.testing.expectEqual(@as(u32, 1), header.new_count);
}

test "line numbers preserve new file positions" {
    const allocator = std.testing.allocator;

    const diff =
        \\diff --git a/sample.txt b/sample.txt
        \\--- a/sample.txt
        \\+++ b/sample.txt
        \\@@ -650,2 +650,3 @@
        \\ context line
        \\-removed line
        \\+added line
        \\+another addition
    ;

    const files = try parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 1), files.len);
    const hunk = files[0].hunks[0];
    try std.testing.expectEqual(@as(u32, 650), hunk.header.new_start);

    try std.testing.expectEqual(@as(usize, 4), hunk.lines.len);
    try std.testing.expectEqual(@as(?u32, 650), hunk.lines[0].new_lineno); // context line
    try std.testing.expectEqual(@as(?u32, 651), hunk.lines[2].new_lineno); // first added line
    try std.testing.expectEqual(@as(?u32, 652), hunk.lines[3].new_lineno); // second added line
}

test "parse path with prefix" {
    try std.testing.expectEqualStrings("foo/bar.txt", parsePath("a/foo/bar.txt"));
    try std.testing.expectEqualStrings("foo/bar.txt", parsePath("b/foo/bar.txt"));
    try std.testing.expectEqualStrings("", parsePath("/dev/null"));
}
