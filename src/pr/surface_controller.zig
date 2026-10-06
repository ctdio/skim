//! PR surface controller: swapping the diff on screen between PRs and
//! between the PR surface and a non-PR diff. Owns the diff source a PR is
//! shown with, the parking of the non-PR diff's comments, the editor that
//! is open as a diff is replaced, and the previews the sidebar cursor
//! drives. Works on the narrow App slices in `Ctx`; the App operations it
//! needs but does not own (refresh, install, LineMap rebuild) come in
//! through `Host`. `flip_controller` keeps the notes and seen bookkeeping.

const std = @import("std");
const skim_io = @import("skim_io");
const flip = @import("flip.zig");
const flip_controller = @import("flip_controller.zig");
const github = @import("github.zig");
const review_controller = @import("review_controller.zig");
const types = @import("db/types.zig");
const sidebar_controller = @import("sidebar/controller.zig");
const SidebarState = @import("sidebar/state.zig").SidebarState;
const git = @import("../git/diff.zig");
const diff_loader = @import("../git/diff_loader.zig");
const parser = @import("../git/parser.zig");
const line_map = @import("../line_map.zig");
const comments = @import("../comments/store.zig");
const CommentEditor = @import("../comments/editor.zig").CommentEditor;
const Mode = @import("../mode.zig").Mode;
const pr_surface = if (@import("../platform.zig").is_web) @import("surface_stub.zig") else @import("surface.zig");

const Allocator = std.mem.Allocator;
const DiffSource = git.DiffSource;

/// The App state the PR surface touches. Built per call (`App.surfaceCtx`).
pub const Ctx = struct {
    allocator: Allocator,
    host: Host,
    parking: *Parking,
    diff_source: *DiffSource,
    diff_load: *diff_loader.DiffLoad,
    comment_store: *comments.CommentStore,
    review: *review_controller.ReviewSession,
    flip: *flip.FlipState,
    surface: *pr_surface.Surface,
    sidebar: *SidebarState,
    /// `App.state.files`, read through the pointer: an install replaces it.
    files: *const []parser.FileDiff,
    line_map: *const line_map.LineMap,
    cursor_line: *usize,
    scroll_offset: *usize,
    folds: *flip.Folds,
    active_comment_input: *?CommentEditor.State,
    mode: *Mode,
    pager_mode: *bool,
    needs_render: *bool,
    needs_async_highlight: *bool,
};

/// The App operations the controller drives but does not own. `ptr` is the
/// App.
pub const Host = struct {
    ptr: *anyopaque,
    /// Stream `diff_source` in; the diff on screen stays until it lands.
    refresh: *const fn (ptr: *anyopaque) void,
    /// Install an already-parsed set without spawning; ownership moves in.
    install_files: *const fn (ptr: *anyopaque, files: []parser.FileDiff) Allocator.Error!void,
    /// Clear the folds, expansions, search and cursor of the diff on screen.
    clear_view: *const fn (ptr: *anyopaque) void,
    /// Re-anchor the review threads and rebuild the LineMap in place.
    rebuild_line_map: *const fn (ptr: *anyopaque) void,
    clamp_scroll: *const fn (ptr: *anyopaque) void,
    show_error: *const fn (ptr: *anyopaque, message: []const u8) void,
    /// Save the open comment editor; false when it was refused or failed.
    save_open_comment: *const fn (ptr: *anyopaque) bool,
};

/// The non-PR diff's local comments while the PR surface is up, and the
/// surface change in flight. Comments are parked when a PR diff source is
/// selected (`enterReviewDiff`) and restored when the next non-PR diff is
/// installed after `App.leavePrSurface` (`completeSurfaceChange`), so
/// `comments` is non-null from PR entry until a non-PR diff is on screen
/// again.
pub const Parking = struct {
    comments: ?comments.CommentStore = null,
    change: SurfaceChange = .none,
    /// What a whole-stack or since-seen load (`startLocalPrLoad`)
    /// replaced, so a load that will not land puts back the source of
    /// the diff still on screen (`cancelLocalPrLoad`). Null otherwise.
    local_load: ?LocalLoad = null,

    /// A diff-source change between the PR surface and a non-PR diff that
    /// `completeSurfaceChange` completes once the new diff is installed, so
    /// the outgoing diff never shows the incoming surface's comments or
    /// threads.
    pub const SurfaceChange = enum { none, enter_pr, leave_pr };

    const LocalLoad = struct { source: DiffSource, change: SurfaceChange };

    /// True while the diff on screen is not the one `comment_store` belongs
    /// to. Local comment writes are refused then: they would land in the
    /// wrong store, and on a leave be discarded with it.
    pub fn pending(self: *const Parking) bool {
        return self.change != .none;
    }
};

