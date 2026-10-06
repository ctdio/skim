//! Local PR notes (FR-9), pure side: where a persisted note lands in a diff,
//! how notes become CommentStore comments, and the reconcile plan that turns
//! the CommentStore back into `local_note` writes. Imports no Store (D4):
//! `pr/surface.zig` owns the Store calls (`restoreNotes` / `saveNotes`).

const std = @import("std");
const parser = @import("../git/parser.zig");
const comments = @import("../comments/store.zig");
const types = @import("db/types.zig");

const Allocator = std.mem.Allocator;

/// A persisted note that anchors nowhere in the current diff. It stays in the
/// DB untouched and appears only in the export. Strings owned.
pub const OrphanNote = struct {
    note_id: i64,
    file_path: []u8,
    line_content: []u8,
    text: []u8,

    pub fn deinit(self: *const OrphanNote, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.line_content);
        allocator.free(self.text);
    }
};

/// Where a note sits in a diff: indices into `files`.
pub const Anchor = struct {
    file_idx: usize,
    hunk_idx: usize,
    line_idx: usize,
    end_hunk_idx: ?usize = null,
    end_line_idx: ?usize = null,
};

pub const NoteAnchorInput = struct {
    file_path: []const u8,
    line_type: parser.Line.LineType,
    old_lineno: ?u32,
    new_lineno: ?u32,
    end_old_lineno: ?u32 = null,
    end_new_lineno: ?u32 = null,
    line_content: []const u8,
};

pub const RestoreParams = struct {
    allocator: Allocator,
    notes: []const types.NoteRow,
    files: []const parser.FileDiff,
    /// Already cleared by the PR switch.
    comments: *comments.CommentStore,
    /// Replaced: orphans of the PR being restored.
    orphans: *std.ArrayList(OrphanNote),
    /// Replaced: Comment.id → local_note.id.
    note_ids: *std.AutoHashMapUnmanaged(u64, i64),
};

pub const SaveParams = struct {
    allocator: Allocator,
    number: u32,
    comments: *const comments.CommentStore,
    /// The diff the comments are anchored in (for the range-end linenos).
    files: []const parser.FileDiff,
    note_ids: *const std.AutoHashMapUnmanaged(u64, i64),
    /// The PR's rows as stored now, so unchanged notes are not rewritten.
    saved: []const types.NoteRow,
    now: i64,
};

pub const NewNote = struct { comment_id: u64, row: types.NoteRow };

pub const NoteUpdate = struct { id: i64, text: []const u8, replies: []const u8 };

/// Text fields borrow from the CommentStore; `replies` JSON strings and the
/// slices are owned.
pub const SavePlan = struct {
    inserts: []NewNote = &.{},
    updates: []NoteUpdate = &.{},
    deletes: []i64 = &.{},

    pub fn deinit(self: *SavePlan, allocator: Allocator) void {
        for (self.inserts) |insert| allocator.free(insert.row.replies);
        for (self.updates) |update| allocator.free(update.replies);
        allocator.free(self.inserts);
        allocator.free(self.updates);
        allocator.free(self.deletes);
        self.* = .{};
    }

    pub fn isEmpty(self: *const SavePlan) bool {
        return self.inserts.len == 0 and self.updates.len == 0 and self.deletes.len == 0;
    }
};

const ReplyJson = struct { author: []const u8, text: []const u8 };

/// Map each persisted note back into `files` and add it to the CommentStore;
/// the ones that anchor nowhere become orphans.
pub fn restore(params: RestoreParams) !void {
    clearOrphans(params.allocator, params.orphans);
    params.note_ids.clearRetainingCapacity();
    for (params.notes) |*note| {
        const anchor = if (anchorInput(note)) |input| anchorFor(params.files, input) else null;
        if (anchor) |found| {
            try addComment(.{ .allocator = params.allocator, .note = note, .files = params.files, .anchor = found, .comments = params.comments, .note_ids = params.note_ids });
        } else {
            try appendOrphan(.{ .allocator = params.allocator, .orphans = params.orphans, .note = note });
        }
    }
}

