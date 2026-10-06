//! Draws the PR sidebar into a vaxis window: a header (preset, counts, sync
//! status), the query or filter prompt, an optional parse-error line, a rule,
//! the stack-grouped PR list, and a footer. Pure drawing: it reads a `View`
//! built by `controller.view` and never touches App or the store.

const std = @import("std");
const vaxis = @import("vaxis");
const parse = @import("../parse.zig");
const stack = @import("../stack.zig");
const line_writer = @import("../line_writer.zig");
const common = @import("../../rendering/common.zig");
const state_mod = @import("state.zig");

const CiStatus = parse.CiStatus;
const Style = vaxis.Cell.Style;
const LineWriter = line_writer.LineWriter;
const Color = common.Color;
const FrameChars = common.FrameChars;
const RowKind = state_mod.RowKind;

pub const ReviewGlyph = enum { none, requested_me, approved_by_me, approved, changes_requested };

/// 6a: always `.unknown`; 6b fills it from the prefetch cache.
pub const CacheState = enum { unknown, cached };

pub const SyncTone = enum { ok, busy, stale, err };

pub const EmptyState = union(enum) {
    /// The DB holds no open PRs for this repo.
    no_prs,
    /// Nothing synced yet and no error: the first sync is still running.
    syncing,
    /// Open PRs exist but the query hides all of them; the preset name, or
    /// the query text for a custom query.
    no_match: []const u8,
    /// The surface could not start (`SidebarState.unavailable`); the message.
    unavailable: []const u8,
    /// The DB holds no PRs because no sync has succeeded yet; the classified
    /// `github.kindMessage` of the last failure.
    sync_failed: []const u8,
};

pub const RowView = struct {
    kind: RowKind,
    number: u32,
    title: []const u8,
    author: []const u8,
    /// Member rows of a multi-PR stack; `.none` for header and standalone rows.
    connector: stack.Mark,
    /// Header rows only.
    stack_size: u16 = 0,
    /// Header rows only.
    expanded: bool = false,
    is_draft: bool,
    ci: CiStatus,
    review: ReviewGlyph,
    changed_since_seen: bool,
    cache: CacheState = .unknown,
};

pub const HeaderView = struct {
    /// Active preset name, or "custom".
    label: []const u8,
    /// PRs in the filtered view (collapsed members included).
    visible: usize,
    total: usize,
    query: []const u8,
};

pub const MenuLineKind = enum { section, preset, toggle, action };

pub const MenuLine = struct {
    kind: MenuLineKind,
    /// Section heading ("" = a blank spacer row) or item label.
    label: []const u8,
    /// Query text the item stands for, drawn dim on the right when it fits.
    detail: []const u8 = "",
    /// Preset: it is the applied query. Toggle: its term is in the query.
    on: bool = false,
    selected: bool = false,
};

/// The `f` filter menu, drawn as a box over the bottom of the list.
pub const MenuView = struct {
    lines: []const MenuLine,
    query: []const u8,
    /// PRs in the filtered view, as in `HeaderView`.
    visible: usize,
    total: usize,
    /// Visible stacks of more than one PR.
    stacks: usize,
};

/// One frame of the sidebar. `rows` holds the rows on screen, from the scroll
/// offset down; `draw` drops any that do not fit the window.
pub const View = struct {
    rows: []const RowView,
    /// Index into `rows`; null when the cursor row is not among them.
    cursor: ?usize,
    focused: bool,
    header: HeaderView,
    /// Prompt text while the query prompt is open.
    prompt: ?[]const u8 = null,
    /// Non-null while the filter menu is open.
    menu: ?MenuView = null,
    /// `ParseError.format` text of the last rejected query.
    parse_error: ?[]const u8 = null,
    sync_line: []const u8,
    sync_tone: SyncTone,
    empty: ?EmptyState = null,
    /// Surface or entry message (e.g. "Loading PR #812…"); replaces the hint.
    message: []const u8 = "",
};

pub const Columns = struct {
    /// Author column width; 0 = dropped.
    author: u16,
    /// First column of the glyph tail (D, CI, review, Δ, cache).
    tail: u16,
    /// The `│` divider.
    divider: u16,
};

// Semantic roles mapped onto the shared palette (moved from the picker).
const meta_fg = Color.syntax_comment;
const author_fg = Color.syntax_number;
const title_fg = Color.chat_content;
const accent_fg = Color.cyan;
const rule_fg = Color.comment_border;
const selected_bg = Color.list_selected_bg;

