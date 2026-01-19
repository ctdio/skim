//! Session file management for skim TUI discovery.
//!
//! Each TUI instance writes a session file to `~/.skim/sessions/<pid>.json`
//! containing connection info (port, cwd, diff_ref, files). CLI commands and
//! MCP adapters discover running TUIs by reading these files.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// =============================================================================
// Session Types
// =============================================================================

pub const SESSIONS_DIR = "sessions";
pub const SKIM_DIR = ".skim";

/// Information about a running skim TUI session
pub const SessionInfo = struct {
    pid: posix.pid_t,
    port: u16,
    cwd: []const u8,
    diff_ref: []const u8,
    files: []const []const u8,
    started_at: i64,

    /// Free allocated memory
    pub fn deinit(self: *SessionInfo, allocator: Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.diff_ref);
        for (self.files) |f| {
            allocator.free(f);
        }
        allocator.free(self.files);
    }
};

/// JSON representation for session file
const SessionFileJson = struct {
    pid: i32,
    port: u16,
    cwd: []const u8,
    diff_ref: []const u8,
    files: []const []const u8,
    started_at: i64,
};

// =============================================================================
// Session Manager
// =============================================================================

/// Manager for session files in `~/.skim/sessions/`
pub const SessionManager = struct {
    allocator: Allocator,
    sessions_dir: []const u8,
    current_pid: posix.pid_t,

    /// Initialize session manager, creating sessions directory if needed
    pub fn init(allocator: Allocator) !SessionManager {
        const sessions_dir = try getSessionsDir(allocator);
        errdefer allocator.free(sessions_dir);

        // Create sessions directory if it doesn't exist
        std.fs.makeDirAbsolute(sessions_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return .{
            .allocator = allocator,
            .sessions_dir = sessions_dir,
            .current_pid = getCurrentPid(),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.allocator.free(self.sessions_dir);
    }

    /// Write session file for current process (atomic: write to temp, rename)
    pub fn writeSession(self: *SessionManager, info: SessionInfo) !void {
        const file_path = try self.getSessionFilePath(self.current_pid);
        defer self.allocator.free(file_path);

        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
        defer self.allocator.free(temp_path);

        // Write to temp file
        const file = try std.fs.createFileAbsolute(temp_path, .{});
        defer file.close();

        // Zig 0.15: file.writer() requires a buffer
        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        defer file_writer.interface.flush() catch {};

        // Manually construct JSON using std.json.fmt for string escaping
        try file_writer.interface.print("{{\"pid\":{d},\"port\":{d},\"cwd\":{f},\"diff_ref\":{f},\"files\":[", .{
            @as(i32, @intCast(info.pid)),
            info.port,
            std.json.fmt(info.cwd, .{}),
            std.json.fmt(info.diff_ref, .{}),
        });

        for (info.files, 0..) |f, i| {
            if (i > 0) try file_writer.interface.writeByte(',');
            try file_writer.interface.print("{f}", .{std.json.fmt(f, .{})});
        }

        try file_writer.interface.print("],\"started_at\":{d}}}", .{info.started_at});

        // Atomic rename
        try std.fs.renameAbsolute(temp_path, file_path);
    }

    /// Remove session file for current process
    pub fn removeSession(self: *SessionManager) void {
        const file_path = self.getSessionFilePath(self.current_pid) catch return;
        defer self.allocator.free(file_path);

        std.fs.deleteFileAbsolute(file_path) catch {};
    }

    /// List all valid sessions (validates PIDs, prunes stale files)
    pub fn listSessions(self: *SessionManager) ![]SessionInfo {
        var sessions: std.ArrayList(SessionInfo) = .{};
        errdefer {
            for (sessions.items) |*s| s.deinit(self.allocator);
            sessions.deinit(self.allocator);
        }

        var dir = std.fs.openDirAbsolute(self.sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return sessions.toOwnedSlice(self.allocator),
            else => return err,
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            // Parse PID from filename
            const pid_str = entry.name[0 .. entry.name.len - 5]; // Remove ".json"
            const pid = std.fmt.parseInt(posix.pid_t, pid_str, 10) catch continue;

            // Check if process is alive
            if (!isProcessAlive(pid)) {
                // Prune stale session file
                dir.deleteFile(entry.name) catch {};
                continue;
            }

            // Read session file
            if (self.readSessionFile(pid)) |session| {
                try sessions.append(self.allocator, session);
            } else |_| {
                // Invalid file, try to prune
                dir.deleteFile(entry.name) catch {};
            }
        }

        return sessions.toOwnedSlice(self.allocator);
    }

    /// Find session by PID
    pub fn findSession(self: *SessionManager, pid: posix.pid_t) !?SessionInfo {
        if (!isProcessAlive(pid)) {
            // Prune stale file
            const file_path = try self.getSessionFilePath(pid);
            defer self.allocator.free(file_path);
            std.fs.deleteFileAbsolute(file_path) catch {};
            return null;
        }

        return self.readSessionFile(pid) catch null;
    }

    /// Find session matching cwd (returns first match)
    pub fn findSessionByCwd(self: *SessionManager, cwd: []const u8) !?SessionInfo {
        const sessions = try self.listSessions();
        defer {
            for (sessions) |*s| {
                var session = s.*;
                session.deinit(self.allocator);
            }
            self.allocator.free(sessions);
        }

        for (sessions) |session| {
            if (std.mem.eql(u8, session.cwd, cwd)) {
                // Found match - need to read it again since we freed the list
                return self.readSessionFile(session.pid) catch null;
            }
        }

        return null;
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    fn getSessionFilePath(self: *SessionManager, pid: posix.pid_t) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{d}.json", .{ self.sessions_dir, pid });
    }

    fn readSessionFile(self: *SessionManager, pid: posix.pid_t) !SessionInfo {
        const file_path = try self.getSessionFilePath(pid);
        defer self.allocator.free(file_path);

        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();

        var buffer: [8192]u8 = undefined;
        const bytes_read = try file.readAll(&buffer);

        const parsed = try std.json.parseFromSlice(SessionFileJson, self.allocator, buffer[0..bytes_read], .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // Copy strings to owned memory
        const cwd = try self.allocator.dupe(u8, parsed.value.cwd);
        errdefer self.allocator.free(cwd);

        const diff_ref = try self.allocator.dupe(u8, parsed.value.diff_ref);
        errdefer self.allocator.free(diff_ref);

        var files = try self.allocator.alloc([]const u8, parsed.value.files.len);
        errdefer self.allocator.free(files);

        for (parsed.value.files, 0..) |f, i| {
            files[i] = try self.allocator.dupe(u8, f);
        }

        return .{
            .pid = @intCast(parsed.value.pid),
            .port = parsed.value.port,
            .cwd = cwd,
            .diff_ref = diff_ref,
            .files = files,
            .started_at = parsed.value.started_at,
        };
    }
};

// =============================================================================
// Utility Functions
// =============================================================================

/// Get the path to sessions directory: ~/.skim/sessions/
pub fn getSessionsDir(allocator: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const skim_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, SKIM_DIR });
    defer allocator.free(skim_dir);

    // Ensure ~/.skim exists
    std.fs.makeDirAbsolute(skim_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ skim_dir, SESSIONS_DIR });
}

