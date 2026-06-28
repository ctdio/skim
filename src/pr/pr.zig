//! PR browsing for skim: an interactive picker over open pull requests (via the
//! GitHub CLI) that hands a selected PR to skim's diff view.
//!
//! Layering mirrors the rest of skim — a pure data core (parse/filter/authors)
//! with a thin IO shell (github/cache) and a vaxis TUI (render/picker):
//!   - `parse`   : `gh pr list` JSON -> domain PullRequest values (pure)
//!   - `github`  : `gh`/`git` shell-outs (the only PR-layer IO)
//!   - `cache`   : on-disk stale-while-revalidate cache of the raw listing
//!   - `filter`  : live text + author filtering (pure)
//!   - `authors` : distinct-author tally for the filter overlay (pure)
//!   - `stack`   : forge-native stacked-PR detection from base->head edges (pure)
//!   - `render`  : draws the picker into a vaxis window (pure drawing)
//!
//! The picker itself is no longer a standalone vaxis app: PR review is a native
//! mode of the main skim App (see `app.zig` / `modes/pr_review_mode.zig`), which
//! reuses these data and render modules and swaps the diff in-process.

const std = @import("std");

pub const parse = @import("parse.zig");
pub const github = @import("github.zig");
pub const cache = @import("cache.zig");
pub const filter = @import("filter.zig");
pub const authors = @import("authors.zig");
pub const stack = @import("stack.zig");
pub const render = @import("render.zig");

pub const PullRequest = parse.PullRequest;
pub const PullRequestList = parse.PullRequestList;
pub const CiStatus = parse.CiStatus;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
