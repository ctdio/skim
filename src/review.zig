const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

// =============================================================================
// Types
// =============================================================================

pub const ReviewStatus = enum {
    running,
    completed,
    failed,
};

pub const ReviewProcess = struct {
    allocator: Allocator,
    child: std.process.Child,
    started_at: i64,
    status: ReviewStatus,

    pub fn deinit(self: *ReviewProcess) void {
        self.allocator.destroy(self);
    }
};

// =============================================================================
// Review Process Management
// =============================================================================

/// Start a review process with the given command.
/// The command is parsed and executed as a shell command.
/// Output is redirected to ~/.skim/review.log
pub fn start(allocator: Allocator, command: []const u8, ctx: config.ReviewContext) !*ReviewProcess {
    // Substitute template variables
    const expanded_command = try config.substituteTemplateVars(allocator, command, ctx);
    defer allocator.free(expanded_command);

    // Ensure ~/.skim directory exists
    const skim_dir = try config.getSkimDir(allocator);
    defer allocator.free(skim_dir);

    std.fs.makeDirAbsolute(skim_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Get log path for shell redirection
    const log_path = try getLogPath(allocator);
    defer allocator.free(log_path);

    // Build command with shell redirection to log file
    // Truncate file first, then redirect both stdout and stderr
    const shell_command = try std.fmt.allocPrint(
        allocator,
        ": > \"{s}\" && {{ {s} ; }} > \"{s}\" 2>&1",
        .{ log_path, expanded_command, log_path },
    );
    defer allocator.free(shell_command);

    // Create the review process
    const process = try allocator.create(ReviewProcess);
    errdefer allocator.destroy(process);

    // Parse command into argv using shell
    const argv = [_][]const u8{ "/bin/sh", "-c", shell_command };

    process.* = .{
        .allocator = allocator,
        .child = std.process.Child.init(&argv, allocator),
        .started_at = std.time.timestamp(),
        .status = .running,
    };

    // Set working directory to the repo
    process.child.cwd = ctx.repo;

    // Ignore stdin, let shell handle stdout/stderr redirection
    process.child.stdin_behavior = .Ignore;
    process.child.stdout_behavior = .Ignore;
    process.child.stderr_behavior = .Ignore;

    // Spawn the process
    try process.child.spawn();

    return process;
}

/// Check if the review process has completed (non-blocking).
/// Updates the status field and returns the current status.
pub fn checkStatus(process: *ReviewProcess) ReviewStatus {
    if (process.status != .running) {
        return process.status;
    }

    // Non-blocking wait using WNOHANG
    const result = std.posix.waitpid(process.child.id, std.posix.W.NOHANG);

    if (result.pid == 0) {
        // Process still running (WNOHANG returned 0)
        return process.status;
    }

    // Process has terminated
    if (std.posix.W.IFEXITED(result.status)) {
        const code = std.posix.W.EXITSTATUS(result.status);
        if (code == 0) {
            process.status = .completed;
        } else {
            process.status = .failed;
        }
    } else if (std.posix.W.IFSIGNALED(result.status)) {
        process.status = .failed;
    } else if (std.posix.W.IFSTOPPED(result.status)) {
        process.status = .failed;
    } else {
        process.status = .failed;
    }

    return process.status;
}

/// Get the path to the review log file: ~/.skim/review.log
pub fn getLogPath(allocator: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.skim/review.log", .{home});
}

/// Read the contents of the review log file.
/// Returns owned slice that must be freed by caller.
/// Returns empty string if file doesn't exist.
/// ANSI escape codes are stripped from the content.
pub fn readLogContents(allocator: Allocator) ![]u8 {
    const log_path = try getLogPath(allocator);
    defer allocator.free(log_path);

    const file = std.fs.openFileAbsolute(log_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.dupe(u8, ""),
        else => return err,
    };
    defer file.close();

    // Read up to 1MB
    const raw_content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw_content);

    // Strip ANSI escape codes
    return stripAnsiCodes(allocator, raw_content);
}

/// Get elapsed time since review started in seconds
pub fn getElapsedSeconds(process: *const ReviewProcess) i64 {
    return std.time.timestamp() - process.started_at;
}