/// Why local comment writes are refused right now (`localWritesBlocked`).
pub const LocalWriteBlock = enum {
    /// A PR surface change is waiting for its diff to install.
    diff_loading,
    /// Another PR was selected from the PR surface and its entry has not
    /// landed; `comment_store` is about to become that PR's.
    pr_loading,
    /// The whole-stack or since-seen view is on screen: its line numbers
    /// belong to another diff, so notes written there are never saved.
    unsaved_view,
};

/// What `localWritesBlocked` reads.
pub const WriteGate = struct {
    parking: *const Parking,
    review: *const review_controller.ReviewSession,
    sidebar: *const SidebarState,
    flip: *const flip.FlipState,
};

/// A landed PR entry for `enterReviewDiff`. `head_ref` is the head oid
/// the entry's `git fetch` landed (its local ref when that cannot be
/// resolved); `base_ref` is the base branch
/// name (empty → diff against HEAD); `gh_error` is set when git succeeded but
/// the review data fetch failed.
pub const ReviewDiffEntry = struct {
    head_ref: []const u8,
    base_ref: []const u8,
    gh_error: ?github.GhErrorKind = null,
};

/// A cached PR diff to show without spawning anything (`installPrDiff`).
pub const PrInstall = struct {
    /// From the sidebar snapshot; borrowed for the call.
    record: *const types.PrRecord,
    /// Ownership moves in.
    files: []parser.FileDiff,
    key: types.DiffKey,
    view: flip.DiffView,
    /// Raw review payload from thread_cache; borrowed. `.pr` view only.
    threads_json: ?[]const u8,
    threads_fresh: bool,
    /// Whole-stack: the stack bottom's base branch; else the PR's.
    stack_base_ref: []const u8,
};

const discarded_comment_message = "unsent comment on the previous diff discarded";
const editor_open_message = "finish or cancel the open comment first";

/// Begin reviewing a PR selected in the sidebar. Kicks off the async entry
/// worker (git fetch + gh review fetch) off-thread and returns immediately —
/// the main loop's `App.pollReviewEntry` swaps the diff once the fetch lands,
/// so the sidebar never freezes. The sidebar shows "Loading…" until then.
/// `error.CommentEditorOpen` when an editor is open: nothing started.
pub fn selectPullRequest(ctx: Ctx, params: review_controller.EnterParams) !void {
    // An editor left open behind the sidebar (Ctrl-E from the editor keeps
    // it) would otherwise be settled against the next PR's entry.
    if (refuseForOpenEditor(ctx)) return error.CommentEditorOpen;
    const sb = ctx.sidebar;
    var msg_buf: [64]u8 = undefined;
    const loading = std.fmt.bufPrint(&msg_buf, "Loading PR #{d}…", .{params.number}) catch "Loading PR…";
    sidebar_controller.setMessage(sb, loading);

    review_controller.startEnterPr(ctx.review, ctx.allocator, params) catch |err| {
        sidebar_controller.setMessage(sb, "failed to start PR entry");
        ctx.needs_render.* = true;
        return err;
    };
    resetPerPrViewState(ctx);
    ctx.needs_render.* = true;
}

/// On a PR→PR switch, drop the previous PR's local comments and view state
/// as soon as the next PR is selected. Off the PR surface this is a no-op:
/// the non-PR diff stays on screen with its comments until the PR diff is
/// installed (`enterReviewDiff` parks them), so a failed entry loses nothing.
pub fn resetPerPrViewState(ctx: Ctx) void {
    if (ctx.parking.comments == null) return;
    ctx.comment_store.clearAll();
    resetDiffViewState(ctx);
}

