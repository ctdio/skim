//! PR sidebar logic: free functions over `*SidebarState`. Pure: none of them
//! touches the store, the sync worker or github (D4). `surface.zig` reads the
//! DB and hands an in-memory `Snapshot` to `applySnapshot`; everything else
//! reshapes that snapshot for the cursor, the filter and the view.

const std = @import("std");
const types = @import("../db/types.zig");
const filter_query = @import("../filter_query.zig");
const stack = @import("../stack.zig");
const config = @import("../../config.zig");
const state_mod = @import("state.zig");
const render = @import("render.zig");

const Allocator = std.mem.Allocator;
const SidebarState = state_mod.SidebarState;
const Row = state_mod.Row;
const SyncSnapshot = state_mod.SyncSnapshot;
const PrRecord = types.PrRecord;

pub const Snapshot = struct {
    /// Ownership moves into the state, also when `applySnapshot` fails.
    records: types.RecordList,
    /// Copied; the caller's `OwnedRepo` is freed after the call.
    viewer_login: []const u8,
    /// '\n'-joined "org/slug"; copied.
    viewer_teams: []const u8,
    sync: SyncSnapshot,
};

pub const ViewParams = struct {
    /// `app.mode == .pr_review`.
    focused: bool,
    /// Unix seconds, for the sync age.
    now_secs: i64,
    /// `View.rows` and the formatted strings live here for one frame.
    frame_allocator: Allocator,
    /// List rows on screen (`render.listRows`); only those are built.
    visible_rows: usize,
};

pub const PromptKey = union(enum) {
    char: u21,
    backspace,
    enter,
    escape,
};

pub const PromptOutcome = enum { none, query_changed };

pub const Edge = enum { top, bottom };

/// Where record `index` sits in its stack, as `records.items` indices.
/// `bottom` and `tip` are null for a standalone PR.
pub const StackPlace = struct {
    parent: ?usize = null,
    bottom: ?usize = null,
    tip: ?usize = null,
};

/// Seconds after the last good sync at which the list counts as stale.
const stale_after_secs: i64 = 5 * 60;

/// Matches every PR; used while no query has been applied.
const match_all = filter_query.Query{ .source = "", .terms = &.{} };

/// Install a DB snapshot: recompute stack analysis and re-run the filter. The
/// cursor follows `selected_number`; the prompt and expanded set survive.
pub fn applySnapshot(state: *SidebarState, allocator: Allocator, snap: Snapshot) !void {
    var records = snap.records;
    var records_owned = true;
    defer if (records_owned) records.deinit();

    const edges = try filter_query.edgesOf(allocator, records.items);
    defer allocator.free(edges);
    var analysis = try stack.analyzeEdges(allocator, edges);
    errdefer analysis.deinit(allocator);
    const arena = records.arena.allocator();
    const viewer_login = try arena.dupe(u8, snap.viewer_login);
    const viewer_teams = try arena.dupe(u8, snap.viewer_teams);

    // Rows and stacks index the old records; drop them before the swap so a
    // failed rebuild leaves an empty list rather than dangling indices.
    clearRows(state, allocator);
    releaseSnapshot(state, allocator);
    state.records = records;
    records_owned = false;
    state.analysis = analysis;
    state.viewer_login = viewer_login;
    state.viewer_teams = viewer_teams;
    state.sync = snap.sync;
    try rebuildRows(state, allocator);
}

/// Re-evaluate the active query over the current records and rebuild `rows`.
/// Keeps `selected_number` (re-finds the cursor) and the expanded set.
pub fn rebuildRows(state: *SidebarState, allocator: Allocator) !void {
    const records = state.records orelse {
        clearRows(state, allocator);
        refindCursor(state);
        return;
    };
    const next = try filter_query.visibleStacks(allocator, .{
        .records = records.items,
        .analysis = &state.analysis.?,
        .query = state.active_query orelse match_all,
        .ctx = .{ .viewer_login = state.viewer_login, .viewer_teams = state.viewer_teams },
    });
    state.stacks.deinit(allocator);
    state.stacks = next;
    try layoutRows(state, allocator);
}

/// Row by row (`j`/`k`, arrows, half pages).
pub fn move(state: *SidebarState, delta: isize) void {
    if (state.rows.items.len == 0) return;
    state.cursor = clampIndex(@as(isize, @intCast(state.cursor)) + delta, state.rows.items.len);
    syncSelected(state);
}

