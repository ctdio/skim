//! PR flip state (pure, web-safe): the debounce that turns sidebar cursor
//! moves into previews, the dwell that marks a previewed PR seen, the
//! rewritten-history file comparison, and per-PR diff cursor memory. Imports
//! no Store (D4): `FlipState` lives on `App.State`, which the wasm build
//! compiles.

const std = @import("std");
const parser = @import("../git/parser.zig");
const line_map = @import("../line_map.zig");
const types = @import("db/types.zig");
const priority = @import("prefetch/priority.zig");
const notes = @import("notes.zig");
const review_controller = @import("review_controller.zig");
const ParsedLru = @import("prefetch/parsed_lru.zig").ParsedLru;

const Allocator = std.mem.Allocator;

pub const DiffView = priority.View;
pub const OrphanNote = notes.OrphanNote;

/// What a PR diff source compares: `origin/<branch>...<head>`, or
/// `<commit> <head>` for the since-seen view. The head is the oid the
/// diff was cached or listed at, never `refs/skim/pr-<n>`: that ref can
/// lag a head that is already local, and `r` must re-diff what is shown.
pub const PrDiffRefs = struct {
    base: union(enum) { branch: []const u8, commit: []const u8 },
    head_oid: []const u8,
};

pub const CursorMemory = struct {
    /// Owned.
    file_path: []u8,
    line_type: parser.Line.LineType,
    /// new_lineno for add/context, old_lineno for delete; null = file header.
    lineno: ?u32,
    /// cursor_line - scroll_offset, so the viewport position survives too.
    rows_from_top: usize,
};

pub const FlipAction = union(enum) {
    preview: u32,
    mark_seen: u32,
};

pub const FlipState = struct {
    pending: ?struct { number: u32, due_ms: i64 } = null,
    /// PR whose diff `App.state.files` currently holds.
    previewed: ?u32 = null,
    previewed_view: DiffView = .pr,
    /// Key of `App.state.files` when it came from the cache; null = it did not,
    /// so the next swap frees it instead of parking it in `lru`.
    displayed_key: ?types.DiffKey = null,
    /// Miss-path load in flight for this PR.
    loading_number: ?u32 = null,
    /// The miss-path load was an explicit open (Enter, `skim pr <n>`), so the
    /// diff takes focus when it installs; a preview leaves it on the sidebar.
    focus_diff: bool = false,
    /// File indices folded by the "changed files only" toggle. Owned.
    collapsed_by_changed: []usize = &.{},
    preview_started_ms: i64 = 0,
    /// Seen already written for this preview (or the PR was seen at its head).
    dwell_done: bool = false,
    /// Requested view for the next preview (`S` / `c` toggle it).
    view: DiffView = .pr,
    cursor_memory: std.AutoHashMapUnmanaged(u32, CursorMemory) = .{},
    /// Parsed sets the App is not displaying. Initialised on surface open
    /// with the App allocator, the one every FileDiff is allocated with.
    lru: ?ParsedLru = null,
    /// FR-8 header marks: len == App.state.files.len when non-empty. Owned.
    changed_files: []bool = &.{},
    /// FR-9 notes of the previewed PR that anchor nowhere in its diff.
    orphan_notes: std.ArrayList(OrphanNote) = .empty,
    /// Comment.id → local_note.id for the previewed PR's restored notes.
    note_ids: std.AutoHashMapUnmanaged(u64, i64) = .{},
    notes_saved_revision: u64 = 0,
};

pub const RememberParams = struct {
    allocator: Allocator,
    number: u32,
    files: []const parser.FileDiff,
    line_map: *const line_map.LineMap,
    cursor_line: usize,
    scroll_offset: usize,
};

pub const RecallParams = struct {
    number: u32,
    files: []const parser.FileDiff,
    line_map: *const line_map.LineMap,
};

pub const RecalledCursor = struct { cursor_line: usize, scroll_offset: usize };

/// `App.state.collapsed_folds`: fold keys of collapsed files and hunks.
pub const Folds = std.AutoHashMap(u64, void);

pub const debounce_ms: i64 = 40;
pub const dwell_ms: i64 = 3000;

