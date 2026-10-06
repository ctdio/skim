//! App-free renderer for the PR description block drawn above the first file
//! of a review diff, plus the matching row-height calculation. The LineMap emits
//! one `pr_description` record per source line of the description; this module
//! draws one record at a time and reports how many rows it took, so navigation
//! reserves exactly what gets painted (`rowHeight` and `drawRow` share
//! `textWidth` and the same wrap iterator).

const std = @import("std");
const vaxis = @import("vaxis");
const cells = @import("cells.zig");
const common = @import("common.zig");
const width_util = @import("width.zig");
const line_map = @import("../line_map.zig");

const Allocator = std.mem.Allocator;
const Color = common.Color;

pub const Row = @FieldType(line_map.LineType, "pr_description");

/// What the block shows. Strings are borrowed from the review session.
pub const DescriptionView = struct {
    number: u32,
    title: []const u8,
    author: []const u8,
    body: []const u8,
    /// Shown as the only line when `body` is empty ("No description.", or a
    /// loading / unavailable note while the review data is not in yet).
    placeholder: []const u8,
    collapsed: bool,
};

const min_text_width = 12;

/// Lines the LineMap reserves for `body`: one per source line, ignoring
/// trailing blank lines, and one for the placeholder when the body is empty.
pub fn lineCount(body: []const u8) usize {
    const trimmed = trimBody(body);
    if (trimmed.len == 0) return 1;
    return std.mem.count(u8, trimmed, "\n") + 1;
}

/// Rows the record occupies at `width`. Only body lines wrap.
pub fn rowHeight(view: DescriptionView, row: Row, width: usize) usize {
    return switch (row.kind) {
        .header, .bottom, .gap => 1,
        .body_line => @max(1, width_util.wrapRowCount(bodyLine(view, row.line_idx), textWidth(width))),
    };
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
    const styles = Styles.init(params.is_cursor);
    return switch (params.row.kind) {
        .header => drawHeader(win, params.view, params.start_row, styles, params.frame_allocator),
        .body_line => drawBodyLine(win, params.view, params.row.line_idx, params.start_row, styles),
        .bottom => printRow(win, params.start_row, &.{.{ .text = "└─", .style = styles.accent }}),
        .gap => drawGap(win, params.start_row, params.is_cursor, params.frame_allocator),
    };
}

const Styles = struct {
    accent: vaxis.Style,
    text: vaxis.Style,
    heading: vaxis.Style,
    dim: vaxis.Style,

    fn init(is_cursor: bool) Styles {
        return .{
            .accent = if (is_cursor) .{ .fg = Color.yellow, .bold = true } else .{ .fg = Color.magenta, .bold = true },
            .text = if (is_cursor) .{ .fg = Color.bright_white } else .{ .fg = Color.white },
            .heading = if (is_cursor) .{ .fg = Color.bright_white, .bold = true } else .{ .fg = Color.white, .bold = true },
            .dim = .{ .fg = Color.dim_gray },
        };
    }
};

fn drawHeader(win: vaxis.Window, view: DescriptionView, start_row: usize, styles: Styles, frame_allocator: Allocator) usize {
    const label = std.fmt.allocPrint(frame_allocator, "#{d} {s}", .{ view.number, view.title }) catch return 1;
    const byline = std.fmt.allocPrint(frame_allocator, " · {s}", .{view.author}) catch return 1;
    const hint = if (view.collapsed) "  description (o to expand)" else "  (o to collapse)";
    return printRow(win, start_row, &.{
        .{ .text = if (view.collapsed) "▸ " else "┌ ", .style = styles.accent },
        .{ .text = label, .style = styles.accent },
        .{ .text = byline, .style = styles.dim },
        .{ .text = hint, .style = styles.dim },
    });
}

fn drawBodyLine(win: vaxis.Window, view: DescriptionView, line_idx: usize, start_row: usize, styles: Styles) usize {
    const line = bodyLine(view, line_idx);
    const style = if (trimBody(view.body).len == 0)
        styles.dim
    else if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "#"))
        styles.heading
    else
        styles.text;

    var drawn: usize = 0;
    var wrap = width_util.WrapIterator{ .text = line, .max_width = textWidth(win.width) };
    while (wrap.next()) |seg| {
        if (start_row + drawn >= win.height) break;
        drawn += printRow(win, start_row + drawn, &.{
            .{ .text = "│ ", .style = styles.accent },
            .{ .text = seg, .style = style },
        });
    }
    return @max(1, drawn);
}

fn drawGap(win: vaxis.Window, start_row: usize, is_cursor: bool, frame_allocator: Allocator) usize {
    if (!is_cursor or win.width == 0) return 1;
    const fill = frame_allocator.alloc(u8, win.width) catch return 1;
    @memset(fill, ' ');
    return printRow(win, start_row, &.{.{ .text = fill, .style = .{ .bg = Color.cursor_bg } }});
}

fn printRow(win: vaxis.Window, row: usize, segments: []const vaxis.Cell.Segment) usize {
    _ = cells.print(win, segments, .{ .row_offset = @intCast(row), .col_offset = 0, .wrap = .none });
    return 1;
}

/// The text of body line `line_idx`, or the placeholder for an empty body. An
/// index past the end (the body changed without a LineMap rebuild) reads as an
/// empty line rather than tripping a bounds check.
fn bodyLine(view: DescriptionView, line_idx: usize) []const u8 {
    const body = trimBody(view.body);
    if (body.len == 0) return if (line_idx == 0) view.placeholder else "";
    var it = std.mem.splitScalar(u8, body, '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx == line_idx) return std.mem.trimEnd(u8, line, "\r");
    }
    return "";
}

fn trimBody(body: []const u8) []const u8 {
    return std.mem.trimEnd(u8, body, " \t\r\n");
}

/// Content column right of the "│ " prefix, with a one-column right margin.
fn textWidth(width: usize) usize {
    return @max(min_text_width, width -| 3);
}

test "lineCount ignores trailing blank lines" {
    try std.testing.expectEqual(@as(usize, 2), lineCount("first\r\nsecond\r\n\r\n"));
}

test "lineCount reserves one line for an empty body" {
    try std.testing.expectEqual(@as(usize, 1), lineCount("  \n"));
}

test "rowHeight counts the wrapped rows of a body line" {
    const view: DescriptionView = .{
        .number = 1,
        .title = "t",
        .author = "a",
        .body = "short\none two three four five six seven eight nine ten",
        .placeholder = "",
        .collapsed = false,
    };
    try std.testing.expectEqual(@as(usize, 1), rowHeight(view, .{ .kind = .body_line, .line_idx = 0 }, 20));
    try std.testing.expectEqual(@as(usize, 4), rowHeight(view, .{ .kind = .body_line, .line_idx = 1 }, 20));
}

test "rowHeight treats an out-of-range line as one blank row" {
    const view: DescriptionView = .{ .number = 1, .title = "t", .author = "a", .body = "only", .placeholder = "", .collapsed = false };
    try std.testing.expectEqual(@as(usize, 1), rowHeight(view, .{ .kind = .body_line, .line_idx = 9 }, 40));
}
