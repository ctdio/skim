//! Renders the PR picker into a vaxis window: a header line, the search prompt,
//! a rule, the scrollable PR list, and a key-hint footer. Pure drawing — it reads
//! a `View` snapshot and never mutates app state.

const std = @import("std");
const vaxis = @import("vaxis");
const parse = @import("parse.zig");
const authors = @import("authors.zig");
const stack = @import("stack.zig");
const line_writer = @import("line_writer.zig");
const common = @import("../rendering/common.zig");

const PullRequest = parse.PullRequest;
const CiStatus = parse.CiStatus;
const AuthorCount = authors.AuthorCount;
const Style = vaxis.Cell.Style;
const LineWriter = line_writer.LineWriter;
const Color = common.Color;

// Semantic roles mapped onto the shared palette, so the picker reads as part of
// skim rather than re-deriving its own raw ANSI indices.
const meta_fg = Color.syntax_comment;
const author_fg = Color.syntax_number;
const title_fg = Color.chat_content;
const accent_fg = Color.cyan;
const rule_fg = Color.comment_border;
const selected_bg = Color.list_selected_bg;

// Chrome rows: header, search, rule at the top; a single hint row at the bottom.
const list_top: u16 = 3;
const min_height: u16 = list_top + 2;

// Cap on the aligned author column so one long login cannot squeeze out titles.
const max_author_col: u16 = 16;

const Columns = struct {
    number: u16,
    author: u16,
};

pub const View = struct {
    prs: []const PullRequest,
    filtered: []const usize,
    selected: usize,
    scroll: usize,
    loading: bool,
    load_failed: bool = false,
    query: []const u8,
    message: []const u8,
    author_filter: []const u8 = "",

    // `skim pr` boots straight into the picker, so ^c quits; when the picker is
    // opened over an existing diff, ^c returns to that diff instead.
    pr_only: bool = false,

    // Stacked-PR analysis (indexed by PR index). When present, rows show a
    // connector glyph; pair it with a stack-grouped `filtered` order so the
    // glyphs read as a connected stack.
    analysis: ?*const stack.Analysis = null,

    // Author-filter overlay.
    picking_author: bool = false,
    authors: []const AuthorCount = &.{},
    author_filtered: []const usize = &.{},
    author_selected: usize = 0,
    author_scroll: usize = 0,
    author_query: []const u8 = "",
};

pub fn draw(win: vaxis.Window, view: View) void {
    win.clear();
    if (win.height < min_height or win.width == 0) return;

    if (view.picking_author) {
        drawAuthorPicker(win, view);
        return;
    }

    drawHeader(win, view);
    drawSearchRow(win, view.query, view.filtered.len, view.selected);
    drawRule(win, 2);

    const list_bottom: u16 = win.height - 1; // exclusive; last row is the hint footer

    if (view.loading and view.filtered.len == 0) {
        drawCentered(win, list_top, "Loading pull requests…");
    } else if (view.load_failed and view.filtered.len == 0) {
        // Match the classified cause the status bar shows; only fall back to a
        // generic line when no specific message was supplied.
        const body = if (view.message.len > 0) view.message else "Couldn't load pull requests.";
        drawCentered(win, list_top, body);
    } else if (view.filtered.len == 0) {
        const empty = if (view.query.len > 0 or view.author_filter.len > 0) "No PRs match." else "No open pull requests.";
        drawCentered(win, list_top, empty);
    } else {
        const columns = measureColumns(win, view);
        var row: u16 = list_top;
        var i: usize = view.scroll;
        while (i < view.filtered.len and row < list_bottom) : ({
            i += 1;
            row += 1;
        }) {
            const idx = view.filtered[i];
            const mark = if (view.analysis) |a| a.markOf(idx) else stack.Mark.none;
            drawRow(.{
                .win = win,
                .row = row,
                .pr = view.prs[idx],
                .selected = i == view.selected,
                .mark = mark,
                .columns = columns,
            });
        }
    }

    drawFooter(win, view);
}