const header_rows: u16 = 3;
const footer_rows: u16 = 1;
const tail_glyphs: u16 = 5;
const max_author_cols: u16 = 10;
/// Inner width (window minus divider) at which the author column appears.
const author_min_inner: u16 = 40;
const min_title_cols: u16 = 6;
/// Footer key hints in priority order; trailing ones are dropped when narrow.
const hints = [_][]const u8{ " f:filter", " F:preset", " R:sync", " ^b:hide" };
const menu_hints = [_][]const u8{ " space:toggle", " enter:apply", " esc:close", " /:query" };
/// Box rows besides the items: top border, rule, query, counts, bottom border.
const menu_chrome_rows: u16 = 5;
const menu_bg = Color.dialog_bg;

pub fn draw(win: vaxis.Window, v: View) void {
    if (win.width < 2 or win.height == 0) return;
    const inner = win.width - 1;
    const body = win.child(.{ .width = inner, .height = win.height });

    drawHeaderRow(body, v);
    if (win.height > 1) drawQueryRow(body, v);
    var row: u16 = 2;
    if (v.parse_error) |message| {
        if (row < win.height) drawErrorRow(body, row, message);
        row += 1;
    }
    if (row < win.height) drawRule(body, row);
    row += 1;

    const list_rows = listRows(win.height, v.parse_error != null);
    if (v.empty) |empty| {
        drawEmpty(.{ .win = body, .top = row, .rows = list_rows, .empty = empty });
    } else {
        drawList(.{ .win = body, .top = row, .rows = list_rows, .view = v });
    }
    if (v.menu) |menu| {
        if (win.height > row + 1) drawMenu(.{ .win = body, .top = row, .bottom = win.height - 1, .menu = menu });
    }
    if (win.height > row) drawFooter(body, v);
    drawDivider(win);
}

/// Rows left for the PR list in a sidebar `height` rows tall.
pub fn listRows(height: u16, has_parse_error: bool) usize {
    const chrome = header_rows + footer_rows + @as(u16, @intFromBool(has_parse_error));
    return height -| chrome;
}

/// Column plan for a sidebar `width` wide whose longest author is
/// `longest_author` cells. The author column is the first thing dropped when
/// the sidebar is narrow.
pub fn rowColumns(width: u16, longest_author: u16) Columns {
    const inner = width -| 1;
    const author: u16 = if (inner >= author_min_inner) @min(max_author_cols, longest_author) else 0;
    return .{ .author = author, .tail = inner -| tail_glyphs, .divider = inner };
}

/// Main-pane placeholder while the PR surface has no diff loaded.
pub fn drawDiffPlaceholder(win: vaxis.Window, params: struct { message: []const u8, selected_number: ?u32 }) void {
    if (win.height == 0 or win.width == 0) return;
    const row = win.height / 2;
    if (params.message.len > 0) return drawCentered(win, row, params.message);
    const number = params.selected_number orelse return drawCentered(win, row, "No pull request selected");
    // Cells keep grapheme slices by reference, so the number is written from
    // LineWriter's static digits rather than a formatted stack buffer.
    const prefix = "Enter: open #";
    const width = win.gwidth(prefix) + digitWidth(number);
    const col: u16 = if (width < win.width) (win.width - width) / 2 else 0;
    var writer = LineWriter.init(.{ .win = win, .row = row, .col = col, .style = .{ .fg = meta_fg } });
    writer.text(prefix);
    writer.unsigned(number);
}

// =============================================================================
// Helpers
// =============================================================================

/// "preset · visible/total" on the left always wins, the preset name cut with
/// `…` so the count stays whole; the sync line takes the columns left over,
/// right-aligned, and is cut with `…` when they run out.
fn drawHeaderRow(win: vaxis.Window, v: View) void {
    var writer = LineWriter.init(.{ .win = win, .row = 0, .style = .{ .fg = meta_fg } });
    writer.text(" ");
    // " · " + visible + "/" + total.
    const count_cols = 3 + digitWidth(v.header.visible) + 1 + digitWidth(v.header.total);
    writeTruncated(.{
        .writer = &writer,
        .text = v.header.label,
        .cols = win.width -| (writer.col + count_cols),
        .style = .{ .fg = accent_fg, .bold = true },
    });
    writer.text(" · ");
    writer.unsigned(v.header.visible);
    writer.text("/");
    writer.unsigned(v.header.total);

    // One blank column after the count and one before the divider.
    const free = win.width -| (writer.col + 2);
    const sync_cols = @min(line_writer.displayWidth(win, v.sync_line), free);
    if (sync_cols == 0) return;
    const style = Style{ .fg = toneColor(v.sync_tone) };
    var sync = LineWriter.init(.{ .win = win, .row = 0, .col = win.width - 1 - sync_cols, .style = style });
    writeTruncated(.{ .writer = &sync, .text = v.sync_line, .cols = sync_cols, .style = style });
}