/// One step of PR-surface work: drain the sync and prefetch workers, turn
/// sidebar cursor moves into debounced previews, mark a PR seen after the
/// dwell, and save the previewed PR's notes when they changed. The main
/// loop calls it every tick; the harness calls it with a virtual clock.
pub fn tick(ctx: Ctx, now_ms: i64) void {
    const sb = ctx.sidebar;
    if (pr_surface.poll(ctx.surface, .{ .allocator = ctx.allocator, .sidebar = sb })) ctx.needs_render.* = true;
    if (!sb.open) return;
    if (sidebar_controller.takeCursorChanged(sb)) {
        const selected = sidebar_controller.selectedPr(sb);
        flip.onCursorMoved(ctx.flip, .{ .number = if (selected) |record| record.number else null, .now_ms = now_ms });
        pr_surface.focusPrefetch(ctx.surface, sb);
    }
    // An open editor defers the preview (`previewPr`) until it closes.
    const deferred = ctx.active_comment_input.* != null and ctx.flip.pending != null;
    if (!deferred) if (flip.tick(ctx.flip, now_ms)) |action| switch (action) {
        .preview => |number| {
            // A cursor move starts every PR in its own diff, unfocused.
            ctx.flip.view = .pr;
            ctx.flip.focus_diff = false;
            previewPr(ctx, number);
        },
        .mark_seen => |number| {
            flip_controller.markSeen(flipCtx(ctx), number);
            // The header and sidebar change-since-seen marks just cleared.
            ctx.needs_render.* = true;
        },
    };
    persistNotesIfDirty(ctx);
}

/// Show PR `number` in `flip.view`: install it from the cache when the
/// diff is there (no subprocess), else start a streaming load.
pub fn previewPr(ctx: Ctx, number: u32) void {
    const record = sidebar_controller.recordByNumber(ctx.sidebar, number) orelse return;
    // The editor belongs to the diff on screen: the flip waits for it to
    // close (`tick`), then lands on the cursor's PR.
    if (refuseForOpenEditor(ctx)) {
        ctx.flip.pending = .{ .number = number, .due_ms = 0 };
        return;
    }
    var plan = pr_surface.planFlip(ctx.surface, .{
        .allocator = ctx.allocator,
        .sidebar = ctx.sidebar,
        .record = record,
        .view = ctx.flip.view,
        .lru = if (ctx.flip.lru) |*lru| lru else null,
        .now = skim_io.timestamp(),
    }) catch |err| blk: {
        std.log.warn("pr flip: cache lookup for #{d} failed: {any}", .{ number, err });
        break :blk .miss;
    };
    switch (plan) {
        .miss => previewMiss(ctx, record),
        .hit => |*hit| {
            defer if (hit.threads) |threads| threads.deinit(ctx.allocator);
            installPrDiff(ctx, .{
                .record = record,
                .files = hit.files,
                .key = hit.key,
                .view = ctx.flip.view,
                .threads_json = if (hit.threads) |threads| threads.json else null,
                .threads_fresh = hit.threads_fresh,
                .stack_base_ref = hit.stack_base_ref,
            }) catch |err| {
                std.log.warn("pr flip: installing cached #{d} failed: {any}", .{ number, err });
                previewMiss(ctx, record);
            };
        },
    }
}

/// Show a pre-parsed, cached PR diff without spawning git: the diff source
/// is set to what a streamed load of the same PR would use (so `r` still
/// re-diffs), the session enters from the cached threads, and the PR's
/// notes come back. Focus stays where it is unless an explicit open asked
/// for the diff. Takes ownership of `install.files`.
pub fn installPrDiff(ctx: Ctx, install: PrInstall) !void {
    var files_owned = true;
    errdefer if (files_owned) freeParsedFiles(ctx.allocator, install.files);
    if (refuseForOpenEditor(ctx)) return error.CommentEditorOpen;
    const record = install.record;
    cancelLocalPrLoad(ctx);
    persistOutgoingPr(ctx);
    // Saved; from here `comment_store` is cleared for the incoming PR, so a
    // failure below must not save it again as the outgoing PR's notes.
    ctx.flip.previewed = null;
    try setPrDiffSource(ctx, flip.prDiffRefs(.{ .record = record, .view = install.view, .stack_base_ref = install.stack_base_ref, .head_oid = &install.key.head_oid }));
    switch (install.view) {
        .pr => _ = try review_controller.enterFromCache(ctx.review, ctx.allocator, .{
            .number = record.number,
            .pr_node_id = record.node_id,
            .head_ref_oid = record.head_oid,
            .head_ref = record.head_ref,
            .base_ref = record.base_ref,
            .title = record.title,
            .author = record.author,
            .is_draft = record.is_draft,
            .threads_json = install.threads_json,
            .threads_fresh = install.threads_fresh,
        }),
        .whole_stack, .since_seen => _ = review_controller.leaveSurface(ctx.review, ctx.allocator),
    }
    takeCommentStoreForPr(ctx);
    ctx.host.clear_view(ctx.host.ptr);
    try flip_controller.restoreNotes(flipCtx(ctx), .{ .number = record.number, .view = install.view, .files = install.files });
    // Anchored in `install.files`: a set that fails to install takes them along.
    errdefer ctx.comment_store.clearAll();
    files_owned = false;
    try ctx.host.install_files(ctx.host.ptr, install.files);
    ctx.flip.displayed_key = install.key;
    finishPreview(ctx, .{ .number = record.number, .view = install.view, .key = install.key, .already_seen = flip.seenAtHead(record) });
    sidebar_controller.setMessage(ctx.sidebar, "");
    ctx.pager_mode.* = false;
    ctx.needs_render.* = true;
    ctx.needs_async_highlight.* = true;
}

