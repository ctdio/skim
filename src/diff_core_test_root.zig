//! Test root for the core diff data path: the unified-diff parser, the LineMap
//! record registry, the comment store, and the streaming diff loader.
//!
//! These four modules are reachable from `main.zig` only through `app.zig`, and
//! a transitively-imported file does not reliably contribute its `test {}`
//! blocks to the `main.zig`-rooted binary (see the note on `width_tests` in
//! build.zig). Rooted *directly* by `addTest` so every listed file's own tests
//! are pulled in. Rooted at `src/` so `git/parser.zig` can reach
//! `../highlighting/core.zig`.

const std = @import("std");

pub const parser = @import("git/parser.zig");
pub const diff_loader = @import("git/diff_loader.zig");
pub const line_map = @import("line_map.zig");
pub const comment_store = @import("comments/store.zig");

test {
    std.testing.refAllDecls(@This());
}
