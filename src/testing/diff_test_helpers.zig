const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

// Color constants for testing (subset from rendering/common.zig)
const Color = struct {
    const white: vaxis.Cell.Color = .{ .index = 7 };
    const dim: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 100, 100 } };
    const diff_add_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 37, 53, 37 } };
    const diff_delete_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 54, 32, 32 } };
    const diff_sign_add: vaxis.Cell.Color = .{ .rgb = [3]u8{ 63, 185, 80 } };
    const diff_sign_delete: vaxis.Cell.Color = .{ .rgb = [3]u8{ 247, 81, 73 } };
    const cursor_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 80, 80, 80 } };
    const cursor_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 255, 255 } };
};

// Layout constants for testing (subset from rendering/common.zig)
const Layout = struct {
    const gutter_spacing = 2;
};

// Types for diff structures (mirrors git/parser.zig types)
pub const LineType = enum {
    add,
    delete,
    context,
};

pub const Line = struct {
    line_type: LineType,
    content: []const u8,
    old_lineno: ?u32,
    new_lineno: ?u32,
};

pub const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    context: []const u8,
};

pub const Hunk = struct {
    header: HunkHeader,
    lines: []const Line,
    highlights: ?[]const u8, // Simplified - just need to store something
    old_highlights: ?[]const u8,

    pub fn deinit(self: *const Hunk, allocator: Allocator) void {
        allocator.free(self.header.context);
        for (self.lines) |line| {
            _ = line; // Content is not owned by Line in tests
        }
        allocator.free(self.lines);
    }
};

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []const Hunk,
    is_untracked: bool,

    pub fn deinit(self: *const FileDiff, allocator: Allocator) void {
        allocator.free(self.old_path);
        allocator.free(self.new_path);
        for (self.hunks) |*hunk| {
            hunk.deinit(allocator);
        }
        allocator.free(self.hunks);
    }
};

/// TestDiffBuilder provides a fluent interface for constructing test FileDiff structures.
/// Use init() to start, chain builder methods, then call build() to get the final FileDiff.
pub const TestDiffBuilder = struct {
    allocator: Allocator,
    old_path: []const u8,
    new_path: []const u8,
    is_untracked: bool,
    hunks: std.ArrayList(Hunk),
    current_hunk: ?CurrentHunk,

    const CurrentHunk = struct {
        header: HunkHeader,
        lines: std.ArrayList(Line),
    };

    pub fn init(allocator: Allocator, path: []const u8) TestDiffBuilder {
        return .{
            .allocator = allocator,
            .old_path = path,
            .new_path = path,
            .is_untracked = false,
            .hunks = .{},
            .current_hunk = null,
        };
    }

    pub fn withOldPath(self: *TestDiffBuilder, path: []const u8) *TestDiffBuilder {
        self.old_path = path;
        return self;
    }

    pub fn withNewPath(self: *TestDiffBuilder, path: []const u8) *TestDiffBuilder {
        self.new_path = path;
        return self;
    }

    pub fn withUntracked(self: *TestDiffBuilder, untracked: bool) *TestDiffBuilder {
        self.is_untracked = untracked;
        return self;
    }

    pub fn addHunk(
        self: *TestDiffBuilder,
        old_start: u32,
        old_count: u32,
        new_start: u32,
        new_count: u32,
    ) *TestDiffBuilder {
        // Finalize previous hunk if any
        self.finalizeCurrentHunk();

        // Start new hunk
        self.current_hunk = .{
            .header = .{
                .old_start = old_start,
                .old_count = old_count,
                .new_start = new_start,
                .new_count = new_count,
                .context = "",
            },
            .lines = .{},
        };
        return self;
    }

    pub fn withHunkContext(self: *TestDiffBuilder, context: []const u8) *TestDiffBuilder {
        if (self.current_hunk) |*hunk| {
            hunk.header.context = context;
        }
        return self;
    }

    pub fn addLine(self: *TestDiffBuilder, line_type: LineType, content: []const u8) *TestDiffBuilder {
        if (self.current_hunk) |*hunk| {
            const line = Line{
                .line_type = line_type,
                .content = content,
                .old_lineno = if (line_type != .add) @as(?u32, hunk.header.old_start + @as(u32, @intCast(hunk.lines.items.len))) else null,
                .new_lineno = if (line_type != .delete) @as(?u32, hunk.header.new_start + @as(u32, @intCast(hunk.lines.items.len))) else null,
            };
            hunk.lines.append(self.allocator, line) catch {};
        }
        return self;
    }

    pub fn addContextLine(self: *TestDiffBuilder, content: []const u8) *TestDiffBuilder {
        return self.addLine(.context, content);
    }

    pub fn addAddedLine(self: *TestDiffBuilder, content: []const u8) *TestDiffBuilder {
        return self.addLine(.add, content);
    }

    pub fn addRemovedLine(self: *TestDiffBuilder, content: []const u8) *TestDiffBuilder {
        return self.addLine(.delete, content);
    }

    fn finalizeCurrentHunk(self: *TestDiffBuilder) void {
        if (self.current_hunk) |*hunk| {
            // Duplicate context string for the hunk header
            const context_dupe = self.allocator.dupe(u8, hunk.header.context) catch "";

            const final_hunk = Hunk{
                .header = .{
                    .old_start = hunk.header.old_start,
                    .old_count = hunk.header.old_count,
                    .new_start = hunk.header.new_start,
                    .new_count = hunk.header.new_count,
                    .context = context_dupe,
                },
                .lines = hunk.lines.toOwnedSlice(self.allocator) catch &[_]Line{},
                .highlights = null,
                .old_highlights = null,
            };
            self.hunks.append(self.allocator, final_hunk) catch {};
            self.current_hunk = null;
        }
    }

    pub fn build(self: *TestDiffBuilder) FileDiff {
        // Finalize any pending hunk
        self.finalizeCurrentHunk();

        return FileDiff{
            .old_path = self.allocator.dupe(u8, self.old_path) catch "",
            .new_path = self.allocator.dupe(u8, self.new_path) catch "",
            .hunks = self.hunks.toOwnedSlice(self.allocator) catch &[_]Hunk{},
            .is_untracked = self.is_untracked,
        };
    }

    pub fn deinit(self: *TestDiffBuilder) void {
        // Clean up any unfinalized hunk
        if (self.current_hunk) |*hunk| {
            hunk.lines.deinit(self.allocator);
        }
        self.hunks.deinit(self.allocator);
    }
};

