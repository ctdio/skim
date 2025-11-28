const std = @import("std");
const Allocator = std.mem.Allocator;

/// Copy content to system clipboard using platform-appropriate command
/// Currently supports macOS (pbcopy)
pub fn copyToClipboard(allocator: Allocator, content: []const u8) !void {
    const argv = [_][]const u8{"pbcopy"};
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    if (child.stdin) |stdin| {
        try stdin.writeAll(content);
        stdin.close();
        child.stdin = null;
    }

    _ = try child.wait();
}