fn drawQueryRow(win: vaxis.Window, v: View) void {
    var writer = LineWriter.init(.{ .win = win, .row = 1 });
    if (v.prompt) |text| {
        writer.styledText(" /› ", .{ .fg = accent_fg });
        // The cursor sits at the end of the text, so a long query keeps its tail.
        writeTail(.{ .writer = &writer, .text = text, .cols = win.width -| (writer.col + 1), .style = .{ .fg = Color.bright_white } });
        writer.styledText("▏", .{ .fg = accent_fg });
        return;
    }
    writer.text(" ");
    if (v.header.query.len == 0) {
        writer.styledText("no filter", .{ .fg = meta_fg });
        return;
    }
    writeTruncated(.{ .writer = &writer, .text = v.header.query, .cols = win.width -| 2, .style = .{ .fg = meta_fg } });
}

fn drawErrorRow(win: vaxis.Window, row: u16, message: []const u8) void {
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = .{ .fg = Color.diff_sign_delete } });
    writer.text(" ✗ ");
    writeTruncated(.{ .writer = &writer, .text = message, .cols = win.width -| 4, .style = .{ .fg = Color.diff_sign_delete } });
}

fn drawRule(win: vaxis.Window, row: u16) void {
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = .{ .fg = rule_fg } });
    var col: u16 = 0;
    while (col < win.width) : (col += 1) writer.text("─");
}

fn drawEmpty(params: struct { win: vaxis.Window, top: u16, rows: usize, empty: EmptyState }) void {
    if (params.rows == 0) return;
    const offset: u16 = @intCast(@min(params.rows / 3, 4));
    const row = params.top + offset;
    const win = params.win;
    switch (params.empty) {
        .no_prs => drawCentered(win, row, "No open pull requests"),
        .syncing => drawCentered(win, row, "Fetching pull requests…"),
        .unavailable, .sync_failed => |message| drawWrapped(.{ .win = win, .row = row, .rows = params.rows - offset, .text = message }),
        .no_match => |subject| {
            const prefix = "No PRs match `";
            const width = win.gwidth(prefix) + win.gwidth(subject) + 1;
            const col: u16 = if (width < win.width) (win.width - width) / 2 else 0;
            var writer = LineWriter.init(.{ .win = win, .row = row, .col = col, .style = .{ .fg = meta_fg } });
            writer.text(prefix);
            writer.text(subject);
            writer.text("`");
            if (params.rows > 1) drawCentered(win, row + 1, "f: filter menu · F: next preset");
        },
    }
}

fn drawList(params: struct { win: vaxis.Window, top: u16, rows: usize, view: View }) void {
    const v = params.view;
    var longest_author: u16 = 0;
    var digits: u16 = 1;
    const end = @min(v.rows.len, params.rows);
    for (v.rows[0..end]) |row| {
        longest_author = @max(longest_author, line_writer.displayWidth(params.win, row.author));
        digits = @max(digits, digitWidth(row.number));
    }
    // `win` is already the inner area, so add the divider column back.
    const columns = rowColumns(params.win.width + 1, longest_author);
    for (v.rows[0..end], 0..) |row, index| {
        drawRow(.{
            .win = params.win,
            .row = params.top + @as(u16, @intCast(index)),
            .item = row,
            .selected = v.cursor == index,
            .focused = v.focused,
            .columns = columns,
            .digits = digits,
        });
    }
}