/// Format elapsed time as human-readable string (e.g., "1m 23s")
pub fn formatElapsedTime(allocator: Allocator, process: *const ReviewProcess) ![]u8 {
    const elapsed = getElapsedSeconds(process);

    if (elapsed < 60) {
        return std.fmt.allocPrint(allocator, "{d}s", .{elapsed});
    } else {
        const minutes = @divFloor(elapsed, 60);
        const seconds = @mod(elapsed, 60);
        return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ minutes, seconds });
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Strip ANSI escape codes from a string.
/// Handles CSI sequences (ESC [ ... final_byte) and OSC sequences (ESC ] ... BEL/ST).
/// Also handles malformed sequences where ESC is missing (e.g., "[2m" without ESC).
/// Returns owned slice that must be freed by caller.
fn stripAnsiCodes(allocator: Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Check for ESC (0x1B)
        if (input[i] == 0x1B) {
            if (i + 1 < input.len) {
                const next = input[i + 1];
                if (next == '[') {
                    // CSI sequence: ESC [ ... (ends with 0x40-0x7E)
                    i += 2;
                    while (i < input.len) {
                        const c = input[i];
                        i += 1;
                        if (c >= 0x40 and c <= 0x7E) break;
                    }
                    continue;
                } else if (next == ']') {
                    // OSC sequence: ESC ] ... (ends with BEL or ST)
                    i += 2;
                    while (i < input.len) {
                        if (input[i] == 0x07) { // BEL
                            i += 1;
                            break;
                        } else if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '\\') {
                            // ST (String Terminator)
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                    continue;
                } else if (next >= 0x40 and next <= 0x5F) {
                    // Two-byte escape sequence
                    i += 2;
                    continue;
                }
            }
            // Lone ESC or unrecognized - skip it
            i += 1;
            continue;
        }

        // Check for malformed CSI sequence (missing ESC): "[" followed by params and final byte
        // This handles cases like "[2m" or "[0m" where the ESC was lost
        // IMPORTANT: Require at least one digit to avoid stripping text like "[Bash]" or "[method]"
        if (input[i] == '[' and i + 1 < input.len) {
            // Check if this looks like a CSI sequence (digits, semicolons, then final byte)
            var j = i + 1;
            var found_digit = false;
            var looks_like_csi = false;
            while (j < input.len) {
                const c = input[j];
                if (c >= '0' and c <= '9') {
                    found_digit = true;
                    j += 1;
                } else if (c == ';' or c == ':' or c == '?') {
                    j += 1;
                } else if (c >= 0x40 and c <= 0x7E) {
                    // Final byte found - only treat as CSI if we found digits
                    // This prevents stripping "[Bash]" while still stripping "[0m"
                    looks_like_csi = found_digit;
                    j += 1;
                    break;
                } else {
                    // Not a CSI sequence
                    break;
                }
            }
            if (looks_like_csi and j > i + 1) {
                i = j;
                continue;
            }
        }

        // Regular character - keep it
        try result.append(allocator, input[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "stripAnsiCodes removes CSI sequences" {
    const allocator = std.testing.allocator;

    const input = "Hello \x1b[2mworld\x1b[0m!";
    const output = try stripAnsiCodes(allocator, input);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("Hello world!", output);
}

test "stripAnsiCodes handles complex sequences" {
    const allocator = std.testing.allocator;

    const input = "\x1b[38;5;196mRed\x1b[0m \x1b[1;32mGreen\x1b[0m";
    const output = try stripAnsiCodes(allocator, input);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("Red Green", output);
}

test "stripAnsiCodes preserves plain text" {
    const allocator = std.testing.allocator;

    const input = "Plain text without codes";
    const output = try stripAnsiCodes(allocator, input);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(input, output);
}

test "stripAnsiCodes handles malformed sequences without ESC" {
    const allocator = std.testing.allocator;

    // Malformed sequences like "[2m" without the ESC byte
    const input = "[2m[mcp__skim__list_clients[0m";
    const output = try stripAnsiCodes(allocator, input);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("[mcp__skim__list_clients", output);
}

test "stripAnsiCodes preserves valid brackets" {
    const allocator = std.testing.allocator;

    // Normal brackets that aren't escape sequences
    const input = "array[0] and function(x)";
    const output = try stripAnsiCodes(allocator, input);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(input, output);
}

test "getLogPath contains review.log" {
    const allocator = std.testing.allocator;

    if (getLogPath(allocator)) |path| {
        defer allocator.free(path);
        try std.testing.expect(std.mem.endsWith(u8, path, "/.skim/review.log"));
    } else |_| {
        // HOME not set, skip test
    }
}
