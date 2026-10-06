//! Web stand-in for `surface.zig`: the same public API with no store, no
//! workers and no subprocesses, so the wasm build never analyzes SQLite
//! (D4). `:pr` is not offered on web, so `open` is unreachable in practice:
//! every flip is a miss and nothing is persisted.

const std = @import("std");
const sidebar_state = @import("sidebar/state.zig");
const types = @import("db/types.zig");
const parser = @import("../git/parser.zig");
const comments = @import("../comments/store.zig");
const flip = @import("flip.zig");
const notes = @import("notes.zig");
const review_controller = @import("review_controller.zig");
const ParsedLru = @import("prefetch/parsed_lru.zig").ParsedLru;

const Allocator = std.mem.Allocator;
const SidebarState = sidebar_state.SidebarState;

pub const Surface = struct {};

pub const OpenParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
    gh_bin: []const u8 = "gh",
    prefetch_gh_bin: []const u8 = "gh",
    repo_root: []const u8 = ".",
};

pub const ReloadParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
};

pub const SeenParams = struct {
    allocator: Allocator,
    number: u32,
    sidebar: *SidebarState,
    now: i64,
};

pub const PlanParams = struct {
    allocator: Allocator,
    sidebar: *const SidebarState,
    record: *const types.PrRecord,
    view: flip.DiffView,
    lru: ?*ParsedLru,
    now: i64,
};

pub const FlipHit = struct {
    files: []parser.FileDiff,
    key: types.DiffKey,
    threads: ?types.CachedThreads,
    threads_fresh: bool,
    stack_base_ref: []const u8,

    pub fn deinit(self: *FlipHit, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const FlipPlan = union(enum) {
    hit: FlipHit,
    miss,

    pub fn deinit(self: *FlipPlan, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const SeenComparison = enum { unchanged, fast_forward, rewritten, pending };

pub const SaveNotesParams = struct {
    allocator: Allocator,
    number: u32,
    comments: *const comments.CommentStore,
    files: []const parser.FileDiff,
    note_ids: *std.AutoHashMapUnmanaged(u64, i64),
    now: i64,
};

pub const RestoreNotesParams = struct {
    allocator: Allocator,
    number: u32,
    files: []const parser.FileDiff,
    comments: *comments.CommentStore,
    orphans: *std.ArrayList(notes.OrphanNote),
    note_ids: *std.AutoHashMapUnmanaged(u64, i64),
};

pub const ChangedFilesParams = struct {
    allocator: Allocator,
    sidebar: *const SidebarState,
    number: u32,
    current: []const parser.FileDiff,
    lru: ?*ParsedLru,
    now: i64,
};

pub const unknown_merge_base: [40]u8 = @splat('0');

pub fn open(surface: *Surface, params: OpenParams) void {
    _ = surface;
    params.sidebar.unavailable = .not_github;
}

pub fn reload(surface: *Surface, params: ReloadParams) !void {
    _ = surface;
    _ = params;
}

pub fn pushVisible(surface: *Surface, params: ReloadParams) void {
    _ = surface;
    _ = params;
}

pub fn poll(surface: *Surface, params: ReloadParams) bool {
    _ = surface;
    _ = params;
    return false;
}

pub fn wantsTick(surface: *const Surface) bool {
    _ = surface;
    return false;
}

pub fn requestSync(surface: *Surface) void {
    _ = surface;
}

pub fn openInBrowser(surface: *const Surface, sidebar: *const SidebarState) void {
    _ = surface;
    _ = sidebar;
}

pub fn focusPrefetch(surface: *Surface, sidebar: *const SidebarState) void {
    _ = surface;
    _ = sidebar;
}

pub fn planFlip(surface: *Surface, params: PlanParams) !FlipPlan {
    _ = surface;
    _ = params;
    return .miss;
}

pub fn markSeen(surface: *Surface, params: SeenParams) void {
    _ = surface;
    _ = params;
}

pub fn toggleSeen(surface: *Surface, params: SeenParams) void {
    _ = surface;
    _ = params;
}

pub fn seenComparison(surface: *Surface, params: struct { sidebar: *const SidebarState, number: u32 }) SeenComparison {
    _ = surface;
    _ = params;
    return .unchanged;
}

pub fn changedFiles(surface: *Surface, params: ChangedFilesParams) ![]bool {
    _ = surface;
    return params.allocator.alloc(bool, 0);
}

pub fn saveNotes(surface: *Surface, params: SaveNotesParams) !void {
    _ = surface;
    _ = params;
}

/// No store: the PR has no persisted notes, so the store stays empty.
pub fn restoreNotes(surface: *Surface, params: RestoreNotesParams) !void {
    _ = surface;
    try notes.restore(.{
        .allocator = params.allocator,
        .notes = &.{},
        .files = params.files,
        .comments = params.comments,
        .orphans = params.orphans,
        .note_ids = params.note_ids,
    });
}

pub fn shareOwnerRepo(surface: *Surface, params: struct { allocator: Allocator, review: *review_controller.ReviewSession }) void {
    _ = surface;
    _ = params;
}

pub fn close(surface: *Surface) void {
    _ = surface;
}
