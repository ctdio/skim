const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.clipboard);
const platform = @import("platform.zig");
const skim_io = @import("skim_io");

var tty_file: ?std.Io.File = null;

pub fn setTtyFile(file: std.Io.File) void {
    tty_file = file;
}

/// Copy content to system clipboard via OSC 52 (if tty available) with
/// platform-appropriate command fallback. Never crashes on failure.
pub fn copyToClipboard(allocator: Allocator, content: []const u8) !void {
    // The browser build has no tty and no processes, and wasm cannot reach the
    // page clipboard on its own. A copy there does nothing.
    if (platform.is_web) return;

    if (tty_file) |file| {
        writeOsc52(allocator, file, content) catch |err| {
            log.warn("OSC 52 clipboard write failed: {}", .{err});
        };
    }

    // Also attempt platform tool — works as primary when no tty,
    // and as a belt-and-suspenders backup when OSC 52 is available.
    copyViaCommand(content) catch |err| {
        log.debug("platform clipboard command failed: {}", .{err});
        // If we already wrote via OSC 52, this is fine.
        // If we didn't, propagate the error.
        if (tty_file == null) return err;
    };
}

/// Read content from system clipboard using platform-appropriate command.
/// Returns null on failure.
pub fn readFromClipboard(allocator: Allocator) ?[]const u8 {
    if (platform.is_web) return null;

    return readViaCommand(allocator) catch |err| {
        log.debug("platform clipboard read failed: {}", .{err});
        return null;
    };
}

// --- OSC 52 ---

fn writeOsc52(allocator: Allocator, file: std.Io.File, content: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(content.len);

    // OSC 52: \x1b]52;c;<base64>\x1b\\
    const prefix = "\x1b]52;c;";
    const suffix = "\x1b\\";
    const total_len = prefix.len + encoded_len + suffix.len;

    const buf = try allocator.alloc(u8, total_len);
    defer allocator.free(buf);

    @memcpy(buf[0..prefix.len], prefix);
    _ = encoder.encode(buf[prefix.len .. prefix.len + encoded_len], content);
    @memcpy(buf[prefix.len + encoded_len ..], suffix);

    try file.writeStreamingAll(skim_io.get(), buf);
}

// --- Platform commands ---

const CopyCommand = struct {
    argv: []const []const u8,
};

fn copyCommands() []const CopyCommand {
    if (comptime builtin.os.tag == .macos) {
        return &.{
            .{ .argv = &.{"pbcopy"} },
        };
    } else {
        // Linux: try each in order until one succeeds
        return &.{
            .{ .argv = &.{ "xclip", "-selection", "clipboard" } },
            .{ .argv = &.{ "xsel", "--clipboard", "--input" } },
            .{ .argv = &.{"wl-copy"} },
        };
    }
}

fn copyViaCommand(content: []const u8) !void {
    for (copyCommands()) |cmd| {
        if (spawnCopyChild(cmd.argv, content)) |_| {
            return;
        } else |_| {
            continue;
        }
    }
    return error.NoClipboardCommandAvailable;
}

fn spawnCopyChild(argv: []const []const u8, content: []const u8) !void {
    var child = try std.process.spawn(skim_io.get(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(skim_io.get(), content) catch {};
        stdin.close(skim_io.get());
        child.stdin = null;
    }

    _ = try child.wait(skim_io.get());
}

const PasteCommand = struct {
    argv: []const []const u8,
};

fn pasteCommands() []const PasteCommand {
    if (comptime builtin.os.tag == .macos) {
        return &.{
            .{ .argv = &.{"pbpaste"} },
        };
    } else {
        return &.{
            .{ .argv = &.{ "xclip", "-selection", "clipboard", "-o" } },
            .{ .argv = &.{ "xsel", "--clipboard", "--output" } },
            .{ .argv = &.{"wl-paste"} },
        };
    }
}

fn readViaCommand(allocator: Allocator) ![]const u8 {
    for (pasteCommands()) |cmd| {
        if (spawnPasteChild(allocator, cmd.argv)) |output| {
            return output;
        } else |_| {
            continue;
        }
    }
    return error.NoClipboardCommandAvailable;
}

fn spawnPasteChild(allocator: Allocator, argv: []const []const u8) ![]const u8 {
    var child = try std.process.spawn(skim_io.get(), .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    const stdout = child.stdout.?;
    const output = try skim_io.readAllAlloc(stdout, allocator, 1024 * 1024);

    _ = try child.wait(skim_io.get());

    return output;
}