/// Swap the diff to the fetched PR refs and refresh. Entering the PR surface
/// from a non-PR diff parks that diff's local comments until a non-PR diff is
/// installed after `App.leavePrSurface`.
pub fn enterReviewDiff(ctx: Ctx, entry: ReviewDiffEntry) !void {
    const ref2 = try ctx.allocator.dupe(u8, entry.head_ref);
    errdefer ctx.allocator.free(ref2);
    const ref1 = if (entry.base_ref.len > 0)
        try std.fmt.allocPrint(ctx.allocator, "origin/{s}", .{entry.base_ref})
    else
        try ctx.allocator.dupe(u8, "HEAD");
    errdefer ctx.allocator.free(ref1);

    replaceDiffSource(ctx, .{ .two_refs = .{
        .ref1 = ref1,
        .ref2 = ref2,
        .use_merge_base = true,
    } });
    // After the fallible allocations: a failed entry leaves the editor open.
    const discarded = settleCommentEditorForEntry(ctx);
    takeCommentStoreForPr(ctx);
    // The previous diff stays on screen until the PR diff installs; the
    // session's threads anchor against that diff, not this one.
    ctx.parking.change = .enter_pr;
    resetDiffViewState(ctx);

    sidebar_controller.setMessage(ctx.sidebar, "");
    ctx.pager_mode.* = false;
    // A sidebar preview keeps focus on the sidebar; an explicit open
    // (Enter, `skim pr <n>`) or a PR entered with no sidebar takes the diff.
    if (!ctx.sidebar.open or ctx.flip.focus_diff) ctx.mode.* = .normal;
    ctx.flip.focus_diff = false;
    ctx.host.refresh(ctx.host.ptr);
    if (entry.gh_error) |kind| showEntryGhError(ctx, .{ .kind = kind, .discarded = discarded });
}

/// A replace load landed (`App.pollDiffLoad`). A miss load finishes the
/// preview it was for; a refresh of the previewed PR recomputes its
/// changed-since-seen marks; anything else (a stale entry) is ignored.
pub fn finishPrLoad(ctx: Ctx, load_failed: bool) void {
    const number = ctx.flip.loading_number orelse {
        // A refresh of the previewed PR: its marks indexed the old files.
        if (ctx.flip.previewed) |previewed| flip_controller.refreshChangedFiles(flipCtx(ctx), .{ .number = previewed, .view = ctx.flip.previewed_view });
        return;
    };
    const view = ctx.flip.view;
    if (view == .pr and ctx.review.number != number) return;
    flip_controller.restoreNotes(flipCtx(ctx), .{ .number = number, .view = view, .files = ctx.files.* }) catch |err| {
        std.log.warn("pr flip: restoring #{d}'s notes failed: {any}", .{ number, err });
    };
    ctx.host.rebuild_line_map(ctx.host.ptr);
    // An unlisted PR (`skim pr <n>` filtered out) has no record to mark.
    const record = sidebar_controller.recordByNumber(ctx.sidebar, number);
    finishPreview(ctx, .{
        .number = number,
        .view = view,
        .key = null,
        .already_seen = if (record) |listed| flip.seenAtHead(listed) else true,
        .load_failed = load_failed,
    });
}