/// Where a note lands in `files`. Anchor order: the same lineno on the same
/// side with the same content; else the first line in the same file whose
/// content equals `line_content`; else null (orphan). A lineno whose content
/// changed is not trusted: the note would sit on an unrelated line. A range
/// end that no longer exists degrades the note to a single line.
fn anchorFor(files: []const parser.FileDiff, note: NoteAnchorInput) ?Anchor {
    const file_idx = fileIndex(files, note.file_path) orelse return null;
    const file = &files[file_idx];
    const start = findByLineno(file, .{ .side = sideOf(note.line_type), .lineno = linenoOn(note, sideOf(note.line_type)), .content = note.line_content }) orelse
        findByContent(file, note.line_content) orelse return null;
    var anchor: Anchor = .{ .file_idx = file_idx, .hunk_idx = start.hunk_idx, .line_idx = start.line_idx };
    if (rangeEnd(.{ .file = file, .note = note, .start = start })) |end| {
        anchor.end_hunk_idx = end.hunk_idx;
        anchor.end_line_idx = end.line_idx;
    }
    return anchor;
}

/// Reconcile the PR's notes with the CommentStore: insert new comments, update
/// changed text/replies, delete rows whose comment was removed. Orphans are
/// never in `note_ids`, so they are never touched.
pub fn planSave(params: SaveParams) !SavePlan {
    const allocator = params.allocator;
    var inserts: std.ArrayList(NewNote) = .empty;
    var updates: std.ArrayList(NoteUpdate) = .empty;
    var deletes: std.ArrayList(i64) = .empty;
    var plan: SavePlan = .{};
    errdefer {
        plan.inserts = inserts.items;
        plan.updates = updates.items;
        plan.deletes = deletes.items;
        for (plan.inserts) |insert| allocator.free(insert.row.replies);
        for (plan.updates) |update| allocator.free(update.replies);
        inserts.deinit(allocator);
        updates.deinit(allocator);
        deletes.deinit(allocator);
    }

    for (params.comments.comments.items) |*comment| {
        const replies = try repliesJson(allocator, comment.replies.items);
        var owned = true;
        defer if (owned) allocator.free(replies);
        if (params.note_ids.get(comment.id)) |note_id| {
            if (savedRow(params.saved, note_id)) |row| {
                if (std.mem.eql(u8, row.text, comment.text) and std.mem.eql(u8, row.replies, replies)) continue;
                try updates.append(allocator, .{ .id = note_id, .text = comment.text, .replies = replies });
                owned = false;
                continue;
            }
        }
        try inserts.append(allocator, .{ .comment_id = comment.id, .row = noteRow(.{ .number = params.number, .comment = comment, .files = params.files, .replies = replies, .now = params.now }) });
        owned = false;
    }

    // Only this PR's rows: a stale entry must never delete another PR's note.
    var it = params.note_ids.iterator();
    while (it.next()) |entry| {
        if (params.comments.findById(entry.key_ptr.*) != null) continue;
        if (savedRow(params.saved, entry.value_ptr.*) != null) try deletes.append(allocator, entry.value_ptr.*);
    }

    plan.inserts = try inserts.toOwnedSlice(allocator);
    plan.updates = try updates.toOwnedSlice(allocator);
    plan.deletes = try deletes.toOwnedSlice(allocator);
    return plan;
}

pub fn clearOrphans(allocator: Allocator, orphans: *std.ArrayList(OrphanNote)) void {
    for (orphans.items) |*orphan| orphan.deinit(allocator);
    orphans.clearRetainingCapacity();
}

/// Append the export section for orphaned notes. No-op when there are none.
pub fn writeOrphanSection(writer: *std.Io.Writer, orphans: []const OrphanNote) !void {
    if (orphans.len == 0) return;
    try writer.writeAll("\n## Notes not anchored in this diff\n");
    for (orphans) |orphan| {
        try writer.print("\n### {s}\n", .{orphan.file_path});
        if (orphan.line_content.len > 0) try writer.print("```\n{s}\n```\n", .{orphan.line_content});
        try writer.print("{s}\n", .{orphan.text});
    }
}

const Side = enum { old, new };

const Position = struct { hunk_idx: usize, line_idx: usize };