fn drawHeader(win: vaxis.Window, view: View) void {
    const muted = Style{ .fg = meta_fg };
    var writer = LineWriter.init(.{ .win = win, .row = 0 });
    writer.styledText(" skim pr", .{ .fg = accent_fg, .bold = true });
    // While the first load is still in flight there is no count to report yet;
    // showing "0 open pull requests" would contradict the "Loading…" body.
    if (view.loading and view.prs.len == 0) {
        writer.styledText("  loading…", muted);
        return;
    }
    writer.styledText("  ", muted);
    writer.styledUnsigned(view.prs.len, muted);
    writer.styledText(" open pull request", muted);
    if (view.prs.len != 1) writer.styledText("s", muted);
    if (view.author_filter.len > 0) {
        writer.styledText("  @", .{ .fg = author_fg, .bold = true });
        writer.styledText(view.author_filter, .{ .fg = author_fg, .bold = true });
    }
}

/// The live search prompt, directly under the header. The match count is pinned
/// to the right edge so it reads as a result of the query rather than competing
/// with the key hints for space in the footer.
fn drawSearchRow(win: vaxis.Window, query: []const u8, match_count: usize, selected: usize) void {
    var writer = LineWriter.init(.{ .win = win, .row = 1 });
    writer.styledText(" › ", .{ .fg = accent_fg });
    if (query.len == 0) {
        writer.styledText("filter by title, author, or branch", .{ .fg = meta_fg });
    } else {
        writer.styledText(query, .{ .fg = Color.bright_white });
        writer.styledText("▏", .{ .fg = accent_fg });
    }

    if (match_count == 0) return;

    const position = selected + 1;
    const count_width = digitWidth(position) + 1 + digitWidth(match_count);
    if (count_width + 2 >= win.width) return;
    const col = win.width - count_width - 1;
    if (col <= writer.col) return;

    const muted = Style{ .fg = meta_fg };
    var counter = LineWriter.init(.{ .win = win, .row = 1, .col = col, .style = muted });
    counter.styledUnsigned(position, muted);
    counter.styledText("/", muted);
    counter.styledUnsigned(match_count, muted);
}

fn drawRule(win: vaxis.Window, row: u16) void {
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = .{ .fg = rule_fg } });
    var col: u16 = 0;
    while (col < win.width) : (col += 1) writer.text("─");
}

fn drawRow(params: struct {
    win: vaxis.Window,
    row: u16,
    pr: PullRequest,
    selected: bool,
    mark: stack.Mark,
    columns: Columns,
}) void {
    const win = params.win;
    const row = params.row;
    const pr = params.pr;
    const selected = params.selected;

    // Selection is a background lift plus a leading accent bar rather than
    // inverse video, so the CI/author/branch colors stay readable on the row the
    // eye is actually resting on.
    const bg: ?vaxis.Cell.Color = if (selected) selected_bg else null;
    const meta_style = Style{ .fg = meta_fg };
    const title_style = Style{ .fg = title_fg, .bold = selected };

    if (selected) fillRow(win, row, .{ .bg = selected_bg });

    // A two-column connector glyph leads the row so stacked PRs read as a
    // bracketed group; standalone PRs just get the matching indent.
    // Author follows (right after the number) so it stays visible even when a
    // long title/branch would otherwise push it off the right edge. Number and
    // author are padded to the widest on screen so the titles start on a shared
    // column instead of stepping raggedly in and out.
    var writer = LineWriter.init(.{ .win = win, .row = row, .bg = bg });
    writer.styledText(if (selected) "▌" else " ", .{ .fg = accent_fg });
    writer.text(" ");
    writer.styledText(stackGlyph(params.mark), meta_style);
    writer.styledText(ciGlyph(pr.ci), .{ .fg = ciColor(pr.ci) });
    writer.text("  ");
    writer.styledText("#", meta_style);
    pad(&writer, params.columns.number - digitWidth(pr.number));
    writer.styledUnsigned(pr.number, meta_style);
    writer.styledText("  @", meta_style);
    writer.styledText(pr.author, .{ .fg = author_fg });
    pad(&writer, params.columns.author -| win.gwidth(pr.author));
    writer.text("  ");
    writer.styledText(pr.title, title_style);
    writer.styledText("  ", meta_style);
    writer.styledText(pr.base_ref, meta_style);
    writer.styledText("←", meta_style);
    writer.styledText(pr.head_ref, meta_style);
    if (pr.is_draft) {
        writer.styledText("  draft", meta_style);
    }
}

