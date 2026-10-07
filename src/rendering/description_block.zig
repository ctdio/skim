//! App-free renderer for the PR description block drawn above the first file
//! of a review diff, plus the matching row-height calculation. The LineMap emits
//! one `pr_description` record per display line of the description (see
//! `pr/description.zig`); this module draws one record at a time behind the
//! same left bar diff lines use, and reports how many rows it took.
//! `rowHeight` and `drawRow` both go through `planBodyRows`, so navigation
//! reserves exactly what gets painted.

const std = @import("std");
const vaxis = @import("vaxis");
const cells = @import("cells.zig");
const common = @import("common.zig");
const width_util = @import("width.zig");
const line_map = @import("../line_map.zig");
const description = @import("../pr/description.zig");
const review_parse = @import("../pr/review_parse.zig");
const review_status = @import("../pr/review_status.zig");
const md_colors = @import("../agent/markdown/colors.zig");

const Allocator = std.mem.Allocator;
const Color = common.Color;
const md = md_colors.default;

pub const Row = @FieldType(line_map.LineType, "pr_description");

/// What the block shows. Strings are borrowed from the review session.
pub const DescriptionView = struct {
    number: u32,
    title: []const u8,
    author: []const u8,
    head_ref: []const u8 = "",
    base_ref: []const u8 = "",
    is_draft: bool = false,
    lines: []const description.Line,
    /// Shown as the only line when `lines` is empty ("No description.", or a
    /// loading / unavailable note while the review data is not in yet).
    placeholder: []const u8,
    collapsed: bool,
    /// Reviews and checks for the status row under the title. Null while the
    /// review data is not in, which drops the row.
    status: ?StatusSource = null,
};

pub const StatusSource = struct {
    reviews: []const review_parse.Review,
    checks: []const review_parse.CheckRun,
};

/// One wrapped row of a body line: the lead (indent + list marker, or the
/// matching blank run on continuation rows) and the styled content after it.
pub const PlannedRow = struct {
    lead: []const u8,
    lead_style: vaxis.Style,
    pieces: []const vaxis.Cell.Segment,
    /// Background painted across the whole content column (code blocks).
    fill_bg: ?vaxis.Color = null,
};

/// Narrowest content column; below this rows clip instead of wrapping
/// every word onto its own row.
const min_inner_width = 12;

/// Lines the LineMap reserves for `lines`: one per display line, and one for
/// the placeholder when there are none.
pub fn lineCount(lines: []const description.Line) usize {
    return @max(1, lines.len);
}

/// Columns left of the content: the bar and a space, as diff lines draw it.
const bar_cols = 2;

/// Rows the record occupies in a block `width` cells wide. Only body lines
/// wrap.
pub fn rowHeight(params: struct {
    view: DescriptionView,
    row: Row,
    width: usize,
    allocator: Allocator,
}) usize {
    switch (params.row.kind) {
        .header => return headerRows(params.view),
        .bottom, .gap => return 1,
        .body_line => {},
    }
    var arena = std.heap.ArenaAllocator.init(params.allocator);
    defer arena.deinit();
    const rows = planBodyRows(arena.allocator(), .{
        .view = params.view,
        .line_idx = params.row.line_idx,
        .inner_width = innerWidth(params.width),
    }) catch return 1;
    return @max(1, rows.len);
}

/// Draw one record starting at `start_row` and return the rows it drew.
/// Segment text is allocated from `frame_allocator` (the caller's per-frame
/// arena, which outlives the `print` calls).
pub fn drawRow(win: vaxis.Window, params: struct {
    view: DescriptionView,
    row: Row,
    start_row: usize,
    is_cursor: bool,
    frame_allocator: Allocator,
}) usize {
    if (params.start_row >= win.height) return 0;
    const ctx = DrawContext{
        .win = win,
        .start_row = params.start_row,
        .cursor_bg = if (params.is_cursor) Color.cursor_bg else null,
        .frame_allocator = params.frame_allocator,
    };
    return switch (params.row.kind) {
        .header => drawHeader(ctx, params.view),
        .body_line => drawBodyLine(ctx, params.view, params.row.line_idx),
        .bottom => drawBarRow(ctx, .{ .row = ctx.start_row, .segments = &.{} }),
        .gap => drawGap(ctx),
    };
}

/// Rows for one markdown display line wrapped to `inner_width`, styled as the
/// description body is. The Conversation screen renders comment bodies with it.
pub fn planMarkdownLine(arena: Allocator, params: struct { line: description.Line, inner_width: usize }) ![]PlannedRow {
    return planLine(arena, .{ .line = params.line, .inner_width = params.inner_width });
}

