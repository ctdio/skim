//! Pure drawing for the two Phase-5 review overlays: the submit-review dialog
//! (verdict selector + body preview + discard confirm) and the read-only PR info
//! panel. Both read an immutable `View` snapshot and never mutate app state
//! (AD-1). The imperative shell (`ui.zig`) builds the centered popup window,
//! fills it with `dialog_bg`, and feeds these a `SubmitView` / `InfoView`
//! assembled from the `ReviewSession`; a `bg` on the view keeps every text cell
//! carrying the popup background so the dialog layers cleanly over the diff.
//!
//! Layout mirrors `pr/render.zig`: a small `LineWriter` over `vaxis.Window`
//! cells, colocated `TestScreen` tests (this module cannot import `../testing`
//! without escaping the `pr/` module root).

const std = @import("std");
const vaxis = @import("vaxis");
const review_controller = @import("review_controller.zig");
const review_parse = @import("review_parse.zig");

const Verdict = review_controller.Verdict;
const ThreadCounts = review_controller.ThreadCounts;
const RollupState = review_parse.RollupState;
const ReviewState = review_parse.ReviewState;
const Review = review_parse.Review;
const CheckRun = review_parse.CheckRun;
const Style = vaxis.Cell.Style;
const Color = vaxis.Cell.Color;

const muted = Style{ .fg = .{ .index = 8 } };
const accent = Style{ .fg = .{ .index = 6 } }; // cyan
const danger = Style{ .fg = .{ .index = 1 } }; // red
const ok_green = Style{ .fg = .{ .index = 2 } };
const warn_yellow = Style{ .fg = .{ .index = 3 } };

pub const SubmitView = struct {
    verdict: Verdict,
    body: []const u8 = "",
    draft_count: usize = 0,
    counts: ThreadCounts = .{},
    submitting: bool = false,
    confirm_discard: bool = false,
    error_msg: []const u8 = "",
    // Editor cursor: byte offset into `body`. When `editing`, the body preview
    // scrolls to keep this line visible and a hardware cursor is positioned there
    // (beam in insert mode, block otherwise) — matching the diff comment editor.
    cursor_byte: usize = 0,
    insert_mode: bool = false,
    editing: bool = false,
    bg: Color = .default,
};

pub const InfoView = struct {
    number: u32 = 0,
    title: []const u8 = "",
    author: []const u8 = "",
    base_ref: []const u8 = "",
    head_ref: []const u8 = "",
    is_draft: bool = false,
    review_decision: []const u8 = "",
    rollup: RollupState = .none,
    body: []const u8 = "",
    reviews: []const Review = &.{},
    checks: []const CheckRun = &.{},
    counts: ThreadCounts = .{},
    draft_count: usize = 0,
    unplaced_count: usize = 0,
    truncated: bool = false,
    scroll: usize = 0,
    bg: Color = .default,
};

