const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Types
// =============================================================================

/// Skim-specific extensions (namespaced to avoid ACP spec conflicts)
pub const SkimAgentExtensions = struct {
    default: bool = false,
    mode: ?[]const u8 = null, // e.g., "plan", "code"
    model: ?[]const u8 = null, // e.g., "opus", "sonnet"
};

/// Environment variable entry (name -> value)
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8, // May contain ${VAR} for expansion
};

/// Agent protocol type
pub const Protocol = enum {
    acp, // Agent Client Protocol (default, used by Claude Code, Codex)
    opencode, // HTTP + SSE based protocol
};

/// Standard ACP agent server config with skim extensions
/// Matches the standard agent_servers format used by JetBrains, Zed, etc.
pub const AgentServerConfig = struct {
    name: []const u8, // Populated from object key during parsing
    command: []const u8,
    args: ?[]const []const u8 = null,
    env: ?[]const EnvVar = null, // Environment variables
    skim: ?SkimAgentExtensions = null, // Namespaced skim extensions
    protocol: Protocol = .acp, // Protocol to use for communication
};

pub const Config = struct {
    agent_panel_side: AgentPanelSide = .left,
    agent_servers: ?[]const AgentServerConfig = null,

    pub const AgentPanelSide = enum {
        left,
        right,
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

    var buffer: [16384]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    if (bytes_read == 0) {
        return Config{};
    }

    return parseConfig(allocator, buffer[0..bytes_read]);
}

/// Parse config from JSON string
pub fn parseConfig(allocator: Allocator, json_bytes: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return Config{};
    }

    var config = Config{};

    // Parse agent_panel_side
    if (root.object.get("agent_panel_side")) |side_val| {
        if (side_val == .string) {
            if (std.mem.eql(u8, side_val.string, "right")) {
                config.agent_panel_side = .right;
            }
        }
    }

    // Parse agent_servers (object format)
    if (root.object.get("agent_servers")) |servers_val| {
        if (servers_val == .object) {
            config.agent_servers = try parseAgentServers(allocator, servers_val.object);
        }
    }

    return config;
}

/// Parse agent_servers object into slice of AgentServerConfig
fn parseAgentServers(allocator: Allocator, servers: std.json.ObjectMap) ![]const AgentServerConfig {
    if (servers.count() == 0) return &.{};

    var agents: std.ArrayListUnmanaged(AgentServerConfig) = .{};
    errdefer {
        for (agents.items) |*agent| {
            freeAgentServer(allocator, agent);
        }
        agents.deinit(allocator);
    }

    var iter = servers.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (value != .object) continue;

        const agent = try parseAgentServer(allocator, name, value.object);
        try agents.append(allocator, agent);
    }

    return try agents.toOwnedSlice(allocator);
}