/// Jump to the next/previous header or standalone row, skipping the members
/// of expanded stacks (`Ctrl-n`/`Ctrl-p`).
pub fn moveStack(state: *SidebarState, delta: isize) void {
    const rows = state.rows.items;
    if (rows.len == 0 or delta == 0) return;
    var index = state.cursor;
    var remaining = @abs(delta);
    while (remaining > 0) : (remaining -= 1) {
        index = nextAnchor(state, .{ .from = index, .forward = delta > 0 }) orelse break;
    }
    state.cursor = index;
    syncSelected(state);
}

/// Next/previous member of the cursor's stack (`J`/`K`), clamped to the
/// stack. On a collapsed stack: expand it and land on the review target.
pub fn moveWithinStack(state: *SidebarState, allocator: Allocator, delta: isize) !void {
    const rows = state.rows.items;
    if (rows.len == 0 or delta == 0) return;
    const row = rows[state.cursor];
    const sv = state.stacks.views[row.stack];
    if (sv.members.len == 1) return;

    if (row.kind == .stack_header) {
        const tip = tipNumber(state, row.stack);
        if (!state.expanded.contains(tip)) {
            try state.expanded.put(allocator, tip, {});
            try layoutRows(state, allocator);
            state.cursor = memberRowOf(state, .{ .stack = row.stack, .record = @intCast(sv.target) }) orelse state.cursor;
            syncSelected(state);
            return;
        }
        if (delta < 0) return;
        state.cursor += 1;
        syncSelected(state);
        return;
    }

    const first = (memberRowOf(state, .{ .stack = row.stack, .record = @intCast(sv.members[0]) }) orelse return);
    const last = first + sv.members.len - 1;
    const target = @as(isize, @intCast(state.cursor)) + delta;
    state.cursor = @intCast(std.math.clamp(target, @as(isize, @intCast(first)), @as(isize, @intCast(last))));
    syncSelected(state);
}

/// `gg` / `G`.
pub fn moveToEdge(state: *SidebarState, edge: Edge) void {
    const len = state.rows.items.len;
    if (len == 0) return;
    state.cursor = switch (edge) {
        .top => 0,
        .bottom => len - 1,
    };
    syncSelected(state);
}

/// Expand or collapse the cursor's stack (`space`, `za`). No-op on a
/// standalone PR.
pub fn toggleExpand(state: *SidebarState, allocator: Allocator) !void {
    const row = cursorRow(state) orelse return;
    if (state.stacks.views[row.stack].members.len == 1) return;
    const tip = tipNumber(state, row.stack);
    if (state.expanded.remove(tip)) {
        // Collapsing from a member keeps the cursor on the stack's header.
        state.cursor_on_header = true;
    } else {
        try state.expanded.put(allocator, tip, {});
    }
    try layoutRows(state, allocator);
}

/// Collapse the cursor's stack and put the cursor on its header (`h`).
pub fn collapse(state: *SidebarState, allocator: Allocator) !void {
    const row = cursorRow(state) orelse return;
    if (state.stacks.views[row.stack].members.len == 1) return;
    _ = state.expanded.remove(tipNumber(state, row.stack));
    state.cursor_on_header = true;
    try layoutRows(state, allocator);
}

/// Parse and apply `text`. Returns false on a parse error, which is stored in
/// `parse_error` while the last good query and rows stay (AD-10).
pub fn applyQuery(state: *SidebarState, allocator: Allocator, text: []const u8) !bool {
    switch (try filter_query.parse(allocator, text)) {
        .err => |parse_error| {
            var error_view = state_mod.ParseErrorView{ .reason = parse_error.reason };
            const written = std.fmt.bufPrint(&error_view.text, "{f}", .{parse_error}) catch error_view.text[0..];
            error_view.text_len = written.len;
            state.parse_error = error_view;
            return false;
        },
        .ok => |query| {
            var next = query;
            var previous = state.active_query;
            state.active_query = next;
            rebuildRows(state, allocator) catch |err| {
                state.active_query = previous;
                next.deinit(allocator);
                return err;
            };
            if (previous) |*old| old.deinit(allocator);
            const kept = utf8Prefix(text, state_mod.query_cap);
            @memcpy(state.query[0..kept.len], kept);
            state.query_len = kept.len;
            state.active_preset = presetIndexOf(state, text);
            if (state.active_preset) |index| state.base_preset = index;
            state.parse_error = null;
            return true;
        },
    }
}