/// Create a simple FileDiff with a single file path (shorthand helper)
pub fn createFileDiff(allocator: Allocator, path: []const u8) FileDiff {
    return FileDiff{
        .old_path = allocator.dupe(u8, path) catch "",
        .new_path = allocator.dupe(u8, path) catch "",
        .hunks = &[_]Hunk{},
        .is_untracked = false,
    };
}

/// Create a Hunk structure (shorthand helper)
pub fn createHunk(
    allocator: Allocator,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
) Hunk {
    return Hunk{
        .header = .{
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
            .context = allocator.dupe(u8, "") catch "",
        },
        .lines = &[_]Line{},
        .highlights = null,
        .old_highlights = null,
    };
}

/// Create a Line structure (shorthand helper)
pub fn createLine(line_type: LineType, content: []const u8, old_lineno: ?u32, new_lineno: ?u32) Line {
    return Line{
        .line_type = line_type,
        .content = content,
        .old_lineno = old_lineno,
        .new_lineno = new_lineno,
    };
}

/// Calculate diff stats from a FileDiff (additions and deletions)
pub const DiffStats = struct {
    additions: usize,
    deletions: usize,
};

pub fn calculateDiffStats(file: *const FileDiff) DiffStats {
    var additions: usize = 0;
    var deletions: usize = 0;

    for (file.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .add => additions += 1,
                .delete => deletions += 1,
                .context => {},
            }
        }
    }

    return .{ .additions = additions, .deletions = deletions };
}

// Standalone Rendering Functions
// These render diff elements without requiring full App context

/// Render a file header to a window
/// Format: "path/to/file.ext  +N -M"
/// If frame_alloc is provided, uses it for formatted strings (for snapshot testing).
pub fn renderFileHeader(
    win: vaxis.Window,
    path: []const u8,
    additions: usize,
    deletions: usize,
    row: usize,
    is_cursor: bool,
) void {
    renderFileHeaderAlloc(win, path, additions, deletions, row, is_cursor, null);
}

