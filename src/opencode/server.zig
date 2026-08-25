const std = @import("std");
// Mirrors `is_web` in src/platform.zig. This subtree has its own test target
// rooted at its own directory, so it cannot import across the parent boundary.
const is_web = @import("builtin").target.cpu.arch.isWasm();
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const skim_io = @import("skim_io");
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
pub fn spawnServer(config: ServerConfig) ServerError!std.process.Child {
    // Validate executable exists (only for absolute paths)
    // For relative paths (e.g., "opencode"), rely on PATH resolution during spawn
    if (std.fs.path.isAbsolute(config.opencode_path)) {
        std.Io.Dir.accessAbsolute(skim_io.get(), config.opencode_path, .{}) catch {
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

    // StdIo has no direct file redirect, so stderr is ignored rather than
    // captured. The server has its own logging.
    _ = config.log_file; // Acknowledge the field

    const child = std.process.spawn(skim_io.get(), .{
        .argv = &argv,
        .cwd = if (config.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;

    log.info("Spawned opencode server on port {d}, pid={?d}", .{ config.port, child.id });
    return child;
}

/// Wait for the server to become healthy with exponential backoff
pub fn waitForHealth(client_ptr: *Client, timeout_ms: u64) ServerError!void {
    const start = skim_io.milliTimestamp();
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
        const elapsed: u64 = @intCast(skim_io.milliTimestamp() - start);
        if (elapsed >= timeout_ms) {
            log.err("Server health check timed out after {d}ms", .{timeout_ms});
            return error.ServerStartTimeout;
        }

        // Sleep with backoff
        skim_io.sleep(backoff * std.time.ns_per_ms);
        backoff = @min(backoff * 2, 1000);
    }
}

/// Terminate the server process gracefully (SIGTERM), then force (SIGKILL) after timeout
pub fn terminateServer(process: *std.process.Child) void {
    // The browser build never spawns, and wasi has no pid to signal.
    if (is_web) return;

    const server_pid = process.id orelse return;

    // Send SIGTERM for graceful shutdown
    _ = std.posix.kill(server_pid, std.posix.SIG.TERM) catch {
        log.warn("Failed to send SIGTERM to server", .{});
    };

    // Wait up to 2 seconds for graceful exit. `Child.wait` blocks, and 0.16
    // dropped `posix.waitpid`, so the polling reap goes straight to libc.
    const start = skim_io.milliTimestamp();
    while (skim_io.milliTimestamp() - start < 2000) {
        var status: c_int = undefined;
        if (std.c.waitpid(server_pid, &status, std.c.W.NOHANG) != 0) {
            log.info("Server terminated gracefully", .{});
            return;
        }
        skim_io.sleep(100 * std.time.ns_per_ms);
    }

    // Force kill if still running
    _ = std.posix.kill(server_pid, std.posix.SIG.KILL) catch {
        log.warn("Failed to send SIGKILL to server", .{});
    };

    // Collect the zombie
    var status: c_int = undefined;
    _ = std.c.waitpid(server_pid, &status, 0);
    log.info("Server terminated forcefully", .{});
}

// =============================================================================
// Tests
// =============================================================================

test "spawn missing executable" {
    const config = ServerConfig{
        .opencode_path = "/nonexistent/path/to/opencode",
        .port = 4096,
    };

    const result = spawnServer(config);
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

    const config = ServerConfig{
        .opencode_path = "/usr/local/bin/opencode",
        .port = 14096, // Use non-default port for testing
    };

    var child = try spawnServer(config);
    defer terminateServer(&child);

    // Give it a moment to start
    skim_io.sleep(100 * std.time.ns_per_ms);

    // Verify process is running
    try std.testing.expect(child.id != null);
}