/// Debounce: every cursor move re-arms the deadline, so holding `j` previews
/// nothing until the key rests for `debounce_ms`. Moving back onto the PR
/// already on screen (or already loading) cancels the pending preview. While
/// a miss load for another PR is in flight, moving back onto the previewed PR
/// is a real preview: it must supersede that load.
pub fn onCursorMoved(state: *FlipState, params: struct { number: ?u32, now_ms: i64 }) void {
    const number = params.number orelse {
        state.pending = null;
        return;
    };
    const current = state.loading_number orelse state.previewed;
    if (current == number) {
        state.pending = null;
        return;
    }
    state.pending = .{ .number = number, .due_ms = params.now_ms + debounce_ms };
}

/// Clock step. At most one action per tick; a due preview wins over dwell.
pub fn tick(state: *FlipState, now_ms: i64) ?FlipAction {
    if (state.pending) |pending| {
        if (now_ms < pending.due_ms) return null;
        state.pending = null;
        return .{ .preview = pending.number };
    }
    const number = state.previewed orelse return null;
    if (state.dwell_done or state.loading_number != null) return null;
    if (now_ms - state.preview_started_ms < dwell_ms) return null;
    state.dwell_done = true;
    return .{ .mark_seen = number };
}

/// Record that `number` is now on screen; restarts the dwell clock.
pub fn notePreviewed(state: *FlipState, params: struct {
    number: u32,
    view: DiffView,
    key: ?types.DiffKey,
    now_ms: i64,
    already_seen: bool,
}) void {
    state.previewed = params.number;
    state.previewed_view = params.view;
    state.displayed_key = params.key;
    state.loading_number = null;
    state.preview_started_ms = params.now_ms;
    state.dwell_done = params.already_seen;
}

/// FR-8 rewritten-history comparison. Two files are the same when their
/// ordered add/delete lines (type + content) match; context lines and hunk
/// numbers are ignored, so a rebase that only shifts line numbers or context
/// does not flag the file. Files are matched by new_path, else old_path. A
/// file absent from `seen` is changed. Caller owns the slice.
pub fn changedFiles(allocator: Allocator, pair: struct { seen: []const parser.FileDiff, current: []const parser.FileDiff }) ![]bool {
    const changed = try allocator.alloc(bool, pair.current.len);
    for (pair.current, changed) |*file, *flag| {
        const seen = matchingFile(pair.seen, file) orelse {
            flag.* = true;
            continue;
        };
        flag.* = !sameEdits(seen, file);
    }
    return changed;
}

/// Snapshot the diff cursor (file path + line number) for `number`.
pub fn rememberCursor(state: *FlipState, params: RememberParams) !void {
    const record = params.line_map.getLineRecord(params.cursor_line) orelse return;
    // On the description block the reader is at the top of the PR, which is
    // where an unremembered PR opens: forget any older position.
    if (record.line_type == .pr_description) {
        if (state.cursor_memory.fetchRemove(params.number)) |kv| params.allocator.free(kv.value.file_path);
        return;
    }
    if (record.file_idx >= params.files.len) return;
    const file = &params.files[record.file_idx];
    var memory: CursorMemory = .{
        .file_path = undefined,
        .line_type = .context,
        .lineno = null,
        .rows_from_top = params.cursor_line -| params.scroll_offset,
    };
    switch (record.line_type) {
        .code_line => |code| {
            const line = file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk];
            memory.line_type = line.line_type;
            memory.lineno = if (line.line_type == .delete) line.old_lineno else line.new_lineno;
        },
        else => {},
    }
    memory.file_path = try params.allocator.dupe(u8, filePath(file));
    errdefer params.allocator.free(memory.file_path);
    const entry = try state.cursor_memory.getOrPut(params.allocator, params.number);
    if (entry.found_existing) params.allocator.free(entry.value_ptr.file_path);
    entry.value_ptr.* = memory;
}

/// Map a remembered position into a diff: same path + same lineno on the same
/// side, else that file's header line, else null (the caller keeps line 0).
pub fn recallCursor(state: *const FlipState, params: RecallParams) ?RecalledCursor {
    const memory = state.cursor_memory.get(params.number) orelse return null;
    const file_idx = fileIndex(params.files, memory.file_path) orelse return null;
    const header = params.line_map.getFileHeaderLine(file_idx) orelse return null;
    const cursor_line = if (memory.lineno) |lineno|
        findLine(.{ .files = params.files, .line_map = params.line_map, .file_idx = file_idx, .header = header, .line_type = memory.line_type, .lineno = lineno }) orelse header
    else
        header;
    return .{ .cursor_line = cursor_line, .scroll_offset = cursor_line -| memory.rows_from_top };
}

