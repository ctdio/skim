const std = @import("std");
const syntax = @import("../highlighting/core.zig");

const Allocator = std.mem.Allocator;

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []Hunk,
    is_untracked: bool, // True if file is untracked (not yet added to git)

    pub fn deinit(self: *const FileDiff, allocator: Allocator) void {
        allocator.free(self.old_path);
        allocator.free(self.new_path);
        for (self.hunks) |*hunk| {
            hunk.deinit(allocator);
        }
        allocator.free(self.hunks);
    }
};

pub const Hunk = struct {
    header: HunkHeader,
    lines: []Line,
    highlights: ?[]syntax.Highlight, // Cached syntax highlights for new file (add/context lines)
    old_highlights: ?[]syntax.Highlight, // Cached syntax highlights for old file (delete/context lines)
    new_line_offsets: ?[]usize = null, // Byte offsets for new file line mapping
    old_line_offsets: ?[]usize = null, // Byte offsets for old file line mapping
    new_line_highlight_spans: ?[]LineHighlightSpan = null,
    new_line_highlight_indices: ?[]LineHighlightIndex = null,
    old_line_highlight_spans: ?[]LineHighlightSpan = null,
    old_line_highlight_indices: ?[]LineHighlightIndex = null,

    pub fn deinit(self: *const Hunk, allocator: Allocator) void {
        allocator.free(self.header.context);
        for (self.lines) |*line| {
            line.deinit(allocator);
        }
        allocator.free(self.lines);
        if (self.new_line_offsets) |offsets| {
            allocator.free(offsets);
        }
        if (self.old_line_offsets) |offsets| {
            allocator.free(offsets);
        }
        if (self.new_line_highlight_spans) |spans| {
            allocator.free(spans);
        }
        if (self.new_line_highlight_indices) |indices| {
            allocator.free(indices);
        }
        if (self.old_line_highlight_spans) |spans| {
            allocator.free(spans);
        }
        if (self.old_line_highlight_indices) |indices| {
            allocator.free(indices);
        }
        if (self.highlights) |highlights| {
            for (highlights) |h| {
                allocator.free(h.category);
            }
            allocator.free(highlights);
        }
        if (self.old_highlights) |old_highlights| {
            for (old_highlights) |h| {
                allocator.free(h.category);
            }
            allocator.free(old_highlights);
        }
    }
};

pub const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    context: []const u8,
};

pub const LineHighlightSpan = struct {
    start: usize,
    end: usize,
    category: syntax.Highlight.ColorCategory,
};

pub const LineHighlightIndex = struct {
    start: usize,
    len: usize,
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
    var files: std.ArrayList(FileDiff) = .{};
    errdefer {
        for (files.items) |*file| {
            file.deinit(allocator);
        }
        files.deinit(allocator);
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
                    try file.hunks.append(allocator, try hunk.finalize(allocator));
                    current_hunk = null;
                }
                try files.append(allocator, try file.finalize(allocator));
            }

            // Start new file
            current_file = PartialFileDiff.init();
        } else if (std.mem.startsWith(u8, line, "--- ")) {
            // For standard unified diff (no "diff --git" header), start a new file here
            // If we already have a file with content, save it first (multi-file unified diff)
            if (current_file) |*file| {
                // Check if we have hunks (finalized or pending)
                const has_content = file.hunks.items.len > 0 or current_hunk != null;
                if (has_content) {
                    if (current_hunk) |*hunk| {
                        try file.hunks.append(allocator, try hunk.finalize(allocator));
                        current_hunk = null;
                    }
                    try files.append(allocator, try file.finalize(allocator));
                    current_file = PartialFileDiff.init();
                }
            } else {
                current_file = PartialFileDiff.init();
            }
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
                    try file.hunks.append(allocator, try hunk.finalize(allocator));
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

            try hunk.lines.append(allocator, .{
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
            try file.hunks.append(allocator, try hunk.finalize(allocator));
        }
    }
    if (current_file) |*file| {
        try files.append(allocator, try file.finalize(allocator));
    }

    return files.toOwnedSlice(allocator);
}

