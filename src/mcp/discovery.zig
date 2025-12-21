const std = @import("std");
const net = std.net;
const posix = std.posix;

const Allocator = std.mem.Allocator;
const internal_protocol = @import("internal_protocol.zig");

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

/// Summary of a connected skim TUI client
pub const ConnectedClient = struct {
    id: []const u8,
    cwd: []const u8,
    diff_ref: []const u8,
    file_count: usize,
};

/// Information about a running daemon
pub const DaemonInfo = struct {
    tui_port: u16,
    adapter_port: u16,
    pid: i32,
    clients: []ConnectedClient = &[_]ConnectedClient{},
    adapter_count: usize = 0,
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
    var info = readDiscoveryFile(allocator, path) catch {
        return .not_running;
    };

    // Check if process is alive
    if (!isProcessAlive(info.pid)) {
        return .{ .stale = .{ .reason = "Daemon process not found" } };
    }

    // Query daemon for connected clients
    if (queryDaemonStatus(allocator, info.adapter_port)) |status| {
        info.clients = status.clients;
        info.adapter_count = status.adapter_count;
    } else |_| {
        // If query fails, daemon might be unhealthy
        return .{ .unhealthy = .{ .reason = "Daemon not responding to status query" } };
    }

    return .{ .running = info };
}

/// Query daemon for connected clients and adapter count
fn queryDaemonStatus(allocator: Allocator, adapter_port: u16) !struct { clients: []ConnectedClient, adapter_count: usize } {
    // Connect to daemon adapter port
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, adapter_port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    // Send status query
    const query = try internal_protocol.encodeStatusQuery(allocator);
    defer allocator.free(query);
    try stream.writeAll(query);

    // Read response with timeout
    var buffer: [8192]u8 = undefined;
    var total_read: usize = 0;

    // Read until we get a newline or timeout
    const start_time = std.time.milliTimestamp();
    const timeout_ms: i64 = 5000; // 5 second timeout

    while (total_read < buffer.len) {
        if (std.time.milliTimestamp() - start_time > timeout_ms) {
            return error.Timeout;
        }

        const bytes_read = stream.read(buffer[total_read..]) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };

        if (bytes_read == 0) break;
        total_read += bytes_read;

        // Check for complete message (newline terminated)
        if (std.mem.indexOfScalar(u8, buffer[0..total_read], '\n')) |_| {
            break;
        }
    }

    if (total_read == 0) {
        return error.NoResponse;
    }

    // Parse response
    var msg = try internal_protocol.decodeDaemonMessage(allocator, buffer[0..total_read]);
    defer internal_protocol.freeDaemonMessage(allocator, &msg);

    switch (msg) {
        .status_response => |status| {
            // Copy clients to return (we need to own them since msg will be freed)
            var clients = try allocator.alloc(ConnectedClient, status.clients.len);
            for (status.clients, 0..) |c, i| {
                clients[i] = .{
                    .id = try allocator.dupe(u8, c.id),
                    .cwd = try allocator.dupe(u8, c.cwd),
                    .diff_ref = try allocator.dupe(u8, c.diff_ref),
                    .file_count = c.file_count,
                };
            }
            return .{ .clients = clients, .adapter_count = status.adapter_count };
        },
        else => return error.UnexpectedResponse,
    }
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

    // Zig 0.15: file.writer() requires a buffer
    var write_buffer: [256]u8 = undefined;
    var file_writer = file.writer(&write_buffer);
    defer file_writer.interface.flush() catch {};
    try file_writer.interface.print(
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
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);

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

            // Display connected clients
            try writer.print(
                \\Adapters:     {d}
                \\Clients:      {d}
                \\
            , .{ info.adapter_count, info.clients.len });

            if (info.clients.len > 0) {
                try writer.writeAll("\nConnected TUI Clients:\n");
                for (info.clients) |client| {
                    try writer.print("  - {s}\n    {s} ({d} files)\n    {s}\n", .{
                        client.id,
                        client.diff_ref,
                        client.file_count,
                        client.cwd,
                    });
                }
            }
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

    return output.toOwnedSlice(allocator);
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