/// Draw the submit-review dialog into `win` (a pre-sized popup window; this fn
/// paints the `view.bg` fill). Renders a verdict selector, the draft/thread
/// summary, a preview of the review body, an optional error line, and the key
/// hints (with the discard confirmation when armed).
pub fn drawSubmitDialog(win: vaxis.Window, view: SubmitView) void {
    if (win.height == 0 or win.width == 0) return;
    fillBackground(win, view.bg);

    var title = LineWriter.init(win, 0, .{ .fg = .{ .index = 6 }, .bold = true }, view.bg);
    title.text(" Submit review");
    if (view.submitting) title.styledText("  submitting…", muted);

    // Verdict selector: the active verdict is marked and highlighted.
    var sel = LineWriter.init(win, 2, .{}, view.bg);
    sel.styledText(" ", .{});
    drawVerdictOption(&sel, "Comment", view.verdict == .comment);
    sel.styledText("   ", .{});
    drawVerdictOption(&sel, "Approve", view.verdict == .approve);
    sel.styledText("   ", .{});
    drawVerdictOption(&sel, "Request changes", view.verdict == .request_changes);

    // Summary of what the submit publishes.
    var summary = LineWriter.init(win, 3, muted, view.bg);
    summary.styledText(" ", muted);
    summary.styledUnsigned(view.draft_count, muted);
    summary.styledText(if (view.draft_count == 1) " draft comment · " else " draft comments · ", muted);
    summary.styledUnsigned(view.counts.unresolved, muted);
    summary.styledText("/", muted);
    summary.styledUnsigned(view.counts.total, muted);
    summary.styledText(" threads unresolved", muted);

    // Body editor (multi-line, scrolls to keep the cursor visible; clipped to the
    // available rows above the footer).
    const body_top: u16 = 5;
    const footer_row: u16 = if (win.height >= 2) win.height - 1 else 0;
    const err_row: u16 = if (win.height >= 3) win.height - 2 else 0;
    if (body_top < err_row) {
        drawBodyEditor(win, view, body_top, err_row);
    }

    if (view.error_msg.len > 0 and err_row > body_top) {
        var err = LineWriter.init(win, err_row, danger, view.bg);
        err.styledText(" ⚠ ", danger);
        err.styledText(view.error_msg, danger);
    }

    var footer = LineWriter.init(win, footer_row, muted, view.bg);
    if (view.confirm_discard) {
        footer.styledText(" ^D again to discard the pending review · any key cancels", warn_yellow);
    } else {
        footer.styledText(" ^S submit · Tab verdict · ^D discard · Esc cancel", muted);
    }
}

/// Draw the read-only PR info panel into `win` (a pre-sized popup window; this fn
/// paints the `view.bg` fill). A fixed metadata header, then a scrollable body of
/// checks + reviews + description (`view.scroll` skips that many logical lines),
/// and a footer noting any unplaced/truncated threads (AD-9: nothing silently
/// dropped).
pub fn drawInfoPanel(win: vaxis.Window, view: InfoView) void {
    if (win.height == 0 or win.width == 0) return;
    fillBackground(win, view.bg);

    var header = LineWriter.init(win, 0, .{ .bold = true }, view.bg);
    header.styledText(" #", muted);
    header.styledUnsigned(view.number, muted);
    header.text(" ");
    header.text(view.title);

    var meta = LineWriter.init(win, 1, muted, view.bg);
    meta.styledText(" @", muted);
    meta.styledText(view.author, accent);
    meta.styledText("  ", muted);
    meta.styledText(view.base_ref, muted);
    meta.styledText(" ← ", muted);
    meta.styledText(view.head_ref, muted);
    if (view.is_draft) meta.styledText("  · draft", warn_yellow);

    var status = LineWriter.init(win, 2, muted, view.bg);
    status.styledText(" ", muted);
    status.styledText(rollupGlyph(view.rollup), rollupStyle(view.rollup));
    status.styledText(" CI · ", muted);
    if (view.review_decision.len > 0) {
        status.styledText(decisionLabel(view.review_decision), decisionStyle(view.review_decision));
        status.styledText(" · ", muted);
    }
    status.styledUnsigned(view.counts.unresolved, muted);
    status.styledText("/", muted);
    status.styledUnsigned(view.counts.total, muted);
    status.styledText(" unresolved · ", muted);
    status.styledUnsigned(view.draft_count, muted);
    status.styledText(" drafts", muted);

    // Footer + any note row: reserved at the bottom, drawn last.
    const footer_row: u16 = if (win.height >= 2) win.height - 1 else 0;
    const has_note = view.truncated or view.unplaced_count > 0;
    const note_row: u16 = if (has_note and win.height >= 3) footer_row - 1 else footer_row;
    // Scrollable content region: below the fixed header (rows 0..2 + a separator
    // row 3), above the note/footer rows.
    const body_top: u16 = 4;
    const body_bottom: u16 = if (has_note) note_row else footer_row;
    if (body_top < body_bottom) {
        drawInfoBody(win, view, body_top, body_bottom);
    }

    if (has_note and note_row > body_top) {
        var note = LineWriter.init(win, note_row, warn_yellow, view.bg);
        note.styledText(" ⚠ ", warn_yellow);
        if (view.unplaced_count > 0) {
            note.styledUnsigned(view.unplaced_count, warn_yellow);
            note.styledText(if (view.unplaced_count == 1) " thread not shown in diff" else " threads not shown in diff", warn_yellow);
        }
        if (view.truncated) {
            if (view.unplaced_count > 0) note.styledText(" · ", warn_yellow);
            note.styledText("showing first page (truncated)", warn_yellow);
        }
    }

    var footer = LineWriter.init(win, footer_row, muted, view.bg);
    footer.styledText(" j/k scroll · ^d/^u page · i/Esc/q close", muted);
}

