const std = @import("std");
const net = std.net;
const posix = std.posix;

const Allocator = std.mem.Allocator;

// =============================================================================
// Discovery Types
// =============================================================================

/// Default ports for daemon
pub const DEFAULT_TUI_PORT: u16 = 9999;
pub const DEFAULT_ADAPTER_PORT: u16 = 9998;

/// Discovery file location: ~/.skim/daemon.json
pub const DISCOVERY_FILENAME = "daemon.json";
pub const SKIM_DIR = ".skim";

/// Daemon status result
pub const DaemonStatus = union(enum) {
    /// Daemon is running and healthy
    running: DaemonInfo,
    /// Daemon is not running (no discovery file)
    not_running,
    /// Discovery file exists but daemon process is dead
    stale: struct {
        reason: []const u8,
    },
    /// Daemon appears running but isn't responding
    unhealthy: struct {
        reason: []const u8,
    },
};

/// Information about a running daemon
pub const DaemonInfo = struct {
    tui_port: u16,
    adapter_port: u16,
    pid: i32,
};

/// Contents of the discovery file
pub const DiscoveryFile = struct {
    version: u32 = 1,
    tui_port: u16,
    adapter_port: u16,
    pid: i32,
};

// =============================================================================
// Discovery Functions
// =============================================================================

/// Check if the daemon is running and return its status
pub fn discoverDaemon(allocator: Allocator) DaemonStatus {
    // Get discovery file path
    const path = getDiscoveryFilePath(allocator) catch {
        return .not_running;
    };
    defer allocator.free(path);

    // Try to read and parse discovery file
    const info = readDiscoveryFile(allocator, path) catch {
        return .not_running;
    };

    // Check if process is alive
    if (!isProcessAlive(info.pid)) {
        return .{ .stale = .{ .reason = "Daemon process not found" } };
    }

    // Try to connect to verify it's responding
    if (!canConnectToPort(info.adapter_port)) {
        return .{ .unhealthy = .{ .reason = "Daemon not responding on adapter port" } };
    }

    return .{ .running = info };
}

/// Get the path to the discovery file
pub fn getDiscoveryFilePath(allocator: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ home, SKIM_DIR, DISCOVERY_FILENAME });
}

/// Get the path to the skim config directory
pub fn getSkimDir(allocator: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, SKIM_DIR });
}

/// Read and parse the discovery file
pub fn readDiscoveryFile(allocator: Allocator, path: []const u8) !DaemonInfo {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    const parsed = try std.json.parseFromSlice(DiscoveryFile, allocator, buffer[0..bytes_read], .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .tui_port = parsed.value.tui_port,
        .adapter_port = parsed.value.adapter_port,
        .pid = parsed.value.pid,
    };
}

/// Write the discovery file
pub fn writeDiscoveryFile(allocator: Allocator, info: DaemonInfo) !void {
    // Ensure directory exists
    const dir_path = try getSkimDir(allocator);
    defer allocator.free(dir_path);

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write file
    const file_path = try getDiscoveryFilePath(allocator);
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    try file.writer().print(
        \\{{"version":1,"tui_port":{d},"adapter_port":{d},"pid":{d}}}
    , .{ info.tui_port, info.adapter_port, info.pid });
}

/// Delete the discovery file
pub fn deleteDiscoveryFile(allocator: Allocator) void {
    const path = getDiscoveryFilePath(allocator) catch return;
    defer allocator.free(path);

    std.fs.deleteFileAbsolute(path) catch {};
}

/// Check if a process is alive
pub fn isProcessAlive(pid: i32) bool {
    // Use kill with signal 0 to check if process exists
    const result = posix.kill(pid, 0);
    return result != error.NoSuchProcess and result != error.PermissionDenied;
}

/// Try to connect to a port to verify daemon is responsive
fn canConnectToPort(port: u16) bool {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = net.tcpConnectToAddress(address) catch {
        return false;
    };
    stream.close();
    return true;
}

// =============================================================================
// Auto-start Support
// =============================================================================

/// Check if auto-start is enabled via environment variable
pub fn isAutoStartEnabled() bool {
    const env_value = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIM_DAEMON_AUTO_START") catch {
        return false;
    };
    defer std.heap.page_allocator.free(env_value);

    return std.mem.eql(u8, env_value, "1") or
        std.mem.eql(u8, env_value, "true") or
        std.mem.eql(u8, env_value, "yes");
}

// =============================================================================
// Status Formatting
// =============================================================================

/// Format daemon status for display
pub fn formatStatus(allocator: Allocator, status: DaemonStatus) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();

    switch (status) {
        .running => |info| {
            try writer.print(
                \\skim daemon status
                \\==================
                \\Status:       Running
                \\PID:          {d}
                \\TUI Port:     {d}
                \\Adapter Port: {d}
                \\
            , .{ info.pid, info.tui_port, info.adapter_port });
        },
        .not_running => {
            try writer.writeAll(
                \\skim daemon status
                \\==================
                \\Status: Not running
                \\
                \\Start with: skim daemon start
                \\
            );
        },
        .stale => |s| {
            try writer.print(
                \\skim daemon status
                \\==================
                \\Status: Stale (cleaning up)
                \\Reason: {s}
                \\
                \\The discovery file exists but the daemon process is no longer running.
                \\Run 'skim daemon start' to start a new daemon.
                \\
            , .{s.reason});
        },
        .unhealthy => |u| {
            try writer.print(
                \\skim daemon status
                \\==================
                \\Status: Unhealthy
                \\Reason: {s}
                \\
                \\The daemon process exists but is not responding.
                \\Try: skim daemon restart
                \\
            , .{u.reason});
        },
    }

    return output.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "discovery file path" {
    const allocator = std.testing.allocator;

    // This test will fail if HOME is not set, which is expected
    if (getDiscoveryFilePath(allocator)) |path| {
        defer allocator.free(path);
        try std.testing.expect(std.mem.endsWith(u8, path, "/.skim/daemon.json"));
    } else |_| {
        // HOME not set, skip test
    }
}

test "format status not running" {
    const allocator = std.testing.allocator;

    const formatted = try formatStatus(allocator, .not_running);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Not running") != null);
}

test "format status running" {
    const allocator = std.testing.allocator;

    const formatted = try formatStatus(allocator, .{ .running = .{
        .tui_port = 9999,
        .adapter_port = 9998,
        .pid = 12345,
    } });
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Running") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "12345") != null);
}