fn drawRow(params: struct {
    win: vaxis.Window,
    row: u16,
    item: RowView,
    selected: bool,
    focused: bool,
    columns: Columns,
    digits: u16,
}) void {
    const win = params.win;
    const item = params.item;
    const bg: ?vaxis.Cell.Color = if (params.selected) selected_bg else null;
    const meta = Style{ .fg = meta_fg };
    if (params.selected) fillRow(win, params.row, .{ .bg = selected_bg });

    var writer = LineWriter.init(.{ .win = win, .row = params.row, .bg = bg });
    writer.styledText(if (params.selected and params.focused) "▌" else " ", .{ .fg = accent_fg });
    switch (item.kind) {
        .stack_header => writer.styledText(if (item.expanded) "▾ " else "▸ ", .{ .fg = rule_fg }),
        .member => {
            if (item.connector != .none) writer.text(" ");
            writer.styledText(stackGlyph(item.connector), .{ .fg = rule_fg });
        },
    }
    writer.styledText("#", meta);
    writer.styledUnsigned(item.number, meta);
    pad(&writer, params.digits -| digitWidth(item.number));
    if (item.kind == .stack_header) {
        writer.styledText(" [", meta);
        writer.styledUnsigned(item.stack_size, meta);
        writer.styledText("]", meta);
    }
    writer.text(" ");

    const columns = params.columns;
    const author_cols: u16 = if (columns.author > 0) columns.author + 1 else 0;
    const title_end = columns.tail -| (1 + author_cols);
    const title_cols = title_end -| writer.col;
    if (title_cols >= min_title_cols) {
        const title_style = Style{ .fg = if (item.is_draft) Color.dim_gray else title_fg, .bold = params.selected };
        writeTruncated(.{ .writer = &writer, .text = item.title, .cols = title_cols, .style = title_style });
    }
    if (columns.author > 0 and title_cols >= min_title_cols) {
        writer.col = title_end + 1;
        writeTruncated(.{ .writer = &writer, .text = item.author, .cols = columns.author, .style = .{ .fg = author_fg } });
    }
    drawTail(.{ .win = win, .row = params.row, .col = columns.tail, .bg = bg, .item = item });
}

fn drawTail(params: struct { win: vaxis.Window, row: u16, col: u16, bg: ?vaxis.Cell.Color, item: RowView }) void {
    const item = params.item;
    var writer = LineWriter.init(.{ .win = params.win, .row = params.row, .col = params.col, .bg = params.bg });
    writer.styledText(if (item.is_draft) "D" else " ", .{ .fg = Color.dim_gray });
    writer.styledText(ciGlyph(item.ci), .{ .fg = ciColor(item.ci) });
    writer.styledText(reviewGlyph(item.review), .{ .fg = reviewColor(item.review) });
    writer.styledText(if (item.changed_since_seen) "Δ" else " ", .{ .fg = Color.yellow });
    writer.styledText(if (item.cache == .cached) "◆" else " ", .{ .fg = meta_fg });
}

/// The filter menu as a box over the bottom of the list, between `top` and
/// the footer row `bottom`, so the list it filters stays in view above it.
/// Items scroll to keep the selected one visible; a sidebar too short for
/// one item draws no box.
fn drawMenu(params: struct { win: vaxis.Window, top: u16, bottom: u16, menu: MenuView }) void {
    const win = params.win;
    const menu = params.menu;
    const available = params.bottom -| params.top;
    if (win.width < 3 or available <= menu_chrome_rows or menu.lines.len == 0) return;
    const item_rows: u16 = @intCast(@min(menu.lines.len, available - menu_chrome_rows));
    const box_top = params.bottom - (item_rows + menu_chrome_rows);
    var row = box_top;
    while (row < params.bottom) : (row += 1) {
        fillRow(win, row, .{ .bg = menu_bg });
        drawMenuSides(win, row);
    }

    drawMenuBorder(.{ .win = win, .row = box_top, .left = "╭", .right = "╮", .title = " Filter " });
    const inner = win.child(.{ .x_off = 1, .y_off = 0, .width = win.width - 2, .height = win.height });
    const first = menuScroll(menu.lines, item_rows);
    for (menu.lines[first..][0..item_rows], 0..) |line, index| {
        drawMenuLine(inner, box_top + 1 + @as(u16, @intCast(index)), line);
    }
    row = box_top + 1 + item_rows;
    drawMenuBorder(.{ .win = win, .row = row, .left = "├", .right = "┤" });
    drawMenuQuery(inner, row + 1, menu.query);
    drawMenuCounts(inner, row + 2, menu);
    drawMenuBorder(.{ .win = win, .row = row + 3, .left = "╰", .right = "╯" });
}

/// First line to draw so the selected line is among the `rows` drawn.
fn menuScroll(lines: []const MenuLine, rows: u16) usize {
    for (lines, 0..) |line, index| {
        if (line.selected) return (index + 1) -| rows;
    }
    return 0;
}

fn drawMenuSides(win: vaxis.Window, row: u16) void {
    const style = Style{ .fg = rule_fg, .bg = menu_bg };
    var left = LineWriter.init(.{ .win = win, .row = row, .style = style });
    left.text(FrameChars.vertical);
    var right = LineWriter.init(.{ .win = win, .row = row, .col = win.width - 1, .style = style });
    right.text(FrameChars.vertical);
}

