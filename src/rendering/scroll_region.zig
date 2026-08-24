//! Redraws a scrolled diff with a terminal scroll sequence instead of a full
//! repaint.
//!
//! vaxis diffs the new frame against the frame on screen cell by cell. When the
//! diff view scrolls, every content row moves, so that diff calls the whole
//! screen changed and re-encodes it - about 28 KB for one `j` on a 190x60
//! terminal, and about 42 KB in side-by-side view. A terminal moves those rows
//! itself for ten bytes.
//!
//! `apply` finds the frames that are the previous frame shifted by whole rows,
//! writes the scroll sequence, and rewrites `screen_last` to match what the
//! terminal now shows. The `vaxis.render` that follows then draws only the rows
//! that the scroll exposed.
//!
//! The rewrite of `screen_last` is exact for any shift, so a frame with many
//! changed rows stays correct. The match count below is only a test of whether
//! the scroll saves bytes.

const std = @import("std");
const vaxis = @import("vaxis");
const rendering_common = @import("common.zig");

const Layout = rendering_common.Layout;
const InternalCell = vaxis.AllocatingScreen.InternalCell;
const ctlseqs = vaxis.ctlseqs;

/// Rows that must survive a shift for the scroll to be worth its sequence.
/// The cursor line, the scrollbar thumb, and the hunk header all move
/// independently of the content, so a true scroll never matches every row.
const match_numerator = 3;
const match_denominator = 4;

/// A shift that leaves fewer than this many rows in place costs more in exposed
/// rows than it saves.
const min_overlap = 8;

/// Painted cells a row needs before it can serve as the anchor. A blank row
/// matches every other blank row, so it names every shift and none.
const min_anchor_cells = 8;

/// Number of shift candidates to test in full. An anchor row rarely gives more
/// than one, but a screen with repeated content can give many.
const max_candidates = 8;

/// Divisors that place the anchor rows in the band: the middle, then a quarter
/// down, then a third down. An anchor names a shift only when the shift keeps
/// the anchor inside the band, so spreading them covers shifts from one row up
/// to most of a page.
const anchor_offsets = [_]u16{ 2, 4, 3 };

/// Turns a scrolled frame into a terminal scroll. Call after the frame is built
/// into `vx.screen` and before `vx.render`.
///
/// Returns the number of rows scrolled, negative for a scroll toward the top of
/// the screen, or 0 when the frame is not a shift of the frame on screen.
pub fn apply(vx: *vaxis.Vaxis, writer: *std.io.Writer) !i32 {
    if (vx.refresh) return 0;
    if (!vx.state.alt_screen) return 0;

    const band = bandOf(vx) orelse return 0;
    const shift = detectShift(vx, band);
    if (shift == 0) return 0;

    const magnitude: u16 = @intCast(@abs(shift));

    // Scroll with index and reverse index inside a margin rather than with the
    // pan sequences. Both are VT100, so a terminal that lacks `CSI S` still
    // moves the rows, and both erase the exposed rows with the current
    // background - hence the reset first.
    try writer.writeAll(ctlseqs.sync_set ++ ctlseqs.sgr_reset);
    try writer.print("\x1b[{d};{d}r", .{ band.top + 1, band.bottom });
    var moved: u16 = 0;
    if (shift > 0) {
        try writer.print("\x1b[{d};1H", .{band.bottom});
        while (moved < magnitude) : (moved += 1) try writer.writeAll(ctlseqs.ind);
    } else {
        try writer.print("\x1b[{d};1H", .{band.top + 1});
        while (moved < magnitude) : (moved += 1) try writer.writeAll(ctlseqs.ri);
    }
    try writer.writeAll("\x1b[r");

    shiftLastScreen(vx, band, shift);
    return shift;
}

/// The rows a scroll may move: everything between the file header and the
/// status bar. Both sit outside the scroll region, so the terminal leaves them
/// alone and `screen_last` keeps them unchanged.
const Band = struct {
    top: u16,
    bottom: u16,

    fn height(self: Band) u16 {
        return self.bottom - self.top;
    }
};

fn bandOf(vx: *const vaxis.Vaxis) ?Band {
    const reserved = Layout.header_height + Layout.status_height;
    if (vx.screen.height <= reserved + min_overlap) return null;
    if (vx.screen.width == 0) return null;
    return .{
        .top = Layout.header_height,
        .bottom = vx.screen.height - Layout.status_height,
    };
}

