//! Pure drawing for the two Phase-5 review overlays: the submit-review dialog
//! (verdict selector + body preview + discard confirm) and the read-only PR info
//! panel. Both read an immutable `View` snapshot and never mutate app state
//! (AD-1). The imperative shell (`ui.zig`) builds the centered popup window,
//! fills it with `dialog_bg`, and feeds these a `SubmitView` / `InfoView`
//! assembled from the `ReviewSession`; a `bg` on the view keeps every text cell
//! carrying the popup background so the dialog layers cleanly over the diff.
//!
//! Layout draws through the shared `pr/line_writer.zig` cell writer, with
//! colocated `TestScreen` tests (this module cannot import `../testing` without
//! escaping the `pr/` module root).

const std = @import("std");
const vaxis = @import("vaxis");
const review_controller = @import("review_controller.zig");
const review_parse = @import("review_parse.zig");
const line_writer = @import("line_writer.zig");
const width_util = @import("../rendering/width.zig");
const skim_io = @import("skim_io");

const Verdict = review_controller.Verdict;
const ThreadCounts = review_controller.ThreadCounts;
const RollupState = review_parse.RollupState;
const ReviewState = review_parse.ReviewState;
const Review = review_parse.Review;
const CheckRun = review_parse.CheckRun;
const Style = vaxis.Cell.Style;
const Color = vaxis.Cell.Color;
const LineWriter = line_writer.LineWriter;

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
    // Total logical lines in the scrollable body (from review_controller
    // .infoLineCount) — drives the footer scroll indicator. 0 means nothing
    // scrollable.
    total_lines: usize = 0,
    // Review data could not be fetched (git ok, gh failed). Renders a warn note
    // in place of the empty-PR placeholder so a fetch failure never reads as a
    // genuinely empty PR.
    data_unavailable: bool = false,
    // An `r` refetch is in flight. Surfaces a header marker (and swaps the
    // data-unavailable retry note to a refreshing state) so the action is
    // acknowledged inside the ~80%-screen overlay, not only on the status bar
    // peeking out below it.
    refreshing: bool = false,
    bg: Color = .default,
};

/// Draw the submit-review dialog into `win` (a pre-sized popup window; this fn
/// paints the `view.bg` fill). Renders a verdict selector, the draft/thread
/// summary, a preview of the review body, an optional error line, and the key
/// hints (with the discard confirmation when armed).
pub fn drawSubmitDialog(win: vaxis.Window, view: SubmitView) void {
    if (win.height == 0 or win.width == 0) return;
    fillBackground(win, view.bg);

    var title = LineWriter.init(.{ .win = win, .row = 0, .style = .{ .fg = .{ .index = 6 }, .bold = true }, .bg = view.bg });
    title.text(" Submit review");
    if (view.submitting) title.styledText("  submitting…", muted);

    // Verdict selector: the active verdict is marked and highlighted.
    var sel = LineWriter.init(.{ .win = win, .row = 2, .bg = view.bg });
    sel.styledText(" ", .{});
    drawVerdictOption(&sel, "Comment", view.verdict == .comment);
    sel.styledText("   ", .{});
    drawVerdictOption(&sel, "Approve", view.verdict == .approve);
    sel.styledText("   ", .{});
    drawVerdictOption(&sel, "Request changes", view.verdict == .request_changes);

    // Summary of what the submit publishes.
    var summary = LineWriter.init(.{ .win = win, .row = 3, .style = muted, .bg = view.bg });
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
    } else {
        // Too short to fit the body editor. review_submit_mode still forwards
        // every keystroke into the vim editor, so without a note here the user
        // would type the review body with no preview and no cursor — blind input
        // (Nielsen: visibility of system status). Surface a resize note in a row
        // above the footer so input is never silent.
        const note_row: u16 = @min(@as(u16, 4), footer_row -| 1);
        var note = LineWriter.init(.{ .win = win, .row = note_row, .style = warn_yellow, .bg = view.bg });
        note.styledText(" ⚠ ", warn_yellow);
        note.styledText("Terminal too small — resize to edit", warn_yellow);
    }

    if (view.error_msg.len > 0 and err_row > body_top) {
        var err = LineWriter.init(.{ .win = win, .row = err_row, .style = danger, .bg = view.bg });
        err.styledText(" ⚠ ", danger);
        err.styledText(view.error_msg, danger);
    }

    var footer = LineWriter.init(.{ .win = win, .row = footer_row, .style = muted, .bg = view.bg });
    if (view.confirm_discard) {
        footer.styledText(" ^D:Discard again  |  Any key:Cancel", warn_yellow);
    } else {
        footer.styledText(" Tab:Verdict  |  ^S/Enter:Submit  |  ^D:Discard  |  ESC:Cancel", muted);
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

    var header = LineWriter.init(.{ .win = win, .row = 0, .style = .{ .bold = true }, .bg = view.bg });
    header.styledText(" #", muted);
    header.styledUnsigned(view.number, muted);
    header.text(" ");
    header.text(view.title);
    if (view.refreshing) header.styledText("  refreshing…", muted);

    var meta = LineWriter.init(.{ .win = win, .row = 1, .style = muted, .bg = view.bg });
    meta.styledText(" @", muted);
    meta.styledText(view.author, accent);
    meta.styledText("  ", muted);
    meta.styledText(view.base_ref, muted);
    meta.styledText(" ← ", muted);
    meta.styledText(view.head_ref, muted);
    if (view.is_draft) meta.styledText("  · draft", warn_yellow);

    var status = LineWriter.init(.{ .win = win, .row = 2, .style = muted, .bg = view.bg });
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
        var note = LineWriter.init(.{ .win = win, .row = note_row, .style = warn_yellow, .bg = view.bg });
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

    var footer = LineWriter.init(.{ .win = win, .row = footer_row, .style = muted, .bg = view.bg });
    footer.styledText(" j/k/^d/^u scroll · g/G ends · r refresh · q close", muted);
    drawScrollIndicator(win, footer_row, view, body_top, body_bottom);
}

