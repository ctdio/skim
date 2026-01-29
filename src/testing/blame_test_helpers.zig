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
};

// Layout constants
const Layout = struct {
    const gutter_spacing = 2;
    const blame_gutter_width: usize = 56; // From StateHelpers.BLAME_GUTTER_WIDTH
};

/// Line type for diff lines
pub const LineType = enum {
    add,
    delete,
    context,
};

/// Blame information for a single line (mirrors git/blame.zig)
pub const BlameLine = struct {
    commit_hash: [8]u8,
    author: []const u8,
    username: []const u8,
    summary: []const u8,
    timestamp: i64,
    original_lineno: u32,
};

/// Create a BlameLine with test data
pub fn createBlameLine(
    hash: []const u8,
    author: []const u8,
    username: []const u8,
    summary: []const u8,
    timestamp: i64,
) BlameLine {
    var commit_hash: [8]u8 = undefined;
    const copy_len = @min(hash.len, 8);
    @memcpy(commit_hash[0..copy_len], hash[0..copy_len]);
    if (copy_len < 8) {
        @memset(commit_hash[copy_len..], '0');
    }

    return .{
        .commit_hash = commit_hash,
        .author = author,
        .username = username,
        .summary = summary,
        .timestamp = timestamp,
        .original_lineno = 1,
    };
}

/// Create an uncommitted line (hash is all zeros)
pub fn createUncommittedBlameLine() BlameLine {
    return createBlameLine("00000000", "Not Committed Yet", "", "", 0);
}

/// Format author name for display (truncate to max width)
fn formatAuthor(author: []const u8, max_width: usize) []const u8 {
    if (author.len <= max_width) return author;
    return author[0..max_width];
}

/// Format date from timestamp as "Mon DD YYYY"
fn formatDate(buf: []u8, timestamp: i64) []const u8 {
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const secs_per_day: i64 = 86400;
    var days = @divTrunc(timestamp, secs_per_day);

    if (timestamp < 0 and @rem(timestamp, secs_per_day) != 0) {
        days -= 1;
    }

    var year: i32 = 1970;
    var remaining_days = days;

    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    while (remaining_days < 0) {
        year -= 1;
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        remaining_days += days_in_year;
    }

    const days_in_months = if (isLeapYear(year))
        [_]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: usize = 0;
    while (month < 12 and remaining_days >= days_in_months[month]) {
        remaining_days -= days_in_months[month];
        month += 1;
    }

    const day: u32 = @intCast(remaining_days + 1);

    return std.fmt.bufPrint(buf, "{s} {d:2} {}", .{ month_names[month], day, year }) catch "?";
}

/// Format relative time from timestamp (using a fixed "now" for testing)
fn formatRelativeTimeFixed(buf: []u8, timestamp: i64, now: i64) []const u8 {
    const diff = now - timestamp;

    if (diff < 0) {
        return std.fmt.bufPrint(buf, "future", .{}) catch "?";
    }

    const minutes = @divTrunc(diff, 60);
    const hours = @divTrunc(diff, 3600);
    const days = @divTrunc(diff, 86400);
    const weeks = @divTrunc(diff, 604800);
    const months = @divTrunc(diff, 2592000);
    const years = @divTrunc(diff, 31536000);

    if (years > 0) {
        return std.fmt.bufPrint(buf, "{d}y", .{years}) catch "?";
    } else if (months > 0) {
        return std.fmt.bufPrint(buf, "{d}mo", .{months}) catch "?";
    } else if (weeks > 0) {
        return std.fmt.bufPrint(buf, "{d}w", .{weeks}) catch "?";
    } else if (days > 0) {
        return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "?";
    } else if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "?";
    } else if (minutes > 0) {
        return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "now", .{}) catch "?";
    }
}

fn isLeapYear(year: i32) bool {
    if (@rem(year, 400) == 0) return true;
    if (@rem(year, 100) == 0) return false;
    if (@rem(year, 4) == 0) return true;
    return false;
}