/// Finds the row shift between the new frame and the frame on screen, or 0.
///
/// A few distinctive rows of the new frame give the candidate shifts, so the
/// cost stays near one row comparison per band row even when nothing scrolled.
/// An anchor only names shifts that keep it on screen, so the anchors sit at
/// three points of the band and a half-page shift is still found.
fn detectShift(vx: *const vaxis.Vaxis, band: Band) i32 {
    var candidates: [max_candidates]i32 = undefined;
    var candidate_count: usize = 0;
    var first_anchor = true;

    for (anchor_offsets) |offset| {
        const anchor = anchorRow(vx, band, band.top + band.height() / offset) orelse continue;

        // The first anchor still sits where it was, so the band did not scroll.
        if (first_anchor and rowsMatch(vx, .{ .new_row = anchor, .last_row = anchor })) return 0;
        first_anchor = false;

        var last_row = band.top;
        while (last_row < band.bottom) : (last_row += 1) {
            if (last_row == anchor) continue;
            if (!rowsMatch(vx, .{ .new_row = anchor, .last_row = last_row })) continue;
            const shift = @as(i32, last_row) - @as(i32, anchor);
            if (std.mem.indexOfScalar(i32, candidates[0..candidate_count], shift) != null) continue;
            if (candidate_count == max_candidates) return 0;
            candidates[candidate_count] = shift;
            candidate_count += 1;
        }
    }

    var best: i32 = 0;
    var best_matches: u16 = 0;
    for (candidates[0..candidate_count]) |shift| {
        const matches = countMatches(vx, band, shift) orelse continue;
        if (matches > best_matches) {
            best_matches = matches;
            best = shift;
        }
    }
    return best;
}

/// Counts the band rows that a shift keeps, or null when the shift keeps too
/// few of them to pay for itself.
fn countMatches(vx: *const vaxis.Vaxis, band: Band, shift: i32) ?u16 {
    const magnitude: u16 = @intCast(@abs(shift));
    if (magnitude >= band.height()) return null;
    const overlap = band.height() - magnitude;
    if (overlap < min_overlap) return null;

    const needed: u16 = @intCast((@as(u32, overlap) * match_numerator) / match_denominator);
    const allowed_misses = overlap - needed;

    // A scroll toward the bottom of the screen reads the new rows from lower in
    // the frame on screen, so the first comparable new row moves down instead.
    const first_new_row: u16 = if (shift > 0) band.top else band.top + magnitude;

    var matches: u16 = 0;
    var misses: u16 = 0;
    var offset: u16 = 0;
    while (offset < overlap) : (offset += 1) {
        const new_row = first_new_row + offset;
        const last_row: u16 = @intCast(@as(i32, new_row) + shift);
        if (rowsMatch(vx, .{ .new_row = new_row, .last_row = last_row })) {
            matches += 1;
        } else {
            misses += 1;
            if (misses > allowed_misses) return null;
        }
    }
    return matches;
}

/// Rewrites `screen_last` to the rows the terminal shows after the scroll: the
/// band rotated by the shift, with the exposed rows blanked the way the
/// terminal erases them.
fn shiftLastScreen(vx: *vaxis.Vaxis, band: Band, shift: i32) void {
    const width: usize = vx.screen.width;
    const magnitude: usize = @intCast(@abs(shift));
    const rows = vx.screen_last.buf[@as(usize, band.top) * width .. @as(usize, band.bottom) * width];

    if (shift > 0) {
        std.mem.rotate(InternalCell, rows, magnitude * width);
        blankRows(rows[(rows.len - magnitude * width)..]);
    } else {
        std.mem.rotate(InternalCell, rows, rows.len - magnitude * width);
        blankRows(rows[0 .. magnitude * width]);
    }
}

fn blankRows(cells: []InternalCell) void {
    for (cells) |*cell| {
        cell.char.clearRetainingCapacity();
        cell.char.appendAssumeCapacity(' ');
        cell.style = .{};
        cell.uri.clearRetainingCapacity();
        cell.uri_id.clearRetainingCapacity();
        cell.default = true;
        cell.skipped = false;
        cell.skip = false;
        cell.scale = .{};
    }
}