// =============================================================================
// Helpers
// =============================================================================

/// Placeholder shown when the review body is empty. Names what ^S actually
/// posts: the verdict itself, plus the drafts only when some are pending. The
/// old "submits the drafts" wording misled the approve/request-changes paths,
/// where submitting acts on the verdict even with zero drafts.
fn emptyBodyPlaceholder(verdict: Verdict, draft_count: usize) []const u8 {
    if (draft_count > 0) {
        return switch (verdict) {
            .comment => " (no summary — ^S submits the drafts)",
            .approve => " (no summary — ^S approves and submits the drafts)",
            .request_changes => " (no summary — ^S requests changes and submits the drafts)",
        };
    }
    return switch (verdict) {
        .comment => " (add a summary or a draft comment to submit)",
        .approve => " (no summary — ^S approves this PR)",
        .request_changes => " (no summary — ^S requests changes on this PR)",
    };
}

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
        var empty = LineWriter.init(.{ .win = win, .row = top, .style = muted, .bg = view.bg });
        empty.styledText(emptyBodyPlaceholder(view.verdict, view.draft_count), muted);
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
    var giter = vaxis.unicode.graphemeIterator(view.body[line_start..cb]);
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
        var writer = LineWriter.init(.{ .win = win, .row = row, .bg = view.bg });
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

    // Description section. Each logical line is word-wrapped to the popup content
    // width (one leading padding column) so long lines stay fully readable instead
    // of clipping at the right edge — matching how thread bodies wrap. Row
    // accounting mirrors this in review_controller.infoLineCount.
    if (view.body.len > 0) {
        if (cur.begin(muted)) |lw| {
            var w = lw;
            w.styledText(" Description", muted);
        }
        const content_width: usize = win.width -| 1;
        var it = std.mem.splitScalar(u8, view.body, '\n');
        lines: while (it.next()) |line| {
            var wrap = width_util.WrapIterator{ .text = line, .max_width = content_width };
            while (wrap.next()) |seg| {
                if (cur.begin(.{})) |lw| {
                    var w = lw;
                    w.styledText(" ", .{});
                    w.text(seg);
                } else if (cur.exhausted()) break :lines;
            }
        }
    }

    // Empty body: no checks, reviews, or description leaves the body a blank
    // rectangle — draw a placeholder so the panel never reads as broken. When the
    // review-data fetch failed (data_unavailable), the emptiness is a fetch
    // failure rather than a genuinely empty PR, so surface a distinct warn note
    // pointing at the retry key instead of the "No description." placeholder.
    if (view.checks.len == 0 and view.reviews.len == 0 and view.body.len == 0) {
        if (cur.begin(muted)) |lw| {
            var w = lw;
            if (view.data_unavailable and view.refreshing) {
                w.styledText(" ⚠ Review data unavailable — refreshing…", muted);
            } else if (view.data_unavailable) {
                w.styledText(" ⚠ Review data unavailable — press r to retry", warn_yellow);
            } else {
                w.styledText(" No description.", muted);
            }
        }
    }
}