fn drawFooter(win: vaxis.Window, view: View) void {
    const row = win.height - 1;
    const muted = Style{ .fg = meta_fg };

    var writer = LineWriter.init(.{ .win = win, .row = row, .style = muted });
    if (view.message.len > 0) {
        writer.styledText(" ", muted);
        writer.styledText(view.message, muted);
    } else {
        drawHint(&writer, view.pr_only);
    }
    if (view.loading) writer.styledText("  · loading…", muted);
}

/// Draws the picker key hints from the writer's current column. When the row is
/// too narrow to hold every hint (e.g. an 80-column terminal), lower-priority
/// segments are dropped right-to-left (open, then reload, then author) so the
/// essential "esc clear/back · ^c quit/back" affordance is never clipped.
fn drawHint(writer: *LineWriter, pr_only: bool) void {
    const muted = Style{ .fg = meta_fg };
    const optional = [_][]const u8{ "enter review", "^n/^p move", "^a author", "^r reload", "^o open" };
    const essential = "esc clear/back · ^c ";
    const verb: []const u8 = if (pr_only) "quit" else "back";

    const win = writer.win;
    const lead_w = win.gwidth("  ");
    const sep_w = win.gwidth(" · ");
    const essential_w = win.gwidth(essential) + win.gwidth(verb);

    // Largest count of leading segments that still leaves room for the essential
    // hint; each kept segment carries a trailing " · " into the next one.
    var keep: usize = optional.len;
    while (keep > 0) : (keep -= 1) {
        var used: u16 = writer.col + lead_w + essential_w + @as(u16, @intCast(keep)) * sep_w;
        for (optional[0..keep]) |seg| used += win.gwidth(seg);
        if (used <= win.width) break;
    }

    writer.styledText("  ", muted);
    for (optional[0..keep]) |seg| {
        writer.styledText(seg, muted);
        writer.styledText(" · ", muted);
    }
    writer.styledText(essential, muted);
    writer.styledText(verb, muted);
}

fn drawAuthorPicker(win: vaxis.Window, view: View) void {
    const muted = Style{ .fg = meta_fg };
    var header = LineWriter.init(.{ .win = win, .row = 0 });
    header.styledText(" filter by author", .{ .fg = accent_fg, .bold = true });
    header.styledText("  ", muted);
    header.styledUnsigned(view.author_filtered.len, muted);

    drawSearchRow(win, view.author_query, view.author_filtered.len, view.author_selected);
    drawRule(win, 2);

    const list_bottom: u16 = win.height - 1;

    if (view.author_filtered.len == 0) {
        drawCentered(win, list_top, "No matching authors.");
    } else {
        var row: u16 = list_top;
        var i: usize = view.author_scroll;
        while (i < view.author_filtered.len and row < list_bottom) : ({
            i += 1;
            row += 1;
        }) {
            const author = view.authors[view.author_filtered[i]];
            drawAuthorRow(win, row, author, i == view.author_selected);
        }
    }

    var prompt = LineWriter.init(.{ .win = win, .row = win.height - 1, .style = muted });
    prompt.styledText("  enter apply · esc cancel · ^n/^p move", muted);
}

fn drawAuthorRow(win: vaxis.Window, row: u16, author: AuthorCount, selected: bool) void {
    const bg: ?vaxis.Cell.Color = if (selected) selected_bg else null;
    const meta_style = Style{ .fg = meta_fg };

    if (selected) fillRow(win, row, .{ .bg = selected_bg });

    var writer = LineWriter.init(.{ .win = win, .row = row, .bg = bg });
    writer.styledText(if (selected) "▌" else " ", .{ .fg = accent_fg });
    writer.text(" @");
    writer.styledText(author.login, .{ .fg = author_fg, .bold = selected });
    writer.styledText("  (", meta_style);
    writer.styledUnsigned(author.count, meta_style);
    writer.styledText(")", meta_style);
}

