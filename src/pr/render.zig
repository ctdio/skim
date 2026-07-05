//! Renders the PR picker into a vaxis window: a header line, the scrollable PR
//! list, and a status/search bar. Pure drawing — it reads a `View` snapshot and
//! never mutates app state.

const std = @import("std");
const vaxis = @import("vaxis");
const parse = @import("parse.zig");
const authors = @import("authors.zig");
const stack = @import("stack.zig");
const line_writer = @import("line_writer.zig");

const PullRequest = parse.PullRequest;
const CiStatus = parse.CiStatus;
const AuthorCount = authors.AuthorCount;
const Style = vaxis.Cell.Style;
const LineWriter = line_writer.LineWriter;

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
    if (win.height < 2 or win.width == 0) return;

    if (view.picking_author) {
        drawAuthorPicker(win, view);
        return;
    }

    drawHeader(win, view);

    const list_top: u16 = 1;
    const list_bottom: u16 = win.height - 1; // exclusive; last row is the status bar

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
        var row: u16 = list_top;
        var i: usize = view.scroll;
        while (i < view.filtered.len and row < list_bottom) : ({
            i += 1;
            row += 1;
        }) {
            const idx = view.filtered[i];
            const mark = if (view.analysis) |a| a.markOf(idx) else stack.Mark.none;
            drawRow(win, row, view.prs[idx], i == view.selected, mark);
        }
    }

    drawStatusBar(win, view);
}

fn drawHeader(win: vaxis.Window, view: View) void {
    var writer = LineWriter.init(.{ .win = win, .row = 0 });
    writer.styledText(" skim pr", .{ .bold = true });
    // While the first load is still in flight there is no count to report yet;
    // showing "0 open pull requests" would contradict the "Loading…" body.
    if (view.loading and view.prs.len == 0) {
        writer.styledText("  loading…", mutedStyle(false));
        return;
    }
    writer.styledText("  ", mutedStyle(false));
    writer.styledUnsigned(view.prs.len, mutedStyle(false));
    writer.styledText(" open pull request", mutedStyle(false));
    if (view.prs.len != 1) writer.styledText("s", mutedStyle(false));
    if (view.author_filter.len > 0) {
        writer.styledText("  @", accentStyle());
        writer.styledText(view.author_filter, accentStyle());
    }
}

fn drawRow(win: vaxis.Window, row: u16, pr: PullRequest, selected: bool, mark: stack.Mark) void {
    const base_style = rowStyle(selected, .{});
    const meta_style = rowStyle(selected, mutedStyle(false));
    const status_style = rowStyle(selected, .{ .fg = ciColor(pr.ci) });
    const draft_style = rowStyle(selected, .{ .fg = .{ .index = 3 } });
    const author_style = rowStyle(selected, .{ .fg = .{ .index = 6 } }); // cyan

    if (selected) fillRow(win, row, base_style);

    // A two-column connector glyph leads the row so stacked PRs read as a
    // bracketed group; standalone PRs just get the matching indent.
    // Author follows (right after the number) so it stays visible even when a
    // long title/branch would otherwise push it off the right edge.
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = base_style });
    writer.styledText(stackGlyph(mark), meta_style);
    writer.styledText(ciGlyph(pr.ci), status_style);
    writer.text("  ");
    writer.styledText("#", meta_style);
    writer.styledUnsigned(pr.number, meta_style);
    writer.styledText("  @", meta_style);
    writer.styledText(pr.author, author_style);
    writer.text("  ");
    writer.text(pr.title);
    writer.styledText("  ", meta_style);
    writer.styledText(pr.base_ref, meta_style);
    writer.styledText("←", meta_style);
    writer.styledText(pr.head_ref, meta_style);
    if (pr.is_draft) {
        writer.styledText("  draft", draft_style);
    }
}

fn drawStatusBar(win: vaxis.Window, view: View) void {
    const row = win.height - 1;
    const muted = Style{ .fg = .{ .index = 8 } };

    // The status row is the live search prompt: the query is always editable.
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = muted });
    writer.styledText(" > ", muted);
    writer.text(view.query);

    writer.styledText("  ", muted);
    writer.styledUnsigned(if (view.filtered.len == 0) @as(usize, 0) else view.selected + 1, muted);
    writer.styledText("/", muted);
    writer.styledUnsigned(view.filtered.len, muted);

    if (view.message.len > 0) {
        writer.styledText("  ", muted);
        writer.styledText(view.message, muted);
    } else {
        writer.styledText("  enter review · ^a author · ^r refresh · ^o open · esc clear/back · ^c ", muted);
        writer.styledText(if (view.pr_only) "quit" else "back", muted);
    }
    if (view.loading) writer.styledText("  · loading…", muted);
}

fn drawAuthorPicker(win: vaxis.Window, view: View) void {
    var header = LineWriter.init(.{ .win = win, .row = 0 });
    header.styledText(" filter by author", .{ .bold = true });
    header.styledText("  ", mutedStyle(false));
    header.styledUnsigned(view.author_filtered.len, mutedStyle(false));

    const list_top: u16 = 1;
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

    const muted = Style{ .fg = .{ .index = 8 } };
    var prompt = LineWriter.init(.{ .win = win, .row = win.height - 1, .style = muted });
    prompt.styledText(" > ", muted);
    prompt.text(view.author_query);
    prompt.styledText("  enter apply · esc cancel · ^n/^p move", muted);
}

