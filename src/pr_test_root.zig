//! Test root for the `pr/` module. Rooted at `src/` so pr files can reach their
//! cross-directory imports (e.g. `review_render`/`review_controller` ->
//! `../rendering/width.zig`) — the `src/pr/`-rooted module cannot compile those.
//! Rooted *directly* by `addTest` (not imported by name) so every `pr` file's own
//! `test {}` blocks are pulled into the binary.

const std = @import("std");

pub const pr = @import("pr/pr.zig");
// The SQLite-free sidebar files carry inline render/layout tests.
pub const sidebar_layout = @import("pr/sidebar/layout.zig");
pub const sidebar_render = @import("pr/sidebar/render.zig");
pub const line_writer = @import("pr/line_writer.zig");

test {
    std.testing.refAllDecls(@This());
}
