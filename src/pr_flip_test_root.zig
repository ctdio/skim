//! Test root for the pure PR flip modules (`pr/flip.zig`, `pr/notes.zig`).
//! Rooted at `src/` so they can reach `git/parser.zig` (tree-sitter),
//! `line_map.zig` and `comments/store.zig`.

const std = @import("std");

pub const flip = @import("pr/flip.zig");
pub const notes = @import("pr/notes.zig");

test {
    std.testing.refAllDecls(@This());
}