fn sideOf(line_type: parser.Line.LineType) Side {
    return if (line_type == .delete) .old else .new;
}

fn linenoOn(note: NoteAnchorInput, side: Side) ?u32 {
    return switch (side) {
        .old => note.old_lineno,
        .new => note.new_lineno,
    };
}

fn lineLineno(line: *const parser.Line, side: Side) ?u32 {
    return switch (side) {
        .old => if (line.line_type == .delete) line.old_lineno else null,
        .new => if (line.line_type != .delete) line.new_lineno else null,
    };
}

fn fileIndex(files: []const parser.FileDiff, path: []const u8) ?usize {
    for (files, 0..) |*file, i| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        if (std.mem.eql(u8, file_path, path)) return i;
    }
    return null;
}

fn findByLineno(file: *const parser.FileDiff, params: struct { side: Side, lineno: ?u32, content: ?[]const u8 = null }) ?Position {
    const lineno = params.lineno orelse return null;
    for (file.hunks, 0..) |hunk, h| {
        for (hunk.lines, 0..) |*line, l| {
            if (lineLineno(line, params.side) != lineno) continue;
            if (params.content) |content| {
                if (!std.mem.eql(u8, line.content, content)) continue;
            }
            return .{ .hunk_idx = h, .line_idx = l };
        }
    }
    return null;
}

fn findByContent(file: *const parser.FileDiff, content: []const u8) ?Position {
    for (file.hunks, 0..) |hunk, h| {
        for (hunk.lines, 0..) |line, l| {
            if (std.mem.eql(u8, line.content, content)) return .{ .hunk_idx = h, .line_idx = l };
        }
    }
    return null;
}

/// The range end, shifted by however far the start moved, when it still
/// exists at or after the start.
fn rangeEnd(params: struct { file: *const parser.FileDiff, note: NoteAnchorInput, start: Position }) ?Position {
    const note = params.note;
    const side: Side = if (note.end_new_lineno != null) .new else .old;
    const end_lineno = (if (side == .new) note.end_new_lineno else note.end_old_lineno) orelse return null;
    const start_line = &params.file.hunks[params.start.hunk_idx].lines[params.start.line_idx];
    const shift: i64 = shift: {
        const before = linenoOn(note, sideOf(note.line_type)) orelse break :shift 0;
        const after = lineLineno(start_line, sideOf(note.line_type)) orelse break :shift 0;
        break :shift @as(i64, after) - @as(i64, before);
    };
    const shifted = @as(i64, end_lineno) + shift;
    if (shifted <= 0) return null;
    const end = findByLineno(params.file, .{ .side = side, .lineno = @intCast(shifted) }) orelse return null;
    const ordered = end.hunk_idx > params.start.hunk_idx or (end.hunk_idx == params.start.hunk_idx and end.line_idx > params.start.line_idx);
    return if (ordered) end else null;
}

fn anchorInput(note: *const types.NoteRow) ?NoteAnchorInput {
    const line_type = std.meta.stringToEnum(parser.Line.LineType, note.line_type) orelse return null;
    return .{
        .file_path = note.file_path,
        .line_type = line_type,
        .old_lineno = note.old_lineno,
        .new_lineno = note.new_lineno,
        .end_old_lineno = note.end_old_lineno,
        .end_new_lineno = note.end_new_lineno,
        .line_content = note.line_content,
    };
}

fn addComment(params: struct {
    allocator: Allocator,
    note: *const types.NoteRow,
    files: []const parser.FileDiff,
    anchor: Anchor,
    comments: *comments.CommentStore,
    note_ids: *std.AutoHashMapUnmanaged(u64, i64),
}) !void {
    const note = params.note;
    const anchor = params.anchor;
    const file = &params.files[anchor.file_idx];
    const line = &file.hunks[anchor.hunk_idx].lines[anchor.line_idx];
    const index = try params.comments.add(.{
        .file_path = if (file.new_path.len > 0) file.new_path else file.old_path,
        .hunk_idx = anchor.hunk_idx,
        .line_idx = anchor.line_idx,
        .text = note.text,
        .line_type = line.line_type,
        .line_content = line.content,
        .old_lineno = line.old_lineno,
        .new_lineno = line.new_lineno,
        .end_hunk_idx = anchor.end_hunk_idx,
        .end_line_idx = anchor.end_line_idx,
        .author = note.author,
    });
    const comment_id = params.comments.idAt(index).?;
    try params.note_ids.put(params.allocator, comment_id, note.id);

    const parsed = std.json.parseFromSlice([]ReplyJson, params.allocator, note.replies, .{ .ignore_unknown_fields = true }) catch |err| {
        std.log.warn("pr notes: note {d} has unreadable replies: {any}", .{ note.id, err });
        return;
    };
    defer parsed.deinit();
    for (parsed.value) |reply| _ = try params.comments.addReply(index, reply.author, reply.text);
}