/// Apply the next preset in config order, wrapping (`F`).
pub fn cyclePreset(state: *SidebarState, allocator: Allocator) !void {
    const presets = state.presets;
    if (presets.len == 0) return;
    const next = if (state.active_preset) |index| (index + 1) % presets.len else 0;
    if (try applyQuery(state, allocator, presets[next].query)) selectPreset(state, next);
}

/// Esc on a custom query: go back to the preset that was active before it.
/// False when already on a preset (or none exist), so Esc peels further.
pub fn restorePreset(state: *SidebarState, allocator: Allocator) !bool {
    if (state.active_preset != null or state.presets.len == 0) return false;
    const index = @min(state.base_preset, state.presets.len - 1);
    if (!try applyQuery(state, allocator, state.presets[index].query)) return false;
    selectPreset(state, index);
    return true;
}

/// Open the `f` prompt pre-filled with the current query.
pub fn openPrompt(state: *SidebarState) void {
    var prompt = state_mod.Prompt{};
    const text = state.queryText();
    @memcpy(prompt.buf[0..text.len], text);
    prompt.len = text.len;
    state.prompt = prompt;
}

/// One key while the prompt is open. `.query_changed` tells the caller to
/// push the new visible set to the workers (FR-5).
pub fn promptKey(state: *SidebarState, allocator: Allocator, key: PromptKey) !PromptOutcome {
    const prompt = if (state.prompt) |*p| p else return .none;
    switch (key) {
        .char => |codepoint| {
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &encoded) catch return .none;
            if (prompt.len + len > prompt.buf.len) return .none;
            @memcpy(prompt.buf[prompt.len..][0..len], encoded[0..len]);
            prompt.len += len;
        },
        .backspace => {
            if (prompt.len == 0) return .none;
            var end = prompt.len - 1;
            while (end > 0 and (prompt.buf[end] & 0xC0) == 0x80) end -= 1;
            prompt.len = end;
        },
        .escape => {
            state.prompt = null;
            state.parse_error = null;
        },
        .enter => {
            const text = prompt.text();
            if (std.mem.eql(u8, text, state.queryText()) and state.active_query != null) {
                state.prompt = null;
                state.parse_error = null;
                return .none;
            }
            if (!try applyQuery(state, allocator, text)) return .none;
            state.prompt = null;
            return .query_changed;
        },
    }
    return .none;
}

/// The PR under the cursor. A header row yields the stack's review target
/// (AD-10), whose title the collapsed header shows.
pub fn selectedPr(state: *const SidebarState) ?*const PrRecord {
    const row = cursorRow(state) orelse return null;
    return &state.records.?.items[row.record];
}

/// Index into `records.items` of PR `number`, whether or not the filter shows it.
pub fn recordIndex(state: *const SidebarState, number: u32) ?usize {
    const records = state.records orelse return null;
    for (records.items, 0..) |record, index| {
        if (record.number == number) return index;
    }
    return null;
}

pub fn recordByNumber(state: *const SidebarState, number: u32) ?*const PrRecord {
    const index = recordIndex(state, number) orelse return null;
    return &state.records.?.items[index];
}

pub fn stackPlace(state: *const SidebarState, index: usize) StackPlace {
    const analysis = state.analysis orelse return .{};
    var place: StackPlace = .{ .parent = analysis.parent_of[index] };
    if (!analysis.isStacked(index)) return place;
    const stack_id = analysis.stack_of[index];
    const height = analysis.heights[stack_id];
    for (analysis.stack_of, analysis.depth_of, 0..) |member_stack, depth, member| {
        if (member_stack != stack_id) continue;
        if (depth == 0 and place.bottom == null) place.bottom = member;
        if (depth == height - 1 and place.tip == null) place.tip = member;
    }
    return place;
}