// =============================================================================
// Helpers
// =============================================================================

fn drawVerdictOption(writer: *LineWriter, label: []const u8, selected: bool) void {
    if (selected) {
        writer.styledText("[", accent);
        writer.styledText(label, .{ .fg = .{ .index = 6 }, .bold = true });
        writer.styledText("]", accent);
    } else {
        writer.styledText(" ", muted);
        writer.styledText(label, muted);
        writer.styledText(" ", muted);
    }
}

/// Draw the review-body editor into rows `[top, bottom)`. The body scrolls
/// vertically so the cursor line stays visible when the body is taller than the
/// region, and (when `view.editing`) a hardware cursor is positioned at the
/// cursor byte offset — mirroring the diff comment editor (rendering/utils.zig).
fn drawBodyEditor(win: vaxis.Window, view: SubmitView, top: u16, bottom: u16) void {
    const visible_rows: usize = bottom - top; // caller guarantees top < bottom

    if (view.body.len == 0) {
        var empty = LineWriter.init(win, top, muted, view.bg);
        empty.styledText(" (no summary — Ctrl-S submits the drafts)", muted);
        if (view.editing) positionCursor(win, top, 1, view.insert_mode);
        return;
    }

    // Cursor line/column from the byte offset: newlines before the cursor give the
    // logical row; graphemes since the last newline give the display column.
    const cb = @min(view.cursor_byte, view.body.len);
    var cursor_row: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < cb) : (i += 1) {
        if (view.body[i] == '\n') {
            cursor_row += 1;
            line_start = i + 1;
        }
    }
    var cursor_col: usize = 0;
    var giter = win.unicode.graphemeIterator(view.body[line_start..cb]);
    while (giter.next()) |g| cursor_col += win.gwidth(g.bytes(view.body[line_start..cb]));

    // Scroll so the cursor row stays inside the visible window (anchor to bottom
    // once the cursor passes the last visible row).
    const scroll: usize = if (cursor_row >= visible_rows) cursor_row - visible_rows + 1 else 0;

    var row = top;
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, view.body, '\n');
    while (it.next()) |line| : (idx += 1) {
        if (idx < scroll) continue;
        if (row >= bottom) break;
        var writer = LineWriter.init(win, row, .{}, view.bg);
        writer.styledText(" ", .{});
        writer.text(line);
        row += 1;
    }

    if (view.editing and cursor_row >= scroll) {
        const phys_row: u16 = top + @as(u16, @intCast(cursor_row - scroll));
        if (phys_row < bottom) positionCursor(win, phys_row, 1 + cursor_col, view.insert_mode);
    }
}

fn positionCursor(win: vaxis.Window, row: u16, col: usize, insert_mode: bool) void {
    const clamped: u16 = @intCast(@min(col, @as(usize, win.width -| 1)));
    win.showCursor(clamped, row);
    win.setCursorShape(if (insert_mode) .beam else .block);
}