/// The status row's segments: approvals, change requests, and the checks
/// tally (see `statusSegments`).
pub fn statusRow(arena: Allocator, source: StatusSource) ![]const vaxis.Cell.Segment {
    return statusSegments(arena, source);
}

const DrawContext = struct {
    win: vaxis.Window,
    start_row: usize,
    /// Set on the cursor record: its rows get the diff's cursor background.
    cursor_bg: ?vaxis.Color,
    frame_allocator: Allocator,

    /// Print `segments` at `row`/`col`, giving any segment without its own
    /// background the cursor background.
    fn print(self: DrawContext, params: struct { row: usize, col: usize = 0, segments: []const vaxis.Cell.Segment }) void {
        if (params.row >= self.win.height) return;
        var segments = params.segments;
        if (self.cursor_bg) |bg| tint: {
            const tinted = self.frame_allocator.dupe(vaxis.Cell.Segment, params.segments) catch break :tint;
            for (tinted) |*seg| {
                if (seg.style.bg == .default) seg.style.bg = bg;
            }
            segments = tinted;
        }
        _ = cells.print(self.win, segments, .{
            .row_offset = @intCast(params.row),
            .col_offset = @intCast(params.col),
            .wrap = .none,
        });
    }

    fn fill(self: DrawContext, params: struct { row: usize, col: usize, count: usize, glyph: []const u8, style: vaxis.Style }) void {
        cells.fillGlyph(self.win, params.glyph, .{
            .col = @intCast(@min(params.col, self.win.width)),
            .row = @intCast(@min(params.row, self.win.height)),
            .count = @intCast(@min(params.count, self.win.width)),
            .style = params.style,
        });
    }
};

const Styles = struct {
    /// Same as the bar beside diff lines.
    const bar: vaxis.Style = .{ .fg = Color.dim };
    const fold: vaxis.Style = .{ .fg = Color.dim_gray };
    const number: vaxis.Style = .{ .fg = Color.dim_gray };
    const title: vaxis.Style = .{ .fg = Color.bright_white, .bold = true };
    const meta: vaxis.Style = .{ .fg = Color.dim_gray };
    const ok: vaxis.Style = .{ .fg = Color.green };
    const failed: vaxis.Style = .{ .fg = Color.red };
    const pending: vaxis.Style = .{ .fg = Color.yellow };
    const author: vaxis.Style = .{ .fg = Color.cyan };
    const hint: vaxis.Style = .{ .fg = Color.dim_gray, .italic = true };
    const cursor_marker: vaxis.Style = .{ .fg = Color.bright_white, .bold = true };
};

/// `┃ ▾ #42 Title  alice · head → base · draft`, the status row, then a
/// bar-only row. Folded: `┃ ▸ #42 Title  alice · 12 lines · o to expand` and
/// the status row. As width runs out the detail goes first, then the author,
/// then the title truncates.
fn drawHeader(ctx: DrawContext, view: DescriptionView) usize {
    const width: usize = ctx.win.width;
    const a = ctx.frame_allocator;
    const number = std.fmt.allocPrint(a, "#{d} ", .{view.number}) catch return 1;
    const detail = if (view.collapsed)
        std.fmt.allocPrint(a, " · {d} line{s} · o to expand", .{ view.lines.len, if (view.lines.len == 1) "" else "s" }) catch ""
    else if (view.head_ref.len > 0 and view.base_ref.len > 0)
        std.fmt.allocPrint(a, " · {s} → {s}{s}", .{ view.head_ref, view.base_ref, if (view.is_draft) " · draft" else "" }) catch ""
    else
        "";

    const lead_cols = bar_cols + 2 + width_util.displayWidth(number);
    const room = width -| (lead_cols + 1);
    const title_cols = width_util.displayWidth(view.title);
    const author_cols = 2 + width_util.displayWidth(view.author);
    const show_meta = title_cols + author_cols <= room;
    const show_detail = show_meta and title_cols + author_cols + width_util.displayWidth(detail) <= room;
    const title = truncate(a, .{ .text = view.title, .width = room }) catch view.title;

    // The cursor background makes the title and the dim meta hard to read,
    // so the header marks the cursor with a bright bar and fold glyph instead
    // of filling its rows.
    const is_cursor = ctx.cursor_bg != null;
    var title_ctx = ctx;
    title_ctx.cursor_bg = null;
    title_ctx.print(.{ .row = ctx.start_row, .segments = &.{
        .{ .text = "┃ ", .style = if (is_cursor) Styles.cursor_marker else Styles.bar },
        .{ .text = if (view.collapsed) "▸ " else "▾ ", .style = if (is_cursor) Styles.cursor_marker else Styles.fold },
        .{ .text = number, .style = Styles.number },
        .{ .text = title, .style = Styles.title },
        .{ .text = if (show_meta) "  " else "", .style = Styles.meta },
        .{ .text = if (show_meta) view.author else "", .style = Styles.author },
        .{ .text = if (show_detail) detail else "", .style = if (view.collapsed) Styles.hint else Styles.meta },
    } });
    var row = ctx.start_row + 1;
    if (view.status) |source| {
        _ = drawBarRow(title_ctx, .{ .row = row, .segments = statusSegments(a, source) catch &.{} });
        row += 1;
    }
    if (!view.collapsed) _ = drawBarRow(title_ctx, .{ .row = row, .segments = &.{} });
    return headerRows(view);
}