/// Picks a band row of the new frame to match against the frame on screen. A
/// blank row matches everywhere, so it cannot name a shift. The search runs
/// outward from `start` so the anchor stays near the point the caller asked for.
fn anchorRow(vx: *const vaxis.Vaxis, band: Band, start: u16) ?u16 {
    var step: u16 = 0;
    while (step < band.height()) : (step += 1) {
        const below = start + step;
        if (below < band.bottom and rowIsDistinctive(vx, below)) return below;
        if (start >= band.top + step) {
            const above = start - step;
            if (rowIsDistinctive(vx, above)) return above;
        }
    }
    return null;
}

fn rowIsDistinctive(vx: *const vaxis.Vaxis, row: u16) bool {
    const width: usize = vx.screen.width;
    const cells = vx.screen.buf[@as(usize, row) * width .. (@as(usize, row) + 1) * width];
    var painted: usize = 0;
    for (cells) |cell| {
        if (cell.default) continue;
        painted += 1;
        if (painted >= min_anchor_cells) return true;
    }
    return false;
}

fn rowsMatch(vx: *const vaxis.Vaxis, rows: struct { new_row: u16, last_row: u16 }) bool {
    const width: usize = vx.screen.width;
    const new_cells = vx.screen.buf[@as(usize, rows.new_row) * width .. (@as(usize, rows.new_row) + 1) * width];
    const last_cells = vx.screen_last.buf[@as(usize, rows.last_row) * width .. (@as(usize, rows.last_row) + 1) * width];
    for (new_cells, last_cells) |new_cell, last_cell| {
        if (new_cell.image != null) return false;
        if (!last_cell.eql(new_cell)) return false;
    }
    return true;
}

const testing = std.testing;

/// Static grapheme source for test cells. A cell borrows its grapheme, so it
/// cannot point at a buffer that a later row reuses.
const alphabet = "abcdefghijklmnopqrstuvwxyz";

/// A vaxis screen plus the bytes it writes, so a test can drive two frames and
/// read back what the scroll left behind.
const TestScreen = struct {
    vx: vaxis.Vaxis,
    out: std.io.Writer.Allocating,
    /// A cell borrows its grapheme, so the label bytes must outlive the frame
    /// that vaxis keeps in `screen_last`.
    labels: [max_rows][label_width]u8,

    const label_width = 10;
    const max_rows = 64;

    fn init(cols: u16, rows: u16) !TestScreen {
        std.debug.assert(rows <= max_rows);
        var self: TestScreen = .{
            .vx = try vaxis.init(testing.allocator, .{}),
            .out = .init(testing.allocator),
            .labels = undefined,
        };
        self.vx.state.alt_screen = true;
        try self.vx.resize(testing.allocator, &self.out.writer, .{
            .rows = rows,
            .cols = cols,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        self.out.clearRetainingCapacity();
        return self;
    }

    fn deinit(self: *TestScreen) void {
        self.vx.screen.deinit(testing.allocator);
        self.vx.screen_last.deinit(testing.allocator);
        self.vx.unicode.deinit(testing.allocator);
        self.out.deinit();
    }

    /// Fills every row with content derived from `base`, so row `r` carries line
    /// `base + r`. Painting `base + 1` is a one-row scroll up. The first columns
    /// hold a readable label and the rest hold a per-line pattern, so two lines
    /// share almost no cells and a cell-by-cell redraw stays expensive.
    fn paint(self: *TestScreen, base: u16) void {
        const win = self.vx.window();
        win.clear();
        var row: u16 = 0;
        while (row < win.height) : (row += 1) {
            const line = base + row;
            const text = std.fmt.bufPrint(&self.labels[row], "line{d:0>6}", .{line}) catch unreachable;
            for (text, 0..) |byte, col| {
                win.writeCell(@intCast(col), row, .{
                    .char = .{ .grapheme = text[col .. col + 1], .width = 1 },
                    .style = .{ .fg = .{ .index = @intCast(byte % 8) } },
                });
            }
            var col: u16 = label_width;
            while (col < win.width) : (col += 1) {
                const pick = (@as(usize, line) * 7 + col * 3) % alphabet.len;
                win.writeCell(col, row, .{
                    .char = .{ .grapheme = alphabet[pick .. pick + 1], .width = 1 },
                    .style = .{ .fg = .{ .index = @intCast(pick % 8) } },
                });
            }
        }
    }

    /// Sends the current frame to the terminal and drops the bytes, so the next
    /// frame starts from a known screen.
    fn commit(self: *TestScreen) !void {
        try self.vx.render(&self.out.writer);
        try self.out.writer.flush();
        self.out.clearRetainingCapacity();
    }

    /// The label the terminal shows on `row`, taken from what vaxis believes it
    /// has already drawn.
    fn lastRowText(self: *TestScreen, row: u16, buf: []u8) []const u8 {
        const width: usize = self.vx.screen.width;
        const cells = self.vx.screen_last.buf[@as(usize, row) * width ..][0..label_width];
        for (cells, 0..) |cell, i| buf[i] = cell.char.items[0];
        return buf[0..label_width];
    }
};

test "reports a one-row scroll toward the top of the screen" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(1);

    try testing.expectEqual(@as(i32, 1), try apply(&screen.vx, &screen.out.writer));
}

test "reports a one-row scroll toward the bottom of the screen" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(5);
    try screen.commit();
    screen.paint(4);

    try testing.expectEqual(@as(i32, -1), try apply(&screen.vx, &screen.out.writer));
}