const PartialFileDiff = struct {
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    hunks: std.ArrayList(Hunk),

    fn init() PartialFileDiff {
        return .{
            .old_path = null,
            .new_path = null,
            .hunks = .{},
        };
    }

    fn finalize(self: *PartialFileDiff, allocator: Allocator) !FileDiff {
        return FileDiff{
            .old_path = self.old_path orelse try allocator.dupe(u8, ""),
            .new_path = self.new_path orelse try allocator.dupe(u8, ""),
            .hunks = try self.hunks.toOwnedSlice(allocator),
            .is_untracked = false, // Will be set to true for untracked files after parsing
        };
    }
};

const PartialHunk = struct {
    header: HunkHeader,
    lines: std.ArrayList(Line),
    old_lineno: u32,
    new_lineno: u32,

    fn finalize(self: *PartialHunk, allocator: Allocator) !Hunk {
        const lines = try self.lines.toOwnedSlice(allocator);
        errdefer allocator.free(lines);

        const new_offsets = try buildLineOffsets(allocator, lines, .new);
        errdefer allocator.free(new_offsets);

        const old_offsets = try buildLineOffsets(allocator, lines, .old);
        errdefer allocator.free(old_offsets);

        return Hunk{
            .header = self.header,
            .lines = lines,
            .highlights = null, // Will be populated by async highlighting
            .old_highlights = null, // Will be populated by async highlighting
            .new_line_offsets = new_offsets,
            .old_line_offsets = old_offsets,
            .new_line_highlight_spans = null,
            .new_line_highlight_indices = null,
            .old_line_highlight_spans = null,
            .old_line_highlight_indices = null,
        };
    }
};

const LineOffsetMode = enum { new, old };

fn buildLineOffsets(allocator: Allocator, lines: []const Line, mode: LineOffsetMode) ![]usize {
    const offsets = try allocator.alloc(usize, lines.len);
    var offset: usize = 0;

    for (lines, 0..) |line, idx| {
        offsets[idx] = offset;
        switch (line.line_type) {
            .add => {
                if (mode == .new) offset += line.content.len + 1;
            },
            .delete => {
                if (mode == .old) offset += line.content.len + 1;
            },
            .context => {
                offset += line.content.len + 1;
            },
        }
    }

    return offsets;
}

fn parsePath(path_with_prefix: []const u8) []const u8 {
    var path = path_with_prefix;

    // Strip timestamp suffix (standard unified diff: "filename\t2024-01-01 12:00:00")
    if (std.mem.indexOfScalar(u8, path, '\t')) |tab_idx| {
        path = path[0..tab_idx];
    }

    // Remove a/ or b/ prefix (git diff format)
    if (std.mem.startsWith(u8, path, "a/") or
        std.mem.startsWith(u8, path, "b/"))
    {
        return path[2..];
    }
    // Handle /dev/null for new/deleted files
    if (std.mem.eql(u8, path, "/dev/null")) {
        return "";
    }
    return path;
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
        .lines = .{},
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

/// Mark files as untracked based on a list of untracked file paths
pub fn markUntrackedFiles(files: []FileDiff, untracked_paths: []const []const u8) void {
    for (files) |*file| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        for (untracked_paths) |untracked_path| {
            if (std.mem.eql(u8, file_path, untracked_path)) {
                file.is_untracked = true;
                break;
            }
        }
    }
}