/// Title row, the status row when there is review data, and a blank row
/// before the body when expanded.
fn headerRows(view: DescriptionView) usize {
    return 1 + @as(usize, @intFromBool(view.status != null)) + @as(usize, @intFromBool(!view.collapsed));
}

/// `✓ approved by alice, bob · ✗ changes requested by carol · checks ✓12 ✗1 ●2 (lint)`.
/// Clipped at the window edge rather than wrapped.
fn statusSegments(arena: Allocator, source: StatusSource) ![]const vaxis.Cell.Segment {
    const status = try review_status.summarize(arena, .{ .reviews = source.reviews, .checks = source.checks });
    var segments: std.ArrayList(vaxis.Cell.Segment) = .empty;
    if (status.approvers.len > 0) {
        try segments.appendSlice(arena, &.{
            .{ .text = "✓ ", .style = Styles.ok },
            .{ .text = "approved by ", .style = Styles.meta },
            .{ .text = try std.mem.join(arena, ", ", status.approvers), .style = Styles.author },
        });
    } else {
        try segments.append(arena, .{ .text = "no approvals", .style = Styles.meta });
    }
    if (status.change_requesters.len > 0) {
        try segments.appendSlice(arena, &.{
            .{ .text = " · ", .style = Styles.meta },
            .{ .text = "✗ ", .style = Styles.failed },
            .{ .text = "changes requested by ", .style = Styles.meta },
            .{ .text = try std.mem.join(arena, ", ", status.change_requesters), .style = Styles.author },
        });
    }
    if (source.checks.len > 0) {
        try segments.append(arena, .{ .text = " · checks", .style = Styles.meta });
        if (status.passed > 0) try segments.append(arena, .{ .text = try std.fmt.allocPrint(arena, " ✓{d}", .{status.passed}), .style = Styles.ok });
        if (status.failed > 0) try segments.append(arena, .{ .text = try std.fmt.allocPrint(arena, " ✗{d}", .{status.failed}), .style = Styles.failed });
        if (status.pending > 0) try segments.append(arena, .{ .text = try std.fmt.allocPrint(arena, " ●{d}", .{status.pending}), .style = Styles.pending });
        if (status.failing.len > 0) {
            try segments.appendSlice(arena, &.{
                .{ .text = " (", .style = Styles.meta },
                .{ .text = try std.mem.join(arena, ", ", status.failing), .style = Styles.failed },
                .{ .text = ")", .style = Styles.meta },
            });
        }
    }
    return segments.items;
}

/// `┃ <segments>`, with the cursor background across the row when set.
fn drawBarRow(ctx: DrawContext, params: struct { row: usize, segments: []const vaxis.Cell.Segment, fill_bg: ?vaxis.Color = null }) usize {
    if (ctx.cursor_bg) |bg| ctx.fill(.{ .row = params.row, .col = 0, .count = ctx.win.width, .glyph = " ", .style = .{ .bg = bg } });
    if (params.fill_bg) |bg| ctx.fill(.{ .row = params.row, .col = bar_cols, .count = innerWidth(ctx.win.width), .glyph = " ", .style = .{ .bg = bg } });
    ctx.print(.{ .row = params.row, .segments = &.{.{ .text = "┃ ", .style = Styles.bar }} });
    ctx.print(.{ .row = params.row, .col = bar_cols, .segments = params.segments });
    return 1;
}

/// `text` cut to `width` display cells, ending in "…" when it was cut.
fn truncate(arena: Allocator, params: struct { text: []const u8, width: usize }) ![]const u8 {
    if (width_util.displayWidth(params.text) <= params.width) return params.text;
    if (params.width == 0) return "";
    const kept = std.mem.trimEnd(u8, width_util.sliceByDisplayWidth(params.text, params.width - 1), " ");
    return std.mem.concat(arena, u8, &.{ kept, "…" });
}