/// Fold keys the "changed files only" toggle collapses: every file not marked
/// changed. Caller owns.
pub fn unchangedFiles(allocator: Allocator, changed: []const bool) ![]usize {
    var unchanged: std.ArrayList(usize) = .empty;
    errdefer unchanged.deinit(allocator);
    for (changed, 0..) |flag, i| {
        if (!flag) try unchanged.append(allocator, i);
    }
    return unchanged.toOwnedSlice(allocator);
}

/// Drop the per-diff derived state that indexes into `App.state.files`,
/// unfolding what the changed-only toggle folded in `folds`.
pub fn clearDiffState(state: *FlipState, allocator: Allocator, folds: *Folds) void {
    allocator.free(state.changed_files);
    state.changed_files = &.{};
    releaseChangedOnlyFolds(state, allocator, folds);
}

/// Unfold the files the changed-only toggle folded, and forget them.
pub fn releaseChangedOnlyFolds(state: *FlipState, allocator: Allocator, folds: *Folds) void {
    for (state.collapsed_by_changed) |file_idx| _ = folds.remove(line_map.LineMap.FoldKey.fileKey(file_idx));
    allocator.free(state.collapsed_by_changed);
    state.collapsed_by_changed = &.{};
}

pub fn deinitState(state: *FlipState, allocator: Allocator) void {
    var it = state.cursor_memory.valueIterator();
    while (it.next()) |memory| allocator.free(memory.file_path);
    state.cursor_memory.deinit(allocator);
    if (state.lru) |*lru| lru.deinit();
    allocator.free(state.changed_files);
    allocator.free(state.collapsed_by_changed);
    notes.clearOrphans(allocator, &state.orphan_notes);
    state.orphan_notes.deinit(allocator);
    state.note_ids.deinit(allocator);
    state.* = .{};
}

/// Entry parameters for a sidebar record. The strings borrow from the
/// record; `startEnterPr` copies them.
pub fn enterParamsFor(record: *const types.PrRecord) review_controller.EnterParams {
    return .{ .number = record.number, .base_ref = record.base_ref, .title = record.title, .url = record.url };
}

/// The diff source refs for showing `record` in `view`.
/// `head_oid` is the diffed head: the stack tip's for the whole-stack view,
/// else the PR's.
pub fn prDiffRefs(params: struct { record: *const types.PrRecord, view: DiffView, stack_base_ref: []const u8, head_oid: []const u8 }) PrDiffRefs {
    return switch (params.view) {
        .pr, .whole_stack => .{ .base = .{ .branch = params.stack_base_ref }, .head_oid = params.head_oid },
        .since_seen => .{ .base = .{ .commit = params.record.seen_head_oid orelse "" }, .head_oid = params.head_oid },
    };
}

/// Seen at its current head already: no dwell needed.
pub fn seenAtHead(record: *const types.PrRecord) bool {
    const seen = record.seen_head_oid orelse return false;
    return std.mem.eql(u8, seen, record.head_oid);
}

/// The path a diff file is known by: new_path, or old_path for a deletion.
fn filePath(file: *const parser.FileDiff) []const u8 {
    return if (file.new_path.len > 0) file.new_path else file.old_path;
}

fn fileIndex(files: []const parser.FileDiff, path: []const u8) ?usize {
    for (files, 0..) |*file, i| {
        if (std.mem.eql(u8, filePath(file), path)) return i;
    }
    return null;
}

fn matchingFile(files: []const parser.FileDiff, wanted: *const parser.FileDiff) ?*const parser.FileDiff {
    if (wanted.new_path.len > 0) {
        for (files) |*file| {
            if (std.mem.eql(u8, file.new_path, wanted.new_path)) return file;
        }
    }
    if (wanted.old_path.len > 0) {
        for (files) |*file| {
            if (std.mem.eql(u8, file.old_path, wanted.old_path)) return file;
        }
    }
    return null;
}

