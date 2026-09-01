//! Test root for `highlighting/scheduler.zig`. Rooted at `src/` so it can reach
//! the scheduler's `../git/parser.zig` and `../state.zig` imports across
//! directory boundaries. Rooted *directly* by `addTest` (not imported by name)
//! so the scheduler's own `test {}` blocks are pulled into the binary.

const std = @import("std");

pub const scheduler = @import("highlighting/scheduler.zig");

test {
    std.testing.refAllDecls(@This());
}