/// Render a file header with allocator for persistent strings (for snapshot testing)
pub fn renderFileHeaderAlloc(
    win: vaxis.Window,
    path: []const u8,
    additions: usize,
    deletions: usize,
    row: usize,
    is_cursor: bool,
    frame_alloc: ?Allocator,
) void {
    if (row >= win.height) return;

    // Build path text with trailing spaces
    var path_buf: [1024]u8 = undefined;
    const path_text = if (frame_alloc) |alloc|
        std.fmt.allocPrint(alloc, "{s}  ", .{path}) catch path
    else
        std.fmt.bufPrint(&path_buf, "{s}  ", .{path}) catch path;

    // Build additions text
    var add_buf: [64]u8 = undefined;
    const add_text = if (frame_alloc) |alloc|
        std.fmt.allocPrint(alloc, "+{d} ", .{additions}) catch "+0 "
    else
        std.fmt.bufPrint(&add_buf, "+{d} ", .{additions}) catch "+0 ";

    // Build deletions text
    var del_buf: [64]u8 = undefined;
    const del_text = if (frame_alloc) |alloc|
        std.fmt.allocPrint(alloc, "-{d}", .{deletions}) catch "-0"
    else
        std.fmt.bufPrint(&del_buf, "-{d}", .{deletions}) catch "-0";

    // Styles
    const path_style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.white, .bg = Color.cursor_bg, .bold = true }
    else
        .{ .fg = Color.white, .bold = true };

    const add_style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.diff_sign_add, .bg = Color.cursor_bg }
    else
        .{ .fg = Color.diff_sign_add };

    const del_style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.diff_sign_delete, .bg = Color.cursor_bg }
    else
        .{ .fg = Color.diff_sign_delete };

    var segments = [_]vaxis.Cell.Segment{
        .{ .text = path_text, .style = path_style },
        .{ .text = add_text, .style = add_style },
        .{ .text = del_text, .style = del_style },
    };

    _ = win.print(&segments, .{
        .row_offset = @intCast(row),
        .col_offset = 0,
    });
}

/// Render a hunk header to a window
/// Format: "| @@ -old_start,old_count +new_start,new_count @@ context"
pub fn renderHunkHeader(
    win: vaxis.Window,
    hunk: Hunk,
    row: usize,
    is_cursor: bool,
) void {
    if (row >= win.height) return;

    // Build hunk header text
    var buf: [256]u8 = undefined;
    const header_text = std.fmt.bufPrint(
        &buf,
        "@@ -{d},{d} +{d},{d} @@ {s}",
        .{
            hunk.header.old_start,
            hunk.header.old_count,
            hunk.header.new_start,
            hunk.header.new_count,
            hunk.header.context,
        },
    ) catch "@@ ... @@";

    // Style
    const style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.white, .bg = Color.cursor_bg }
    else
        .{ .fg = Color.dim };

    // Render sidebar
    const sidebar_style: vaxis.Style = .{ .fg = Color.dim };
    var sidebar_seg = [_]vaxis.Cell.Segment{.{
        .text = "\xe2\x94\x83", // Unicode box drawing character for vertical bar
        .style = sidebar_style,
    }};
    _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });

    // Render header text after sidebar
    var header_seg = [_]vaxis.Cell.Segment{.{
        .text = header_text,
        .style = style,
    }};
    _ = win.print(&header_seg, .{
        .row_offset = @intCast(row),
        .col_offset = 1, // After sidebar
    });
}