/// Put the cursor on PR `number`, expanding its stack (`skim pr <n>`).
/// False when the PR is not in the filtered view.
pub fn selectNumber(state: *SidebarState, allocator: Allocator, number: u32) !bool {
    const records = state.records orelse return false;
    for (state.stacks.views, 0..) |sv, stack_index| {
        for (sv.members) |member| {
            if (records.items[member].number != number) continue;
            if (sv.members.len > 1) {
                try state.expanded.put(allocator, tipNumber(state, stack_index), {});
                try layoutRows(state, allocator);
            }
            state.cursor = memberRowOf(state, .{ .stack = stack_index, .record = member }) orelse return false;
            syncSelected(state);
            return true;
        }
    }
    return false;
}

/// Every PR in the filtered view in display order, members of collapsed
/// stacks included. Caller owns the slice.
pub fn visibleNumbers(state: *const SidebarState, allocator: Allocator) ![]u32 {
    const records = state.records orelse return allocator.alloc(u32, 0);
    var numbers: std.ArrayList(u32) = .empty;
    errdefer numbers.deinit(allocator);
    for (state.stacks.views) |sv| {
        for (sv.members) |member| try numbers.append(allocator, records.items[member].number);
    }
    return numbers.toOwnedSlice(allocator);
}

/// True once per change of the selected PR.
pub fn takeCursorChanged(state: *SidebarState) bool {
    const changed = state.cursor_changed;
    state.cursor_changed = false;
    return changed;
}

/// Keep the cursor inside a list `visible_rows` tall.
pub fn clampScroll(state: *SidebarState, visible_rows: usize) void {
    if (visible_rows == 0) return;
    const len = state.rows.items.len;
    if (state.cursor < state.scroll) state.scroll = state.cursor;
    if (state.cursor >= state.scroll + visible_rows) state.scroll = state.cursor + 1 - visible_rows;
    state.scroll = @min(state.scroll, len -| visible_rows);
}

pub fn setMessage(state: *SidebarState, text: []const u8) void {
    const kept = utf8Prefix(text, state.message.len);
    @memcpy(state.message[0..kept.len], kept);
    state.message_len = kept.len;
}

/// Install the configured presets (the built-in `all` when none) and apply
/// the default one.
pub fn setPresets(state: *SidebarState, allocator: Allocator, filters: *const config.PrFilters) !void {
    const source = filters.effectivePresets();
    const presets = try allocator.alloc(state_mod.Preset, source.len);
    var copied: usize = 0;
    errdefer {
        for (presets[0..copied]) |preset| freePreset(allocator, preset);
        allocator.free(presets);
    }
    for (source, presets) |preset, *out| {
        const name = try allocator.dupe(u8, preset.name);
        errdefer allocator.free(name);
        out.* = .{ .name = name, .query = try allocator.dupe(u8, preset.query) };
        copied += 1;
    }
    freePresets(state, allocator);
    state.presets = presets;

    const index = filters.defaultIndex();
    if (try applyQuery(state, allocator, presets[index].query)) selectPreset(state, index);
}

/// Everything `render.draw` needs for one frame.
pub fn view(state: *const SidebarState, params: ViewParams) render.View {
    const first = @min(state.scroll, state.rows.items.len);
    const end = @min(state.rows.items.len, first +| params.visible_rows);
    const rows = buildRows(state, .{ .allocator = params.frame_allocator, .first = first, .end = end }) catch &.{};
    // An unavailable surface runs no sync; its empty state carries the reason.
    const sync = if (state.unavailable != .none)
        SyncLine{ .line = "", .tone = .err }
    else
        syncLine(.{ .sync = state.sync, .now_secs = params.now_secs, .frame_allocator = params.frame_allocator });
    return .{
        .rows = rows,
        .cursor = if (state.cursor >= first and state.cursor < end) state.cursor - first else null,
        .focused = params.focused,
        .header = .{
            .label = if (state.active_preset) |index| state.presets[index].name else "custom",
            .visible = visibleCount(state),
            .total = if (state.records) |records| records.items.len else 0,
            .query = state.queryText(),
        },
        .prompt = if (state.prompt) |*prompt| prompt.text() else null,
        .parse_error = if (state.parse_error) |*parse_error| parse_error.message() else null,
        .sync_line = sync.line,
        .sync_tone = sync.tone,
        .empty = emptyState(state, state.rows.items.len),
        .message = state.messageText(),
    };
}

