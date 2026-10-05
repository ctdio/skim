//! PR data for skim: `gh` listing/review IO, parsing, stack detection and
//! the native review session.
//!
//! Layering mirrors the rest of skim — a pure data core with a thin IO shell:
//!   - `parse`   : `gh pr list` JSON -> domain PullRequest values (pure)
//!   - `github`  : `gh`/`git` shell-outs (the only PR-layer IO)
//!   - `cache`   : on-disk stale-while-revalidate cache of the raw listing
//!   - `filter`  : live text filtering (pure)
//!   - `stack`   : forge-native stacked-PR detection from base->head edges (pure)
//!
//! The PR list itself is the sidebar beside the diff (`sidebar/`, driven by
//! `surface.zig` and `modes/pr_review_mode.zig`). It is not re-exported here:
//! the surface links SQLite, which this module must stay free of.

const std = @import("std");

pub const parse = @import("parse.zig");
pub const github = @import("github.zig");
pub const cache = @import("cache.zig");
pub const filter = @import("filter.zig");
pub const stack = @import("stack.zig");
pub const review_render = @import("review_render.zig");
pub const review_parse = @import("review_parse.zig");
pub const review_controller = @import("review_controller.zig");
pub const thread_hint = @import("thread_hint.zig");

pub const PullRequest = parse.PullRequest;
pub const PullRequestList = parse.PullRequestList;
pub const CiStatus = parse.CiStatus;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