fn appendOrphan(params: struct { allocator: Allocator, orphans: *std.ArrayList(OrphanNote), note: *const types.NoteRow }) !void {
    const allocator = params.allocator;
    const file_path = try allocator.dupe(u8, params.note.file_path);
    errdefer allocator.free(file_path);
    const line_content = try allocator.dupe(u8, params.note.line_content);
    errdefer allocator.free(line_content);
    const text = try allocator.dupe(u8, params.note.text);
    errdefer allocator.free(text);
    try params.orphans.append(allocator, .{ .note_id = params.note.id, .file_path = file_path, .line_content = line_content, .text = text });
}

fn savedRow(saved: []const types.NoteRow, id: i64) ?*const types.NoteRow {
    for (saved) |*row| {
        if (row.id == id) return row;
    }
    return null;
}

fn repliesJson(allocator: Allocator, replies: []const comments.Reply) ![]u8 {
    const items = try allocator.alloc(ReplyJson, replies.len);
    defer allocator.free(items);
    for (replies, items) |reply, *item| item.* = .{ .author = reply.author, .text = reply.text };
    return std.json.Stringify.valueAlloc(allocator, items, .{});
}

fn noteRow(params: struct { number: u32, comment: *const comments.Comment, files: []const parser.FileDiff, replies: []const u8, now: i64 }) types.NoteRow {
    const comment = params.comment;
    const end_line = endLine(.{ .files = params.files, .comment = comment });
    return .{
        .id = 0,
        .number = params.number,
        .file_path = comment.file_path,
        .line_type = @tagName(comment.line_type),
        .old_lineno = comment.old_lineno,
        .new_lineno = comment.new_lineno,
        .end_old_lineno = if (end_line) |line| line.old_lineno else null,
        .end_new_lineno = if (end_line) |line| line.new_lineno else null,
        .line_content = comment.line_content,
        .author = comment.author,
        .text = comment.text,
        .replies = params.replies,
        .created_at = params.now,
    };
}