fn drawMenuBorder(params: struct { win: vaxis.Window, row: u16, left: []const u8, right: []const u8, title: []const u8 = "" }) void {
    const win = params.win;
    var writer = LineWriter.init(.{ .win = win, .row = params.row, .style = .{ .fg = rule_fg }, .bg = menu_bg });
    writer.text(params.left);
    if (params.title.len > 0) {
        writer.text(FrameChars.horizontal);
        writer.styledText(params.title, .{ .fg = accent_fg, .bold = true });
    }
    while (writer.col < win.width - 1) writer.text(FrameChars.horizontal);
    writer.text(params.right);
}

/// `▌○ Ready for review      -is:draft`: the cursor bar, the radio or
/// checkbox, the label, and the item's query text right-aligned when it fits.
fn drawMenuLine(win: vaxis.Window, row: u16, line: MenuLine) void {
    const bg = if (line.selected) selected_bg else menu_bg;
    if (line.selected) fillRow(win, row, .{ .bg = bg });
    var writer = LineWriter.init(.{ .win = win, .row = row, .bg = bg });
    if (line.kind == .section) {
        writer.text(" ");
        writer.styledText(line.label, .{ .fg = meta_fg, .bold = true });
        return;
    }
    writer.styledText(if (line.selected) "▌" else " ", .{ .fg = accent_fg });
    const mark_style = Style{ .fg = if (line.on) accent_fg else meta_fg };
    switch (line.kind) {
        .preset => writer.styledText(if (line.on) "● " else "○ ", mark_style),
        .toggle => writer.styledText(if (line.on) "[x] " else "[ ] ", mark_style),
        .action, .section => writer.text("  "),
    }
    const label_style = Style{ .fg = title_fg, .bold = line.selected };
    const detail_cols = line_writer.displayWidth(win, line.detail);
    // Label, one space, detail, one space before the border.
    const room = win.width -| writer.col;
    const label_cols = line_writer.displayWidth(win, line.label);
    if (detail_cols == 0 or label_cols + 1 + detail_cols + 1 > room) {
        writeTruncated(.{ .writer = &writer, .text = line.label, .cols = room -| 1, .style = label_style });
        return;
    }
    writer.styledText(line.label, label_style);
    writer.col = win.width - 1 - detail_cols;
    writer.styledText(line.detail, .{ .fg = meta_fg });
}

fn drawMenuQuery(win: vaxis.Window, row: u16, query: []const u8) void {
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = .{ .fg = meta_fg }, .bg = menu_bg });
    writer.text(" query ");
    if (query.len == 0) return writer.text("none");
    writeTruncated(.{ .writer = &writer, .text = query, .cols = win.width -| (writer.col + 1), .style = .{ .fg = Color.bright_white } });
}

/// ` 12/31 PRs · 2 stacks`.
fn drawMenuCounts(win: vaxis.Window, row: u16, menu: MenuView) void {
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = .{ .fg = meta_fg }, .bg = menu_bg });
    writer.text(" ");
    writer.unsigned(menu.visible);
    writer.text("/");
    writer.unsigned(menu.total);
    writer.text(if (menu.total == 1) " PR · " else " PRs · ");
    writer.unsigned(menu.stacks);
    writer.text(if (menu.stacks == 1) " stack" else " stacks");
}

fn drawFooter(win: vaxis.Window, v: View) void {
    const row = win.height - 1;
    var writer = LineWriter.init(.{ .win = win, .row = row, .style = .{ .fg = meta_fg } });
    if (v.message.len > 0) {
        writer.text(" ");
        writeTruncated(.{ .writer = &writer, .text = v.message, .cols = win.width -| 1, .style = .{ .fg = meta_fg } });
        return;
    }
    if (!v.focused) return;
    for (if (v.menu != null) &menu_hints else &hints) |segment| {
        if (writer.col + win.gwidth(segment) > win.width) return;
        writer.text(segment);
    }
}

fn drawDivider(win: vaxis.Window) void {
    var row: u16 = 0;
    while (row < win.height) : (row += 1) {
        var writer = LineWriter.init(.{ .win = win, .row = row, .col = win.width - 1, .style = .{ .fg = rule_fg } });
        writer.text("│");
    }
}

/// Writes `text` in at most `cols` cells, ending in `…` when it does not fit.
fn writeTruncated(params: struct { writer: *LineWriter, text: []const u8, cols: u16, style: Style }) void {
    const writer = params.writer;
    if (params.cols == 0) return;
    const win = writer.win;
    if (line_writer.displayWidth(win, params.text) <= params.cols) return writer.styledText(params.text, params.style);
    const limit = writer.col + params.cols - 1;
    var iter = vaxis.unicode.graphemeIterator(params.text);
    while (iter.next()) |item| {
        const bytes = item.bytes(params.text);
        if (writer.col + win.gwidth(bytes) > limit) break;
        writer.styledText(bytes, params.style);
    }
    writer.styledText("…", params.style);
}