/// Parse a single agent server configuration
fn parseAgentServer(allocator: Allocator, name: []const u8, obj: std.json.ObjectMap) !AgentServerConfig {
    var agent = AgentServerConfig{
        .name = try allocator.dupe(u8, name),
        .command = "",
    };
    errdefer allocator.free(agent.name);

    // Parse command (required)
    if (obj.get("command")) |cmd_val| {
        if (cmd_val == .string) {
            agent.command = try allocator.dupe(u8, cmd_val.string);
        }
    }

    // Parse args (optional)
    if (obj.get("args")) |args_val| {
        if (args_val == .array) {
            var args: std.ArrayListUnmanaged([]const u8) = .{};
            errdefer {
                for (args.items) |arg| allocator.free(arg);
                args.deinit(allocator);
            }
            for (args_val.array.items) |item| {
                if (item == .string) {
                    try args.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            agent.args = try args.toOwnedSlice(allocator);
        }
    }

    // Parse env (optional) - object of name -> value
    if (obj.get("env")) |env_val| {
        if (env_val == .object) {
            var env_vars: std.ArrayListUnmanaged(EnvVar) = .{};
            errdefer {
                for (env_vars.items) |ev| {
                    allocator.free(ev.name);
                    allocator.free(ev.value);
                }
                env_vars.deinit(allocator);
            }
            var env_iter = env_val.object.iterator();
            while (env_iter.next()) |env_entry| {
                if (env_entry.value_ptr.* == .string) {
                    try env_vars.append(allocator, .{
                        .name = try allocator.dupe(u8, env_entry.key_ptr.*),
                        .value = try allocator.dupe(u8, env_entry.value_ptr.string),
                    });
                }
            }
            agent.env = try env_vars.toOwnedSlice(allocator);
        }
    }

    // Parse skim extensions (optional)
    if (obj.get("skim")) |skim_val| {
        if (skim_val == .object) {
            var skim_ext = SkimAgentExtensions{};

            if (skim_val.object.get("default")) |v| {
                if (v == .bool) skim_ext.default = v.bool;
            }
            if (skim_val.object.get("mode")) |v| {
                if (v == .string) skim_ext.mode = try allocator.dupe(u8, v.string);
            }
            if (skim_val.object.get("model")) |v| {
                if (v == .string) skim_ext.model = try allocator.dupe(u8, v.string);
            }

            agent.skim = skim_ext;
        }
    }

    // Parse protocol (optional, defaults to .acp)
    if (obj.get("protocol")) |proto_val| {
        if (proto_val == .string) {
            if (std.mem.eql(u8, proto_val.string, "opencode")) {
                agent.protocol = .opencode;
            }
            // "acp" or unknown values default to .acp (already set)
        }
    }

    return agent;
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
// Environment Variable Expansion
// =============================================================================

/// Expand ${VAR} syntax in env values from user's environment
pub fn expandEnvValue(allocator: Allocator, value: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, value, "${") and std.mem.endsWith(u8, value, "}")) {
        const var_name = value[2 .. value.len - 1];
        const expanded = std.process.getEnvVarOwned(allocator, var_name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return try allocator.dupe(u8, ""),
            else => return err,
        };
        return expanded;
    }
    return try allocator.dupe(u8, value);
}

/// Expand all env vars in an agent config, returning expanded EnvVar slice
pub fn expandAgentEnv(allocator: Allocator, agent: AgentServerConfig) ![]const EnvVar {
    const env = agent.env orelse return &.{};
    if (env.len == 0) return &.{};

    var expanded = try allocator.alloc(EnvVar, env.len);
    errdefer allocator.free(expanded);

    for (env, 0..) |ev, i| {
        expanded[i] = .{
            .name = try allocator.dupe(u8, ev.name),
            .value = try expandEnvValue(allocator, ev.value),
        };
    }

    return expanded;
}

// =============================================================================
// Agent Configuration Helpers
// =============================================================================

/// Get configured agent servers from config file.
/// Returns null if config cannot be loaded or no agents are configured.
/// Caller must free returned agents using freeAgentServers().
pub fn getConfiguredAgents(allocator: Allocator) !?[]const AgentServerConfig {
    const config = load(allocator) catch return null;
    // Note: caller takes ownership of agent_servers, we don't free the full config
    return config.agent_servers;
}

/// Find the default agent from configured agents.
/// Returns index of agent marked as default, or null if none marked.
pub fn findDefaultAgentIndex(agents: []const AgentServerConfig) ?usize {
    for (agents, 0..) |agent, i| {
        if (agent.skim) |skim| {
            if (skim.default) return i;
        }
    }
    return null;
}

/// Free a single agent server config
fn freeAgentServer(allocator: Allocator, agent: *const AgentServerConfig) void {
    allocator.free(agent.name);
    if (agent.command.len > 0) allocator.free(agent.command);
    if (agent.args) |args| {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }
    if (agent.env) |env| {
        for (env) |ev| {
            allocator.free(ev.name);
            allocator.free(ev.value);
        }
        allocator.free(env);
    }
    if (agent.skim) |skim| {
        if (skim.mode) |m| allocator.free(m);
        if (skim.model) |m| allocator.free(m);
    }
}

/// Free agent servers array and all contained data.
pub fn freeAgentServers(allocator: Allocator, agents: []const AgentServerConfig) void {
    for (agents) |*agent| {
        freeAgentServer(allocator, agent);
    }
    allocator.free(agents);
}

/// Free expanded env vars
pub fn freeExpandedEnv(allocator: Allocator, env: []const EnvVar) void {
    for (env) |ev| {
        allocator.free(ev.name);
        allocator.free(ev.value);
    }
    allocator.free(env);
}

/// Free config and all owned memory
pub fn freeConfig(allocator: Allocator, config: Config) void {
    if (config.agent_servers) |agents| {
        freeAgentServers(allocator, agents);
    }
}

// Legacy alias for compatibility during transition
pub const AgentConfig = AgentServerConfig;
pub const freeAgents = freeAgentServers;

// =============================================================================
// Tests
// =============================================================================

test "parse agent_panel_side config from json" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "agent_panel_side": "right"
        \\}
    ;

    const config = try parseConfig(allocator, json);
    defer freeConfig(allocator, config);

    try std.testing.expectEqual(Config.AgentPanelSide.right, config.agent_panel_side);
}