fn endLine(params: struct { files: []const parser.FileDiff, comment: *const comments.Comment }) ?*const parser.Line {
    const comment = params.comment;
    const end_hunk = comment.end_hunk_idx orelse return null;
    const end_idx = comment.end_line_idx orelse return null;
    const file_idx = fileIndex(params.files, comment.file_path) orelse return null;
    const hunks = params.files[file_idx].hunks;
    if (end_hunk >= hunks.len or end_idx >= hunks[end_hunk].lines.len) return null;
    return &hunks[end_hunk].lines[end_idx];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,4 +1,5 @@
    \\ one
    \\+two
    \\ three
    \\-four
    \\+FOUR
    \\ five
    \\diff --git a/b.txt b/b.txt
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -10,2 +10,3 @@
    \\ ten
    \\+eleven
    \\ twelve
    \\
;

/// `diff` with a.txt's edits moved 20 lines down.
const moved =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -21,4 +21,5 @@
    \\ one
    \\+two
    \\ three
    \\-four
    \\+FOUR
    \\ five
    \\
;

fn parseDiff(text: []const u8) ![]parser.FileDiff {
    return parser.parse(testing.allocator, text);
}

fn freeFiles(files: []parser.FileDiff) void {
    for (files) |*file| file.deinit(testing.allocator);
    testing.allocator.free(files);
}

fn noteFor(params: struct {
    id: i64 = 1,
    file_path: []const u8 = "a.txt",
    line_type: []const u8 = "add",
    old_lineno: ?u32 = null,
    new_lineno: ?u32 = null,
    end_old_lineno: ?u32 = null,
    end_new_lineno: ?u32 = null,
    line_content: []const u8,
    text: []const u8 = "note",
    replies: []const u8 = "[]",
}) types.NoteRow {
    return .{
        .id = params.id,
        .number = 7,
        .file_path = params.file_path,
        .line_type = params.line_type,
        .old_lineno = params.old_lineno,
        .new_lineno = params.new_lineno,
        .end_old_lineno = params.end_old_lineno,
        .end_new_lineno = params.end_new_lineno,
        .line_content = params.line_content,
        .author = "you",
        .text = params.text,
        .replies = params.replies,
        .created_at = 1,
    };
}

fn inputOf(note: types.NoteRow) NoteAnchorInput {
    return anchorInput(&note).?;
}

const Restored = struct {
    store: comments.CommentStore,
    orphans: std.ArrayList(OrphanNote) = .empty,
    note_ids: std.AutoHashMapUnmanaged(u64, i64) = .{},

    fn init() Restored {
        return .{ .store = comments.CommentStore.init(testing.allocator) };
    }

    fn deinit(self: *Restored) void {
        self.store.deinit();
        clearOrphans(testing.allocator, &self.orphans);
        self.orphans.deinit(testing.allocator);
        self.note_ids.deinit(testing.allocator);
    }

    fn run(self: *Restored, params: struct { notes: []const types.NoteRow, files: []const parser.FileDiff }) !void {
        try restore(.{ .allocator = testing.allocator, .notes = params.notes, .files = params.files, .comments = &self.store, .orphans = &self.orphans, .note_ids = &self.note_ids });
    }

    fn plan(self: *const Restored, params: struct { files: []const parser.FileDiff, saved: []const types.NoteRow }) !SavePlan {
        return planSave(.{ .allocator = testing.allocator, .number = 7, .comments = &self.store, .files = params.files, .note_ids = &self.note_ids, .saved = params.saved, .now = 5 });
    }
};

test "anchorFor: exact new_lineno match on an add line" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    const anchor = anchorFor(files, inputOf(noteFor(.{ .new_lineno = 2, .line_content = "two" }))).?;
    try testing.expectEqual(Anchor{ .file_idx = 0, .hunk_idx = 0, .line_idx = 1 }, anchor);
}

test "anchorFor: delete line matches old_lineno, not new_lineno" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    // old 3 is "-four"; new 3 is " three".
    const anchor = anchorFor(files, inputOf(noteFor(.{ .line_type = "delete", .old_lineno = 3, .new_lineno = 3, .line_content = "four" }))).?;
    try testing.expectEqual(@as(usize, 3), anchor.line_idx);
    try testing.expectEqual(parser.Line.LineType.delete, files[0].hunks[0].lines[anchor.line_idx].line_type);
}

test "anchorFor: lineno moved → first line in the same file with equal content" {
    const files = try parseDiff(moved);
    defer freeFiles(files);
    const anchor = anchorFor(files, inputOf(noteFor(.{ .new_lineno = 2, .line_content = "two" }))).?;
    try testing.expectEqual(Anchor{ .file_idx = 0, .hunk_idx = 0, .line_idx = 1 }, anchor);
}

test "anchorFor: same lineno with different content falls back to content" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    // new 3 is " three"; the note was written on "two", now at new 2.
    const anchor = anchorFor(files, inputOf(noteFor(.{ .new_lineno = 3, .line_content = "two" }))).?;
    try testing.expectEqual(@as(usize, 1), anchor.line_idx);
}

test "anchorFor: neither → null (orphan)" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    try testing.expectEqual(@as(?Anchor, null), anchorFor(files, inputOf(noteFor(.{ .new_lineno = 2, .line_content = "gone" }))));
    try testing.expectEqual(@as(?Anchor, null), anchorFor(files, inputOf(noteFor(.{ .file_path = "zzz.txt", .new_lineno = 2, .line_content = "two" }))));
}