/// Writes the end of `text` in at most `cols` cells, behind a `…` when the
/// start does not fit.
fn writeTail(params: struct { writer: *LineWriter, text: []const u8, cols: u16, style: Style }) void {
    const writer = params.writer;
    if (params.cols == 0) return;
    const win = writer.win;
    const total = win.gwidth(params.text);
    if (total <= params.cols) return writer.styledText(params.text, params.style);
    writer.styledText("…", params.style);
    var skip = total - (params.cols - 1);
    var iter = vaxis.unicode.graphemeIterator(params.text);
    while (iter.next()) |item| {
        const bytes = item.bytes(params.text);
        if (skip > 0) {
            skip -|= win.gwidth(bytes);
            continue;
        }
        writer.styledText(bytes, params.style);
    }
}

/// Word-wraps `text` into centered lines one column in from each side, using
/// at most `rows` rows from `row` down.
fn drawWrapped(params: struct { win: vaxis.Window, row: u16, rows: usize, text: []const u8 }) void {
    const win = params.win;
    const width = win.width -| 2;
    if (width == 0) return;
    var rest = std.mem.trim(u8, params.text, " ");
    var drawn: usize = 0;
    while (rest.len > 0 and drawn < params.rows) : (drawn += 1) {
        const line = wrapLine(win, rest, width);
        drawCentered(win, params.row + @as(u16, @intCast(drawn)), line);
        rest = std.mem.trimStart(u8, rest[line.len..], " ");
    }
}

/// The longest prefix of `text` ending at a space that fits in `width`
/// cells; a first word wider than that comes back whole (and is clipped).
fn wrapLine(win: vaxis.Window, text: []const u8, width: u16) []const u8 {
    if (win.gwidth(text) <= width) return text;
    var end: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, search_from, ' ')) |space| {
        if (win.gwidth(text[0..space]) > width) break;
        end = space;
        search_from = space + 1;
    }
    if (end > 0) return text[0..end];
    return text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
}

fn toneColor(tone: SyncTone) vaxis.Cell.Color {
    return switch (tone) {
        .ok => meta_fg,
        .busy => accent_fg,
        .stale => Color.yellow,
        .err => Color.diff_sign_delete,
    };
}

fn reviewGlyph(review: ReviewGlyph) []const u8 {
    return switch (review) {
        .none => " ",
        .requested_me => "●",
        .approved_by_me, .approved => "✓",
        .changes_requested => "±",
    };
}

fn reviewColor(review: ReviewGlyph) vaxis.Cell.Color {
    return switch (review) {
        .none, .requested_me => Color.cyan,
        .approved_by_me, .approved => Color.diff_sign_add,
        .changes_requested => Color.diff_sign_delete,
    };
}

fn drawCentered(win: vaxis.Window, row: u16, label: []const u8) void {
    if (row >= win.height) return;
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
        .pending => Color.syntax_type,
        .success => Color.diff_sign_add,
        .failure => Color.diff_sign_delete,
    };
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
const render_test_screen = @import("../render_test_screen.zig");
const TestScreen = render_test_screen.TestScreen;
const rowContains = render_test_screen.rowContains;

fn testRow(params: struct {
    kind: RowKind = .member,
    number: u32 = 812,
    title: []const u8 = "Retry fetch on 502",
    author: []const u8 = "alice",
    connector: stack.Mark = .none,
    stack_size: u16 = 0,
    expanded: bool = false,
    is_draft: bool = false,
    ci: CiStatus = .success,
    review: ReviewGlyph = .requested_me,
}) RowView {
    return .{
        .kind = params.kind,
        .number = params.number,
        .title = params.title,
        .author = params.author,
        .connector = params.connector,
        .stack_size = params.stack_size,
        .expanded = params.expanded,
        .is_draft = params.is_draft,
        .ci = params.ci,
        .review = params.review,
        .changed_since_seen = false,
    };
}

fn testView(rows: []const RowView, params: struct { focused: bool = true, cursor: ?usize = 0 }) View {
    return .{
        .rows = rows,
        .cursor = params.cursor,
        .focused = params.focused,
        .header = .{ .label = "all", .visible = rows.len, .total = rows.len, .query = "" },
        .sync_line = "⟳ 2m ago",
        .sync_tone = .ok,
    };
}

fn cellAt(ts: *TestScreen, col: u16, row: u16) []const u8 {
    const cell = ts.screen.readCell(col, row) orelse return "";
    return cell.char.grapheme;
}