fn drawCentered(win: vaxis.Window, row: u16, label: []const u8) void {
    const text_width = win.gwidth(label);
    const col: u16 = if (text_width < win.width) (win.width - text_width) / 2 else 0;
    var writer = LineWriter.init(.{ .win = win, .row = row, .col = col, .style = .{ .fg = meta_fg } });
    writer.text(label);
}

fn ciGlyph(ci: CiStatus) []const u8 {
    return switch (ci) {
        .none => " ",
        .pending => "•",
        .success => "✓",
        .failure => "✗",
    };
}

/// Two-column stack connector: `┌`/`│`/`└` bracket a stack top-to-bottom; a
/// standalone PR gets a blank indent so every row's content still aligns.
fn stackGlyph(mark: stack.Mark) []const u8 {
    return switch (mark) {
        .none => "  ",
        .top => "┌ ",
        .middle => "│ ",
        .bottom => "└ ",
    };
}

fn ciColor(ci: CiStatus) vaxis.Cell.Color {
    return switch (ci) {
        .none => meta_fg,
        .pending => Color.syntax_type, // warm orange
        .success => Color.diff_sign_add,
        .failure => Color.diff_sign_delete,
    };
}

/// Widest number and author among the PRs on offer, so every row can align its
/// title to a shared column. Author is capped so one very long login cannot push
/// every title off the right edge.
fn measureColumns(win: vaxis.Window, view: View) Columns {
    var columns = Columns{ .number = 1, .author = 0 };
    for (view.filtered) |idx| {
        const pr = view.prs[idx];
        columns.number = @max(columns.number, digitWidth(pr.number));
        columns.author = @max(columns.author, win.gwidth(pr.author));
    }
    columns.author = @min(columns.author, max_author_col);
    return columns;
}

fn pad(writer: *LineWriter, count: u16) void {
    var i: u16 = 0;
    while (i < count) : (i += 1) writer.text(" ");
}

fn digitWidth(value: usize) u16 {
    var width: u16 = 1;
    var remaining = value;
    while (remaining >= 10) : (remaining /= 10) width += 1;
    return width;
}

fn fillRow(win: vaxis.Window, row: u16, style: Style) void {
    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        win.writeCell(col, row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style,
        });
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const render_test_screen = @import("render_test_screen.zig");

fn testPr(params: struct {
    title: []const u8,
    author: []const u8 = "octocat",
    head_ref: []const u8 = "feature",
    base_ref: []const u8 = "main",
    number: u32 = 1,
    is_draft: bool = false,
    ci: CiStatus = .none,
}) PullRequest {
    return .{
        .number = params.number,
        .title = params.title,
        .author = params.author,
        .head_ref = params.head_ref,
        .base_ref = params.base_ref,
        .is_draft = params.is_draft,
        .updated_at = "",
        .url = "",
        .ci = params.ci,
    };
}

const TestScreen = render_test_screen.TestScreen;
const rowContains = render_test_screen.rowContains;

fn expectColor(actual: vaxis.Cell.Color, expected: vaxis.Cell.Color) !void {
    try testing.expect(vaxis.Cell.Color.eql(actual, expected));
}

test "draw: clips long PR rows without spilling into following rows" {
    var ts = try TestScreen.init(24, 6);
    defer ts.deinit();

    const prs = [_]PullRequest{
        testPr(.{ .title = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }),
    };
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 1,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    var col: u16 = 0;
    while (col < ts.screen.width) : (col += 1) {
        const cell = ts.screen.readCell(col, 4) orelse return error.MissingCell;
        if (cell.default) continue;
        try testing.expectEqualStrings(" ", cell.char.grapheme);
    }
}

test "draw: does not mark row cells as terminal-wrapped" {
    var ts = try TestScreen.init(16, 6);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "short" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    for (ts.screen.buf) |cell| {
        try testing.expect(!cell.wrapped);
    }
}