test "anchorFor: range end follows a moved start" {
    const files = try parseDiff(moved);
    defer freeFiles(files);
    const anchor = anchorFor(files, inputOf(noteFor(.{ .new_lineno = 2, .end_new_lineno = 4, .line_content = "two" }))).?;
    try testing.expectEqual(@as(?usize, 0), anchor.end_hunk_idx);
    try testing.expectEqualStrings("FOUR", files[0].hunks[0].lines[anchor.end_line_idx.?].content);
}

test "anchorFor: range end missing → single-line anchor" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    const anchor = anchorFor(files, inputOf(noteFor(.{ .new_lineno = 2, .end_new_lineno = 90, .line_content = "two" }))).?;
    try testing.expectEqual(@as(?usize, null), anchor.end_hunk_idx);
    try testing.expectEqual(@as(?usize, null), anchor.end_line_idx);
}

test "restore: anchored notes become comments with replies; note_ids maps them" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    const notes = [_]types.NoteRow{noteFor(.{ .id = 41, .new_lineno = 11, .file_path = "b.txt", .line_content = "eleven", .text = "hi", .replies = "[{\"author\":\"bot\",\"text\":\"ok\"}]" })};
    try restored.run(.{ .notes = &notes, .files = files });

    try testing.expectEqual(@as(usize, 1), restored.store.comments.items.len);
    const comment = restored.store.comments.items[0];
    try testing.expectEqualStrings("b.txt", comment.file_path);
    try testing.expectEqualStrings("hi", comment.text);
    try testing.expectEqual(@as(?u32, 11), comment.new_lineno);
    try testing.expectEqualStrings("bot", comment.replies.items[0].author);
    try testing.expectEqual(@as(?i64, 41), restored.note_ids.get(comment.id));
}

test "restore: unanchorable and unknown-type notes become orphans" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    const notes = [_]types.NoteRow{
        noteFor(.{ .id = 1, .new_lineno = 2, .line_content = "gone", .text = "lost" }),
        noteFor(.{ .id = 2, .line_type = "bogus", .new_lineno = 2, .line_content = "two" }),
    };
    try restored.run(.{ .notes = &notes, .files = files });
    try testing.expectEqual(@as(usize, 0), restored.store.comments.items.len);
    try testing.expectEqual(@as(usize, 2), restored.orphans.items.len);
    try testing.expectEqualStrings("lost", restored.orphans.items[0].text);
    try testing.expectEqual(@as(u32, 0), restored.note_ids.count());
}

test "restore: a second restore replaces the previous PR's orphans and ids" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    try restored.run(.{ .notes = &.{noteFor(.{ .id = 1, .new_lineno = 2, .line_content = "gone" })}, .files = files });
    restored.store.clearAll();
    try restored.run(.{ .notes = &.{noteFor(.{ .id = 2, .new_lineno = 2, .line_content = "two" })}, .files = files });
    try testing.expectEqual(@as(usize, 0), restored.orphans.items.len);
    try testing.expectEqual(@as(u32, 1), restored.note_ids.count());
}

test "planSave: new comment → one insert carrying its Comment.id" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    const index = try restored.store.add(.{ .file_path = "a.txt", .hunk_idx = 0, .line_idx = 1, .end_hunk_idx = 0, .end_line_idx = 4, .text = "new", .line_type = .add, .line_content = "two", .new_lineno = 2 });

    var plan = try restored.plan(.{ .files = files, .saved = &.{} });
    defer plan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), plan.inserts.len);
    try testing.expectEqual(restored.store.idAt(index).?, plan.inserts[0].comment_id);
    const row = plan.inserts[0].row;
    try testing.expectEqualStrings("add", row.line_type);
    try testing.expectEqualStrings("two", row.line_content);
    try testing.expectEqual(@as(?u32, 2), row.new_lineno);
    try testing.expectEqual(@as(?u32, 4), row.end_new_lineno);
    try testing.expectEqualStrings("[]", row.replies);
    try testing.expectEqual(@as(u32, 7), row.number);
    try testing.expectEqual(@as(usize, 0), plan.updates.len + plan.deletes.len);
}