/// Render a diff line to a window
/// Format: "| lineno+/- content"
pub fn renderDiffLine(
    win: vaxis.Window,
    line: Line,
    row: usize,
    gutter_width: usize,
    is_cursor: bool,
) void {
    if (row >= win.height) return;

    // Get line style based on type
    const base_style: vaxis.Style = switch (line.line_type) {
        .add => .{ .bg = Color.diff_add_bg },
        .delete => .{ .bg = Color.diff_delete_bg },
        .context => .{},
    };

    const style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
    else
        base_style;

    // Render sidebar
    const sidebar_style: vaxis.Style = .{ .fg = Color.dim };
    var sidebar_seg = [_]vaxis.Cell.Segment{.{
        .text = "\xe2\x94\x83", // Unicode box drawing character
        .style = sidebar_style,
    }};
    _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });

    // Format line number
    var num_buf: [16]u8 = undefined;
    const lineno = switch (line.line_type) {
        .delete => line.old_lineno,
        .add, .context => line.new_lineno,
    };

    const num_str = if (lineno) |n|
        std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch ""
    else
        "";

    // Right-justify line number in gutter
    var gutter_buf: [32]u8 = undefined;
    const padding_needed = gutter_width -| num_str.len -| 1; // -1 for sign
    var i: usize = 0;
    while (i < padding_needed) : (i += 1) {
        gutter_buf[i] = ' ';
    }
    @memcpy(gutter_buf[padding_needed .. padding_needed + num_str.len], num_str);

    // Add sign
    const sign: u8 = switch (line.line_type) {
        .add => '+',
        .delete => '-',
        .context => ' ',
    };
    gutter_buf[padding_needed + num_str.len] = sign;
    const gutter_text = gutter_buf[0 .. padding_needed + num_str.len + 1];

    // Get sign style
    const sign_style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
    else switch (line.line_type) {
        .add => .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg, .bold = true },
        .delete => .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg, .bold = true },
        .context => .{ .fg = Color.dim },
    };

    // Render gutter
    var gutter_seg = [_]vaxis.Cell.Segment{.{
        .text = gutter_text,
        .style = sign_style,
    }};
    _ = win.print(&gutter_seg, .{ .row_offset = @intCast(row), .col_offset = 1 }); // After sidebar

    // Render content after gutter + spacing
    const content_col = 1 + gutter_width + Layout.gutter_spacing;
    var content_seg = [_]vaxis.Cell.Segment{.{
        .text = line.content,
        .style = style,
    }};
    _ = win.print(&content_seg, .{
        .row_offset = @intCast(row),
        .col_offset = @intCast(content_col),
    });
}

// =============================================================================
// Snapshot-friendly render functions (with allocator for persistent strings)
// =============================================================================

/// Render a hunk header with allocator for persistent strings (for snapshot testing)
pub fn renderHunkHeaderAlloc(
    win: vaxis.Window,
    hunk: Hunk,
    row: usize,
    is_cursor: bool,
    alloc: Allocator,
) void {
    if (row >= win.height) return;

    // Build hunk header text with allocator
    const header_text = std.fmt.allocPrint(
        alloc,
        "@@ -{d},{d} +{d},{d} @@ {s}",
        .{
            hunk.header.old_start,
            hunk.header.old_count,
            hunk.header.new_start,
            hunk.header.new_count,
            hunk.header.context,
        },
    ) catch "@@ ... @@";

    // Style
    const style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.white, .bg = Color.cursor_bg }
    else
        .{ .fg = Color.dim };

    // Render sidebar
    const sidebar_style: vaxis.Style = .{ .fg = Color.dim };
    var sidebar_seg = [_]vaxis.Cell.Segment{.{
        .text = "┃",
        .style = sidebar_style,
    }};
    _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });

    // Render header text after sidebar
    var header_seg = [_]vaxis.Cell.Segment{.{
        .text = header_text,
        .style = style,
    }};
    _ = win.print(&header_seg, .{
        .row_offset = @intCast(row),
        .col_offset = 1,
    });
}

/// Render a diff line with allocator for persistent strings (for snapshot testing)
pub fn renderDiffLineAlloc(
    win: vaxis.Window,
    line: Line,
    row: usize,
    gutter_width: usize,
    is_cursor: bool,
    alloc: Allocator,
) void {
    if (row >= win.height) return;

    // Get line style based on type
    const base_style: vaxis.Style = switch (line.line_type) {
        .add => .{ .bg = Color.diff_add_bg },
        .delete => .{ .bg = Color.diff_delete_bg },
        .context => .{},
    };

    const style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
    else
        base_style;

    // Render sidebar
    const sidebar_style: vaxis.Style = .{ .fg = Color.dim };
    var sidebar_seg = [_]vaxis.Cell.Segment{.{
        .text = "┃",
        .style = sidebar_style,
    }};
    _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });

    // Format line number with allocator
    const lineno = switch (line.line_type) {
        .delete => line.old_lineno,
        .add, .context => line.new_lineno,
    };

    const num_str = if (lineno) |n|
        std.fmt.allocPrint(alloc, "{d}", .{n}) catch ""
    else
        "";

    // Build gutter text with allocator
    const padding_needed = gutter_width -| num_str.len -| 1;
    const sign: u8 = switch (line.line_type) {
        .add => '+',
        .delete => '-',
        .context => ' ',
    };

    const gutter_text = blk: {
        var list: std.ArrayList(u8) = .{};
        list.appendNTimes(alloc, ' ', padding_needed) catch {};
        list.appendSlice(alloc, num_str) catch {};
        list.append(alloc, sign) catch {};
        break :blk list.toOwnedSlice(alloc) catch "";
    };

    // Get sign style
    const sign_style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
    else switch (line.line_type) {
        .add => .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg, .bold = true },
        .delete => .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg, .bold = true },
        .context => .{ .fg = Color.dim },
    };

    // Render gutter
    var gutter_seg = [_]vaxis.Cell.Segment{.{
        .text = gutter_text,
        .style = sign_style,
    }};
    _ = win.print(&gutter_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

    // Render content after gutter + spacing
    const content_col = 1 + gutter_width + Layout.gutter_spacing;
    var content_seg = [_]vaxis.Cell.Segment{.{
        .text = line.content,
        .style = style,
    }};
    _ = win.print(&content_seg, .{
        .row_offset = @intCast(row),
        .col_offset = @intCast(content_col),
    });
}

