const std = @import("std");
const skim_io = @import("skim_io");

const Dir = std.Io.Dir;
const File = std.Io.File;

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
    opencode, // Opencode agent integration logging
};

/// Global state for logging
var log_file: ?File = null;
/// Append position. 0.16 dropped `File.seek`, so the write offset is tracked
/// here and advanced under `log_mutex` instead.
var log_offset: u64 = 0;
var log_mutex: std.Io.Mutex = .init;
var initialized: bool = false;

/// Check if log file needs rotation (fast, synchronous)
fn needsRotation(log_path: []const u8) bool {
    const io = skim_io.get();
    const file = Dir.openFileAbsolute(io, log_path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    return stat.size >= MAX_LOG_SIZE;
}

/// Perform the actual rotation (called from background thread)
fn doRotation(log_path_ptr: [*]const u8, log_path_len: usize) void {
    const log_path = log_path_ptr[0..log_path_len];
    const allocator = std.heap.page_allocator;

    // Read entire file
    const io = skim_io.get();
    const content = Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(MAX_LOG_SIZE * 2)) catch return;
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

    const tmp_file = Dir.createFileAbsolute(io, tmp_path, .{}) catch return;
    tmp_file.writePositionalAll(io, content[start_pos..], 0) catch {
        tmp_file.close(io);
        Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return;
    };
    tmp_file.close(io);

    // Atomic rename
    Dir.renameAbsolute(tmp_path, log_path, io) catch {
        Dir.deleteFileAbsolute(io, tmp_path) catch {};
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

    const io = skim_io.get();
    const home = skim_io.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);

    // Ensure ~/.skim/ exists
    const skim_dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.skim", .{home}) catch return;
    defer std.heap.page_allocator.free(skim_dir);

    Dir.createDirAbsolute(io, skim_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    // Determine log file name
    const log_name = switch (component) {
        .tui => "tui.log",
        .daemon => "daemon.log",
        .mcp => "mcp.log",
        .acp => "acp.log",
        .opencode => "opencode.log",
    };

    const log_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.skim/{s}", .{ home, log_name }) catch return;

    // Check if rotation needed (fast stat), spawn async if so
    const needs_rotate = needsRotation(log_path);

    // Open log file immediately (don't block on rotation)
    log_file = Dir.createFileAbsolute(io, log_path, .{
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

    // Start appending past whatever the previous run left behind.
    log_offset = if (log_file) |f| blk: {
        const stat = f.stat(io) catch break :blk 0;
        break :blk stat.size;
    } else 0;

    initialized = true;
}

/// Close the log file
pub fn deinit() void {
    if (log_file) |f| {
        f.close(skim_io.get());
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
    const io = skim_io.get();
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);

    const file = log_file orelse return;

    // Get timestamp
    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
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
    var fbs: std.Io.Writer = .fixed(&format_buffer);
    const writer = &fbs;

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
    const written = fbs.buffered();
    file.writePositionalAll(io, written, log_offset) catch return;
    log_offset += written.len;
}

/// Get the path to a log file
pub fn getLogPath(allocator: std.mem.Allocator, component: Component) ![]u8 {
    const home = try skim_io.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const log_name = switch (component) {
        .tui => "tui.log",
        .daemon => "daemon.log",
        .mcp => "mcp.log",
        .acp => "acp.log",
        .opencode => "opencode.log",
    };

    return std.fmt.allocPrint(allocator, "{s}/.skim/{s}", .{ home, log_name });
}
