//! Lays out and draws the Conversation screen: the PR title and status row,
//! the description, then every timeline entry with its body as markdown.
//! `layout` is pure (rows of styled segments); `draw` paints a scrolled
//! window of them with the cursor row highlighted.

const std = @import("std");
const vaxis = @import("vaxis");
const cells = @import("../../rendering/cells.zig");
const common = @import("../../rendering/common.zig");
const description_block = @import("../../rendering/description_block.zig");
const description = @import("../description.zig");
const timeline = @import("timeline.zig");

const Allocator = std.mem.Allocator;
const Color = common.Color;
const Segment = vaxis.Cell.Segment;

/// What the screen shows. Strings are borrowed from the review session.
pub const View = struct {
    number: u32,
    title: []const u8,
    author: []const u8,
    /// Null while the review data is not in, which drops the status row.
    status: ?description_block.StatusSource,
    description: []const description.Line,
    /// Shown in place of an empty description.
    placeholder: []const u8,
    entries: []const timeline.Entry,
};

pub const Row = struct {
    segments: []const Segment = &.{},
    /// Background from `fill_col` to the right edge (code blocks).
    fill_bg: ?vaxis.Color = null,
    fill_col: usize = 0,
    /// Session thread index when the row belongs to a code-thread entry.
    thread: ?usize = null,
};

const Styles = struct {
    const title: vaxis.Style = .{ .fg = Color.bright_white, .bold = true };
    const number: vaxis.Style = .{ .fg = Color.dim_gray };
    const section: vaxis.Style = .{ .fg = Color.bright_white, .bold = true };
    const meta: vaxis.Style = .{ .fg = Color.dim_gray };
    const author: vaxis.Style = .{ .fg = Color.cyan, .bold = true };
    const path: vaxis.Style = .{ .fg = Color.yellow };
    const ok: vaxis.Style = .{ .fg = Color.green };
    const failed: vaxis.Style = .{ .fg = Color.red };
    const placeholder: vaxis.Style = .{ .fg = Color.dim_gray, .italic = true };
};

/// Left margin before every row.
const margin = " ";
/// Indent of an entry's body under its header.
const body_indent = "   ";
/// Narrowest body column; below this rows clip instead of wrapping.
const min_body_width = 12;

pub fn layout(arena: Allocator, params: struct { view: View, width: usize }) ![]Row {
    const view = params.view;
    const body_width = @max(min_body_width, params.width -| (margin.len + body_indent.len + 1));
    var rows: std.ArrayList(Row) = .empty;

    try rows.append(arena, .{ .segments = try dupeSegments(arena, &.{
        .{ .text = margin },
        .{ .text = try std.fmt.allocPrint(arena, "#{d} ", .{view.number}), .style = Styles.number },
        .{ .text = view.title, .style = Styles.title },
        .{ .text = "  " },
        .{ .text = view.author, .style = Styles.author },
    }) });
    if (view.status) |source| {
        const status = try description_block.statusRow(arena, source);
        try rows.append(arena, .{ .segments = try std.mem.concat(arena, Segment, &.{ &.{.{ .text = margin }}, status }) });
    }
    try rows.append(arena, .{});

    try appendSection(arena, &rows, "Description");
    if (view.description.len == 0) {
        try rows.append(arena, .{ .segments = try dupeSegments(arena, &.{ .{ .text = margin ++ body_indent }, .{ .text = view.placeholder, .style = Styles.placeholder } }) });
    } else {
        try appendMarkdown(arena, &rows, .{ .lines = view.description, .width = body_width, .thread = null });
    }
    try rows.append(arena, .{});

    try appendSection(arena, &rows, try std.fmt.allocPrint(arena, "Conversation · {d}", .{view.entries.len}));
    try rows.append(arena, .{});
    if (view.entries.len == 0) {
        try rows.append(arena, .{ .segments = try dupeSegments(arena, &.{ .{ .text = margin ++ body_indent }, .{ .text = "No comments yet.", .style = Styles.placeholder } }) });
    }
    for (view.entries) |entry| {
        const thread: ?usize = switch (entry.kind) {
            .thread => |t| t.index,
            else => null,
        };
        try rows.append(arena, .{ .segments = try entryHeader(arena, entry), .thread = thread });
        if (std.mem.trim(u8, entry.body, " \t\r\n").len > 0) {
            const lines = try description.layout(arena, entry.body);
            try appendMarkdown(arena, &rows, .{ .lines = lines, .width = body_width, .thread = thread });
        }
        try rows.append(arena, .{ .thread = thread });
    }
    return rows.items;
}

/// Paint `rows[scroll..]` into `win`, the `cursor` row on the diff's cursor
/// background.
pub fn draw(win: vaxis.Window, params: struct {
    rows: []const Row,
    cursor: usize,
    scroll: usize,
    frame_allocator: Allocator,
}) void {
    var screen_row: usize = 0;
    var index = params.scroll;
    while (screen_row < win.height and index < params.rows.len) : ({
        screen_row += 1;
        index += 1;
    }) {
        const row = params.rows[index];
        const is_cursor = index == params.cursor;
        var segments = row.segments;
        if (is_cursor) {
            fill(win, .{ .row = screen_row, .col = 0, .bg = Color.cursor_bg });
            segments = tint(params.frame_allocator, segments) catch segments;
        }
        if (row.fill_bg) |bg| fill(win, .{ .row = screen_row, .col = row.fill_col, .bg = bg });
        _ = cells.print(win, segments, .{ .row_offset = @intCast(screen_row), .wrap = .none });
    }
}

