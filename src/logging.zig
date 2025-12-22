const std = @import("std");
const fs = std.fs;

/// Log component type - determines which log file to use
pub const Component = enum {
    tui,
    daemon,
    mcp,
};

/// Global state for logging
var log_file: ?fs.File = null;
var log_mutex: std.Thread.Mutex = .{};
var initialized: bool = false;

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
    };

    const log_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.skim/{s}", .{ home, log_name }) catch return;
    defer std.heap.page_allocator.free(log_path);

    // Open log file (append mode)
    log_file = fs.createFileAbsolute(log_path, .{
        .truncate = false,
    }) catch return;

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