/// The miss load will not land (`flip_controller.abandonMissPreview`).
pub fn abandonMissPreview(ctx: Ctx) void {
    if (ctx.flip.loading_number == null) return;
    cancelLocalPrLoad(ctx);
    const restored = flip_controller.abandonMissPreview(flipCtx(ctx), .{ .surface_change_pending = ctx.parking.change != .none });
    if (!restored) return;
    ctx.host.rebuild_line_map(ctx.host.ptr);
    restorePrCursor(ctx, ctx.flip.previewed.?);
    ctx.needs_render.* = true;
}

/// A new diff is being installed (`App.swapFiles`): the surface change
/// waiting on it completes. A leave puts the parked non-PR comments back;
/// the caller rebuilds the LineMap.
pub fn completeSurfaceChange(ctx: Ctx) void {
    if (ctx.parking.change == .leave_pr) restoreNonPrComments(ctx);
    ctx.parking.change = .none;
    dropLocalLoad(ctx);
}

/// Write the previewed PR's notes back when they changed.
pub fn persistNotesIfDirty(ctx: Ctx) void {
    flip_controller.persistNotesIfDirty(flipCtx(ctx));
}

/// The local load's diff installed (or the surface is going away): the
/// source it replaced is not coming back.
pub fn dropLocalLoad(ctx: Ctx) void {
    const load = ctx.parking.local_load orelse return;
    ctx.parking.local_load = null;
    git.freeDiffSource(ctx.allocator, load.source);
}

/// Local comment writes (editor open/save, local reply, MCP add/reply) are
/// refused while the diff on screen is not the one `comment_store` will
/// belong to, or while the view on screen is one whose notes are never
/// saved. Null when writes are allowed.
pub fn localWritesBlocked(gate: WriteGate) ?LocalWriteBlock {
    if (gate.parking.pending()) return .diff_loading;
    // A first entry from a non-PR diff stays writable: `enterReviewDiff`
    // parks whatever is written meanwhile with that diff.
    if (gate.parking.comments != null and review_controller.entryPending(gate.review)) return .pr_loading;
    if (!gate.sidebar.open or gate.parking.comments == null) return null;
    // On the PR surface `comment_store` is saved for `flip.previewed`;
    // with none (a failed switch left no PR's notes on screen) a write
    // would never be saved.
    if (gate.flip.previewed == null) return .pr_loading;
    // Only the PR's own view is saved (`flip_controller.persistNotesIfDirty`).
    if (gate.flip.previewed_view != .pr) return .unsaved_view;
    return null;
}

/// The slices the flip controller works on, with the diff on screen now.
pub fn flipCtx(ctx: Ctx) flip_controller.Ctx {
    return .{
        .allocator = ctx.allocator,
        .flip = ctx.flip,
        .surface = ctx.surface,
        .sidebar = ctx.sidebar,
        .comments = ctx.comment_store,
        .files = ctx.files.*,
        .folds = ctx.folds,
    };
}

// =============================================================================
// Helpers
// =============================================================================

/// An open editor belongs to the diff on screen, which must not be replaced
/// under it. True (and the sidebar says so) when one is open.
fn refuseForOpenEditor(ctx: Ctx) bool {
    if (ctx.active_comment_input.* == null) return false;
    sidebar_controller.setMessage(ctx.sidebar, editor_open_message);
    ctx.needs_render.* = true;
    return true;
}

/// Stream PR `record` in `flip.view`. The `.pr` view goes through the
/// review entry (fetch + review data); the whole-stack and since-seen
/// views diff refs the prefetch worker already fetched, without a session.
/// Callers have already refused an open editor.
fn previewMiss(ctx: Ctx, record: *const types.PrRecord) void {
    persistOutgoingPr(ctx);
    ctx.flip.loading_number = record.number;
    ctx.needs_render.* = true;
    const view = ctx.flip.view;
    if (view == .pr) {
        // A streamed load still running (`r`, an earlier miss) would land
        // under the entry; `startLocalPrLoad` cancels its own. A
        // whole-stack or since-seen load also gives the shown PR its
        // source back, for when this entry fails.
        cancelLocalPrLoad(ctx);
        diff_loader.cancel(ctx.diff_load, ctx.allocator);
        selectPullRequest(ctx, flip.enterParamsFor(record)) catch |err| {
            std.log.warn("pr flip: starting #{d} failed: {any}", .{ record.number, err });
            abandonMissPreview(ctx);
        };
        return;
    }
    startLocalPrLoad(ctx, .{ .record = record, .view = view }) catch |err| {
        std.log.warn("pr flip: streaming #{d} failed: {any}", .{ record.number, err });
        abandonMissPreview(ctx);
        ctx.host.show_error(ctx.host.ptr, "failed to load the PR diff");
    };
}