test "draw: row shows #number, truncated title with …, author, glyph tail" {
    var ts = try TestScreen.init(50, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{ .title = "Retry fetch on 502 with exponential backoff and jitter" })};
    draw(ts.window(), testView(&rows, .{}));

    try testing.expect(rowContains(ts.screen, 3, "#812"));
    try testing.expect(rowContains(ts.screen, 3, "Retry fetch"));
    try testing.expect(rowContains(ts.screen, 3, "…"));
    try testing.expect(rowContains(ts.screen, 3, "alice"));
    try testing.expect(rowContains(ts.screen, 3, "✓●"));
}

test "draw: author column dropped below 40 inner cols" {
    var ts = try TestScreen.init(36, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{ .title = "Short", .author = "zelda" })};
    draw(ts.window(), testView(&rows, .{}));

    try testing.expect(rowContains(ts.screen, 3, "#812 Short"));
    try testing.expect(!rowContains(ts.screen, 3, "zelda"));
}

test "draw: title dropped below 6 cols, #number and glyphs remain" {
    var ts = try TestScreen.init(16, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{ .title = "Retry" })};
    draw(ts.window(), testView(&rows, .{}));

    try testing.expect(rowContains(ts.screen, 3, "#812"));
    try testing.expect(!rowContains(ts.screen, 3, "Retry"));
    try testing.expect(rowContains(ts.screen, 3, "✓●"));
}

test "draw: focused selection draws ▌; unfocused draws no bar" {
    var focused = try TestScreen.init(44, 8);
    defer focused.deinit();
    const rows = [_]RowView{testRow(.{})};
    draw(focused.window(), testView(&rows, .{ .focused = true }));
    try testing.expectEqualStrings("▌", cellAt(&focused, 0, 3));

    var unfocused = try TestScreen.init(44, 8);
    defer unfocused.deinit();
    draw(unfocused.window(), testView(&rows, .{ .focused = false }));
    try testing.expectEqualStrings(" ", cellAt(&unfocused, 0, 3));
    const cell = unfocused.screen.readCell(5, 3).?;
    try testing.expect(vaxis.Cell.Color.eql(cell.style.bg, selected_bg));
}

test "draw: header row shows ▸/▾ and [size]" {
    var ts = try TestScreen.init(44, 8);
    defer ts.deinit();
    const rows = [_]RowView{
        testRow(.{ .kind = .stack_header, .number = 813, .stack_size = 3 }),
        testRow(.{ .kind = .stack_header, .number = 790, .stack_size = 2, .expanded = true }),
    };
    draw(ts.window(), testView(&rows, .{}));

    try testing.expect(rowContains(ts.screen, 3, "▸ #813 [3]"));
    try testing.expect(rowContains(ts.screen, 4, "▾ #790 [2]"));
}

test "draw: member rows of a stack show the connector" {
    var ts = try TestScreen.init(44, 8);
    defer ts.deinit();
    const rows = [_]RowView{
        testRow(.{ .number = 814, .connector = .top }),
        testRow(.{ .number = 813, .connector = .middle }),
        testRow(.{ .number = 812, .connector = .bottom }),
    };
    draw(ts.window(), testView(&rows, .{ .cursor = null }));

    try testing.expect(rowContains(ts.screen, 3, "┌ #814"));
    try testing.expect(rowContains(ts.screen, 4, "│ #813"));
    try testing.expect(rowContains(ts.screen, 5, "└ #812"));
}

test "draw: divider │ in the last column on every row" {
    var ts = try TestScreen.init(40, 6);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{})};
    draw(ts.window(), testView(&rows, .{}));

    var row: u16 = 0;
    while (row < 6) : (row += 1) try testing.expectEqualStrings("│", cellAt(&ts, 39, row));
}

test "draw: rows below the window are not drawn" {
    var ts = try TestScreen.init(40, 6);
    defer ts.deinit();
    const rows = [_]RowView{ testRow(.{ .number = 1 }), testRow(.{ .number = 2 }), testRow(.{ .number = 3 }) };
    draw(ts.window(), testView(&rows, .{ .cursor = 2 }));

    try testing.expect(rowContains(ts.screen, 3, "#1"));
    try testing.expect(rowContains(ts.screen, 4, "#2"));
    try testing.expect(!rowContains(ts.screen, 5, "#3"));
}

test "drawDiffPlaceholder: shows the message, else Enter: open #n" {
    var ts = try TestScreen.init(40, 6);
    defer ts.deinit();
    drawDiffPlaceholder(ts.window(), .{ .message = "", .selected_number = 812 });
    try testing.expect(rowContains(ts.screen, 3, "Enter: open #812"));

    var loading = try TestScreen.init(40, 6);
    defer loading.deinit();
    drawDiffPlaceholder(loading.window(), .{ .message = "Loading PR #812…", .selected_number = 812 });
    try testing.expect(rowContains(loading.screen, 3, "Loading PR #812…"));
}