/// `● alice commented · 2025-01-03 12:00`, `✓ carol approved · …`, or
/// `▸ dave on src/x.zig:42 · 1 reply · resolved · …`.
fn entryHeader(arena: Allocator, entry: timeline.Entry) ![]const Segment {
    const author = if (entry.author.len == 0) "ghost" else entry.author;
    const when = try shortDate(arena, entry.at);
    var segments: std.ArrayList(Segment) = .empty;
    try segments.append(arena, .{ .text = margin });
    switch (entry.kind) {
        .comment => try segments.appendSlice(arena, &.{
            .{ .text = "● ", .style = Styles.meta },
            .{ .text = author, .style = Styles.author },
            .{ .text = " commented", .style = Styles.meta },
        }),
        .review => |state| {
            const icon: Segment = switch (state) {
                .approved => .{ .text = "✓ ", .style = Styles.ok },
                .changes_requested => .{ .text = "✗ ", .style = Styles.failed },
                else => .{ .text = "● ", .style = Styles.meta },
            };
            const verb = switch (state) {
                .approved => " approved",
                .changes_requested => " requested changes",
                .dismissed => " reviewed (dismissed)",
                else => " reviewed",
            };
            try segments.appendSlice(arena, &.{ icon, .{ .text = author, .style = Styles.author }, .{ .text = verb, .style = Styles.meta } });
        },
        .thread => |thread| {
            const location = if (thread.line) |line|
                try std.fmt.allocPrint(arena, "{s}:{d}", .{ thread.path, line })
            else
                thread.path;
            try segments.appendSlice(arena, &.{
                .{ .text = "▸ ", .style = Styles.meta },
                .{ .text = author, .style = Styles.author },
                .{ .text = " on ", .style = Styles.meta },
                .{ .text = location, .style = Styles.path },
            });
            if (thread.replies > 0) {
                const replies = try std.fmt.allocPrint(arena, " · {d} repl{s}", .{ thread.replies, if (thread.replies == 1) "y" else "ies" });
                try segments.append(arena, .{ .text = replies, .style = Styles.meta });
            }
            if (thread.resolved) try segments.append(arena, .{ .text = " · resolved", .style = Styles.ok });
            if (thread.outdated) try segments.append(arena, .{ .text = " · outdated", .style = Styles.meta });
        },
    }
    if (when.len > 0) try segments.append(arena, .{ .text = try std.fmt.allocPrint(arena, " · {s}", .{when}), .style = Styles.meta });
    return segments.items;
}

fn appendSection(arena: Allocator, rows: *std.ArrayList(Row), title: []const u8) !void {
    try rows.append(arena, .{ .segments = try dupeSegments(arena, &.{ .{ .text = margin }, .{ .text = title, .style = Styles.section } }) });
}

fn appendMarkdown(arena: Allocator, rows: *std.ArrayList(Row), params: struct {
    lines: []const description.Line,
    width: usize,
    thread: ?usize,
}) !void {
    const lead = margin ++ body_indent;
    for (params.lines) |line| {
        const planned = try description_block.planMarkdownLine(arena, .{ .line = line, .inner_width = params.width });
        for (planned) |p| {
            try rows.append(arena, .{
                .segments = try std.mem.concat(arena, Segment, &.{ &.{ .{ .text = lead }, .{ .text = p.lead, .style = p.lead_style } }, p.pieces }),
                .fill_bg = p.fill_bg,
                .fill_col = lead.len,
                .thread = params.thread,
            });
        }
    }
}

/// `2025-01-03T12:34:56Z` -> `2025-01-03 12:34`; anything else as given.
fn shortDate(arena: Allocator, at: []const u8) ![]const u8 {
    if (at.len < 16 or at[10] != 'T') return at;
    return std.mem.concat(arena, u8, &.{ at[0..10], " ", at[11..16] });
}

fn dupeSegments(arena: Allocator, segments: []const Segment) ![]const Segment {
    return arena.dupe(Segment, segments);
}

fn tint(arena: Allocator, segments: []const Segment) ![]const Segment {
    const tinted = try arena.dupe(Segment, segments);
    for (tinted) |*seg| {
        if (seg.style.bg == .default) seg.style.bg = Color.cursor_bg;
    }
    return tinted;
}

fn fill(win: vaxis.Window, params: struct { row: usize, col: usize, bg: vaxis.Color }) void {
    if (params.col >= win.width) return;
    cells.fillGlyph(win, " ", .{
        .col = @intCast(params.col),
        .row = @intCast(params.row),
        .count = @intCast(win.width - params.col),
        .style = .{ .bg = params.bg },
    });
}
