//! State for the PR sidebar (`App.state.sidebar`): the DB snapshot it shows,
//! the filtered rows, the cursor, the filter prompt and the sync status line.
//! Pure data. Every import here is SQLite-free (D4): the wasm build compiles
//! this file through `app.zig`, so it never reaches `store.zig`, `sync/` or
//! `github.zig`. Logic lives in `controller.zig`.

const std = @import("std");
const types = @import("../db/types.zig");
const filter_query = @import("../filter_query.zig");
const stack = @import("../stack.zig");

pub const RowKind = enum { stack_header, member };

/// One rendered line in the list. `stack` indexes `SidebarState.stacks.views`;
/// `record` indexes `records.items` (for a header row: the stack's review target).
pub const Row = struct {
    kind: RowKind,
    stack: u32,
    record: u32,
};

/// Point-in-time copy of the sync worker's status, mapped by `surface.zig` so
/// this file never imports sync/ or github.zig.
pub const SyncSnapshot = struct {
    running: bool = false,
    /// Unix seconds of the last successful sync; null = never.
    last_ok_at: ?i64 = null,
    last_error: ?types.SyncErrorKind = null,
    /// Static `github.kindMessage` text for `last_error`, filled by surface.zig.
    last_error_message: []const u8 = "",
};

pub const Unavailable = enum { none, not_github, gh_missing, gh_unauthenticated, db_error };

/// Allocator-owned copy of a `config.PrFilterPreset`.
pub const Preset = struct {
    name: []const u8,
    query: []const u8,
};

pub const query_cap = 256;

pub const Prompt = struct {
    buf: [query_cap]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Prompt) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const ParseErrorView = struct {
    reason: filter_query.ParseErrorReason,
    /// `ParseError.format` output, rendered when the query was applied because
    /// `ParseError.term` slices the prompt text, which is not kept.
    text: [128]u8 = undefined,
    text_len: usize = 0,

    pub fn message(self: *const ParseErrorView) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const SidebarState = struct {
    // Surface lifecycle. Focus is not stored here: it is `App.mode`
    // (`.pr_review` = sidebar focused, AD-8).
    /// Sidebar column drawn (Ctrl-b toggles).
    visible: bool = false,
    /// PR surface active (`skim pr` / `:pr`); `visible` may be false while open.
    open: bool = false,
    /// Launched as `skim pr`: leaving the sidebar quits.
    pr_only: bool = false,
    /// `skim pr <n>`: select and enter this PR once the surface opens.
    boot_number: ?u32 = null,
    unavailable: Unavailable = .none,

    // DB snapshot (AD-4), replaced wholesale on reload. `viewer_login` and
    // `viewer_teams` are copies in `records.arena`.
    records: ?types.RecordList = null,
    analysis: ?stack.Analysis = null,
    viewer_login: []const u8 = "",
    /// '\n'-joined "org/slug".
    viewer_teams: []const u8 = "",

    // Filtered view, rebuilt by `controller.rebuildRows`.
    stacks: filter_query.VisibleStacks = .{ .views = &.{}, .member_storage = &.{} },
    rows: std.ArrayList(Row) = .empty,
    /// Expanded stacks, keyed by tip PR number so expansion survives reloads.
    expanded: std.AutoHashMapUnmanaged(u32, void) = .{},

    // Cursor. `selected_number` is the identity the cursor follows across
    // reloads; `cursor_on_header` keeps it on a header row rather than the
    // same PR's member row.
    cursor: usize = 0,
    scroll: usize = 0,
    selected_number: ?u32 = null,
    cursor_on_header: bool = false,
    /// Set when `selected_number` changes; consumed by `takeCursorChanged`.
    cursor_changed: bool = false,
    pending_g: bool = false,
    pending_z: bool = false,

    // Filter. `query` is the text of the last good query.
    query: [query_cap]u8 = undefined,
    query_len: usize = 0,
    active_query: ?filter_query.Query = null,
    parse_error: ?ParseErrorView = null,
    /// Non-null while the `f` prompt is open.
    prompt: ?Prompt = null,
    presets: []Preset = &.{},
    /// Null = custom query.
    active_preset: ?usize = null,
    /// The last preset that was active; Esc returns a custom query to it.
    base_preset: usize = 0,

    // Status
    sync: SyncSnapshot = .{},
    message: [128]u8 = undefined,
    message_len: usize = 0,

    pub fn queryText(self: *const SidebarState) []const u8 {
        return self.query[0..self.query_len];
    }

    pub fn messageText(self: *const SidebarState) []const u8 {
        return self.message[0..self.message_len];
    }
};