/// Render the scrollable info body: a Checks section (per-check glyph rows), a
/// Reviews section (state + author + first body line), then the PR description.
/// `view.scroll` skips that many logical lines from the top of this region.
fn drawInfoBody(win: vaxis.Window, view: InfoView, top: u16, bottom: u16) void {
    var cur = BodyCursor{ .win = win, .bg = view.bg, .scroll = view.scroll, .bottom = bottom, .row = top };

    // Checks section.
    if (view.checks.len > 0) {
        if (cur.begin(muted)) |lw| {
            var w = lw;
            w.styledText(" Checks (", muted);
            w.styledUnsigned(view.checks.len, muted);
            w.styledText(")", muted);
        }
        for (view.checks) |c| {
            if (cur.begin(.{})) |lw| {
                var w = lw;
                w.styledText("   ", muted);
                w.styledText(checkGlyph(c), checkStyle(c));
                w.styledText(" ", muted);
                w.text(c.name);
            }
        }
        _ = cur.begin(muted); // spacer
    }

    // Reviews section.
    if (view.reviews.len > 0) {
        if (cur.begin(muted)) |lw| {
            var w = lw;
            w.styledText(" Reviews (", muted);
            w.styledUnsigned(view.reviews.len, muted);
            w.styledText(")", muted);
        }
        for (view.reviews) |r| {
            if (cur.begin(.{})) |lw| {
                var w = lw;
                w.styledText("   ", muted);
                w.styledText(reviewStateLabel(r.state), reviewStateStyle(r.state));
                w.styledText(" ", muted);
                w.styledText(r.author, accent);
                const first = firstLine(r.body);
                if (first.len > 0) {
                    w.styledText(" — ", muted);
                    w.text(first);
                }
            }
        }
        _ = cur.begin(muted); // spacer
    }

    // Description section.
    if (view.body.len > 0) {
        if (cur.begin(muted)) |lw| {
            var w = lw;
            w.styledText(" Description", muted);
        }
        var it = std.mem.splitScalar(u8, view.body, '\n');
        while (it.next()) |line| {
            if (cur.begin(.{})) |lw| {
                var w = lw;
                w.styledText(" ", .{});
                w.text(line);
            } else if (cur.exhausted()) break;
        }
    }
}

fn fillBackground(win: vaxis.Window, bg: Color) void {
    win.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
}

fn checkGlyph(c: CheckRun) []const u8 {
    if (!std.mem.eql(u8, c.status, "COMPLETED")) return "●";
    if (isFailureConclusion(c.conclusion)) return "✗";
    return "✓";
}

fn checkStyle(c: CheckRun) Style {
    if (!std.mem.eql(u8, c.status, "COMPLETED")) return warn_yellow;
    if (isFailureConclusion(c.conclusion)) return danger;
    return ok_green;
}

fn isFailureConclusion(conclusion: []const u8) bool {
    const failures = [_][]const u8{ "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE" };
    for (failures) |f| {
        if (std.mem.eql(u8, conclusion, f)) return true;
    }
    return false;
}

fn reviewStateLabel(state: ReviewState) []const u8 {
    return switch (state) {
        .approved => "approved",
        .changes_requested => "changes",
        .commented => "commented",
        .dismissed => "dismissed",
        .pending => "pending",
        .unknown => "review",
    };
}

fn reviewStateStyle(state: ReviewState) Style {
    return switch (state) {
        .approved => ok_green,
        .changes_requested => danger,
        .pending => warn_yellow,
        else => muted,
    };
}

fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    return it.next() orelse "";
}

fn rollupGlyph(rollup: RollupState) []const u8 {
    return switch (rollup) {
        .success => "✓",
        .failure, .err => "✗",
        .pending => "•",
        .none => "·",
    };
}

fn rollupStyle(rollup: RollupState) Style {
    return switch (rollup) {
        .success => ok_green,
        .failure, .err => danger,
        .pending => warn_yellow,
        .none => muted,
    };
}

fn decisionLabel(decision: []const u8) []const u8 {
    if (std.mem.eql(u8, decision, "APPROVED")) return "approved";
    if (std.mem.eql(u8, decision, "CHANGES_REQUESTED")) return "changes requested";
    if (std.mem.eql(u8, decision, "REVIEW_REQUIRED")) return "review required";
    return decision;
}

fn decisionStyle(decision: []const u8) Style {
    if (std.mem.eql(u8, decision, "APPROVED")) return ok_green;
    if (std.mem.eql(u8, decision, "CHANGES_REQUESTED")) return danger;
    return muted;
}