// Tests

test "TestDiffBuilder creates FileDiff with path" {
    const allocator = std.testing.allocator;

    var builder = TestDiffBuilder.init(allocator, "src/main.zig");
    defer builder.deinit();

    var file = builder.build();
    defer file.deinit(allocator);

    try std.testing.expectEqualStrings("src/main.zig", file.new_path);
    try std.testing.expectEqualStrings("src/main.zig", file.old_path);
    try std.testing.expectEqual(false, file.is_untracked);
}

test "TestDiffBuilder withUntracked sets flag" {
    const allocator = std.testing.allocator;

    var builder = TestDiffBuilder.init(allocator, "new_file.zig");
    _ = builder.withUntracked(true);
    defer builder.deinit();

    var file = builder.build();
    defer file.deinit(allocator);

    try std.testing.expectEqual(true, file.is_untracked);
}

test "TestDiffBuilder addHunk creates hunk" {
    const allocator = std.testing.allocator;

    var builder = TestDiffBuilder.init(allocator, "test.zig");
    _ = builder.addHunk(10, 7, 10, 9);
    defer builder.deinit();

    var file = builder.build();
    defer file.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), file.hunks.len);
    try std.testing.expectEqual(@as(u32, 10), file.hunks[0].header.old_start);
    try std.testing.expectEqual(@as(u32, 7), file.hunks[0].header.old_count);
    try std.testing.expectEqual(@as(u32, 10), file.hunks[0].header.new_start);
    try std.testing.expectEqual(@as(u32, 9), file.hunks[0].header.new_count);
}

test "TestDiffBuilder addLine adds lines to current hunk" {
    const allocator = std.testing.allocator;

    var builder = TestDiffBuilder.init(allocator, "test.zig");
    _ = builder.addHunk(1, 3, 1, 4);
    _ = builder.addContextLine("fn main() void {");
    _ = builder.addRemovedLine("    const old = 1;");
    _ = builder.addAddedLine("    const new = 2;");
    _ = builder.addAddedLine("    const extra = 3;");
    defer builder.deinit();

    var file = builder.build();
    defer file.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), file.hunks.len);
    try std.testing.expectEqual(@as(usize, 4), file.hunks[0].lines.len);
    try std.testing.expectEqual(LineType.context, file.hunks[0].lines[0].line_type);
    try std.testing.expectEqual(LineType.delete, file.hunks[0].lines[1].line_type);
    try std.testing.expectEqual(LineType.add, file.hunks[0].lines[2].line_type);
    try std.testing.expectEqual(LineType.add, file.hunks[0].lines[3].line_type);
}

test "createLine creates correct Line struct" {
    const line = createLine(.add, "new content", null, 42);

    try std.testing.expectEqual(LineType.add, line.line_type);
    try std.testing.expectEqualStrings("new content", line.content);
    try std.testing.expectEqual(@as(?u32, null), line.old_lineno);
    try std.testing.expectEqual(@as(?u32, 42), line.new_lineno);
}

