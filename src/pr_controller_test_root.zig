//! Test root for `pr/controller.zig`. Rooted at `src/` so it can reach the
//! controller's `../git/graphite.zig` import across directory boundaries — the
//! `src/pr/`-rooted `pr_tests` module cannot compile the controller for that
//! reason, which is why its tests live behind this dedicated step. Rooted
//! *directly* by `addTest` (not imported by name) so the controller's own
//! `test {}` blocks are pulled into the binary.

const std = @import("std");

pub const controller = @import("pr/controller.zig");

test {
    std.testing.refAllDecls(@This());
}