/// Walks the scrollable info body, drawing only the logical lines within the
/// `[scroll, scroll + visible_rows)` window. `begin` returns a positioned
/// `LineWriter` for the current logical line when it is visible (and advances the
/// physical row), or null when it is scrolled off / past the bottom.
const BodyCursor = struct {
    win: vaxis.Window,
    bg: Color,
    scroll: usize,
    bottom: u16,
    vi: usize = 0,
    row: u16,

    fn begin(self: *BodyCursor, style: Style) ?LineWriter {
        const visible = self.vi >= self.scroll and self.row < self.bottom;
        self.vi += 1;
        if (!visible) return null;
        const lw = LineWriter.init(self.win, self.row, style, self.bg);
        self.row += 1;
        return lw;
    }

    fn exhausted(self: *const BodyCursor) bool {
        return self.row >= self.bottom;
    }
};

const LineWriter = struct {
    win: vaxis.Window,
    row: u16,
    col: u16,
    style: Style,
    bg: Color,

    fn init(win: vaxis.Window, row: u16, style: Style, bg: Color) LineWriter {
        return .{ .win = win, .row = row, .col = 0, .style = style, .bg = bg };
    }

    fn text(self: *LineWriter, value: []const u8) void {
        var iter = self.win.unicode.graphemeIterator(value);
        while (iter.next()) |item| {
            const bytes = item.bytes(value);
            if (std.mem.eql(u8, bytes, "\n")) return;
            self.grapheme(bytes);
        }
    }

    fn styledText(self: *LineWriter, value: []const u8, style: Style) void {
        const old_style = self.style;
        self.style = style;
        self.text(value);
        self.style = old_style;
    }

    fn unsigned(self: *LineWriter, value: u64) void {
        var divisor: u64 = 1;
        while (value / divisor >= 10) divisor *= 10;
        var remaining = divisor;
        while (remaining > 0) : (remaining /= 10) {
            const digit: usize = @intCast((value / remaining) % 10);
            self.grapheme(digit_graphemes[digit]);
        }
    }

    fn styledUnsigned(self: *LineWriter, value: u64, style: Style) void {
        const old_style = self.style;
        self.style = style;
        self.unsigned(value);
        self.style = old_style;
    }

    fn grapheme(self: *LineWriter, value: []const u8) void {
        const width = self.win.gwidth(value);
        if (width == 0) return;
        if (width > self.win.width - self.col) {
            self.col = self.win.width;
            return;
        }
        var style = self.style;
        style.bg = self.bg;
        self.win.writeCell(self.col, self.row, .{
            .char = .{ .grapheme = value, .width = @intCast(width) },
            .style = style,
        });
        self.col += width;
    }
};

const digit_graphemes = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TestScreen = struct {
    screen: vaxis.Screen,
    unicode: vaxis.Unicode,

    fn init(cols: u16, rows: u16) !TestScreen {
        var screen = try vaxis.Screen.init(testing.allocator, .{
            .cols = cols,
            .rows = rows,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        errdefer screen.deinit(testing.allocator);
        const unicode = try vaxis.Unicode.init(testing.allocator);
        return .{ .screen = screen, .unicode = unicode };
    }

    fn deinit(self: *TestScreen) void {
        self.screen.deinit(testing.allocator);
        self.unicode.deinit(testing.allocator);
    }

    fn window(self: *TestScreen) vaxis.Window {
        return .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = self.screen.width,
            .height = self.screen.height,
            .screen = &self.screen,
            .unicode = &self.unicode,
        };
    }
};

fn rowContains(screen: vaxis.Screen, row: u16, needle: []const u8) bool {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    var col: u16 = 0;
    while (col < screen.width) : (col += 1) {
        const cell = screen.readCell(col, row) orelse continue;
        const g = cell.char.grapheme;
        if (len + g.len > buf.len) break;
        @memcpy(buf[len .. len + g.len], g);
        len += g.len;
    }
    return std.mem.indexOf(u8, buf[0..len], needle) != null;
}

fn screenContains(screen: vaxis.Screen, needle: []const u8) bool {
    var row: u16 = 0;
    while (row < screen.height) : (row += 1) {
        if (rowContains(screen, row, needle)) return true;
    }
    return false;
}

test "drawSubmitDialog: lists all three verdicts and brackets the selected one" {
    var ts = try TestScreen.init(60, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{
        .verdict = .approve,
        .body = "looks good",
        .draft_count = 2,
        .counts = .{ .total = 3, .unresolved = 1 },
    });

    try testing.expect(rowContains(ts.screen, 0, "Submit review"));
    try testing.expect(rowContains(ts.screen, 2, "Comment"));
    try testing.expect(rowContains(ts.screen, 2, "[Approve]"));
    try testing.expect(rowContains(ts.screen, 2, "Request changes"));
}

test "drawSubmitDialog: summary shows draft count and unresolved/total threads" {
    var ts = try TestScreen.init(60, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{
        .verdict = .comment,
        .draft_count = 2,
        .counts = .{ .total = 5, .unresolved = 2 },
    });

    try testing.expect(rowContains(ts.screen, 3, "2 draft comments"));
    try testing.expect(rowContains(ts.screen, 3, "2/5 threads unresolved"));
}

test "drawSubmitDialog: renders the review body preview" {
    var ts = try TestScreen.init(60, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .comment, .body = "first line\nsecond line" });

    try testing.expect(rowContains(ts.screen, 5, "first line"));
    try testing.expect(rowContains(ts.screen, 6, "second line"));
}