test "draw: colors CI as an accent without tinting the whole row" {
    var ts = try TestScreen.init(40, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready to merge", .ci = .success })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 1,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    // Layout: "  ✓  #1  @octocat  Ready to merge" — author leads, title follows.
    const status_cell = ts.screen.readCell(4, 3) orelse return error.MissingCell;
    const author_cell = ts.screen.readCell(12, 3) orelse return error.MissingCell;
    const title_cell = ts.screen.readCell(21, 3) orelse return error.MissingCell;

    try expectColor(status_cell.style.fg, ciColor(.success));
    try expectColor(author_cell.style.fg, author_fg);
    try testing.expectEqualStrings("o", author_cell.char.grapheme);
    try expectColor(title_cell.style.fg, title_fg);
    try testing.expectEqualStrings("R", title_cell.char.grapheme);
}

test "draw: stacked PRs show connector glyphs tip-to-bottom" {
    var ts = try TestScreen.init(60, 9);
    defer ts.deinit();

    const prs = [_]PullRequest{
        testPr(.{ .number = 10, .title = "bottom", .head_ref = "feat", .base_ref = "main" }),
        testPr(.{ .number = 11, .title = "tip", .head_ref = "feat2", .base_ref = "feat" }),
    };
    var analysis = try stack.analyze(testing.allocator, &prs);
    defer analysis.deinit(testing.allocator);

    // Tip-first display order: index 1 (tip) then index 0 (bottom).
    const filtered = [_]usize{ 1, 0 };
    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 99,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
        .analysis = &analysis,
    });

    try testing.expect(rowContains(ts.screen, 3, "┌"));
    try testing.expect(rowContains(ts.screen, 4, "└"));
}

test "draw: standalone PRs get no connector glyph" {
    var ts = try TestScreen.init(60, 4);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .number = 7, .title = "solo", .head_ref = "x", .base_ref = "main" })};
    var analysis = try stack.analyze(testing.allocator, &prs);
    defer analysis.deinit(testing.allocator);

    const filtered = [_]usize{0};
    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 99,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
        .analysis = &analysis,
    });

    try testing.expect(!rowContains(ts.screen, 3, "┌"));
    try testing.expect(!rowContains(ts.screen, 3, "│"));
    try testing.expect(!rowContains(ts.screen, 3, "└"));
}

test "draw: header shows the active author filter as a chip" {
    var ts = try TestScreen.init(40, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready", .author = "alice" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
        .author_filter = "alice",
    });

    try testing.expect(rowContains(ts.screen, 0, "@alice"));
}

test "draw: a failed load reads as an error, not an empty repo" {
    var ts = try TestScreen.init(80, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{};
    const filtered = [_]usize{};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .load_failed = true,
        .query = "",
        .message = "",
    });

    try testing.expect(rowContains(ts.screen, 3, "Couldn't load pull requests"));
    try testing.expect(!rowContains(ts.screen, 3, "No open pull requests."));
}

test "draw: a failed load shows the classified cause, not a generic auth prompt" {
    var ts = try TestScreen.init(80, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{};
    const filtered = [_]usize{};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .load_failed = true,
        .query = "",
        .message = "GitHub API rate limit reached",
    });

    try testing.expect(rowContains(ts.screen, 3, "rate limit"));
    try testing.expect(!rowContains(ts.screen, 3, "authenticated"));
}

test "draw: initial load header hides the count instead of claiming zero PRs" {
    var ts = try TestScreen.init(80, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{};
    const filtered = [_]usize{};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = true,
        .query = "",
        .message = "",
    });

    try testing.expect(rowContains(ts.screen, 0, "skim pr"));
    try testing.expect(rowContains(ts.screen, 0, "loading…"));
    try testing.expect(!rowContains(ts.screen, 0, "0 open pull request"));
    try testing.expect(rowContains(ts.screen, 3, "Loading pull requests…"));
}

test "draw: header reports the count once a load completes" {
    var ts = try TestScreen.init(80, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    try testing.expect(rowContains(ts.screen, 0, "1 open pull request"));
}

test "draw: footer says ^c quit when booted into the picker" {
    var ts = try TestScreen.init(90, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
        .pr_only = true,
    });

    try testing.expect(rowContains(ts.screen, ts.screen.height - 1, "esc clear/back"));
    try testing.expect(rowContains(ts.screen, ts.screen.height - 1, "^c quit"));
    try testing.expect(!rowContains(ts.screen, ts.screen.height - 1, "^c back"));
}