fn startLocalPrLoad(ctx: Ctx, params: struct { record: *const types.PrRecord, view: flip.DiffView }) !void {
    const sb = ctx.sidebar;
    const index = sidebar_controller.recordIndex(sb, params.record.number) orelse return error.UnknownPr;
    const place = sidebar_controller.stackPlace(sb, index);
    const items = sb.records.?.items;
    const whole_stack = params.view == .whole_stack;
    if (whole_stack and (place.bottom == null or place.tip == null)) return error.NotStacked;
    const source = try prDiffSource(ctx.allocator, flip.prDiffRefs(.{
        .record = params.record,
        .view = params.view,
        .stack_base_ref = if (whole_stack) items[place.bottom.?].base_ref else params.record.base_ref,
        .head_oid = if (whole_stack) items[place.tip.?].head_oid else params.record.head_oid,
    }));
    diff_loader.cancel(ctx.diff_load, ctx.allocator);
    parkSourceForLocalLoad(ctx, source);
    _ = review_controller.leaveSurface(ctx.review, ctx.allocator);
    takeCommentStoreForPr(ctx);
    ctx.parking.change = .enter_pr;
    resetDiffViewState(ctx);
    ctx.pager_mode.* = false;
    ctx.host.refresh(ctx.host.ptr);
}

/// Install `source` (ownership moves in) for a whole-stack or since-seen
/// load, keeping the source and surface change it replaces for
/// `cancelLocalPrLoad`. A second one before the first lands keeps the
/// first's: that is still the diff on screen.
fn parkSourceForLocalLoad(ctx: Ctx, source: DiffSource) void {
    const parking = ctx.parking;
    if (parking.local_load != null) return replaceDiffSource(ctx, source);
    parking.local_load = .{ .source = ctx.diff_source.*, .change = parking.change };
    ctx.diff_source.* = source;
}

/// A whole-stack or since-seen load that will not land: stop it and put
/// back the source and surface change of the diff still on screen, so
/// `r` re-diffs what is shown and its notes can come back.
fn cancelLocalPrLoad(ctx: Ctx) void {
    const parking = ctx.parking;
    const load = parking.local_load orelse return;
    parking.local_load = null;
    replaceDiffSource(ctx, load.source);
    parking.change = load.change;
}

/// Point the diff source at a PR's refs.
fn setPrDiffSource(ctx: Ctx, refs: flip.PrDiffRefs) !void {
    replaceDiffSource(ctx, try prDiffSource(ctx.allocator, refs));
}

/// The `two_refs` source for `refs`. Caller owns.
fn prDiffSource(allocator: Allocator, refs: flip.PrDiffRefs) !DiffSource {
    const ref2 = try allocator.dupe(u8, refs.head_oid);
    errdefer allocator.free(ref2);
    const ref1 = switch (refs.base) {
        .branch => |branch| try std.fmt.allocPrint(allocator, "origin/{s}", .{branch}),
        .commit => |commit| try allocator.dupe(u8, commit),
    };
    return .{ .two_refs = .{
        .ref1 = ref1,
        .ref2 = ref2,
        .use_merge_base = refs.base == .branch,
    } };
}

/// Install `source` (ownership moves in) and free the previous one. Joins
/// any streaming load first: its worker borrows the previous source.
fn replaceDiffSource(ctx: Ctx, source: DiffSource) void {
    diff_loader.cancel(ctx.diff_load, ctx.allocator);
    const old_source = ctx.diff_source.*;
    ctx.diff_source.* = source;
    git.freeDiffSource(ctx.allocator, old_source);
}

/// Make `comment_store` the incoming PR's (empty) store: entering from a
/// non-PR diff parks that diff's comments; PR→PR drops the outgoing
/// PR's, which `persistOutgoingPr` already saved.
fn takeCommentStoreForPr(ctx: Ctx) void {
    if (ctx.parking.comments == null) {
        ctx.parking.comments = ctx.comment_store.*;
        ctx.comment_store.* = comments.CommentStore.init(ctx.allocator);
    } else {
        // PR→PR: writes are refused while the entry is pending
        // (`localWritesBlocked`), so this only guards against a gap there.
        ctx.comment_store.clearAll();
    }
}