/// Draw a scroll-position indicator right-aligned into the footer's trailing
/// columns — arrows cue that content extends above (`↑`) / below (`↓`) the
/// visible region, and `pos/total` mirrors the picker's `selected/total`
/// readout. Right-aligned (rather than appended after the hint) so it renders
/// independently of the hint length: on a narrow popup — e.g. the 64-col default
/// on an 80-col terminal — appending would clip it off past the right edge.
/// Drawn only when the body is actually taller than the visible region (nothing
/// to scroll → no clutter).
fn drawScrollIndicator(win: vaxis.Window, footer_row: u16, view: InfoView, body_top: u16, body_bottom: u16) void {
    if (body_top >= body_bottom) return;
    const visible_rows: usize = body_bottom - body_top;
    if (view.total_lines <= visible_rows) return;

    const scroll = @min(view.scroll, view.total_lines -| 1);
    const more_above = scroll > 0;
    const more_below = scroll + visible_rows < view.total_lines;

    const arrows: u16 = @as(u16, @intFromBool(more_above)) + @as(u16, @intFromBool(more_below));
    const indicator_width: u16 = arrows + 1 + digitCount(scroll + 1) + 1 + digitCount(view.total_lines);
    if (win.width <= indicator_width) return;
    // Flush right with a one-column margin mirroring the hint's one-column left pad.
    const start_col: u16 = win.width -| indicator_width -| 1;

    var ind = LineWriter.init(.{ .win = win, .row = footer_row, .col = start_col, .style = muted, .bg = view.bg });
    if (more_above) ind.styledText("↑", muted);
    if (more_below) ind.styledText("↓", muted);
    ind.styledText(" ", muted);
    ind.styledUnsigned(scroll + 1, muted);
    ind.styledText("/", muted);
    ind.styledUnsigned(view.total_lines, muted);
}

fn digitCount(value: u64) u16 {
    var count: u16 = 1;
    var v = value;
    while (v >= 10) : (v /= 10) count += 1;
    return count;
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
        const lw = LineWriter.init(.{ .win = self.win, .row = self.row, .style = style, .bg = self.bg });
        self.row += 1;
        return lw;
    }

    fn exhausted(self: *const BodyCursor) bool {
        return self.row >= self.bottom;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const render_test_screen = @import("render_test_screen.zig");
const TestScreen = render_test_screen.TestScreen;
const rowContains = render_test_screen.rowContains;

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

test "drawSubmitDialog: empty-body approve placeholder names the verdict, not drafts" {
    var ts = try TestScreen.init(70, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .approve, .draft_count = 0 });

    try testing.expect(rowContains(ts.screen, 5, "approves this PR"));
    try testing.expect(!screenContains(ts.screen, "submits the drafts"));
}

test "drawSubmitDialog: empty-body request-changes placeholder names the verdict" {
    var ts = try TestScreen.init(70, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .request_changes, .draft_count = 0 });

    try testing.expect(rowContains(ts.screen, 5, "requests changes on this PR"));
}

test "drawSubmitDialog: empty-body comment placeholder guides instead of promising a refused submit" {
    var ts = try TestScreen.init(70, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .comment, .draft_count = 0 });

    try testing.expect(rowContains(ts.screen, 5, "add a summary or a draft comment to submit"));
    try testing.expect(!screenContains(ts.screen, "submits an empty comment review"));
}

test "drawSubmitDialog: empty-body placeholder mentions drafts when some are pending" {
    var ts = try TestScreen.init(70, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .approve, .draft_count = 3 });

    try testing.expect(rowContains(ts.screen, 5, "approves and submits the drafts"));
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
    try testing.expectEqual(@as(u16, 5), ts.screen.cursor.row);
    try testing.expectEqual(@as(u16, 4), ts.screen.cursor.col);
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

test "drawSubmitDialog: warns to resize instead of accepting blind input on an ultra-short terminal" {
    // height 6 → footer row 5, error row 4, body_top 5: the body editor region
    // collapses, so drawBodyEditor is skipped and no cursor is positioned. Keys
    // still forward into the editor, so a resize note must appear or the user
    // types the review body blind.
    var ts = try TestScreen.init(40, 6);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{
        .verdict = .comment,
        .body = "typed blind",
        .editing = true,
        .insert_mode = true,
    });

    try testing.expect(screenContains(ts.screen, "Terminal too small"));
    // No hardware cursor is positioned, so it must not read as an active editor.
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

    try testing.expect(rowContains(ts.screen, 11, "^D:Discard again"));
}

test "drawSubmitDialog: footer hints fit the production popup width without clipping ESC" {
    // Production sizes this popup at desired_width 64 (ui.zig). The footer must
    // fit so its trailing ESC:Cancel hint is never truncated.
    var ts = try TestScreen.init(64, 12);
    defer ts.deinit();

    drawSubmitDialog(ts.window(), .{ .verdict = .comment });

    try testing.expect(rowContains(ts.screen, 11, "ESC:Cancel"));
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

test "drawInfoPanel: shows a placeholder when there are no checks, reviews, or description" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T" });

    try testing.expect(screenContains(ts.screen, "No description."));
}