fn drawGap(ctx: DrawContext) usize {
    if (ctx.cursor_bg) |bg| ctx.fill(.{ .row = ctx.start_row, .col = 0, .count = ctx.win.width, .glyph = " ", .style = .{ .bg = bg } });
    return 1;
}

/// `┃ <lead><content>` per wrapped row.
fn drawBodyLine(ctx: DrawContext, view: DescriptionView, line_idx: usize) usize {
    const rows = planBodyRows(ctx.frame_allocator, .{ .view = view, .line_idx = line_idx, .inner_width = innerWidth(ctx.win.width) }) catch return 1;

    for (rows, 0..) |planned, i| {
        const row = ctx.start_row + i;
        if (row >= ctx.win.height) break;
        const segments = std.mem.concat(ctx.frame_allocator, vaxis.Cell.Segment, &.{
            &.{.{ .text = planned.lead, .style = planned.lead_style }},
            planned.pieces,
        }) catch planned.pieces;
        _ = drawBarRow(ctx, .{ .row = row, .segments = segments, .fill_bg = planned.fill_bg });
    }
    return @max(1, rows.len);
}

/// Wrap one description line into rows of styled pieces. A line index past
/// the end (the session changed without a LineMap rebuild) plans one blank
/// row rather than tripping a bounds check.
fn planBodyRows(arena: Allocator, params: struct {
    view: DescriptionView,
    line_idx: usize,
    inner_width: usize,
}) ![]PlannedRow {
    const view = params.view;
    if (view.lines.len == 0) {
        const text = if (params.line_idx == 0) view.placeholder else "";
        return planSingle(arena, .{ .text = text, .style = .{ .fg = Color.dim_gray, .italic = true } });
    }
    if (params.line_idx >= view.lines.len) return planSingle(arena, .{ .text = "", .style = .{} });
    return planLine(arena, .{ .line = view.lines[params.line_idx], .inner_width = params.inner_width });
}

fn planLine(arena: Allocator, params: struct { line: description.Line, inner_width: usize }) ![]PlannedRow {
    const line = params.line;
    switch (line.kind) {
        .blank => return planSingle(arena, .{ .text = "", .style = .{} }),
        .rule => {
            const rule = try arena.alloc(u8, params.inner_width * "─".len);
            var i: usize = 0;
            while (i < params.inner_width) : (i += 1) @memcpy(rule[i * "─".len ..][0.."─".len], "─");
            return planSingle(arena, .{ .text = rule, .style = md.horizontal_rule });
        },
        .code => {
            const text = width_util.sliceByDisplayWidth(line.text, params.inner_width -| 2);
            const rows = try arena.alloc(PlannedRow, 1);
            const pieces = try arena.alloc(vaxis.Cell.Segment, 1);
            pieces[0] = .{ .text = text, .style = .{ .fg = md.text.fg, .bg = md.code_block_bg } };
            rows[0] = .{ .lead = "  ", .lead_style = .{ .bg = md.code_block_bg }, .pieces = pieces, .fill_bg = md.code_block_bg };
            return rows;
        },
        else => {},
    }

    const lead = try leadFor(arena, line);
    const base = baseStyle(line);
    const spans = try description.inlineSpans(arena, line.text);
    return wrapSpans(arena, .{
        .spans = spans,
        .base = base,
        .lead = lead,
        .width = params.inner_width -| width_util.displayWidth(lead.text),
    });
}

const Lead = struct { text: []const u8, style: vaxis.Style };

fn leadFor(arena: Allocator, line: description.Line) !Lead {
    const indent = try arena.alloc(u8, @as(usize, line.depth) * 2);
    @memset(indent, ' ');
    const marker: Lead = switch (line.kind) {
        .bullet => .{ .text = switch (line.depth) {
            0 => "• ",
            1 => "◦ ",
            else => "▪ ",
        }, .style = md.list_marker },
        .ordered => .{ .text = try std.fmt.allocPrint(arena, "{s} ", .{line.marker}), .style = md.list_marker },
        .task => if (line.checked) .{ .text = "☑ ", .style = md.task_checked } else .{ .text = "☐ ", .style = md.task_unchecked },
        .quote => .{ .text = "▎ ", .style = md.blockquote_border },
        else => .{ .text = "", .style = .{} },
    };
    return .{ .text = try std.mem.concat(arena, u8, &.{ indent, marker.text }), .style = marker.style };
}