test "planSave: comment in note_ids with changed text → one update; unchanged → nothing" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    const saved = [_]types.NoteRow{noteFor(.{ .id = 9, .new_lineno = 2, .line_content = "two", .text = "same" })};
    try restored.run(.{ .notes = &saved, .files = files });

    var unchanged = try restored.plan(.{ .files = files, .saved = &saved });
    defer unchanged.deinit(testing.allocator);
    try testing.expect(unchanged.isEmpty());

    try restored.store.updateComment(0, "edited");
    _ = try restored.store.addReply(0, "you", "and a reply");
    var changed = try restored.plan(.{ .files = files, .saved = &saved });
    defer changed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), changed.updates.len);
    try testing.expectEqual(@as(i64, 9), changed.updates[0].id);
    try testing.expectEqualStrings("edited", changed.updates[0].text);
    try testing.expectEqualStrings("[{\"author\":\"you\",\"text\":\"and a reply\"}]", changed.updates[0].replies);
    try testing.expectEqual(@as(usize, 0), changed.inserts.len + changed.deletes.len);
}

test "planSave: note_ids entry whose comment is gone → delete; orphans are never deleted" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    const saved = [_]types.NoteRow{
        noteFor(.{ .id = 9, .new_lineno = 2, .line_content = "two" }),
        noteFor(.{ .id = 10, .new_lineno = 2, .line_content = "orphaned" }),
    };
    try restored.run(.{ .notes = &saved, .files = files });
    try testing.expectEqual(@as(usize, 1), restored.orphans.items.len);
    try restored.store.deleteComment(0);

    var plan = try restored.plan(.{ .files = files, .saved = &saved });
    defer plan.deinit(testing.allocator);
    try testing.expectEqualSlices(i64, &.{9}, plan.deletes);
    try testing.expectEqual(@as(usize, 0), plan.inserts.len + plan.updates.len);
}

test "planSave: a stale note_ids entry for a row not among this PR's notes is never deleted" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    try restored.run(.{ .notes = &.{noteFor(.{ .id = 9, .new_lineno = 2, .line_content = "two" })}, .files = files });
    restored.store.clearAll();

    var plan = try restored.plan(.{ .files = files, .saved = &.{} });
    defer plan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), plan.deletes.len);
}

test "planSave: a note_ids row missing from the DB is inserted again" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var restored = Restored.init();
    defer restored.deinit();
    try restored.run(.{ .notes = &.{noteFor(.{ .id = 9, .new_lineno = 2, .line_content = "two" })}, .files = files });
    var plan = try restored.plan(.{ .files = files, .saved = &.{} });
    defer plan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), plan.inserts.len);
}

test "replies round-trip through JSON with quotes and newlines intact" {
    const files = try parseDiff(diff);
    defer freeFiles(files);
    var first = Restored.init();
    defer first.deinit();
    _ = try first.store.add(.{ .file_path = "a.txt", .hunk_idx = 0, .line_idx = 1, .text = "t", .line_type = .add, .line_content = "two", .new_lineno = 2 });
    _ = try first.store.addReply(0, "bot", "say \"hi\"\nthen go");
    var plan = try first.plan(.{ .files = files, .saved = &.{} });
    defer plan.deinit(testing.allocator);

    var row = plan.inserts[0].row;
    row.id = 3;
    var second = Restored.init();
    defer second.deinit();
    try second.run(.{ .notes = &.{row}, .files = files });
    try testing.expectEqualStrings("say \"hi\"\nthen go", second.store.comments.items[0].replies.items[0].text);
}

test "writeOrphanSection lists each orphan under the heading; empty writes nothing" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeOrphanSection(&out.writer, &.{});
    try testing.expectEqual(@as(usize, 0), out.written().len);

    var path = "a.txt".*;
    var content = "two".*;
    var text = "note-9".*;
    try writeOrphanSection(&out.writer, &.{.{ .note_id = 1, .file_path = &path, .line_content = &content, .text = &text }});
    const written = out.written();
    const heading = std.mem.indexOf(u8, written, "Notes not anchored in this diff").?;
    try testing.expect(std.mem.indexOf(u8, written, "note-9").? > heading);
}