/// Check if a process is alive using kill(pid, 0)
pub fn isProcessAlive(pid: posix.pid_t) bool {
    // In Zig 0.15, kill returns an error union
    posix.kill(pid, 0) catch |err| {
        // ESRCH means no such process, EPERM means exists but no permission
        return err != error.ProcessNotFound;
    };
    return true;
}

/// Cross-platform getpid implementation
pub fn getCurrentPid() posix.pid_t {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    } else {
        // Use extern for macOS and other POSIX systems
        const c_getpid = @extern(*const fn () callconv(.c) c_int, .{ .name = "getpid" });
        return @intCast(c_getpid());
    }
}

// =============================================================================
// Tests
// =============================================================================

test "session directory path" {
    const allocator = std.testing.allocator;

    if (getSessionsDir(allocator)) |path| {
        defer allocator.free(path);
        try std.testing.expect(std.mem.endsWith(u8, path, "/.skim/sessions"));
    } else |_| {
        // HOME not set, skip
    }
}

test "isProcessAlive with current process" {
    // Current process should be alive
    try std.testing.expect(isProcessAlive(getCurrentPid()));
}

test "isProcessAlive with invalid PID" {
    // PID 0 is special (kernel), use a very high PID that shouldn't exist
    const fake_pid: posix.pid_t = 999999999;
    try std.testing.expect(!isProcessAlive(fake_pid));
}

test "session manager init creates directory" {
    const allocator = std.testing.allocator;

    var manager = SessionManager.init(allocator) catch {
        // HOME not set or other env issue, skip
        return;
    };
    defer manager.deinit();

    // Verify directory exists
    var dir = std.fs.openDirAbsolute(manager.sessions_dir, .{}) catch {
        try std.testing.expect(false); // Directory should exist
        return;
    };
    dir.close();
}

test "write and read session file" {
    const allocator = std.testing.allocator;

    var manager = SessionManager.init(allocator) catch return;
    defer manager.deinit();

    // Create test session info
    const files = [_][]const u8{ "src/main.zig", "src/app.zig" };
    const info = SessionInfo{
        .pid = manager.current_pid,
        .port = 12345,
        .cwd = "/test/path",
        .diff_ref = "main..feature",
        .files = &files,
        .started_at = 1705600000,
    };

    // Write session
    try manager.writeSession(info);

    // Read it back
    var read_info = try manager.readSessionFile(manager.current_pid);
    defer read_info.deinit(allocator);

    try std.testing.expectEqual(info.pid, read_info.pid);
    try std.testing.expectEqual(info.port, read_info.port);
    try std.testing.expectEqualStrings(info.cwd, read_info.cwd);
    try std.testing.expectEqualStrings(info.diff_ref, read_info.diff_ref);
    try std.testing.expectEqual(info.files.len, read_info.files.len);

    // Clean up
    manager.removeSession();
}

test "list sessions filters dead PIDs" {
    const allocator = std.testing.allocator;

    var manager = SessionManager.init(allocator) catch return;
    defer manager.deinit();

    // Create a fake session file with a dead PID
    const fake_pid: posix.pid_t = 999999998;
    const fake_path = try std.fmt.allocPrint(allocator, "{s}/{d}.json", .{ manager.sessions_dir, fake_pid });
    defer allocator.free(fake_path);

    // Write fake session file
    {
        const file = try std.fs.createFileAbsolute(fake_path, .{});
        defer file.close();
        try file.writer().writeAll("{\"pid\":999999998,\"port\":11111,\"cwd\":\"/fake\",\"diff_ref\":\"main\",\"files\":[],\"started_at\":0}");
    }

    // List sessions - should prune the fake one
    const sessions = try manager.listSessions();
    defer {
        for (sessions) |*s| {
            var session = s.*;
            session.deinit(allocator);
        }
        allocator.free(sessions);
    }

    // Fake session should not be in list
    for (sessions) |s| {
        try std.testing.expect(s.pid != fake_pid);
    }

    // Fake file should be deleted
    std.fs.accessAbsolute(fake_path, .{}) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    // If we get here, file still exists (test failure)
    try std.testing.expect(false);
}
