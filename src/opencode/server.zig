const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const Client = client_mod.Client;

// =============================================================================
// Opencode Server Process Management
// =============================================================================
//
// Spawns and manages the opencode serve process.
// Provides health checking and graceful termination.
//
// =============================================================================

const log = std.log.scoped(.opencode);

/// Configuration for spawning the opencode server
pub const ServerConfig = struct {
    /// Path to opencode executable
    opencode_path: []const u8,
    /// Port to listen on
    port: u16,
    /// Working directory
    cwd: ?[]const u8 = null,
    /// Log file path for stderr
    log_file: ?[]const u8 = null,
};

/// Errors for server operations
pub const ServerError = error{
    ExecutableNotFound,
    ServerStartTimeout,
    SpawnFailed,
    HealthCheckFailed,
} || Allocator.Error;

/// Spawn the opencode serve process
pub fn spawnServer(allocator: Allocator, config: ServerConfig) ServerError!std.process.Child {
    // Validate executable exists (only for absolute paths)
    // For relative paths (e.g., "opencode"), rely on PATH resolution during spawn
    if (std.fs.path.isAbsolute(config.opencode_path)) {
        std.fs.accessAbsolute(config.opencode_path, .{}) catch {
            return error.ExecutableNotFound;
        };
    }

    // Format port as string
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{config.port}) catch return error.SpawnFailed;

    // Build argv
    const argv = [_][]const u8{
        config.opencode_path,
        "serve",
        "--port",
        port_str,
    };

    var child = std.process.Child.init(&argv, allocator);

    // Set working directory
    if (config.cwd) |cwd| {
        child.cwd = cwd;
    }

    // Redirect stderr to log file if specified
    // Note: Zig 0.15.1 StdIo doesn't support direct file redirect via enum,
    // so we simply ignore stderr. The server should have its own logging.
    _ = config.log_file; // Acknowledge the field
    child.stderr_behavior = .Ignore;

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    child.spawn() catch return error.SpawnFailed;

    log.info("Spawned opencode server on port {d}, pid={d}", .{ config.port, child.id });
    return child;
}

/// Wait for the server to become healthy with exponential backoff
pub fn waitForHealth(client_ptr: *Client, timeout_ms: u64) ServerError!void {
    const start = std.time.milliTimestamp();
    var backoff: u64 = 50;

    while (true) {
        // Try health check
        const health = client_ptr.healthCheck() catch null;
        if (health) |h| {
            client_ptr.allocator.free(h.version);
            if (h.healthy) {
                log.info("Server is healthy", .{});
                return;
            }
        }

        // Check timeout
        const elapsed: u64 = @intCast(std.time.milliTimestamp() - start);
        if (elapsed >= timeout_ms) {
            log.err("Server health check timed out after {d}ms", .{timeout_ms});
            return error.ServerStartTimeout;
        }

        // Sleep with backoff
        std.Thread.sleep(backoff * std.time.ns_per_ms);
        backoff = @min(backoff * 2, 1000);
    }
}

/// Terminate the server process gracefully (SIGTERM), then force (SIGKILL) after timeout
pub fn terminateServer(process: *std.process.Child) void {
    // Send SIGTERM for graceful shutdown
    _ = std.posix.kill(process.id, std.posix.SIG.TERM) catch {
        log.warn("Failed to send SIGTERM to server", .{});
    };

    // Wait up to 2 seconds for graceful exit
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 2000) {
        // Try to collect exit status without blocking
        _ = process.wait() catch {
            // Process still running, wait a bit
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        log.info("Server terminated gracefully", .{});
        return;
    }

    // Force kill if still running
    _ = std.posix.kill(process.id, std.posix.SIG.KILL) catch {
        log.warn("Failed to send SIGKILL to server", .{});
    };

    // Collect the zombie
    _ = process.wait() catch {};
    log.info("Server terminated forcefully", .{});
}

// =============================================================================
// Tests
// =============================================================================

test "spawn missing executable" {
    const allocator = std.testing.allocator;
    const config = ServerConfig{
        .opencode_path = "/nonexistent/path/to/opencode",
        .port = 4096,
    };

    const result = spawnServer(allocator, config);
    try std.testing.expectError(error.ExecutableNotFound, result);
}

test "ServerConfig defaults" {
    const config = ServerConfig{
        .opencode_path = "/usr/bin/opencode",
        .port = 4096,
    };

    try std.testing.expectEqualStrings("/usr/bin/opencode", config.opencode_path);
    try std.testing.expectEqual(@as(u16, 4096), config.port);
    try std.testing.expect(config.cwd == null);
    try std.testing.expect(config.log_file == null);
}

// Integration tests - skipped in unit test runs (require live opencode binary)
test "integration: spawn and terminate server" {
    // Skip in normal test runs - requires opencode binary
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const config = ServerConfig{
        .opencode_path = "/usr/local/bin/opencode",
        .port = 14096, // Use non-default port for testing
    };

    var child = try spawnServer(allocator, config);
    defer terminateServer(&child);

    // Give it a moment to start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify process is running
    try std.testing.expect(child.id > 0);
}