fn sameEdits(a: *const parser.FileDiff, b: *const parser.FileDiff) bool {
    var left = EditIterator{ .file = a };
    var right = EditIterator{ .file = b };
    while (true) {
        const l = left.next();
        const r = right.next();
        if (l == null or r == null) return l == null and r == null;
        if (l.?.line_type != r.?.line_type or !std.mem.eql(u8, l.?.content, r.?.content)) return false;
    }
}

/// The add/delete lines of a file in diff order.
const EditIterator = struct {
    file: *const parser.FileDiff,
    hunk: usize = 0,
    line: usize = 0,

    fn next(self: *EditIterator) ?*const parser.Line {
        while (self.hunk < self.file.hunks.len) {
            const lines = self.file.hunks[self.hunk].lines;
            while (self.line < lines.len) {
                const line = &lines[self.line];
                self.line += 1;
                if (line.line_type != .context) return line;
            }
            self.hunk += 1;
            self.line = 0;
        }
        return null;
    }
};

fn findLine(params: struct {
    files: []const parser.FileDiff,
    line_map: *const line_map.LineMap,
    file_idx: usize,
    header: usize,
    line_type: parser.Line.LineType,
    lineno: u32,
}) ?usize {
    const file = &params.files[params.file_idx];
    for (params.line_map.records[params.header..]) |record| {
        if (record.file_idx != params.file_idx) break;
        const code = switch (record.line_type) {
            .code_line => |code| code,
            else => continue,
        };
        const line = file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk];
        const matches = if (params.line_type == .delete)
            line.line_type == .delete and line.old_lineno == params.lineno
        else
            line.line_type != .delete and line.new_lineno == params.lineno;
        if (matches) return record.global_line;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const comments = @import("../comments/store.zig");

const two_files =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,3 +1,4 @@
    \\ one
    \\+two
    \\ three
    \\-four
    \\diff --git a/b.txt b/b.txt
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -10,2 +10,3 @@
    \\ ten
    \\+eleven
    \\ twelve
    \\
;

/// `two_files` rebased: different hunk numbers and context, same edits.
const two_files_shifted =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -40,3 +40,4 @@
    \\ uno
    \\+two
    \\ tres
    \\-four
    \\diff --git a/b.txt b/b.txt
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -90,2 +90,3 @@
    \\ diez
    \\+eleven
    \\ doce
    \\
;

const b_edit_changed =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,3 +1,4 @@
    \\ one
    \\+two
    \\ three
    \\-four
    \\diff --git a/b.txt b/b.txt
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -10,2 +10,3 @@
    \\ ten
    \\+ELEVEN
    \\ twelve
    \\
;

const renamed_and_new =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,3 +1,4 @@
    \\ one
    \\+two
    \\ three
    \\-four
    \\diff --git a/b.txt b/c.txt
    \\--- a/b.txt
    \\+++ b/c.txt
    \\@@ -10,2 +10,3 @@
    \\ ten
    \\+eleven
    \\ twelve
    \\diff --git a/d.txt b/d.txt
    \\--- a/d.txt
    \\+++ b/d.txt
    \\@@ -1,1 +1,2 @@
    \\ d
    \\+new
    \\
;

const Fixture = struct {
    files: []parser.FileDiff,
    comment_store: comments.CommentStore,
    map: line_map.LineMap,

    fn init(diff: []const u8) !Fixture {
        const files = try parser.parse(testing.allocator, diff);
        errdefer freeFiles(files);
        var comment_store = comments.CommentStore.init(testing.allocator);
        errdefer comment_store.deinit();
        const map = try line_map.LineMap.build(testing.allocator, .{ .files = files, .comment_store = &comment_store, .hunk_view_mode = .all, .apply_filtering = false });
        return .{ .files = files, .comment_store = comment_store, .map = map };
    }

    fn deinit(self: *Fixture) void {
        self.map.deinit();
        self.comment_store.deinit();
        freeFiles(self.files);
    }

    /// Global line of the code line in `file_idx` with this type and lineno.
    fn lineOf(self: *const Fixture, params: struct { file_idx: usize, line_type: parser.Line.LineType, lineno: u32 }) usize {
        const header = self.map.getFileHeaderLine(params.file_idx).?;
        return findLine(.{ .files = self.files, .line_map = &self.map, .file_idx = params.file_idx, .header = header, .line_type = params.line_type, .lineno = params.lineno }).?;
    }
};

fn freeFiles(files: []parser.FileDiff) void {
    for (files) |*file| file.deinit(testing.allocator);
    testing.allocator.free(files);
}

fn parseFiles(diff: []const u8) ![]parser.FileDiff {
    return parser.parse(testing.allocator, diff);
}

fn expectChanged(params: struct { seen: []const u8, current: []const u8, expected: []const bool }) !void {
    const seen = try parseFiles(params.seen);
    defer freeFiles(seen);
    const current = try parseFiles(params.current);
    defer freeFiles(current);
    const changed = try changedFiles(testing.allocator, .{ .seen = seen, .current = current });
    defer testing.allocator.free(changed);
    try testing.expectEqualSlices(bool, params.expected, changed);
}

test "onCursorMoved + tick: no preview before the debounce deadline" {
    var state: FlipState = .{};
    onCursorMoved(&state, .{ .number = 7, .now_ms = 1000 });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1000));
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1039));
}

