//! PR flip controller: the notes, seen and changed-since-seen bookkeeping
//! around a preview, on `FlipState` plus the narrow App slices it touches.
//! `flip.zig` stays pure and Store-free (D4); everything here that reaches
//! the Store goes through `pr_surface`, which the wasm build stubs out.
//! App keeps the parts that swap the diff on screen (installPrDiff,
//! previewMiss, swapFiles, tickPrSurface) and forwards the rest here.

const std = @import("std");
const skim_io = @import("skim_io");
const flip = @import("flip.zig");
const notes = @import("notes.zig");
const types = @import("db/types.zig");
const parser = @import("../git/parser.zig");
const line_map = @import("../line_map.zig");
const comments = @import("../comments/store.zig");
const SidebarState = @import("sidebar/state.zig").SidebarState;
const pr_surface = if (@import("../platform.zig").is_web) @import("surface_stub.zig") else @import("surface.zig");

const Allocator = std.mem.Allocator;

/// The App state a flip touches. Built per call (`App.flipCtx`), so `files`
/// is the diff on screen at that moment.
pub const Ctx = struct {
    allocator: Allocator,
    flip: *flip.FlipState,
    surface: *pr_surface.Surface,
    sidebar: *SidebarState,
    comments: *comments.CommentStore,
    files: []const parser.FileDiff,
    /// `App.state.collapsed_folds`: the changed-only toggle folds files here.
    folds: *flip.Folds,
};

/// What the changed-only toggle (`c` on rewritten history) did.
pub const ChangedOnly = enum { folded, unfolded, no_seen_diff };

pub const CursorSnapshot = struct {
    line_map: *const line_map.LineMap,
    cursor_line: usize,
    scroll_offset: usize,
};

pub const PreviewDone = struct {
    number: u32,
    view: flip.DiffView,
    /// The cached set's key; null for a streamed load.
    key: ?types.DiffKey,
    /// Seen at its current head already (or not listed): no dwell.
    already_seen: bool,
    /// The streamed load failed: what is on screen is not the PR's diff.
    load_failed: bool = false,
    /// An explicit open (Enter, `skim pr <n>`) is moving focus to the diff.
    moves_focus: bool = false,
};

/// Write the previewed PR's notes back when `comment_store` changed since
/// the last save (FR-9). Only the PR's own view: whole-stack and
/// since-seen line numbers belong to another diff. Skipped while a miss
/// is loading: the store was cleared for the incoming PR.
pub fn persistNotesIfDirty(ctx: Ctx) void {
    const state = ctx.flip;
    const number = state.previewed orelse return;
    if (state.previewed_view != .pr or state.loading_number != null) return;
    if (ctx.comments.revision == state.notes_saved_revision) return;
    pr_surface.saveNotes(ctx.surface, .{
        .allocator = ctx.allocator,
        .number = number,
        .comments = ctx.comments,
        .files = ctx.files,
        .note_ids = &state.note_ids,
        .now = skim_io.timestamp(),
    }) catch |err| {
        std.log.warn("pr flip: saving #{d}'s notes failed: {any}", .{ number, err });
        return;
    };
    state.notes_saved_revision = ctx.comments.revision;
}

/// Before the diff on screen is replaced: save the previewed PR's notes and
/// remember its cursor.
pub fn persistOutgoing(ctx: Ctx, cursor: CursorSnapshot) void {
    persistNotesIfDirty(ctx);
    const state = ctx.flip;
    const number = state.previewed orelse return;
    if (state.previewed_view != .pr or state.loading_number != null) return;
    flip.rememberCursor(state, .{
        .allocator = ctx.allocator,
        .number = number,
        .files = ctx.files,
        .line_map = cursor.line_map,
        .cursor_line = cursor.cursor_line,
        .scroll_offset = cursor.scroll_offset,
    }) catch |err| {
        std.log.warn("pr flip: cursor for #{d} not remembered: {any}", .{ number, err });
    };
}

/// The incoming PR's notes into the (empty) `comment_store`, anchored in
/// `files`; other views start with no notes.
pub fn restoreNotes(ctx: Ctx, params: struct { number: u32, view: flip.DiffView, files: []const parser.FileDiff }) !void {
    const state = ctx.flip;
    if (params.view != .pr) {
        notes.clearOrphans(ctx.allocator, &state.orphan_notes);
        state.note_ids.clearRetainingCapacity();
        return;
    }
    try pr_surface.restoreNotes(ctx.surface, .{
        .allocator = ctx.allocator,
        .number = params.number,
        .files = params.files,
        .comments = ctx.comments,
        .orphans = &state.orphan_notes,
        .note_ids = &state.note_ids,
    });
}

