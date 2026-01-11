const std = @import("std");
const fs = std.fs;

/// Maximum log file size before rotation (5MB)
const MAX_LOG_SIZE: u64 = 5 * 1024 * 1024;
/// Number of lines to keep after rotation
const KEEP_LINES: usize = 1000;

/// Log component type - determines which log file to use
pub const Component = enum {
    tui,
    daemon,
    mcp,
    acp, // ACP protocol debug logging (opt-in)
};

/// Global state for logging
var log_file: ?fs.File = null;
var log_mutex: std.Thread.Mutex = .{};
var initialized: bool = false;

/// Check if log file needs rotation (fast, synchronous)
fn needsRotation(log_path: []const u8) bool {
    const file = fs.openFileAbsolute(log_path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    return stat.size >= MAX_LOG_SIZE;
}

/// Perform the actual rotation (called from background thread)
fn doRotation(log_path_ptr: [*]const u8, log_path_len: usize) void {
    const log_path = log_path_ptr[0..log_path_len];
    const allocator = std.heap.page_allocator;

    // Read entire file
    const file = fs.openFileAbsolute(log_path, .{}) catch return;
    const stat = file.stat() catch {
        file.close();
        return;
    };
    const content = file.readToEndAlloc(allocator, @intCast(stat.size)) catch {
        file.close();
        return;
    };
    file.close();
    defer allocator.free(content);

    // Find last KEEP_LINES lines by scanning backwards for newlines
    var line_count: usize = 0;
    var start_pos: usize = content.len;

    while (start_pos > 0) {
        start_pos -= 1;
        if (content[start_pos] == '\n') {
            line_count += 1;
            if (line_count >= KEEP_LINES) {
                start_pos += 1; // Move past the newline
                break;
            }
        }
    }

    // Write truncated content to temp file, then rename
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{log_path}) catch return;
    defer allocator.free(tmp_path);

    const tmp_file = fs.createFileAbsolute(tmp_path, .{}) catch return;
    tmp_file.writeAll(content[start_pos..]) catch {
        tmp_file.close();
        fs.deleteFileAbsolute(tmp_path) catch {};
        return;
    };
    tmp_file.close();

    // Atomic rename
    fs.renameAbsolute(tmp_path, log_path) catch {
        fs.deleteFileAbsolute(tmp_path) catch {};
    };
}

/// Spawn background thread to rotate log file
fn spawnRotation(log_path: []const u8) void {
    // Copy path to heap for thread (will leak but rotation is rare)
    const path_copy = std.heap.page_allocator.dupe(u8, log_path) catch return;
    _ = std.Thread.spawn(.{}, doRotation, .{ path_copy.ptr, path_copy.len }) catch return;
}

/// Initialize logging for a specific component
/// Creates ~/.skim/ directory if needed and opens the log file
pub fn init(component: Component) void {
    if (initialized) return;

    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);

    // Ensure ~/.skim/ exists
    const skim_dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.skim", .{home}) catch return;
    defer std.heap.page_allocator.free(skim_dir);

    fs.makeDirAbsolute(skim_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    // Determine log file name
    const log_name = switch (component) {
        .tui => "tui.log",
        .daemon => "daemon.log",
        .mcp => "mcp.log",
        .acp => "acp.log",
    };

    const log_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.skim/{s}", .{ home, log_name }) catch return;

    // Check if rotation needed (fast stat), spawn async if so
    const needs_rotate = needsRotation(log_path);

    // Open log file immediately (don't block on rotation)
    log_file = fs.createFileAbsolute(log_path, .{
        .truncate = false,
    }) catch {
        std.heap.page_allocator.free(log_path);
        return;
    };

    // Spawn rotation in background after opening file
    // Our handle stays valid (points to old inode), new instances get rotated file
    if (needs_rotate) {
        spawnRotation(log_path);
    }
    std.heap.page_allocator.free(log_path);

    // Seek to end for append
    if (log_file) |f| {
        f.seekFromEnd(0) catch {};
    }

    initialized = true;
}

/// Close the log file
pub fn deinit() void {
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
    initialized = false;
}

/// Buffer for formatting log messages
var format_buffer: [8192]u8 = undefined;

/// Custom log function that writes to file instead of stderr
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_mutex.lock();
    defer log_mutex.unlock();

    const file = log_file orelse return;

    // Get timestamp
    const timestamp = std.time.timestamp();
    const hours = @mod(@divFloor(timestamp, 3600), 24);
    const minutes = @mod(@divFloor(timestamp, 60), 60);
    const seconds = @mod(timestamp, 60);

    // Format: [HH:MM:SS] [LEVEL] (scope) message
    const level_str = switch (level) {
        .err => "ERROR",
        .warn => "WARN ",
        .info => "INFO ",
        .debug => "DEBUG",
    };

    const scope_str = if (scope == .default) "" else @tagName(scope);

    // Format the entire log line into buffer
    var fbs = std.io.fixedBufferStream(&format_buffer);
    const writer = fbs.writer();

    // Write timestamp and level
    writer.print("[+{d}:+{d}:+{d}] [{s}]", .{ hours, minutes, seconds, level_str }) catch return;

    // Write scope if not default
    if (scope_str.len > 0) {
        writer.print(" ({s})", .{scope_str}) catch return;
    }

    // Write message
    writer.print(" ", .{}) catch return;
    writer.print(format, args) catch return;
    writer.print("\n", .{}) catch return;

    // Write directly to file
    const written = fbs.getWritten();
    _ = file.write(written) catch return;
}

/// Get the path to a log file
pub fn getLogPath(allocator: std.mem.Allocator, component: Component) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const log_name = switch (component) {
        .tui => "tui.log",
        .daemon => "daemon.log",
        .mcp => "mcp.log",
    };

    return std.fmt.allocPrint(allocator, "{s}/.skim/{s}", .{ home, log_name });
}