test "drawSubmitDialog: scrolls the body to keep the cursor line visible" {
    var ts = try TestScreen.init(40, 10);
    defer ts.deinit();

    // height 10 → footer row 9, error row 8, body rows [5, 8): 3 visible rows.
    const body = "l0\nl1\nl2\nl3\nl4\nl5";
    drawSubmitDialog(ts.window(), .{
        .verdict = .comment,
        .body = body,
        .cursor_byte = body.len, // cursor on the last line (row 5)
        .editing = true,
        .insert_mode = true,
    });

    // cursor_row = 5, visible_rows = 3 → scroll = 3; rows show l3/l4/l5.
    try testing.expect(rowContains(ts.screen, 5, "l3"));
    try testing.expect(rowContains(ts.screen, 7, "l5"));
    try testing.expect(!screenContains(ts.screen, "l0"));
}

test "drawSubmitDialog: positions a beam cursor at the editor cursor in insert mode" {
    var ts = try TestScreen.init(40, 12);
    defer ts.deinit();

    // Cursor after "abc" on the first body line: physical row = body_top (5),
    // physical col = 1 (leading space) + 3 graphemes = 4.
    drawSubmitDialog(ts.window(), .{
        .verdict = .comment,
        .body = "abc",
        .cursor_byte = 3,
        .editing = true,
        .insert_mode = true,
    });

    try testing.expect(ts.screen.cursor_vis);
    try testing.expectEqual(@as(u16, 5), ts.screen.cursor_row);
    try testing.expectEqual(@as(u16, 4), ts.screen.cursor_col);
    try testing.expectEqual(vaxis.Cell.CursorShape.beam, ts.screen.cursor_shape);
}

test "drawSubmitDialog: uses a block cursor in normal mode" {
    var ts = try TestScreen.init(40, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{
        .verdict = .comment,
        .body = "x",
        .cursor_byte = 0,
        .editing = true,
        .insert_mode = false,
    });

    try testing.expect(ts.screen.cursor_vis);
    try testing.expectEqual(vaxis.Cell.CursorShape.block, ts.screen.cursor_shape);
}

test "drawSubmitDialog: no cursor is shown when not editing" {
    var ts = try TestScreen.init(40, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .comment, .body = "abc", .editing = false });

    try testing.expect(!ts.screen.cursor_vis);
}

test "drawSubmitDialog: surfaces a submit error above the footer" {
    var ts = try TestScreen.init(70, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{
        .verdict = .approve,
        .error_msg = "Can not approve your own pull request",
    });

    try testing.expect(rowContains(ts.screen, 10, "approve your own pull request"));
}

test "drawSubmitDialog: armed discard shows the confirm prompt in the footer" {
    var ts = try TestScreen.init(70, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .comment, .confirm_discard = true });

    try testing.expect(rowContains(ts.screen, 11, "^D again to discard"));
}

