//! Shared git shell-out for the PR data layer. The disk cache (`cache.zig`) and
//! the GitHub backend (`github.zig`) both need to resolve repo identity from a
//! single line of `git` stdout, so the helper lives here rather than in either.

const std = @import("std");

/// Run a git command and return its single trimmed line of stdout, or null on
/// any failure/empty output. Caller owns the result.
pub fn line(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;

    const trimmed = std.mem.trimRight(u8, result.stdout, " \r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}