fn baseStyle(line: description.Line) vaxis.Style {
    return switch (line.kind) {
        .heading => switch (line.level) {
            1 => md.h1,
            2 => md.h2,
            else => md.h3,
        },
        .quote => md_colors.mergeStyles(md.blockquote_text, .{ .italic = true }),
        .task => if (line.checked) .{ .fg = Color.dim_gray } else md.text,
        else => md.text,
    };
}

fn roleStyle(base: vaxis.Style, role: description.Role) vaxis.Style {
    return switch (role) {
        .plain => base,
        .bold => md_colors.mergeStyles(base, .{ .bold = true }),
        .italic => md_colors.mergeStyles(base, .{ .italic = true }),
        .strike => md.strikethrough,
        .code => .{ .fg = md.inline_code.fg, .bg = md.inline_code_bg },
        .link => md.link_text,
    };
}

/// Word-wrap styled spans as one string, then cut each wrapped row back into
/// the spans it overlaps so styling survives the wrap.
fn wrapSpans(arena: Allocator, params: struct {
    spans: []const description.Span,
    base: vaxis.Style,
    lead: Lead,
    width: usize,
}) ![]PlannedRow {
    var plain: std.ArrayList(u8) = .empty;
    for (params.spans) |span| try plain.appendSlice(arena, span.text);
    const continuation = try arena.alloc(u8, width_util.displayWidth(params.lead.text));
    @memset(continuation, ' ');

    var rows: std.ArrayList(PlannedRow) = .empty;
    var wrap = width_util.WrapIterator{ .text = plain.items, .max_width = @max(min_inner_width, params.width) };
    while (wrap.next()) |seg| {
        const seg_start = @intFromPtr(seg.ptr) - @intFromPtr(plain.items.ptr);
        const seg_end = seg_start + seg.len;

        var pieces: std.ArrayList(vaxis.Cell.Segment) = .empty;
        var span_start: usize = 0;
        for (params.spans) |span| {
            const span_end = span_start + span.text.len;
            defer span_start = span_end;
            const from = @max(span_start, seg_start);
            const to = @min(span_end, seg_end);
            if (from >= to) continue;
            try pieces.append(arena, .{ .text = plain.items[from..to], .style = roleStyle(params.base, span.role) });
        }
        try rows.append(arena, .{
            .lead = if (rows.items.len == 0) params.lead.text else continuation,
            .lead_style = params.lead.style,
            .pieces = pieces.items,
        });
    }
    if (rows.items.len == 0) return planSingle(arena, .{ .text = "", .style = .{} });
    return rows.items;
}

fn planSingle(arena: Allocator, params: struct { text: []const u8, style: vaxis.Style }) ![]PlannedRow {
    const rows = try arena.alloc(PlannedRow, 1);
    const pieces = try arena.alloc(vaxis.Cell.Segment, 1);
    pieces[0] = .{ .text = params.text, .style = params.style };
    rows[0] = .{ .lead = "", .lead_style = .{}, .pieces = pieces };
    return rows;
}

/// Content column right of the bar, with a one-column right margin.
fn innerWidth(width: usize) usize {
    return @max(min_inner_width, width -| (bar_cols + 1));
}

test "lineCount reserves one line for the placeholder" {
    try std.testing.expectEqual(@as(usize, 1), lineCount(&.{}));
}

test "rowHeight counts the wrapped rows of a body line" {
    const lines = [_]description.Line{
        .{ .kind = .text, .text = "short" },
        .{ .kind = .text, .text = "one two three four five six seven eight nine ten" },
    };
    const view: DescriptionView = .{ .number = 1, .title = "t", .author = "a", .lines = &lines, .placeholder = "", .collapsed = false };
    try std.testing.expectEqual(@as(usize, 1), rowHeight(.{ .view = view, .row = .{ .kind = .body_line, .line_idx = 0 }, .width = 20, .allocator = std.testing.allocator }));
    try std.testing.expectEqual(@as(usize, 4), rowHeight(.{ .view = view, .row = .{ .kind = .body_line, .line_idx = 1 }, .width = 20, .allocator = std.testing.allocator }));
}

test "rowHeight treats an out-of-range line as one blank row" {
    const lines = [_]description.Line{.{ .kind = .text, .text = "only" }};
    const view: DescriptionView = .{ .number = 1, .title = "t", .author = "a", .lines = &lines, .placeholder = "", .collapsed = false };
    try std.testing.expectEqual(@as(usize, 1), rowHeight(.{ .view = view, .row = .{ .kind = .body_line, .line_idx = 9 }, .width = 40, .allocator = std.testing.allocator }));
}
