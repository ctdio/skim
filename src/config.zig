const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Types
// =============================================================================

/// Agent configuration from ~/.skim/config.json
pub const AgentConfig = struct {
    name: []const u8,
    command: []const u8,
    api_key_env: ?[]const u8 = null, // Environment variable containing API key (for status display)
    default: bool = false,
    args: ?[]const []const u8 = null,
    model: ?[]const u8 = null, // AI model to use (e.g., "sonnet", "opus")
    mode: ?[]const u8 = null, // Agent session mode (e.g., "plan", "code")
};

pub const Config = struct {
    agent_panel_side: AgentPanelSide = .left,
    experimental: Experimental = .{},
    agents: ?[]const AgentConfig = null,

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

    // Duplicate agents array if present
    const duped_agents: ?[]const AgentConfig = if (parsed.value.agents) |agents| blk: {
        const result = try allocator.alloc(AgentConfig, agents.len);
        for (agents, 0..) |agent, i| {
            result[i] = try dupeAgentConfig(allocator, agent);
        }
        break :blk result;
    } else null;

    // Return a copy since parsed will be freed
    return Config{
        .agent_panel_side = parsed.value.agent_panel_side,
        .experimental = parsed.value.experimental,
        .agents = duped_agents,
    };
}

/// Duplicate an AgentConfig, copying all strings
fn dupeAgentConfig(allocator: Allocator, agent: AgentConfig) !AgentConfig {
    return AgentConfig{
        .name = try allocator.dupe(u8, agent.name),
        .command = try allocator.dupe(u8, agent.command),
        .api_key_env = if (agent.api_key_env) |e| try allocator.dupe(u8, e) else null,
        .default = agent.default,
        .args = if (agent.args) |args| try dupeStringSlice(allocator, args) else null,
        .model = if (agent.model) |m| try allocator.dupe(u8, m) else null,
        .mode = if (agent.mode) |m| try allocator.dupe(u8, m) else null,
    };
}

/// Duplicate a slice of strings
fn dupeStringSlice(allocator: Allocator, strings: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, strings.len);
    for (strings, 0..) |s, i| {
        result[i] = try allocator.dupe(u8, s);
    }
    return result;
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
// Agent Configuration Helpers
// =============================================================================

/// Get configured agents from config file.
/// Returns null if config cannot be loaded or no agents are configured.
/// Caller must free returned agents using freeAgents().
pub fn getConfiguredAgents(allocator: Allocator) !?[]const AgentConfig {
    const config = load(allocator) catch return null;
    return config.agents;
}

/// Find the default agent from configured agents.
/// Returns index of agent marked as default, or null if none marked.
pub fn findDefaultAgentIndex(agents: []const AgentConfig) ?usize {
    for (agents, 0..) |agent, i| {
        if (agent.default) return i;
    }
    return null;
}

/// Free agents array and all contained strings.
pub fn freeAgents(allocator: Allocator, agents: []const AgentConfig) void {
    for (agents) |agent| {
        allocator.free(agent.name);
        allocator.free(agent.command);
        if (agent.api_key_env) |e| allocator.free(e);
        if (agent.args) |args| {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }
        if (agent.model) |m| allocator.free(m);
        if (agent.mode) |m| allocator.free(m);
    }
    allocator.free(agents);
}

// =============================================================================
// Tests
// =============================================================================

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

test "parse agents config from json" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "agents": [
        \\    {
        \\      "name": "Claude Code",
        \\      "command": "claude-code-acp",
        \\      "api_key_env": "ANTHROPIC_API_KEY",
        \\      "default": true,
        \\      "model": "opus",
        \\      "mode": "plan"
        \\    },
        \\    {
        \\      "name": "Codex",
        \\      "command": "codex-acp"
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const agents = parsed.value.agents orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), agents.len);

    // First agent
    try std.testing.expectEqualStrings("Claude Code", agents[0].name);
    try std.testing.expectEqualStrings("claude-code-acp", agents[0].command);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", agents[0].api_key_env.?);
    try std.testing.expectEqual(true, agents[0].default);
    try std.testing.expectEqualStrings("opus", agents[0].model.?);
    try std.testing.expectEqualStrings("plan", agents[0].mode.?);

    // Second agent - minimal config
    try std.testing.expectEqualStrings("Codex", agents[1].name);
    try std.testing.expectEqualStrings("codex-acp", agents[1].command);
    try std.testing.expectEqual(@as(?[]const u8, null), agents[1].api_key_env);
    try std.testing.expectEqual(false, agents[1].default);
}

test "findDefaultAgentIndex returns correct index" {
    const agents = [_]AgentConfig{
        .{ .name = "Agent 1", .command = "cmd1", .default = false },
        .{ .name = "Agent 2", .command = "cmd2", .default = true },
        .{ .name = "Agent 3", .command = "cmd3", .default = false },
    };

    const idx = findDefaultAgentIndex(&agents);
    try std.testing.expectEqual(@as(?usize, 1), idx);
}

test "findDefaultAgentIndex returns null when no default" {
    const agents = [_]AgentConfig{
        .{ .name = "Agent 1", .command = "cmd1", .default = false },
        .{ .name = "Agent 2", .command = "cmd2", .default = false },
    };

    const idx = findDefaultAgentIndex(&agents);
    try std.testing.expectEqual(@as(?usize, null), idx);
}
