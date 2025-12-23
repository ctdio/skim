const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Types
// =============================================================================

pub const Config = struct {
    review_command: ?[]const u8 = null,
    agent_panel_side: AgentPanelSide = .left,
    experimental: Experimental = .{},

    pub const AgentPanelSide = enum {
        left,
        right,
    };

    pub const Experimental = struct {
        mcp_enabled: bool = false,
        acp_enabled: bool = false,
    };
};

// =============================================================================
// Config Loading
// =============================================================================

/// Get the review command from environment variable or config file.
/// Priority: SKIM_REVIEW_COMMAND env var > ~/.skim/config.json
/// Returns owned string that must be freed by caller, or null if not configured.
pub fn getReviewCommand(allocator: Allocator) !?[]const u8 {
    // First, check environment variable
    if (std.process.getEnvVarOwned(allocator, "SKIM_REVIEW_COMMAND")) |command| {
        if (command.len > 0) {
            return command;
        }
        allocator.free(command);
    } else |_| {}

    // Fall back to config file
    const config = load(allocator) catch |err| {
        // Config file doesn't exist or is invalid - that's fine
        std.log.debug("Could not load config: {any}", .{err});
        return null;
    };

    if (config.review_command) |cmd| {
        return try allocator.dupe(u8, cmd);
    }

    return null;
}

/// Load config from ~/.skim/config.json
pub fn load(allocator: Allocator) !Config {
    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();

    var buffer: [8192]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    if (bytes_read == 0) {
        return Config{};
    }

    const parsed = try std.json.parseFromSlice(Config, allocator, buffer[0..bytes_read], .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Return a copy since parsed will be freed
    return Config{
        .review_command = if (parsed.value.review_command) |cmd|
            try allocator.dupe(u8, cmd)
        else
            null,
        .agent_panel_side = parsed.value.agent_panel_side,
        .experimental = parsed.value.experimental,
    };
}

/// Get the path to the config file: ~/.skim/config.json
pub fn getConfigFilePath(allocator: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.skim/config.json", .{home});
}

/// Get the path to the skim directory: ~/.skim
pub fn getSkimDir(allocator: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.skim", .{home});
}

// =============================================================================
// Feature Checks
// =============================================================================

/// Check if MCP features are enabled in config.
/// Returns false if config cannot be loaded.
pub fn isMcpEnabled(allocator: Allocator) bool {
    const config = load(allocator) catch return false;
    return config.experimental.mcp_enabled;
}

/// Check if ACP features are enabled in config.
/// Returns false if config cannot be loaded.
pub fn isAcpEnabled(allocator: Allocator) bool {
    const config = load(allocator) catch return false;
    return config.experimental.acp_enabled;
}

// =============================================================================
// Template Substitution
// =============================================================================

/// Context for template variable substitution
pub const ReviewContext = struct {
    client_id: []const u8,
    repo: []const u8,
    diff_ref: []const u8,
    adapter_port: u16,
};

/// Substitute template variables in a command string.
/// Supported variables: {client_id}, {repo}, {diff_ref}, {adapter_port}
/// Returns owned string that must be freed by caller.
pub fn substituteTemplateVars(allocator: Allocator, command: []const u8, ctx: ReviewContext) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < command.len) {
        if (command[i] == '{') {
            // Look for closing brace
            const end = std.mem.indexOfScalarPos(u8, command, i + 1, '}');
            if (end) |close_pos| {
                const var_name = command[i + 1 .. close_pos];

                if (std.mem.eql(u8, var_name, "client_id")) {
                    try result.appendSlice(allocator, ctx.client_id);
                } else if (std.mem.eql(u8, var_name, "repo")) {
                    try result.appendSlice(allocator, ctx.repo);
                } else if (std.mem.eql(u8, var_name, "diff_ref")) {
                    try result.appendSlice(allocator, ctx.diff_ref);
                } else if (std.mem.eql(u8, var_name, "adapter_port")) {
                    var port_buf: [8]u8 = undefined;
                    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{ctx.adapter_port}) catch unreachable;
                    try result.appendSlice(allocator, port_str);
                } else {
                    // Unknown variable - keep as-is
                    try result.appendSlice(allocator, command[i .. close_pos + 1]);
                }
                i = close_pos + 1;
                continue;
            }
        }
        try result.append(allocator, command[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "substitute template vars" {
    const allocator = std.testing.allocator;

    const ctx = ReviewContext{
        .client_id = "abc-123",
        .repo = "/home/user/project",
        .diff_ref = "staged",
        .adapter_port = 9998,
    };

    const result = try substituteTemplateVars(
        allocator,
        "review --client {client_id} --repo {repo} --ref {diff_ref} --port {adapter_port}",
        ctx,
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "review --client abc-123 --repo /home/user/project --ref staged --port 9998",
        result,
    );
}

test "substitute unknown vars preserved" {
    const allocator = std.testing.allocator;

    const ctx = ReviewContext{
        .client_id = "test",
        .repo = "/test",
        .diff_ref = "main",
        .adapter_port = 1234,
    };

    const result = try substituteTemplateVars(allocator, "cmd {unknown} {client_id}", ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("cmd {unknown} test", result);
}

test "experimental features default to false" {
    const config = Config{};
    try std.testing.expectEqual(false, config.experimental.mcp_enabled);
    try std.testing.expectEqual(false, config.experimental.acp_enabled);
}

test "parse experimental config from json" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "experimental": {
        \\    "mcp_enabled": true,
        \\    "acp_enabled": true
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(true, parsed.value.experimental.mcp_enabled);
    try std.testing.expectEqual(true, parsed.value.experimental.acp_enabled);
}

test "parse config without experimental section uses defaults" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "agent_panel_side": "left"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(false, parsed.value.experimental.mcp_enabled);
    try std.testing.expectEqual(false, parsed.value.experimental.acp_enabled);
    try std.testing.expectEqual(Config.AgentPanelSide.left, parsed.value.agent_panel_side);
}