test "listRows: chrome is three header rows, one footer, plus the error line" {
    try testing.expectEqual(@as(usize, 16), listRows(20, false));
    try testing.expectEqual(@as(usize, 15), listRows(20, true));
    try testing.expectEqual(@as(usize, 0), listRows(3, true));
}

test "rowColumns: author capped at 10 and dropped below 40 inner cols" {
    try testing.expectEqual(Columns{ .author = 10, .tail = 38, .divider = 43 }, rowColumns(44, 14));
    try testing.expectEqual(Columns{ .author = 5, .tail = 38, .divider = 43 }, rowColumns(44, 5));
    try testing.expectEqual(Columns{ .author = 0, .tail = 26, .divider = 31 }, rowColumns(32, 14));
}

test "draw: a long sync line is cut with … and the preset and count stay visible" {
    var ts = try TestScreen.init(32, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{})};
    var v = testView(&rows, .{});
    v.header.label = "review-requested";
    v.sync_line = "offline · network error reaching GitHub";
    v.sync_tone = .stale;
    draw(ts.window(), v);

    try testing.expect(rowContains(ts.screen, 0, " review-requested · 1/1"));
    try testing.expect(rowContains(ts.screen, 0, "offl"));
    try testing.expect(rowContains(ts.screen, 0, "…"));
    try testing.expectEqualStrings("│", cellAt(&ts, 31, 0));
}

test "draw: a sync line that fits is drawn whole and right-aligned" {
    var ts = try TestScreen.init(44, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{})};
    draw(ts.window(), testView(&rows, .{}));

    try testing.expect(rowContains(ts.screen, 0, " all · 1/1"));
    try testing.expect(rowContains(ts.screen, 0, "⟳ 2m ago │"));
}

test "draw: the unavailable message wraps instead of losing its end at 32 cols" {
    var ts = try TestScreen.init(32, 12);
    defer ts.deinit();
    var v = testView(&.{}, .{ .cursor = null });
    v.empty = .{ .unavailable = "gh not authenticated — run `gh auth login`" };
    draw(ts.window(), v);

    var found_end = false;
    var row: u16 = 3;
    while (row < 11) : (row += 1) {
        if (rowContains(ts.screen, row, "`gh auth login`")) found_end = true;
    }
    try testing.expect(found_end);
    try testing.expect(!rowContains(ts.screen, 4, "…"));
}

test "draw: a failed first sync shows its message instead of an empty list" {
    var ts = try TestScreen.init(44, 12);
    defer ts.deinit();
    var v = testView(&.{}, .{ .cursor = null });
    v.empty = .{ .sync_failed = "network error reaching GitHub" };
    draw(ts.window(), v);

    var found = false;
    var row: u16 = 3;
    while (row < 11) : (row += 1) {
        if (rowContains(ts.screen, row, "network error reaching GitHub")) found = true;
        try testing.expect(!rowContains(ts.screen, row, "No open pull requests"));
    }
    try testing.expect(found);
}

test "draw: a prompt wider than the sidebar shows its tail after …" {
    var ts = try TestScreen.init(24, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{})};
    var v = testView(&rows, .{});
    v.prompt = "author:alice label:backend is:draft";
    draw(ts.window(), v);

    try testing.expect(rowContains(ts.screen, 1, " /› …"));
    try testing.expect(rowContains(ts.screen, 1, "is:draft▏"));
    try testing.expect(!rowContains(ts.screen, 1, "author"));
}

test "draw: a prompt that fits is drawn whole" {
    var ts = try TestScreen.init(44, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{})};
    var v = testView(&rows, .{});
    v.prompt = "author:alice";
    draw(ts.window(), v);

    try testing.expect(rowContains(ts.screen, 1, " /› author:alice▏"));
}

test "draw: a preset name too long for 32 cols is cut with … and the count still fits" {
    var ts = try TestScreen.init(32, 8);
    defer ts.deinit();
    const rows = [_]RowView{testRow(.{})};
    var v = testView(&rows, .{});
    v.header.label = "review-requested-by-my-team-and-more";
    v.header.visible = 12;
    v.header.total = 345;
    draw(ts.window(), v);

    try testing.expect(rowContains(ts.screen, 0, " review-requested-by-… · 12/345"));
    try testing.expectEqualStrings("│", cellAt(&ts, 31, 0));
}
