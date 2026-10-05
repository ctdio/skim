//! Plain data types shared by the PR store and everything that reads its rows.
//!
//! This file must never import SQLite (directly or through `store.zig`,
//! `sqlite.zig`, `config.zig` or `github.zig`): the sidebar, filter, flip and
//! notes-mapping code compile into the wasm build through `app.zig` and name
//! these types, and the wasm module cannot resolve `sqlite_c`. `store.zig`
//! re-exports every declaration here for callers that already hold a `Store`.

const std = @import("std");
const parse = @import("../parse.zig");

/// Stored as 'OPEN' | 'CLOSED' | 'MERGED' in `pr.state`.
pub const PrState = enum { open, closed, merged };

/// Same tag names as `github.GhErrorKind`. `repo.last_sync_error` stores the
/// tag name as text (the sync worker writes `@tagName(kind)`); readers parse it with
/// `std.meta.stringToEnum(SyncErrorKind, name)` (null for an unknown/NULL value).
/// A test in `src/pr_db_test_root.zig` asserts both enums have the same fields.
pub const SyncErrorKind = enum { not_installed, not_authenticated, not_found, rate_limited, network, other };

/// Diff cache identity: SHA-1 hex of the merge base and the PR head.
pub const DiffKey = struct {
    merge_base_oid: [40]u8,
    head_oid: [40]u8,
};

/// One `pr` row as the sidebar/filter/flip see it. Strings borrow from the
/// owning `RecordList.arena`. '\n'-joined columns stay joined (iterate with
/// `listItems`). `seen_*` come from a LEFT JOIN on `pr_seen` (null = never seen).
pub const PrRecord = struct {
    number: u32,
    node_id: []const u8,
    state: PrState,
    title: []const u8,
    author: []const u8,
    url: []const u8,
    is_draft: bool,
    head_ref: []const u8,
    base_ref: []const u8,
    head_oid: []const u8,
    base_oid: []const u8,
    updated_at: []const u8,
    hydrated_at_update: ?[]const u8,
    additions: u32,
    deletions: u32,
    changed_files: u32,
    review_decision: []const u8,
    ci: parse.CiStatus,
    labels: []const u8,
    requested_users: []const u8,
    requested_teams: []const u8,
    my_review_state: []const u8,
    my_review_oid: []const u8,
    seen_head_oid: ?[]const u8,
    seen_merge_base_oid: ?[]const u8,
};

pub const RecordList = struct {
    arena: std.heap.ArenaAllocator,
    items: []PrRecord,

    pub fn deinit(self: *RecordList) void {
        self.arena.deinit();
    }
};

/// Row from the cheap index sync pass. Always OPEN.
pub const IndexRow = struct {
    number: u32,
    node_id: []const u8,
    title: []const u8,
    author: []const u8,
    url: []const u8,
    is_draft: bool,
    head_ref: []const u8,
    base_ref: []const u8,
    head_oid: []const u8,
    base_oid: []const u8,
    updated_at: []const u8,
    /// '\n'-joined label names.
    labels: []const u8,
};

/// Row from the hydrate sync pass (the expensive per-PR fields). `updated_at`
/// is the PR's updatedAt the hydrate query saw; it is stored as
/// `hydrated_at_update`.
pub const HydrateRow = struct {
    number: u32,
    updated_at: []const u8,
    additions: u32,
    deletions: u32,
    changed_files: u32,
    review_decision: []const u8,
    ci: parse.CiStatus,
    /// '\n'-joined logins.
    requested_users: []const u8,
    /// '\n'-joined "org/slug".
    requested_teams: []const u8,
    my_review_state: []const u8,
    my_review_oid: []const u8,
};

pub const ClosedRow = struct {
    number: u32,
    /// `.closed` or `.merged`.
    state: PrState,
    updated_at: []const u8,
};

/// A PR whose hydrate fields are missing or stale. `node_id` is the
/// `nodes(ids:)` argument. Strings borrow from the owning `NodeRefList.arena`.
pub const NodeRef = struct {
    number: u32,
    node_id: []const u8,
    updated_at: []const u8,
};

pub const NodeRefList = struct {
    arena: std.heap.ArenaAllocator,
    items: []NodeRef,

    pub fn deinit(self: *NodeRefList) void {
        self.arena.deinit();
    }
};

pub const RepoRow = struct {
    id: i64,
    key: []const u8,
    owner: []const u8,
    name: []const u8,
    viewer_login: ?[]const u8,
    /// '\n'-joined "org/slug".
    viewer_teams: []const u8,
    teams_synced_at: i64,
    open_watermark: ?[]const u8,
    closed_watermark: ?[]const u8,
    last_sync_at: i64,
    /// A `SyncErrorKind` tag name, or null after a successful sync.
    last_sync_error: ?[]const u8,
};

/// A `RepoRow` whose strings borrow from `arena`.
pub const OwnedRepo = struct {
    arena: std.heap.ArenaAllocator,
    row: RepoRow,

    pub fn deinit(self: *OwnedRepo) void {
        self.arena.deinit();
    }
};

pub const SeenRow = struct {
    head_oid: [40]u8,
    merge_base_oid: [40]u8,
    seen_at: i64,
};

/// Merge-base cache lookup key. A merge base is a pure function of two commit
/// ids, so rows never go stale (they are deleted only with their repo).
/// `base_tip_oid`: trunk PR → pr.base_oid; stacked PR → parent pr.head_oid;
/// whole stack → bottom pr.base_oid. The key is ordered: (a, b) and (b, a) are
/// different entries.
pub const OidPair = struct {
    base_tip_oid: []const u8,
    head_oid: []const u8,
};

pub const MergeBaseEntry = struct {
    base_tip_oid: []const u8,
    head_oid: []const u8,
    merge_base_oid: []const u8,
};

/// Staleness probe for `thread_cache` without loading the JSON blob.
pub const ThreadRef = struct {
    number: u32,
    pr_updated_at: []const u8,
};

/// Both slices are owned by the allocator passed to `Store.getThreads`.
pub const CachedThreads = struct {
    pr_updated_at: []u8,
    json: []u8,

    pub fn deinit(self: CachedThreads, allocator: std.mem.Allocator) void {
        allocator.free(self.pr_updated_at);
        allocator.free(self.json);
    }
};

/// One `local_note` row. Line numbers mirror parser.Line old/new numbering.
pub const NoteRow = struct {
    id: i64,
    number: u32,
    file_path: []const u8,
    /// parser.Line.LineType tag name.
    line_type: []const u8,
    old_lineno: ?u32,
    new_lineno: ?u32,
    end_old_lineno: ?u32,
    end_new_lineno: ?u32,
    line_content: []const u8,
    author: []const u8,
    text: []const u8,
    /// JSON array `[{author,text}]`.
    replies: []const u8,
    created_at: i64,
};

pub const NoteList = struct {
    arena: std.heap.ArenaAllocator,
    items: []NoteRow,

    pub fn deinit(self: *NoteList) void {
        self.arena.deinit();
    }
};

/// Iterate a '\n'-joined column (`labels`, `requested_users`, ...). Skips
/// nothing: "" yields one empty item, so check `joined.len == 0` first when an
/// empty column means "no items".
pub fn listItems(joined: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, joined, '\n');
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "listItems splits a newline-joined list" {
    var it = listItems("a\nb");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "listItems yields one empty item for an empty string" {
    var it = listItems("");
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "listItems keeps empty items between consecutive separators" {
    var it = listItems("a\n\nb");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}