test "tick: previews at the deadline exactly once" {
    var state: FlipState = .{};
    onCursorMoved(&state, .{ .number = 7, .now_ms = 1000 });
    try testing.expectEqual(@as(?FlipAction, .{ .preview = 7 }), tick(&state, 1040));
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1041));
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 2000));
}

test "onCursorMoved: each move re-arms the deadline (holding j previews nothing until rest)" {
    var state: FlipState = .{};
    var now: i64 = 1000;
    for (1..10) |n| {
        onCursorMoved(&state, .{ .number = @intCast(n), .now_ms = now });
        now += 30;
        try testing.expectEqual(@as(?FlipAction, null), tick(&state, now));
    }
    try testing.expectEqual(@as(?FlipAction, .{ .preview = 9 }), tick(&state, now + 10));
}

test "onCursorMoved: moving back onto the previewed PR cancels the pending preview" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 0, .already_seen = true });
    onCursorMoved(&state, .{ .number = 4, .now_ms = 1000 });
    onCursorMoved(&state, .{ .number = 3, .now_ms = 1010 });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 2000));
}

test "onCursorMoved: moving back onto the previewed PR while another loads is a real preview" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 0, .already_seen = true });
    state.loading_number = 4;
    onCursorMoved(&state, .{ .number = 3, .now_ms = 1000 });
    try testing.expectEqual(@as(?FlipAction, .{ .preview = 3 }), tick(&state, 1040));
}

test "onCursorMoved: moving onto the PR already loading cancels the pending preview" {
    var state: FlipState = .{};
    state.loading_number = 4;
    onCursorMoved(&state, .{ .number = 5, .now_ms = 1000 });
    onCursorMoved(&state, .{ .number = 4, .now_ms = 1010 });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 2000));
}

test "onCursorMoved: null selection (empty list) clears pending" {
    var state: FlipState = .{};
    onCursorMoved(&state, .{ .number = 7, .now_ms = 1000 });
    onCursorMoved(&state, .{ .number = null, .now_ms = 1010 });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 2000));
}

test "tick: mark_seen after dwell_ms of continuous preview, once" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 1000, .already_seen = false });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1000 + dwell_ms - 1));
    try testing.expectEqual(@as(?FlipAction, .{ .mark_seen = 3 }), tick(&state, 1000 + dwell_ms));
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1000 + 2 * dwell_ms));
}

test "tick: no mark_seen when the PR was already seen at its head" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 1000, .already_seen = true });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1000 + 10 * dwell_ms));
}

test "tick: no mark_seen while a miss load is in flight" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 1000, .already_seen = false });
    state.loading_number = 4;
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1000 + dwell_ms));
}

test "tick: a new preview resets the dwell clock" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 1000, .already_seen = false });
    notePreviewed(&state, .{ .number = 4, .view = .pr, .key = null, .now_ms = 3000, .already_seen = false });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, 1000 + dwell_ms));
    try testing.expectEqual(@as(?FlipAction, .{ .mark_seen = 4 }), tick(&state, 3000 + dwell_ms));
}

