//! Test root for the prefetch modules (src/pr/prefetch/). Rooted at `src/` so
//! `parsed_lru.zig` can reach `git/parser.zig` (tree-sitter) and
//! `prefetch.zig` can reach `pr/db/store.zig` (SQLite); both are linked by the
//! `pr_prefetch_tests` step in build.zig.

const std = @import("std");

pub const plan = @import("pr/prefetch/plan.zig");
pub const priority = @import("pr/prefetch/priority.zig");
pub const parsed_lru = @import("pr/prefetch/parsed_lru.zig");
pub const prefetch = @import("pr/prefetch/prefetch.zig");

test {
    std.testing.refAllDecls(@This());
}
