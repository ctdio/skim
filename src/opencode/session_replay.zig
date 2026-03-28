const std = @import("std");
const OpencodeManager = @import("manager.zig").OpencodeManager;

pub fn loadReplayLines(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(content);

    return loadReplayLinesFromString(allocator, content);
}

pub fn loadReplayLinesFromString(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var lines_out: std.ArrayList([]const u8) = .{};
    var current: std.ArrayList(u8) = .{};
    errdefer {
        current.deinit(allocator);
        for (lines_out.items) |line| allocator.free(line);
        lines_out.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (isReplayEventStart(trimmed)) {
            if (current.items.len > 0) {
                try lines_out.append(allocator, try current.toOwnedSlice(allocator));
                current = .{};
            }
            try current.appendSlice(allocator, trimmed);
            continue;
        }

        if (current.items.len == 0) {
            try current.appendSlice(allocator, trimmed);
            continue;
        }

        try current.appendSlice(allocator, trimmed);
    }

    if (current.items.len > 0) {
        try lines_out.append(allocator, try current.toOwnedSlice(allocator));
    }

    return lines_out.toOwnedSlice(allocator);
}

pub fn freeReplayLines(allocator: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

pub fn configureReplayManager(allocator: std.mem.Allocator, mgr: *OpencodeManager, path: []const u8) !void {
    const session_id = extractSessionIdFromPath(path) orelse return;

    if (mgr.session_id) |existing| {
        allocator.free(existing);
        mgr.session_id = null;
    }

    mgr.session_id = try allocator.dupe(u8, session_id);
}

pub fn replaySessionLine(mgr: *OpencodeManager, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    const payload = stripTimestampPrefix(trimmed);
    if (payload.len == 0) return;

    mgr.replayEventData(payload);
}

fn isReplayEventStart(line: []const u8) bool {
    return line.len >= 2 and line[0] == '[' and std.mem.indexOf(u8, line, "] ") != null;
}

fn stripTimestampPrefix(line: []const u8) []const u8 {
    if (line.len == 0 or line[0] != '[') return line;

    const end_idx = std.mem.indexOf(u8, line, "] ") orelse return line;
    return line[end_idx + 2 ..];
}

fn extractSessionIdFromPath(path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, basename, "ses_")) return null;
    if (!std.mem.endsWith(u8, basename, ".log")) return null;
    return basename["ses_".len .. basename.len - ".log".len];
}

test "loadReplayLinesFromString groups multiline events" {
    const allocator = std.testing.allocator;

    const log =
        \\[12:00:00.000] {"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_demo","type":"text","text":"hello"}}}}
        \\[12:00:00.100] {"type":"session.idle","properties":{"sessionID":"ses_demo"}}
    ;

    const lines = try loadReplayLinesFromString(allocator, log);
    defer freeReplayLines(allocator, lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "\"sessionID\":\"ses_demo\"") != null);
}

test "extractSessionIdFromPath strips replay filename wrapper" {
    try std.testing.expectEqualStrings(
        "ses_demo",
        extractSessionIdFromPath("/tmp/ses_ses_demo.log").?,
    );
}
