//! PR data for skim that stays free of SQLite: `gh`/`git` shell-outs, stack
//! detection and the native review session.
//!
//! Layering mirrors the rest of skim — a pure data core with a thin IO shell:
//!   - `parse`   : `CiStatus`, shared by the store, sync and the sidebar (pure)
//!   - `github`  : `gh`/`git` shell-outs
//!   - `filter`  : case-insensitive substring match (pure)
//!   - `stack`   : forge-native stacked-PR detection from base->head edges (pure)
//!   - `review_*`, `thread_hint` : the review session and its threads
//!   - `description` : PR body markdown -> display lines (pure)
//!   - `review_status` : approvers and check tally for the status line (pure)
//!
//! The PR list is the sidebar beside the diff: sync -> DB -> sidebar, and
//! prefetch -> diff cache -> flip, all driven by `surface.zig` (see
//! `db/`, `sync/`, `prefetch/`, `sidebar/`, `flip.zig`). None of it is
//! re-exported here: the store links SQLite, which this module and the wasm
//! build must stay free of. Those modules have their own test roots.

const std = @import("std");

pub const parse = @import("parse.zig");
pub const github = @import("github.zig");
pub const filter = @import("filter.zig");
pub const stack = @import("stack.zig");
pub const review_render = @import("review_render.zig");
pub const review_parse = @import("review_parse.zig");
pub const review_controller = @import("review_controller.zig");
pub const thread_hint = @import("thread_hint.zig");
pub const description = @import("description.zig");
pub const review_status = @import("review_status.zig");

pub const CiStatus = parse.CiStatus;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