fn drawAuthorRow(win: vaxis.Window, row: u16, author: AuthorCount, selected: bool) void {
    const base_style = rowStyle(selected, .{});
    const meta_style = rowStyle(selected, mutedStyle(false));

    if (selected) fillRow(win, row, base_style);

    var writer = LineWriter.init(.{ .win = win, .row = row, .style = base_style });
    writer.text("  @");
    writer.text(author.login);
    writer.styledText("  (", meta_style);
    writer.styledUnsigned(author.count, meta_style);
    writer.styledText(")", meta_style);
}

fn drawCentered(win: vaxis.Window, row: u16, label: []const u8) void {
    const text_width = win.gwidth(label);
    const col: u16 = if (text_width < win.width) (win.width - text_width) / 2 else 0;
    var writer = LineWriter.init(.{ .win = win, .row = row, .col = col, .style = .{ .fg = .{ .index = 8 } } });
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
        .none => .default,
        .pending => .{ .index = 3 }, // yellow
        .success => .{ .index = 2 }, // green
        .failure => .{ .index = 1 }, // red
    };
}

fn mutedStyle(selected: bool) Style {
    return rowStyle(selected, .{ .fg = .{ .index = 8 } });
}

fn accentStyle() Style {
    return .{ .fg = .{ .index = 4 }, .bold = true };
}

fn rowStyle(selected: bool, style: Style) Style {
    var out = style;
    out.reverse = selected;
    return out;
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
    var ts = try TestScreen.init(24, 4);
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
        const cell = ts.screen.readCell(col, 2) orelse return error.MissingCell;
        if (cell.default) continue;
        try testing.expectEqualStrings(" ", cell.char.grapheme);
    }
}

test "draw: does not mark row cells as terminal-wrapped" {
    var ts = try TestScreen.init(16, 3);
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
    var ts = try TestScreen.init(40, 3);
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
    const status_cell = ts.screen.readCell(2, 1) orelse return error.MissingCell;
    const author_cell = ts.screen.readCell(10, 1) orelse return error.MissingCell;
    const title_cell = ts.screen.readCell(19, 1) orelse return error.MissingCell;

    try expectColor(status_cell.style.fg, ciColor(.success));
    try expectColor(author_cell.style.fg, .{ .index = 6 });
    try testing.expectEqualStrings("o", author_cell.char.grapheme);
    try expectColor(title_cell.style.fg, .default);
    try testing.expectEqualStrings("R", title_cell.char.grapheme);
}

test "draw: stacked PRs show connector glyphs tip-to-bottom" {
    var ts = try TestScreen.init(60, 6);
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

    try testing.expect(rowContains(ts.screen, 1, "┌"));
    try testing.expect(rowContains(ts.screen, 2, "└"));
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

    try testing.expect(!rowContains(ts.screen, 1, "┌"));
    try testing.expect(!rowContains(ts.screen, 1, "│"));
    try testing.expect(!rowContains(ts.screen, 1, "└"));
}

test "draw: header shows the active author filter as a chip" {
    var ts = try TestScreen.init(40, 3);
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
    var ts = try TestScreen.init(80, 4);
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

    try testing.expect(rowContains(ts.screen, 1, "Couldn't load pull requests"));
    try testing.expect(!rowContains(ts.screen, 1, "No open pull requests."));
}

test "draw: a failed load shows the classified cause, not a generic auth prompt" {
    var ts = try TestScreen.init(80, 4);
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

    try testing.expect(rowContains(ts.screen, 1, "rate limit"));
    try testing.expect(!rowContains(ts.screen, 1, "authenticated"));
}

test "draw: initial load header hides the count instead of claiming zero PRs" {
    var ts = try TestScreen.init(80, 4);
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
    try testing.expect(rowContains(ts.screen, 1, "Loading pull requests…"));
}

test "draw: header reports the count once a load completes" {
    var ts = try TestScreen.init(80, 4);
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
    var ts = try TestScreen.init(90, 4);
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

    try testing.expect(rowContains(ts.screen, 3, "esc clear/back"));
    try testing.expect(rowContains(ts.screen, 3, "^c quit"));
    try testing.expect(!rowContains(ts.screen, 3, "^c back"));
}

test "draw: footer says ^c back when picking over a diff" {
    var ts = try TestScreen.init(90, 4);
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

    try testing.expect(rowContains(ts.screen, 3, "esc clear/back"));
    try testing.expect(rowContains(ts.screen, 3, "^c back"));
}

test "draw: author picker lists authors with counts over the PR list" {
    var ts = try TestScreen.init(40, 6);
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
    try testing.expect(rowContains(ts.screen, 1, "@alice"));
    try testing.expect(rowContains(ts.screen, 1, "(3)"));
    try testing.expect(rowContains(ts.screen, 2, "@bob"));
    try testing.expect(!rowContains(ts.screen, 1, "hidden while picking"));
}