/// Strip ANSI escape sequences from text (for pager mode where git sends colored output)
pub fn stripAnsi(allocator: Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Check for ESC (0x1B) followed by '[' (CSI sequence)
        if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
            // Skip the ESC and '['
            i += 2;
            // Skip until we find a letter (the terminator)
            while (i < input.len) {
                const c = input[i];
                i += 1;
                // CSI sequences end with a letter (0x40-0x7E)
                if (c >= 0x40 and c <= 0x7E) break;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

test "stripAnsi removes color codes" {
    const allocator = std.testing.allocator;

    // Test with typical git color output
    const input = "\x1b[32m+added line\x1b[m";
    const result = try stripAnsi(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("+added line", result);
}

test "stripAnsi preserves plain text" {
    const allocator = std.testing.allocator;

    const input = "plain text without colors";
    const result = try stripAnsi(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("plain text without colors", result);
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

test "parse path with timestamp" {
    // Standard unified diff format: filename followed by tab and timestamp
    try std.testing.expectEqualStrings("foo.txt", parsePath("foo.txt\t2024-01-01 12:00:00.000000000 -0500"));
    try std.testing.expectEqualStrings("path/to/file.txt", parsePath("path/to/file.txt\t2024-01-01 12:00:00"));
    // Git format with a/ prefix and timestamp (rare but possible)
    try std.testing.expectEqualStrings("foo.txt", parsePath("a/foo.txt\t2024-01-01"));
}

test "parse standard unified diff (no git header)" {
    const allocator = std.testing.allocator;

    // Standard unified diff from `diff -u old.txt new.txt`
    // Note: Using \t for tab since multiline strings don't allow literal tabs
    const diff = "--- old.txt\t2024-01-01 12:00:00.000000000 -0500\n" ++
        "+++ new.txt\t2024-01-02 12:00:00.000000000 -0500\n" ++
        "@@ -1,3 +1,4 @@\n" ++
        " context line\n" ++
        "-removed line\n" ++
        "+added line\n" ++
        "+another added line\n";

    const files = try parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("old.txt", files[0].old_path);
    try std.testing.expectEqualStrings("new.txt", files[0].new_path);
    try std.testing.expectEqual(@as(usize, 1), files[0].hunks.len);

    const hunk = files[0].hunks[0];
    try std.testing.expectEqual(@as(usize, 4), hunk.lines.len);
}

test "parse multi-file standard unified diff" {
    const allocator = std.testing.allocator;

    // Multiple files in standard unified diff format
    const diff = "--- file1.txt\t2024-01-01 12:00:00\n" ++
        "+++ file1.txt\t2024-01-02 12:00:00\n" ++
        "@@ -1 +1 @@\n" ++
        "-old1\n" ++
        "+new1\n" ++
        "--- file2.txt\t2024-01-01 12:00:00\n" ++
        "+++ file2.txt\t2024-01-02 12:00:00\n" ++
        "@@ -1 +1 @@\n" ++
        "-old2\n" ++
        "+new2\n";

    const files = try parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("file1.txt", files[0].new_path);
    try std.testing.expectEqualStrings("file2.txt", files[1].new_path);
}

test "parse diff with merge conflict markers" {
    const allocator = std.testing.allocator;

    // This is the unified diff format that git produces with `git diff HEAD`
    // during a merge conflict - conflict markers appear as added lines
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1 +1,9 @@
        \\+<<<<<<< HEAD
        \\ main line 2
        \\+||||||| fa1ef98
        \\+line 1
        \\+line 2
        \\+line 3
        \\+=======
        \\+feature line 2
        \\+>>>>>>> feature
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
    try std.testing.expectEqual(@as(usize, 9), hunk.lines.len);

    // Verify conflict markers are parsed as added lines
    try std.testing.expectEqual(Line.LineType.add, hunk.lines[0].line_type);
    try std.testing.expectEqualStrings("<<<<<<< HEAD", hunk.lines[0].content);

    try std.testing.expectEqual(Line.LineType.context, hunk.lines[1].line_type);
    try std.testing.expectEqualStrings("main line 2", hunk.lines[1].content);

    try std.testing.expectEqual(Line.LineType.add, hunk.lines[2].line_type);
    try std.testing.expectEqualStrings("||||||| fa1ef98", hunk.lines[2].content);

    try std.testing.expectEqual(Line.LineType.add, hunk.lines[5].line_type);
    try std.testing.expectEqualStrings("=======", hunk.lines[5].content);

    try std.testing.expectEqual(Line.LineType.add, hunk.lines[7].line_type);
    try std.testing.expectEqualStrings(">>>>>>> feature", hunk.lines[7].content);
}
