//! Shared git shell-out for the PR data layer. The PR surface (`surface.zig`)
//! and the GitHub backend (`github.zig`) both need to resolve repo identity
//! from a single line of `git` stdout, so the helper lives here rather than in
//! either.

const std = @import("std");
const skim_io = @import("skim_io");

/// Stable identity for the repo in the process cwd: the origin remote URL when
/// present, else the repo root path. Null outside a git repo. Caller owns.
/// Used as `repo.key` in the PR database.
pub fn repoKey(allocator: std.mem.Allocator) ?[]u8 {
    if (line(allocator, &.{ "git", "config", "--get", "remote.origin.url" })) |url| return url;
    return line(allocator, &.{ "git", "rev-parse", "--show-toplevel" });
}

/// Run a git command and return its single trimmed line of stdout, or null on
/// any failure/empty output. Caller owns the result.
pub fn line(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(allocator, skim_io.get(), .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;

    const trimmed = std.mem.trimEnd(u8, result.stdout, " \r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}