/// Swap the parked non-PR comments back in as the non-PR diff is installed.
fn restoreNonPrComments(ctx: Ctx) void {
    const parked = ctx.parking.comments orelse return;
    ctx.comment_store.deinit();
    ctx.comment_store.* = parked;
    ctx.parking.comments = null;
    ctx.host.clear_view(ctx.host.ptr);
}

/// Clear view state tied to the diff on screen, then rebuild the LineMap:
/// its comment rows index `comment_store` and its thread rows index
/// `review.threads`, and the callers have just replaced one or both.
fn resetDiffViewState(ctx: Ctx) void {
    ctx.host.clear_view(ctx.host.ptr);
    ctx.host.rebuild_line_map(ctx.host.ptr);
}

/// Common tail of a hit and a landed miss (`flip_controller.finishPreview`),
/// plus the view half: the PR's cursor, and focus for an explicit open.
fn finishPreview(ctx: Ctx, params: struct { number: u32, view: flip.DiffView, key: ?types.DiffKey, already_seen: bool, load_failed: bool = false }) void {
    const moves_focus = ctx.flip.focus_diff and ctx.files.*.len > 0;
    flip_controller.finishPreview(flipCtx(ctx), .{
        .number = params.number,
        .view = params.view,
        .key = params.key,
        .already_seen = params.already_seen,
        .load_failed = params.load_failed,
        .moves_focus = moves_focus and ctx.mode.* != .normal,
    });
    if (params.view == .pr) restorePrCursor(ctx, params.number);
    if (moves_focus) ctx.mode.* = .normal;
    ctx.needs_render.* = true;
}

fn persistOutgoingPr(ctx: Ctx) void {
    flip_controller.persistOutgoing(flipCtx(ctx), .{
        .line_map = ctx.line_map,
        .cursor_line = ctx.cursor_line.*,
        .scroll_offset = ctx.scroll_offset.*,
    });
}

fn restorePrCursor(ctx: Ctx, number: u32) void {
    const recalled = flip.recallCursor(ctx.flip, .{ .number = number, .files = ctx.files.*, .line_map = ctx.line_map }) orelse return;
    ctx.cursor_line.* = recalled.cursor_line;
    ctx.scroll_offset.* = recalled.scroll_offset;
    ctx.host.clamp_scroll(ctx.host.ptr);
}

/// A gh error from the entry, sharing the status line with the discard
/// notice when an open editor was dropped so neither hides the other.
fn showEntryGhError(ctx: Ctx, params: struct { kind: github.GhErrorKind, discarded: bool }) void {
    if (!params.discarded) {
        ctx.host.show_error(ctx.host.ptr, github.kindMessage(params.kind));
        return;
    }
    var msg_buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "unsent comment discarded; {s}", .{github.kindMessage(params.kind)}) catch discarded_comment_message;
    ctx.host.show_error(ctx.host.ptr, msg);
}

/// Close a comment editor left open on the outgoing diff as a PR diff is
/// entered; returns whether its text was discarded. A local comment or
/// reply on a non-PR diff is saved into the outgoing store while
/// `files` is still the diff its anchors index. Everything else is
/// dropped: a GitHub draft or thread reply/edit belongs to the previous
/// PR's session and, saved later, would post to the entered PR; a local
/// comment on a PR diff (PR→PR) goes with that PR's store; and anything
/// open while an earlier surface change is pending has no store of its own.
fn settleCommentEditorForEntry(ctx: Ctx) bool {
    const input = ctx.active_comment_input.* orelse return false;
    const parking = ctx.parking;
    const saves_locally = parking.comments == null and !parking.pending() and switch (input.edit_context) {
        .none => input.target == .local,
        .local_reply => true,
        .reply, .edit_own => false,
    };
    const saved = saves_locally and ctx.host.save_open_comment(ctx.host.ptr);
    ctx.active_comment_input.* = null;
    if (saved) return false;
    ctx.host.show_error(ctx.host.ptr, discarded_comment_message);
    return true;
}

fn freeParsedFiles(allocator: Allocator, files: []parser.FileDiff) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}