test "drawInfoPanel: warns when review data is unavailable instead of showing the empty placeholder" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T", .data_unavailable = true });

    try testing.expect(screenContains(ts.screen, "Review data unavailable"));
    try testing.expect(screenContains(ts.screen, "press r to retry"));
    try testing.expect(!screenContains(ts.screen, "No description."));
}

test "drawInfoPanel: header marks an in-flight refetch so the action is acknowledged in-panel" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T", .refreshing = true });

    try testing.expect(rowContains(ts.screen, 0, "refreshing…"));
}

test "drawInfoPanel: no refreshing marker when a refetch is not in flight" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T" });

    try testing.expect(!screenContains(ts.screen, "refreshing…"));
}

test "drawInfoPanel: data-unavailable note swaps to refreshing while a retry is in flight" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .data_unavailable = true,
        .refreshing = true,
    });

    try testing.expect(screenContains(ts.screen, "Review data unavailable — refreshing…"));
    try testing.expect(!screenContains(ts.screen, "press r to retry"));
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

test "drawInfoPanel: wraps a long description line instead of clipping it" {
    var ts = try TestScreen.init(20, 12);
    defer ts.deinit();

    // At width 20 the description column is 19 cells; this line is 30, so its tail
    // ("delta epsilon") would clip off the right edge without wrapping.
    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "alpha beta gamma delta epsilon",
    });

    // Description header at row 4; the line word-wraps onto rows 5 and 6 so the
    // tail stays readable rather than being lost past the edge.
    try testing.expect(rowContains(ts.screen, 4, "Description"));
    try testing.expect(rowContains(ts.screen, 5, "alpha"));
    try testing.expect(!rowContains(ts.screen, 5, "epsilon"));
    try testing.expect(rowContains(ts.screen, 6, "epsilon"));
}

test "drawInfoPanel: footer cues more content below and position when at the top" {
    var ts = try TestScreen.init(70, 10);
    defer ts.deinit();

    // height 10 → footer row 9, body rows [4, 9): 5 visible; total 9 > 5 scrolls.
    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "a\nb\nc\nd\ne\nf\ng\nh",
        .total_lines = 9,
        .scroll = 0,
    });

    try testing.expect(rowContains(ts.screen, 9, "↓"));
    try testing.expect(rowContains(ts.screen, 9, "1/9"));
    try testing.expect(!rowContains(ts.screen, 9, "↑"));
}

test "drawInfoPanel: footer cues more content above and below when scrolled" {
    var ts = try TestScreen.init(70, 10);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "a\nb\nc\nd\ne\nf\ng\nh",
        .total_lines = 9,
        .scroll = 3,
    });

    try testing.expect(rowContains(ts.screen, 9, "↑"));
    try testing.expect(rowContains(ts.screen, 9, "↓"));
    try testing.expect(rowContains(ts.screen, 9, "4/9"));
}

test "drawInfoPanel: footer omits the scroll indicator when content fits" {
    var ts = try TestScreen.init(70, 10);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "a\nb",
        .total_lines = 3,
    });

    try testing.expect(!rowContains(ts.screen, 9, "↑"));
    try testing.expect(!rowContains(ts.screen, 9, "↓"));
}

test "drawInfoPanel: footer documents g/G end jumps" {
    var ts = try TestScreen.init(80, 20);
    defer ts.deinit();

    drawInfoPanel(ts.window(), .{ .number = 1, .title = "T" });

    try testing.expect(rowContains(ts.screen, 19, "g/G ends"));
}

test "drawInfoPanel: scroll indicator renders at the 64-col default popup width" {
    // On an 80-col terminal the info popup is (80*4)/5 = 64 cols. The footer hint
    // plus a right-aligned scroll indicator must both fit; appending the indicator
    // after the full-width hint used to clip it off entirely at this width.
    var ts = try TestScreen.init(64, 10);
    defer ts.deinit();

    // height 10 → footer row 9, body rows [4, 9): 5 visible; total 9 > 5 scrolls.
    drawInfoPanel(ts.window(), .{
        .number = 1,
        .title = "T",
        .body = "a\nb\nc\nd\ne\nf\ng\nh",
        .total_lines = 9,
        .scroll = 3,
    });

    try testing.expect(rowContains(ts.screen, 9, "↑"));
    try testing.expect(rowContains(ts.screen, 9, "↓"));
    try testing.expect(rowContains(ts.screen, 9, "4/9"));
    // The shortened hint still fits alongside the indicator at this width.
    try testing.expect(rowContains(ts.screen, 9, "q close"));
}