test "drawSubmitDialog: fills every cell with the popup background" {
    var ts = try TestScreen.init(30, 8);
    defer ts.deinit();

    const bg: Color = .{ .rgb = [3]u8{ 22, 22, 22 } };
    drawSubmitDialog(ts.window(), .{ .verdict = .comment, .bg = bg });

    // A blank cell (row 1, past the title) still carries the dialog background.
    const cell = ts.screen.readCell(5, 1).?;
    try testing.expect(std.meta.eql(cell.style.bg, bg));
}

test "drawInfoPanel: header shows number, title, author, and branch flow" {
    var ts = try TestScreen.init(80, 14);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{
        .number = 42,
        .title = "Add widget",
        .author = "octocat",
        .base_ref = "main",
        .head_ref = "feat",
        .review_decision = "APPROVED",
        .rollup = .success,
        .body = "Description body.",
        .counts = .{ .total = 3, .unresolved = 1 },
        .draft_count = 0,
    });

    try testing.expect(rowContains(ts.screen, 0, "#42 Add widget"));
    try testing.expect(rowContains(ts.screen, 1, "@octocat"));
    try testing.expect(rowContains(ts.screen, 1, "main ← feat"));
    try testing.expect(rowContains(ts.screen, 2, "approved"));
    try testing.expect(rowContains(ts.screen, 2, "1/3 unresolved"));
}

test "drawInfoPanel: renders a draft marker when the PR is a draft" {
    var ts = try TestScreen.init(80, 14);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T", .is_draft = true });

    try testing.expect(rowContains(ts.screen, 1, "draft"));
}

test "drawInfoPanel: lists reviews with verdict and author" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    const reviews = [_]Review{.{
        .id = "PRR_1",
        .author = "mlugg",
        .state = .approved,
        .body = "lgtm\nmore detail",
        .submitted_at = "2025-01-01",
    }};
    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .reviews = &reviews,
    });

    try testing.expect(screenContains(ts.screen, "Reviews (1)"));
    try testing.expect(screenContains(ts.screen, "approved"));
    try testing.expect(screenContains(ts.screen, "mlugg"));
    try testing.expect(screenContains(ts.screen, "lgtm"));
}

test "drawInfoPanel: lists a passing check with a check glyph" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    const checks = [_]CheckRun{.{ .name = "build", .status = "COMPLETED", .conclusion = "SUCCESS" }};
    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T", .checks = &checks });

    try testing.expect(screenContains(ts.screen, "Checks (1)"));
    try testing.expect(screenContains(ts.screen, "✓ build"));
}

test "drawInfoPanel: lists a failing check with a failure glyph" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    const checks = [_]CheckRun{.{ .name = "lint", .status = "COMPLETED", .conclusion = "FAILURE" }};
    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .review_decision = "CHANGES_REQUESTED",
        .checks = &checks,
    });

    try testing.expect(screenContains(ts.screen, "✗ lint"));
    try testing.expect(rowContains(ts.screen, 2, "changes requested"));
}

test "drawInfoPanel: lists an in-progress check as pending" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    const checks = [_]CheckRun{.{ .name = "deploy", .status = "IN_PROGRESS", .conclusion = "" }};
    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T", .checks = &checks });

    try testing.expect(screenContains(ts.screen, "● deploy"));
}

test "drawInfoPanel: footer notes unplaced threads" {
    var ts = try TestScreen.init(80, 14);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "desc",
        .unplaced_count = 3,
    });

    try testing.expect(rowContains(ts.screen, 12, "3 threads not shown in diff"));
}

test "drawInfoPanel: footer notes a truncated fetch" {
    var ts = try TestScreen.init(80, 14);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "desc",
        .truncated = true,
    });

    try testing.expect(rowContains(ts.screen, 12, "truncated"));
}

test "drawInfoPanel: body scroll skips leading lines" {
    var ts = try TestScreen.init(60, 10);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "line one\nline two\nline three",
        .scroll = 2,
    });

    // With scroll=2, "Description" header + first body line are skipped; line two
    // shows at the top of the content region.
    try testing.expect(rowContains(ts.screen, 4, "line two"));
    try testing.expect(!rowContains(ts.screen, 4, "line one"));
}