test "parse agent_servers config from json" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "agent_servers": {
        \\    "Claude Code": {
        \\      "command": "claude",
        \\      "args": ["acp"],
        \\      "env": {
        \\        "ANTHROPIC_API_KEY": "${ANTHROPIC_API_KEY}"
        \\      },
        \\      "skim": {
        \\        "default": true,
        \\        "model": "opus",
        \\        "mode": "plan"
        \\      }
        \\    },
        \\    "Codex": {
        \\      "command": "codex"
        \\    }
        \\  }
        \\}
    ;

    const config = try parseConfig(allocator, json);
    defer freeConfig(allocator, config);

    const agents = config.agent_servers orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), agents.len);

    // Find Claude Code agent (order not guaranteed in object)
    var claude_idx: ?usize = null;
    var codex_idx: ?usize = null;
    for (agents, 0..) |agent, i| {
        if (std.mem.eql(u8, agent.name, "Claude Code")) claude_idx = i;
        if (std.mem.eql(u8, agent.name, "Codex")) codex_idx = i;
    }

    // Claude Code agent
    const claude = agents[claude_idx.?];
    try std.testing.expectEqualStrings("Claude Code", claude.name);
    try std.testing.expectEqualStrings("claude", claude.command);
    try std.testing.expectEqual(@as(usize, 1), claude.args.?.len);
    try std.testing.expectEqualStrings("acp", claude.args.?[0]);
    try std.testing.expectEqual(@as(usize, 1), claude.env.?.len);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", claude.env.?[0].name);
    try std.testing.expectEqualStrings("${ANTHROPIC_API_KEY}", claude.env.?[0].value);
    try std.testing.expectEqual(true, claude.skim.?.default);
    try std.testing.expectEqualStrings("opus", claude.skim.?.model.?);
    try std.testing.expectEqualStrings("plan", claude.skim.?.mode.?);

    // Codex agent - minimal config
    const codex = agents[codex_idx.?];
    try std.testing.expectEqualStrings("Codex", codex.name);
    try std.testing.expectEqualStrings("codex", codex.command);
    try std.testing.expectEqual(@as(?[]const []const u8, null), codex.args);
    try std.testing.expectEqual(@as(?SkimAgentExtensions, null), codex.skim);
}

test "findDefaultAgentIndex returns correct index" {
    var agents: [3]AgentServerConfig = undefined;
    agents[0] = .{ .name = "Agent 1", .command = "cmd1", .skim = .{ .default = false } };
    agents[1] = .{ .name = "Agent 2", .command = "cmd2", .skim = .{ .default = true } };
    agents[2] = .{ .name = "Agent 3", .command = "cmd3", .skim = .{ .default = false } };

    const idx = findDefaultAgentIndex(&agents);
    try std.testing.expectEqual(@as(?usize, 1), idx);
}

test "findDefaultAgentIndex returns null when no default" {
    var agents: [2]AgentServerConfig = undefined;
    agents[0] = .{ .name = "Agent 1", .command = "cmd1", .skim = .{ .default = false } };
    agents[1] = .{ .name = "Agent 2", .command = "cmd2", .skim = null };

    const idx = findDefaultAgentIndex(&agents);
    try std.testing.expectEqual(@as(?usize, null), idx);
}

test "expandEnvValue expands variable" {
    const allocator = std.testing.allocator;

    // Test literal value (no expansion)
    const literal = try expandEnvValue(allocator, "literal_value");
    defer allocator.free(literal);
    try std.testing.expectEqualStrings("literal_value", literal);

    // Test expansion syntax with non-existent var (returns empty)
    const missing = try expandEnvValue(allocator, "${NONEXISTENT_VAR_12345}");
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("", missing);

    // Test expansion with existing var (HOME should exist)
    const home = try expandEnvValue(allocator, "${HOME}");
    defer allocator.free(home);
    try std.testing.expect(home.len > 0);
}

test "parse protocol field from agent config" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "agent_servers": {
        \\    "Opencode Agent": {
        \\      "command": "opencode",
        \\      "args": ["serve"],
        \\      "protocol": "opencode"
        \\    },
        \\    "Claude Code": {
        \\      "command": "claude",
        \\      "args": ["acp"]
        \\    }
        \\  }
        \\}
    ;

    const config = try parseConfig(allocator, json);
    defer freeConfig(allocator, config);

    const agents = config.agent_servers orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), agents.len);

    // Find agents by name
    var opencode_idx: ?usize = null;
    var claude_idx: ?usize = null;
    for (agents, 0..) |agent, i| {
        if (std.mem.eql(u8, agent.name, "Opencode Agent")) opencode_idx = i;
        if (std.mem.eql(u8, agent.name, "Claude Code")) claude_idx = i;
    }

    // Opencode agent should have opencode protocol
    const opencode_agent = agents[opencode_idx.?];
    try std.testing.expectEqual(Protocol.opencode, opencode_agent.protocol);

    // Claude Code agent should default to acp protocol
    const claude_agent = agents[claude_idx.?];
    try std.testing.expectEqual(Protocol.acp, claude_agent.protocol);
}