test "draw: footer says ^c back when picking over a diff" {
    var ts = try TestScreen.init(90, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
        .pr_only = false,
    });

    try testing.expect(rowContains(ts.screen, ts.screen.height - 1, "esc clear/back"));
    try testing.expect(rowContains(ts.screen, ts.screen.height - 1, "^c back"));
}

test "draw: footer keeps the quit/back hint on an 80-column terminal" {
    var ts = try TestScreen.init(80, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
        .pr_only = true,
    });

    // The full hint overflows 80 cols; lower-priority segments drop so the
    // essential clear/quit affordance still renders in full.
    try testing.expect(rowContains(ts.screen, ts.screen.height - 1, "esc clear/back"));
    try testing.expect(rowContains(ts.screen, ts.screen.height - 1, "^c quit"));
    try testing.expect(rowContains(ts.screen, ts.screen.height - 1, "enter review"));
}

test "draw: search prompt sits directly under the header" {
    var ts = try TestScreen.init(60, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "flaky",
        .message = "",
    });

    try testing.expect(rowContains(ts.screen, 1, "flaky"));
    try testing.expect(!rowContains(ts.screen, ts.screen.height - 1, "flaky"));
}

test "draw: empty search row prompts instead of showing a bare caret" {
    var ts = try TestScreen.init(60, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    try testing.expect(rowContains(ts.screen, 1, "filter"));
}

test "draw: search row carries the match count" {
    var ts = try TestScreen.init(60, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{ testPr(.{ .title = "a" }), testPr(.{ .number = 2, .title = "b" }) };
    const filtered = [_]usize{ 0, 1 };

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 1,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    try testing.expect(rowContains(ts.screen, 1, "2/2"));
}

test "draw: a rule separates the search row from the list" {
    var ts = try TestScreen.init(60, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready" })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    try testing.expect(rowContains(ts.screen, 2, "─"));
    try testing.expect(rowContains(ts.screen, 3, "Ready"));
}

test "draw: selected row keeps its token colors instead of inverting" {
    var ts = try TestScreen.init(60, 8);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "Ready", .ci = .success })};
    const filtered = [_]usize{0};

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
    });

    // The selected row is lifted with a background wash plus a leading accent
    // bar; the CI glyph and author must survive rather than collapse into a
    // single inverted block.
    const bar_cell = ts.screen.readCell(0, 3) orelse return error.MissingCell;
    const status_cell = ts.screen.readCell(4, 3) orelse return error.MissingCell;
    const author_cell = ts.screen.readCell(12, 3) orelse return error.MissingCell;

    try testing.expectEqualStrings("▌", bar_cell.char.grapheme);
    try expectColor(status_cell.style.bg, selected_bg);
    try expectColor(status_cell.style.fg, ciColor(.success));
    try expectColor(author_cell.style.fg, author_fg);
    try testing.expect(!status_cell.style.reverse);
}

test "draw: author picker lists authors with counts over the PR list" {
    var ts = try TestScreen.init(40, 9);
    defer ts.deinit();

    const prs = [_]PullRequest{testPr(.{ .title = "hidden while picking" })};
    const filtered = [_]usize{0};
    const author_list = [_]AuthorCount{
        .{ .login = "alice", .count = 3 },
        .{ .login = "bob", .count = 1 },
    };
    const author_filtered = [_]usize{ 0, 1 };

    draw(ts.window(), .{
        .prs = &prs,
        .filtered = &filtered,
        .selected = 0,
        .scroll = 0,
        .loading = false,
        .query = "",
        .message = "",
        .picking_author = true,
        .authors = &author_list,
        .author_filtered = &author_filtered,
        .author_selected = 0,
        .author_scroll = 0,
        .author_query = "",
    });

    try testing.expect(rowContains(ts.screen, 0, "filter by author"));
    try testing.expect(rowContains(ts.screen, 3, "@alice"));
    try testing.expect(rowContains(ts.screen, 3, "(3)"));
    try testing.expect(rowContains(ts.screen, 4, "@bob"));
    try testing.expect(!rowContains(ts.screen, 3, "hidden while picking"));
}