test "calculateDiffStats counts additions and deletions" {
    const allocator = std.testing.allocator;

    var builder = TestDiffBuilder.init(allocator, "test.zig");
    _ = builder.addHunk(1, 3, 1, 5);
    _ = builder.addContextLine("context");
    _ = builder.addRemovedLine("removed 1");
    _ = builder.addRemovedLine("removed 2");
    _ = builder.addAddedLine("added 1");
    _ = builder.addAddedLine("added 2");
    _ = builder.addAddedLine("added 3");
    defer builder.deinit();

    var file = builder.build();
    defer file.deinit(allocator);

    const stats = calculateDiffStats(&file);
    try std.testing.expectEqual(@as(usize, 3), stats.additions);
    try std.testing.expectEqual(@as(usize, 2), stats.deletions);
}

// Rendering Integration Tests
// Note: Due to vaxis storing slice references (not copies), we use direct rendering
// with string literals and verify cell-level content rather than snapshot tests.
const harness = @import("harness.zig");

test "renderFileHeader writes path to first cell" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    // Use string literal for path (static lifetime)
    renderFileHeader(win, "src/main.zig", 0, 0, 0, false);

    // Verify first few cells have expected content
    // The path starts at column 0
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expectEqualStrings("s", cell0.?.char.grapheme);
}

test "renderFileHeader applies correct style to path" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    renderFileHeader(win, "test.zig", 10, 5, 0, false);

    // Path should have white foreground and bold
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expect(cell0.?.style.bold);
    try std.testing.expectEqual(Color.white, cell0.?.style.fg);
}

test "renderHunkHeader renders sidebar character" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const hunk = Hunk{
        .header = .{
            .old_start = 10,
            .old_count = 7,
            .new_start = 10,
            .new_count = 9,
            .context = "",
        },
        .lines = &[_]Line{},
        .highlights = null,
        .old_highlights = null,
    };
    renderHunkHeader(win, hunk, 0, false);

    // First column should have the sidebar character
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    // Sidebar is a box drawing vertical bar character
    try std.testing.expectEqualStrings("\xe2\x94\x83", cell0.?.char.grapheme);
}

test "renderHunkHeader applies dim style" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const hunk = Hunk{
        .header = .{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .context = "",
        },
        .lines = &[_]Line{},
        .highlights = null,
        .old_highlights = null,
    };
    renderHunkHeader(win, hunk, 0, false);

    // Check sidebar style is dim
    const sidebar_cell = ctx.screen.readCell(0, 0);
    try std.testing.expect(sidebar_cell != null);
    try std.testing.expectEqual(Color.dim, sidebar_cell.?.style.fg);
}

test "renderDiffLine renders sidebar" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const line = createLine(.context, "content", 10, 10);
    renderDiffLine(win, line, 0, 5, false);

    // First column should have sidebar
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expectEqualStrings("\xe2\x94\x83", cell0.?.char.grapheme);
}

test "renderDiffLine renders content at correct column" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const line = createLine(.context, "X", 10, 10);
    const gutter_width: usize = 5;
    renderDiffLine(win, line, 0, gutter_width, false);

    // Content starts at: sidebar(1) + gutter_width(5) + spacing(2) = 8
    const content_col = 1 + gutter_width + Layout.gutter_spacing;
    const content_cell = ctx.screen.readCell(@intCast(content_col), 0);
    try std.testing.expect(content_cell != null);
    try std.testing.expectEqualStrings("X", content_cell.?.char.grapheme);
}

test "renderDiffLine applies add style" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const line = createLine(.add, "Y", null, 11);
    const gutter_width: usize = 5;
    renderDiffLine(win, line, 0, gutter_width, false);

    // Content cell should have add background
    const content_col = 1 + gutter_width + Layout.gutter_spacing;
    const content_cell = ctx.screen.readCell(@intCast(content_col), 0);
    try std.testing.expect(content_cell != null);
    try std.testing.expectEqual(Color.diff_add_bg, content_cell.?.style.bg);
}

test "renderDiffLine applies delete style" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const line = createLine(.delete, "Z", 10, null);
    const gutter_width: usize = 5;
    renderDiffLine(win, line, 0, gutter_width, false);

    // Content cell should have delete background
    const content_col = 1 + gutter_width + Layout.gutter_spacing;
    const content_cell = ctx.screen.readCell(@intCast(content_col), 0);
    try std.testing.expect(content_cell != null);
    try std.testing.expectEqual(Color.diff_delete_bg, content_cell.?.style.bg);
}