test "reports a half-page scroll" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(9);

    try testing.expectEqual(@as(i32, 9), try apply(&screen.vx, &screen.out.writer));
}

test "reports no scroll when the frame is unchanged" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(3);
    try screen.commit();
    screen.paint(3);

    try testing.expectEqual(@as(i32, 0), try apply(&screen.vx, &screen.out.writer));
}

test "reports no scroll when the frame shares no rows with the screen" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(400);

    try testing.expectEqual(@as(i32, 0), try apply(&screen.vx, &screen.out.writer));
}

test "reports no scroll while a full redraw is queued" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(1);
    screen.vx.queueRefresh();

    try testing.expectEqual(@as(i32, 0), try apply(&screen.vx, &screen.out.writer));
}

test "reports no scroll on a screen too short to hold a scroll region" {
    var screen = try TestScreen.init(30, 8);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(1);

    try testing.expectEqual(@as(i32, 0), try apply(&screen.vx, &screen.out.writer));
}

test "writes a scroll region that spares the header and the status bar" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(1);
    _ = try apply(&screen.vx, &screen.out.writer);
    try screen.out.writer.flush();

    const written = screen.out.written();
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[2;19r") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[19;1H\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[r") != null);
}

test "moves the drawn rows up so the next render redraws only the exposed row" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(1);
    _ = try apply(&screen.vx, &screen.out.writer);

    var buf: [TestScreen.label_width]u8 = undefined;
    try testing.expectEqualStrings("line000002", screen.lastRowText(1, &buf));
    try testing.expectEqualStrings("line000018", screen.lastRowText(17, &buf));
    try testing.expectEqualStrings("          ", screen.lastRowText(18, &buf));
}

test "moves the drawn rows down so the next render redraws only the exposed row" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(5);
    try screen.commit();
    screen.paint(4);
    _ = try apply(&screen.vx, &screen.out.writer);

    var buf: [TestScreen.label_width]u8 = undefined;
    try testing.expectEqualStrings("          ", screen.lastRowText(1, &buf));
    try testing.expectEqualStrings("line000006", screen.lastRowText(2, &buf));
    try testing.expectEqualStrings("line000022", screen.lastRowText(18, &buf));
}

test "leaves the header and the status bar untouched" {
    var screen = try TestScreen.init(30, 20);
    defer screen.deinit();

    screen.paint(0);
    try screen.commit();
    screen.paint(1);
    _ = try apply(&screen.vx, &screen.out.writer);

    var buf: [TestScreen.label_width]u8 = undefined;
    try testing.expectEqualStrings("line000000", screen.lastRowText(0, &buf));
    try testing.expectEqualStrings("line000019", screen.lastRowText(19, &buf));
}

test "cuts the bytes a scrolled frame sends to the terminal" {
    var full = try TestScreen.init(30, 20);
    defer full.deinit();
    full.paint(0);
    try full.commit();
    full.paint(1);
    try full.vx.render(&full.out.writer);
    try full.out.writer.flush();
    const full_bytes = full.out.written().len;

    var scrolled = try TestScreen.init(30, 20);
    defer scrolled.deinit();
    scrolled.paint(0);
    try scrolled.commit();
    scrolled.paint(1);
    _ = try apply(&scrolled.vx, &scrolled.out.writer);
    try scrolled.vx.render(&scrolled.out.writer);
    try scrolled.out.writer.flush();
    const scrolled_bytes = scrolled.out.written().len;

    try testing.expect(scrolled_bytes * 3 < full_bytes);
}