pub fn deinitState(state: *SidebarState, allocator: Allocator) void {
    clearRows(state, allocator);
    state.rows.deinit(allocator);
    state.rows = .empty;
    releaseSnapshot(state, allocator);
    state.expanded.deinit(allocator);
    state.expanded = .{};
    state.cached.deinit(allocator);
    state.cached = .{};
    if (state.active_query) |*query| query.deinit(allocator);
    state.active_query = null;
    freePresets(state, allocator);
}

// =============================================================================
// Helpers
// =============================================================================

fn clearRows(state: *SidebarState, allocator: Allocator) void {
    state.stacks.deinit(allocator);
    state.stacks = .{ .views = &.{}, .member_storage = &.{} };
    state.rows.clearRetainingCapacity();
}

fn releaseSnapshot(state: *SidebarState, allocator: Allocator) void {
    if (state.analysis) |*analysis| analysis.deinit(allocator);
    state.analysis = null;
    if (state.records) |*records| records.deinit();
    state.records = null;
    state.viewer_login = "";
    state.viewer_teams = "";
}

fn freePreset(allocator: Allocator, preset: state_mod.Preset) void {
    allocator.free(preset.name);
    allocator.free(preset.query);
}

fn freePresets(state: *SidebarState, allocator: Allocator) void {
    for (state.presets) |preset| freePreset(allocator, preset);
    allocator.free(state.presets);
    state.presets = &.{};
    state.active_preset = null;
    state.base_preset = 0;
}

/// Rebuild `rows` from `stacks` and the expanded set, then re-find the cursor.
fn layoutRows(state: *SidebarState, allocator: Allocator) !void {
    var count: usize = 0;
    for (state.stacks.views, 0..) |sv, index| count += rowCountOf(state, .{ .stack = index, .members = sv.members.len });
    try state.rows.ensureTotalCapacity(allocator, count);
    state.rows.clearRetainingCapacity();
    for (state.stacks.views, 0..) |sv, index| {
        const stack_index: u32 = @intCast(index);
        if (sv.members.len == 1) {
            state.rows.appendAssumeCapacity(.{ .kind = .member, .stack = stack_index, .record = @intCast(sv.members[0]) });
            continue;
        }
        state.rows.appendAssumeCapacity(.{ .kind = .stack_header, .stack = stack_index, .record = @intCast(sv.target) });
        if (!state.expanded.contains(tipNumber(state, index))) continue;
        for (sv.members) |member| {
            state.rows.appendAssumeCapacity(.{ .kind = .member, .stack = stack_index, .record = @intCast(member) });
        }
    }
    refindCursor(state);
}

fn rowCountOf(state: *const SidebarState, params: struct { stack: usize, members: usize }) usize {
    if (params.members == 1) return 1;
    if (!state.expanded.contains(tipNumber(state, params.stack))) return 1;
    return 1 + params.members;
}

/// After `rows` changed: put the cursor back on the selected PR. Prefers the
/// same row kind, then any row of that PR, then the header of the collapsed
/// stack containing it; otherwise clamps the index.
fn refindCursor(state: *SidebarState) void {
    const rows = state.rows.items;
    if (rows.len == 0) {
        state.cursor = 0;
        state.scroll = 0;
        syncSelected(state);
        return;
    }
    if (state.selected_number) |number| {
        if (findRow(state, .{ .number = number, .header = state.cursor_on_header })) |index| return placeCursor(state, index);
        if (findRow(state, .{ .number = number, .header = !state.cursor_on_header })) |index| return placeCursor(state, index);
        if (collapsedHeaderOf(state, number)) |index| return placeCursor(state, index);
    }
    placeCursor(state, @min(state.cursor, rows.len - 1));
}

fn placeCursor(state: *SidebarState, index: usize) void {
    state.cursor = index;
    syncSelected(state);
}

/// Mirror the cursor row into `selected_number` / `cursor_on_header`.
fn syncSelected(state: *SidebarState) void {
    const row = cursorRow(state) orelse {
        if (state.selected_number != null) state.cursor_changed = true;
        state.selected_number = null;
        state.cursor_on_header = false;
        return;
    };
    const number = state.records.?.items[row.record].number;
    if (state.selected_number != number) state.cursor_changed = true;
    state.selected_number = number;
    state.cursor_on_header = row.kind == .stack_header;
}