test "tick: preview wins over dwell in the same tick" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 0, .already_seen = false });
    onCursorMoved(&state, .{ .number = 4, .now_ms = dwell_ms - debounce_ms });
    try testing.expectEqual(@as(?FlipAction, .{ .preview = 4 }), tick(&state, dwell_ms));
}

test "tick: a pending move away holds the dwell back" {
    var state: FlipState = .{};
    notePreviewed(&state, .{ .number = 3, .view = .pr, .key = null, .now_ms = 0, .already_seen = false });
    onCursorMoved(&state, .{ .number = 4, .now_ms = dwell_ms - 1 });
    try testing.expectEqual(@as(?FlipAction, null), tick(&state, dwell_ms));
}

test "notePreviewed clears the miss load it completes" {
    var state: FlipState = .{};
    state.loading_number = 3;
    notePreviewed(&state, .{ .number = 3, .view = .since_seen, .key = null, .now_ms = 0, .already_seen = false });
    try testing.expectEqual(@as(?u32, null), state.loading_number);
    try testing.expectEqual(DiffView.since_seen, state.previewed_view);
}

test "changedFiles: identical +/- lines → all false" {
    try expectChanged(.{ .seen = two_files, .current = two_files, .expected = &.{ false, false } });
}

test "changedFiles: same +/- lines, shifted hunk numbers and different context → false" {
    try expectChanged(.{ .seen = two_files, .current = two_files_shifted, .expected = &.{ false, false } });
}

test "changedFiles: one file's added line differs → only that file true" {
    try expectChanged(.{ .seen = two_files, .current = b_edit_changed, .expected = &.{ false, true } });
}

test "changedFiles: file only in current → true; matched by new_path, falls back to old_path" {
    try expectChanged(.{ .seen = two_files, .current = renamed_and_new, .expected = &.{ false, false, true } });
}

test "changedFiles: a file that lost an edit is changed" {
    const one_edit =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,3 @@
        \\ one
        \\+two
        \\ three
        \\
    ;
    try expectChanged(.{ .seen = two_files, .current = one_edit, .expected = &.{true} });
}

test "rememberCursor/recallCursor: same path + new_lineno restores the global line" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    const line = fx.lineOf(.{ .file_idx = 1, .line_type = .add, .lineno = 11 });
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = line, .scroll_offset = line });

    var same = try Fixture.init(two_files);
    defer same.deinit();
    const recalled = recallCursor(&state, .{ .number = 5, .files = same.files, .line_map = &same.map }).?;
    try testing.expectEqual(line, recalled.cursor_line);
    try testing.expectEqual(line, recalled.scroll_offset);
    try testing.expectEqual(@as(?RecalledCursor, null), recallCursor(&state, .{ .number = 6, .files = same.files, .line_map = &same.map }));
}

test "recallCursor: deleted line matches on old_lineno" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    const deleted = fx.lineOf(.{ .file_idx = 0, .line_type = .delete, .lineno = 3 });
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = deleted, .scroll_offset = 0 });
    try testing.expectEqual(parser.Line.LineType.delete, state.cursor_memory.get(5).?.line_type);
    // new_lineno 3 is the context line "three": a delete must not land there.
    try testing.expect(fx.lineOf(.{ .file_idx = 0, .line_type = .context, .lineno = 3 }) != deleted);
    try testing.expectEqual(deleted, recallCursor(&state, .{ .number = 5, .files = fx.files, .line_map = &fx.map }).?.cursor_line);
}

test "recallCursor: line gone → that file's header line" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    const line = fx.lineOf(.{ .file_idx = 1, .line_type = .add, .lineno = 11 });
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = line, .scroll_offset = line });

    var shifted = try Fixture.init(two_files_shifted);
    defer shifted.deinit();
    const recalled = recallCursor(&state, .{ .number = 5, .files = shifted.files, .line_map = &shifted.map }).?;
    try testing.expectEqual(shifted.map.getFileHeaderLine(1).?, recalled.cursor_line);
}

test "recallCursor: file gone → null" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    const line = fx.lineOf(.{ .file_idx = 1, .line_type = .add, .lineno = 11 });
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = line, .scroll_offset = 0 });

    const only_a =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,3 @@
        \\ one
        \\+two
        \\ three
        \\
    ;
    var other = try Fixture.init(only_a);
    defer other.deinit();
    try testing.expectEqual(@as(?RecalledCursor, null), recallCursor(&state, .{ .number = 5, .files = other.files, .line_map = &other.map }));
}