/// Render blame info for first line of a commit block
/// Format: "12ab34cd username____ Dec  5 2024 2mo "
pub fn renderBlameFirstLine(
    alloc: Allocator,
    win: vaxis.Window,
    blame: BlameLine,
    row: usize,
    col: usize,
    line_type: ?LineType,
    now_timestamp: i64,
) void {
    const blame_style = getBlameStyle(line_type, false, false);

    var blame_buf: [Layout.blame_gutter_width]u8 = undefined;
    @memset(&blame_buf, ' ');

    // Check if uncommitted
    const is_uncommitted = std.mem.eql(u8, &blame.commit_hash, "00000000");

    if (is_uncommitted) {
        const uncommitted_text = "Uncommitted changes";
        @memcpy(blame_buf[0..uncommitted_text.len], uncommitted_text);
    } else {
        // Copy short hash (8 chars)
        @memcpy(blame_buf[0..8], &blame.commit_hash);
        blame_buf[8] = ' ';

        // Copy username or author (truncated to 12 chars)
        const display_name = if (blame.username.len > 0) blame.username else blame.author;
        const name = formatAuthor(display_name, 12);
        @memcpy(blame_buf[9 .. 9 + name.len], name);
        blame_buf[21] = ' ';

        // Format date as "Mon DD YYYY" (11 chars)
        var date_buf: [16]u8 = undefined;
        const date_str = formatDate(&date_buf, blame.timestamp);
        const date_start: usize = 22;
        const date_len = @min(date_str.len, @as(usize, 11));
        @memcpy(blame_buf[date_start .. date_start + date_len], date_str[0..date_len]);
        blame_buf[33] = ' ';

        // Format relative time (up to 4 chars)
        var time_buf: [8]u8 = undefined;
        const time_str = formatRelativeTimeFixed(&time_buf, blame.timestamp, now_timestamp);
        const time_start: usize = 34;
        const time_len = @min(time_str.len, @as(usize, 4));
        @memcpy(blame_buf[time_start .. time_start + time_len], time_str[0..time_len]);
    }

    const blame_text = alloc.dupe(u8, &blame_buf) catch &blame_buf;
    var blame_seg = [_]vaxis.Cell.Segment{.{
        .text = blame_text,
        .style = blame_style,
    }};
    _ = win.print(&blame_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
}

/// Render blame info for second line of commit block (commit message)
pub fn renderBlameSecondLine(
    alloc: Allocator,
    win: vaxis.Window,
    blame: BlameLine,
    row: usize,
    col: usize,
    line_type: ?LineType,
) void {
    const blame_style = getBlameStyle(line_type, false, false);

    var blame_buf: [Layout.blame_gutter_width]u8 = undefined;
    @memset(&blame_buf, ' ');

    const msg_len = @min(blame.summary.len, Layout.blame_gutter_width);
    @memcpy(blame_buf[0..msg_len], blame.summary[0..msg_len]);

    const blame_text = alloc.dupe(u8, &blame_buf) catch &blame_buf;
    var blame_seg = [_]vaxis.Cell.Segment{.{
        .text = blame_text,
        .style = blame_style,
    }};
    _ = win.print(&blame_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
}

/// Render empty blame gutter (for 3rd+ lines of same commit)
pub fn renderBlameEmpty(
    alloc: Allocator,
    win: vaxis.Window,
    row: usize,
    col: usize,
    line_type: ?LineType,
) void {
    const blame_style = getBlameStyle(line_type, false, false);

    var blame_buf: [Layout.blame_gutter_width]u8 = undefined;
    @memset(&blame_buf, ' ');

    const blame_text = alloc.dupe(u8, &blame_buf) catch &blame_buf;
    var blame_seg = [_]vaxis.Cell.Segment{.{
        .text = blame_text,
        .style = blame_style,
    }};
    _ = win.print(&blame_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
}

/// Get style for blame gutter based on line type
fn getBlameStyle(line_type: ?LineType, is_cursor: bool, is_visual: bool) vaxis.Style {
    if (is_visual) {
        return .{ .fg = Color.dim, .bg = .{ .rgb = [3]u8{ 68, 68, 128 } } };
    } else if (is_cursor) {
        return .{ .fg = Color.dim, .bg = .{ .rgb = [3]u8{ 80, 80, 80 } } };
    } else if (line_type) |lt| {
        return switch (lt) {
            .add => .{ .fg = Color.dim, .bg = Color.diff_add_bg },
            .delete => .{ .fg = Color.dim, .bg = Color.diff_delete_bg },
            .context => .{ .fg = Color.dim },
        };
    }
    return .{ .fg = Color.dim };
}

/// Render a complete diff line with blame gutter
/// This combines blame + line number + content
pub fn renderDiffLineWithBlame(
    alloc: Allocator,
    win: vaxis.Window,
    blame: ?BlameLine,
    blame_display: BlameDisplay,
    lineno: ?u32,
    content: []const u8,
    line_type: LineType,
    row: usize,
    lineno_width: usize,
    now_timestamp: i64,
) void {
    var col: usize = 0;

    // Render sidebar
    const sidebar_style: vaxis.Style = .{ .fg = Color.dim };
    var sidebar_seg = [_]vaxis.Cell.Segment{.{
        .text = "┃",
        .style = sidebar_style,
    }};
    _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    col += 1;

    // Render blame gutter
    if (blame) |b| {
        switch (blame_display) {
            .first_line => renderBlameFirstLine(alloc, win, b, row, col, line_type, now_timestamp),
            .second_line => renderBlameSecondLine(alloc, win, b, row, col, line_type),
            .empty => renderBlameEmpty(alloc, win, row, col, line_type),
        }
    } else {
        renderBlameEmpty(alloc, win, row, col, line_type);
    }
    col += Layout.blame_gutter_width;

    // Render separator between blame and line number
    const separator_style: vaxis.Style = switch (line_type) {
        .add => .{ .fg = Color.dim, .bg = Color.diff_add_bg },
        .delete => .{ .fg = Color.dim, .bg = Color.diff_delete_bg },
        .context => .{ .fg = Color.dim },
    };
    var separator_seg = [_]vaxis.Cell.Segment{.{
        .text = "│",
        .style = separator_style,
    }};
    _ = win.print(&separator_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    col += 1;

    // Render line number
    const sign: u8 = switch (line_type) {
        .add => '+',
        .delete => '-',
        .context => ' ',
    };

    if (lineno) |n| {
        const num_str = std.fmt.allocPrint(alloc, "{d}", .{n}) catch "";
        const padding_needed = lineno_width -| num_str.len -| 1;

        var gutter_list: std.ArrayList(u8) = .{};
        gutter_list.appendNTimes(alloc, ' ', padding_needed) catch {};
        gutter_list.appendSlice(alloc, num_str) catch {};
        gutter_list.append(alloc, sign) catch {};
        const gutter_text = gutter_list.toOwnedSlice(alloc) catch "";

        const sign_style: vaxis.Style = switch (line_type) {
            .add => .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg, .bold = true },
            .delete => .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg, .bold = true },
            .context => .{ .fg = Color.dim },
        };

        var gutter_seg = [_]vaxis.Cell.Segment{.{
            .text = gutter_text,
            .style = sign_style,
        }};
        _ = win.print(&gutter_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    }
    col += lineno_width;

    // Render spacing
    col += Layout.gutter_spacing;

    // Render content
    const content_style: vaxis.Style = switch (line_type) {
        .add => .{ .bg = Color.diff_add_bg },
        .delete => .{ .bg = Color.diff_delete_bg },
        .context => .{},
    };

    var content_seg = [_]vaxis.Cell.Segment{.{
        .text = content,
        .style = content_style,
    }};
    _ = win.print(&content_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
}

/// What to display in the blame column
pub const BlameDisplay = enum {
    first_line, // Full blame info (hash, author, date, relative time)
    second_line, // Commit message
    empty, // Empty (3rd+ line of same commit)
};

// Tests

test "createBlameLine creates valid structure" {
    const blame = createBlameLine("a1b2c3d4", "John Doe", "johndoe", "Fix bug", 1700000000);
    try std.testing.expectEqualStrings("a1b2c3d4", &blame.commit_hash);
    try std.testing.expectEqualStrings("John Doe", blame.author);
    try std.testing.expectEqualStrings("johndoe", blame.username);
    try std.testing.expectEqualStrings("Fix bug", blame.summary);
}

test "createUncommittedBlameLine creates zero hash" {
    const blame = createUncommittedBlameLine();
    try std.testing.expectEqualStrings("00000000", &blame.commit_hash);
}

test "formatDate formats correctly" {
    var buf: [16]u8 = undefined;
    // Jan 15, 2024 00:00:00 UTC = 1705276800
    const result = formatDate(&buf, 1705276800);
    try std.testing.expectEqualStrings("Jan 15 2024", result);
}

test "formatRelativeTimeFixed formats years" {
    var buf: [8]u8 = undefined;
    const now: i64 = 1700000000;
    const two_years_ago = now - (2 * 31536000);
    const result = formatRelativeTimeFixed(&buf, two_years_ago, now);
    try std.testing.expectEqualStrings("2y", result);
}

test "formatRelativeTimeFixed formats months" {
    var buf: [8]u8 = undefined;
    const now: i64 = 1700000000;
    const three_months_ago = now - (3 * 2592000);
    const result = formatRelativeTimeFixed(&buf, three_months_ago, now);
    try std.testing.expectEqualStrings("3mo", result);
}

test "formatRelativeTimeFixed formats days" {
    var buf: [8]u8 = undefined;
    const now: i64 = 1700000000;
    const five_days_ago = now - (5 * 86400);
    const result = formatRelativeTimeFixed(&buf, five_days_ago, now);
    try std.testing.expectEqualStrings("5d", result);
}