fn cursorRow(state: *const SidebarState) ?Row {
    const rows = state.rows.items;
    if (rows.len == 0) return null;
    return rows[@min(state.cursor, rows.len - 1)];
}

fn findRow(state: *const SidebarState, params: struct { number: u32, header: bool }) ?usize {
    const items = state.records.?.items;
    for (state.rows.items, 0..) |row, index| {
        if ((row.kind == .stack_header) != params.header) continue;
        if (items[row.record].number == params.number) return index;
    }
    return null;
}

fn collapsedHeaderOf(state: *const SidebarState, number: u32) ?usize {
    const items = state.records.?.items;
    for (state.rows.items, 0..) |row, index| {
        if (row.kind != .stack_header) continue;
        for (state.stacks.views[row.stack].members) |member| {
            if (items[member].number == number) return index;
        }
    }
    return null;
}

fn memberRowOf(state: *const SidebarState, params: struct { stack: usize, record: usize }) ?usize {
    for (state.rows.items, 0..) |row, index| {
        if (row.kind == .member and row.stack == params.stack and row.record == params.record) return index;
    }
    return null;
}

/// A header or standalone row: what `Ctrl-n`/`Ctrl-p` stop on.
fn nextAnchor(state: *const SidebarState, params: struct { from: usize, forward: bool }) ?usize {
    const rows = state.rows.items;
    var index = params.from;
    while (true) {
        if (params.forward) {
            if (index + 1 >= rows.len) return null;
            index += 1;
        } else {
            if (index == 0) return null;
            index -= 1;
        }
        const row = rows[index];
        if (row.kind == .stack_header or state.stacks.views[row.stack].members.len == 1) return index;
    }
}

fn tipNumber(state: *const SidebarState, stack_index: usize) u32 {
    return state.records.?.items[state.stacks.views[stack_index].members[0]].number;
}

fn clampIndex(value: isize, len: usize) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), len - 1);
}

fn selectPreset(state: *SidebarState, index: usize) void {
    state.active_preset = index;
    state.base_preset = index;
}

fn presetIndexOf(state: *const SidebarState, text: []const u8) ?usize {
    const wanted = std.mem.trim(u8, text, " \t");
    for (state.presets, 0..) |preset, index| {
        if (std.mem.eql(u8, std.mem.trim(u8, preset.query, " \t"), wanted)) return index;
    }
    return null;
}