/// FR-8 marks for the PR's own diff: which files differ from the diff the
/// user last saw. Empty in other views and for unchanged PRs.
pub fn refreshChangedFiles(ctx: Ctx, params: struct { number: u32, view: flip.DiffView }) void {
    flip.clearDiffState(ctx.flip, ctx.allocator, ctx.folds);
    if (params.view != .pr) return;
    ctx.flip.changed_files = pr_surface.changedFiles(ctx.surface, .{
        .allocator = ctx.allocator,
        .sidebar = ctx.sidebar,
        .number = params.number,
        .current = ctx.files,
        .lru = if (ctx.flip.lru) |*lru| lru else null,
        .now = skim_io.timestamp(),
    }) catch |err| blk: {
        std.log.warn("pr flip: changed-since-seen for #{d} failed: {any}", .{ params.number, err });
        break :blk &.{};
    };
}

/// AD-9: mark PR `number` seen at its head. When it is the previewed PR its
/// dwell is done and its changed-since-seen marks are recomputed: the diff
/// on screen is now the seen one.
pub fn markSeen(ctx: Ctx, number: u32) void {
    pr_surface.markSeen(ctx.surface, .{ .allocator = ctx.allocator, .number = number, .sidebar = ctx.sidebar, .now = skim_io.timestamp() });
    afterSeenChange(ctx, number);
}

/// `m`: seen at the head, or unseen when it already is.
pub fn toggleSeen(ctx: Ctx, number: u32) void {
    pr_surface.toggleSeen(ctx.surface, .{ .allocator = ctx.allocator, .number = number, .sidebar = ctx.sidebar, .now = skim_io.timestamp() });
    afterSeenChange(ctx, number);
}

/// FR-8 on rewritten history: fold every file that did not change since
/// seen, or unfold exactly those again. The caller rebuilds the LineMap.
pub fn toggleChangedOnly(ctx: Ctx) !ChangedOnly {
    const state = ctx.flip;
    if (state.collapsed_by_changed.len > 0) {
        flip.releaseChangedOnlyFolds(state, ctx.allocator, ctx.folds);
        return .unfolded;
    }
    if (state.changed_files.len == 0) return .no_seen_diff;
    state.collapsed_by_changed = try flip.unchangedFiles(ctx.allocator, state.changed_files);
    errdefer flip.releaseChangedOnlyFolds(state, ctx.allocator, ctx.folds);
    for (state.collapsed_by_changed) |file_idx| try ctx.folds.put(line_map.LineMap.FoldKey.fileKey(file_idx), {});
    return .folded;
}

/// The miss load will not land. The PR still on screen stays previewed and
/// gets its notes back (the switch cleared `comment_store`), so writes keep
/// persisting to it. With a surface change pending the screen is no PR's,
/// so the preview is forgotten instead and writes are refused
/// (`App.localWritesBlocked`). True when the notes came back: the caller
/// rebuilds the LineMap and restores the cursor.
pub fn abandonMissPreview(ctx: Ctx, params: struct { surface_change_pending: bool }) bool {
    const state = ctx.flip;
    state.loading_number = null;
    state.focus_diff = false;
    const number = state.previewed orelse return false;
    if (params.surface_change_pending) {
        state.previewed = null;
        return false;
    }
    if (state.previewed_view != .pr) return false;
    ctx.comments.clearAll();
    restoreNotes(ctx, .{ .number = number, .view = .pr, .files = ctx.files }) catch |err| {
        std.log.warn("pr flip: restoring #{d}'s notes failed: {any}", .{ number, err });
        state.previewed = null;
        return false;
    };
    state.notes_saved_revision = ctx.comments.revision;
    return true;
}

/// Common tail of a hit and a landed miss: record the preview, mark it seen
/// when an explicit open moved focus onto it, and recompute its
/// changed-since-seen marks. A failed load gets no dwell: nothing was read.
pub fn finishPreview(ctx: Ctx, params: PreviewDone) void {
    const state = ctx.flip;
    flip.notePreviewed(state, .{
        .number = params.number,
        .view = params.view,
        .key = params.key,
        .now_ms = skim_io.milliTimestamp(),
        .already_seen = params.already_seen or params.load_failed,
    });
    state.notes_saved_revision = ctx.comments.revision;
    state.focus_diff = false;
    if (params.moves_focus and params.view == .pr and !state.dwell_done) {
        markSeen(ctx, params.number);
        return;
    }
    refreshChangedFiles(ctx, .{ .number = params.number, .view = params.view });
}

fn afterSeenChange(ctx: Ctx, number: u32) void {
    const state = ctx.flip;
    if (state.previewed != number or state.loading_number != null) return;
    state.dwell_done = true;
    refreshChangedFiles(ctx, .{ .number = number, .view = state.previewed_view });
}