test "recallCursor: restores rows_from_top as scroll offset, clamped at 0" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    const line = fx.lineOf(.{ .file_idx = 1, .line_type = .add, .lineno = 11 });
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = line, .scroll_offset = line - 2 });
    try testing.expectEqual(line - 2, recallCursor(&state, .{ .number = 5, .files = fx.files, .line_map = &fx.map }).?.scroll_offset);

    // Falling back to a header above the remembered row count clamps at 0.
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 6, .files = fx.files, .line_map = &fx.map, .cursor_line = line, .scroll_offset = 0 });
    var gone_line = try Fixture.init(two_files_shifted);
    defer gone_line.deinit();
    const recalled = recallCursor(&state, .{ .number = 6, .files = gone_line.files, .line_map = &gone_line.map }).?;
    try testing.expectEqual(gone_line.map.getFileHeaderLine(1).?, recalled.cursor_line);
    try testing.expect(recalled.cursor_line < line);
    try testing.expectEqual(@as(usize, 0), recalled.scroll_offset);
}

test "rememberCursor: a second remember for the same number frees the old path" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = fx.lineOf(.{ .file_idx = 0, .line_type = .add, .lineno = 2 }), .scroll_offset = 0 });
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = fx.lineOf(.{ .file_idx = 1, .line_type = .add, .lineno = 11 }), .scroll_offset = 0 });
    try testing.expectEqualStrings("b.txt", state.cursor_memory.get(5).?.file_path);
}

test "rememberCursor: cursor on a file header remembers the header" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    const header = fx.map.getFileHeaderLine(1).?;
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = header, .scroll_offset = 0 });
    try testing.expectEqual(@as(?u32, null), state.cursor_memory.get(5).?.lineno);
    try testing.expectEqual(header, recallCursor(&state, .{ .number = 5, .files = fx.files, .line_map = &fx.map }).?.cursor_line);
}

test "rememberCursor: past the end of the line map remembers nothing" {
    var fx = try Fixture.init(two_files);
    defer fx.deinit();
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    try rememberCursor(&state, .{ .allocator = testing.allocator, .number = 5, .files = fx.files, .line_map = &fx.map, .cursor_line = 10_000, .scroll_offset = 0 });
    try testing.expectEqual(@as(u32, 0), state.cursor_memory.count());
}

test "unchangedFiles lists the indices not marked changed" {
    const unchanged = try unchangedFiles(testing.allocator, &.{ false, true, false });
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, unchanged);
}

test "clearDiffState unfolds exactly the files the changed-only toggle folded" {
    var state: FlipState = .{};
    defer deinitState(&state, testing.allocator);
    var folds = Folds.init(testing.allocator);
    defer folds.deinit();
    try folds.put(line_map.LineMap.FoldKey.fileKey(0), {});
    try folds.put(line_map.LineMap.FoldKey.fileKey(2), {});
    state.collapsed_by_changed = try testing.allocator.dupe(usize, &.{2});
    state.changed_files = try testing.allocator.dupe(bool, &.{ false, true, false });

    clearDiffState(&state, testing.allocator, &folds);

    try testing.expect(folds.contains(line_map.LineMap.FoldKey.fileKey(0)));
    try testing.expect(!folds.contains(line_map.LineMap.FoldKey.fileKey(2)));
    try testing.expectEqual(@as(usize, 0), state.collapsed_by_changed.len);
    try testing.expectEqual(@as(usize, 0), state.changed_files.len);
}

test "deinitState frees the LRU and every owned slice" {
    var state: FlipState = .{ .lru = ParsedLru.init(testing.allocator) };
    state.lru.?.put(.{ .merge_base_oid = @splat('1'), .head_oid = @splat('2') }, try parseFiles(two_files));
    state.changed_files = try testing.allocator.dupe(bool, &.{ true, false });
    state.collapsed_by_changed = try testing.allocator.dupe(usize, &.{1});
    try state.note_ids.put(testing.allocator, 1, 2);
    deinitState(&state, testing.allocator);
    try testing.expectEqual(@as(?ParsedLru, null), state.lru);
}