/// Longest prefix of `text` no longer than `max` bytes that ends on a UTF-8
/// boundary.
fn utf8Prefix(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn visibleCount(state: *const SidebarState) usize {
    var count: usize = 0;
    for (state.stacks.views) |sv| count += sv.members.len;
    return count;
}

/// Row views for `state.rows[first..end]`, the rows on screen.
fn buildRows(state: *const SidebarState, range: struct { allocator: Allocator, first: usize, end: usize }) ![]const render.RowView {
    const records = state.records orelse return &.{};
    const ctx = filter_query.EvalContext{ .viewer_login = state.viewer_login, .viewer_teams = state.viewer_teams };
    const out = try range.allocator.alloc(render.RowView, range.end - range.first);
    for (state.rows.items[range.first..range.end], out) |row, *item| {
        const record = &records.items[row.record];
        const sv = state.stacks.views[row.stack];
        const stacked = sv.members.len > 1;
        item.* = .{
            .kind = row.kind,
            .number = record.number,
            .title = record.title,
            .author = record.author,
            .connector = if (row.kind == .member and stacked) state.analysis.?.markOf(row.record) else .none,
            .stack_size = if (row.kind == .stack_header) @intCast(sv.members.len) else 0,
            .expanded = row.kind == .stack_header and state.expanded.contains(tipNumber(state, row.stack)),
            .is_draft = record.is_draft,
            .ci = record.ci,
            .review = reviewGlyphOf(record, ctx),
            .changed_since_seen = changedSinceSeen(record),
            .cache = if (state.cached.contains(record.number)) .cached else .unknown,
        };
    }
    return out;
}

fn reviewGlyphOf(record: *const PrRecord, ctx: filter_query.EvalContext) render.ReviewGlyph {
    if (filter_query.isMineApproved(record)) return .approved_by_me;
    if (filter_query.isRequestedMe(record, ctx) or filter_query.isRequestedTeam(record, ctx)) return .requested_me;
    if (std.mem.eql(u8, record.review_decision, "APPROVED")) return .approved;
    if (std.mem.eql(u8, record.review_decision, "CHANGES_REQUESTED")) return .changes_requested;
    return .none;
}

fn changedSinceSeen(record: *const PrRecord) bool {
    const seen = record.seen_head_oid orelse return false;
    return !std.mem.eql(u8, seen, record.head_oid);
}

fn emptyState(state: *const SidebarState, row_count: usize) ?render.EmptyState {
    if (state.unavailable != .none) return .{ .unavailable = unavailableMessage(state.unavailable) };
    if (row_count > 0) return null;
    const total = if (state.records) |records| records.items.len else 0;
    if (total > 0) return .{ .no_match = if (state.active_preset) |index| state.presets[index].name else state.queryText() };
    if (state.sync.last_ok_at != null) return .no_prs;
    // Never synced: the list is empty because nothing has been fetched yet,
    // not because the repo has no open PRs.
    if (state.sync.running or state.sync.last_error == null) return .syncing;
    return .{ .sync_failed = if (state.sync.last_error_message.len > 0) state.sync.last_error_message else "Sync failed" };
}

fn unavailableMessage(unavailable: state_mod.Unavailable) []const u8 {
    return switch (unavailable) {
        .none => "",
        .not_github => "Not a GitHub repository (no github.com origin)",
        .gh_missing => "gh not installed — https://cli.github.com",
        .gh_unauthenticated => "gh not authenticated — run `gh auth login`",
        .db_error => "PR database unavailable — see ~/.skim/tui.log",
    };
}

const SyncLine = struct {
    line: []const u8,
    tone: render.SyncTone,
};

fn syncLine(params: struct { sync: SyncSnapshot, now_secs: i64, frame_allocator: Allocator }) SyncLine {
    const sync = params.sync;
    // A retry in flight is the current state; the error it may clear is not.
    if (sync.running) return .{ .line = "⟳ syncing…", .tone = .busy };
    if (sync.last_error) |kind| switch (kind) {
        .not_authenticated => return .{ .line = ghLine(sync.last_error_message, "gh: not authenticated"), .tone = .err },
        .not_installed => return .{ .line = ghLine(sync.last_error_message, "gh: not installed"), .tone = .err },
        else => {
            const last_ok = sync.last_ok_at orelse return .{ .line = offlineLine(params.frame_allocator, sync.last_error_message), .tone = .stale };
            return .{ .line = ageLine(params.frame_allocator, "offline · {s} old", params.now_secs - last_ok), .tone = .stale };
        },
    };
    const last_ok = sync.last_ok_at orelse return .{ .line = "⟳ syncing…", .tone = .busy };
    const age = params.now_secs - last_ok;
    if (age >= stale_after_secs) return .{ .line = ageLine(params.frame_allocator, "offline · {s} old", age), .tone = .stale };
    return .{ .line = ageLine(params.frame_allocator, "⟳ {s} ago", age), .tone = .ok };
}

/// `github.kindMessage` text when it already reads "gh: …", else `fallback`.
fn ghLine(message: []const u8, fallback: []const u8) []const u8 {
    if (std.mem.startsWith(u8, message, "gh:")) return message;
    return fallback;
}

/// "offline · <classified error>" for a repo that has never synced.
fn offlineLine(allocator: Allocator, message: []const u8) []const u8 {
    if (message.len == 0) return "offline · never synced";
    return std.fmt.allocPrint(allocator, "offline · {s}", .{message}) catch "offline";
}

fn ageLine(allocator: Allocator, comptime fmt: []const u8, age_secs: i64) []const u8 {
    var buf: [16]u8 = undefined;
    const age = formatAge(&buf, age_secs);
    return std.fmt.allocPrint(allocator, fmt, .{age}) catch "";
}

fn formatAge(buf: []u8, age_secs: i64) []const u8 {
    const secs: u64 = @intCast(@max(age_secs, 0));
    const result = if (secs < 60)
        std.fmt.bufPrint(buf, "{d}s", .{secs})
    else if (secs < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{secs / 60})
    else if (secs < 86400)
        std.fmt.bufPrint(buf, "{d}h", .{secs / 3600})
    else
        std.fmt.bufPrint(buf, "{d}d", .{secs / 86400});
    return result catch "?";
}
