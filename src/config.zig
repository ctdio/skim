const std = @import("std");
const skim_io = @import("skim_io");
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
    acp, // Agent Client Protocol (default, used by Claude Code)
    opencode, // HTTP + SSE based protocol
    codex, // Codex app-server protocol (stdio JSON-RPC without jsonrpc field)
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
    approval_policy: ?[]const u8 = null, // Codex: "never", "on-request", "unless-trusted", "always"
    sandbox_mode: ?[]const u8 = null, // Codex CLI: "read-only", "workspace-write", "danger-full-access"
    web_search: bool = false, // Codex CLI: enable native web search tool
};

/// A named PR sidebar filter query. The query is not validated here: the
/// sidebar parses it when the preset is applied and shows any error inline.
pub const PrFilterPreset = struct {
    name: []const u8,
    query: []const u8,
};

pub const PrFilters = struct {
    /// Preset name to apply on open; null = first preset.
    default: ?[]const u8 = null,
    /// In file order (std.json.ObjectMap preserves insertion order).
    presets: []const PrFilterPreset = &.{},

    pub fn deinit(self: *const PrFilters, allocator: Allocator) void {
        if (self.default) |name| allocator.free(name);
        for (self.presets) |preset| {
            allocator.free(preset.name);
            allocator.free(preset.query);
        }
        allocator.free(self.presets);
    }

    /// `presets`, or the built-in `[{ all, "" }]` when none are configured.
    /// Never empty.
    pub fn effectivePresets(self: *const PrFilters) []const PrFilterPreset {
        if (self.presets.len == 0) return &builtin_presets;
        return self.presets;
    }

    /// Index into `effectivePresets()` of `default`; 0 when unset or unknown.
    pub fn defaultIndex(self: *const PrFilters) usize {
        const name = self.default orelse return 0;
        for (self.effectivePresets(), 0..) |preset, i| {
            if (std.mem.eql(u8, preset.name, name)) return i;
        }
        return 0;
    }
};

pub const Config = struct {
    agent_panel_side: AgentPanelSide = .left,
    agent_servers: ?[]const AgentServerConfig = null,
    pr_filters: PrFilters = .{},

    pub const AgentPanelSide = enum {
        left,
        right,
    };

    /// Free everything `parseConfig` allocated. A default `Config{}` owns
    /// nothing, so this is safe on the value `load` returns after an error.
    pub fn deinit(self: *const Config, allocator: Allocator) void {
        if (self.agent_servers) |servers| freeAgentServers(allocator, servers);
        self.pr_filters.deinit(allocator);
    }
};

const builtin_presets = [_]PrFilterPreset{.{ .name = "All open", .query = "" }};

/// Upper bound on `~/.skim/config.json`. Generous: it only guards against
/// reading something that is not a config file at all.
const max_config_bytes = 4 * 1024 * 1024;

// =============================================================================
// Config Loading
// =============================================================================

/// Load config from ~/.skim/config.json
pub fn load(allocator: Allocator) !Config {
    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);
    return loadFromPath(allocator, config_path);
}

/// Load config from an absolute path. Fails with `error.StreamTooLong` past
/// `max_config_bytes`.
pub fn loadFromPath(allocator: Allocator, path: []const u8) !Config {
    const file = try std.Io.Dir.openFileAbsolute(skim_io.get(), path, .{});
    defer file.close(skim_io.get());

    const bytes = try skim_io.readAllAlloc(file, allocator, max_config_bytes);
    defer allocator.free(bytes);

    if (bytes.len == 0) {
        return Config{};
    }

    return parseConfig(allocator, bytes);
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
    errdefer config.deinit(allocator);

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

    if (root.object.get("pr_filters")) |filters_val| {
        config.pr_filters = try parsePrFilters(allocator, filters_val);
    }

    return config;
}

/// Parse agent_servers object into slice of AgentServerConfig
fn parseAgentServers(allocator: Allocator, servers: std.json.ObjectMap) ![]const AgentServerConfig {
    if (servers.count() == 0) return &.{};

    var agents: std.ArrayListUnmanaged(AgentServerConfig) = .empty;
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
        errdefer freeAgentServer(allocator, &agent);
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
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
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
            var env_vars: std.ArrayListUnmanaged(EnvVar) = .empty;
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
            } else if (std.mem.eql(u8, proto_val.string, "codex")) {
                agent.protocol = .codex;
            }
            // "acp" or unknown values default to .acp (already set)
        }
    }

    // Parse approval_policy (optional, codex thread/start parameter)
    if (obj.get("approval_policy")) |v| {
        if (v == .string) agent.approval_policy = try allocator.dupe(u8, v.string);
    }

    // Parse sandbox_mode (optional, codex CLI launch flag)
    if (obj.get("sandbox_mode")) |v| {
        if (v == .string) agent.sandbox_mode = try allocator.dupe(u8, v.string);
    }

    // Parse web_search (optional, codex CLI launch flag)
    if (obj.get("web_search")) |v| {
        if (v == .bool) agent.web_search = v.bool;
    }

    return agent;
}

/// Parse `pr_filters`. Anything that is not the documented shape is ignored
/// rather than rejected, leaving the defaults.
fn parsePrFilters(allocator: Allocator, value: std.json.Value) !PrFilters {
    if (value != .object) return .{};

    var filters = PrFilters{};
    errdefer filters.deinit(allocator);

    if (value.object.get("default")) |default_val| {
        if (default_val == .string) filters.default = try allocator.dupe(u8, default_val.string);
    }
    if (value.object.get("presets")) |presets_val| {
        if (presets_val == .object) filters.presets = try parsePrFilterPresets(allocator, presets_val.object);
    }
    return filters;
}

/// String entries in file order; non-string entries are skipped.
fn parsePrFilterPresets(allocator: Allocator, presets: std.json.ObjectMap) ![]const PrFilterPreset {
    var list: std.ArrayListUnmanaged(PrFilterPreset) = .empty;
    errdefer {
        for (list.items) |preset| {
            allocator.free(preset.name);
            allocator.free(preset.query);
        }
        list.deinit(allocator);
    }

    var iter = presets.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const query = try allocator.dupe(u8, entry.value_ptr.string);
        errdefer allocator.free(query);
        try list.append(allocator, .{ .name = name, .query = query });
    }

    return try list.toOwnedSlice(allocator);
}

/// Get the path to the config file: ~/.skim/config.json
pub fn getConfigFilePath(allocator: Allocator) ![]u8 {
    const home = try skim_io.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.skim/config.json", .{home});
}

/// Get the path to the skim directory: ~/.skim
pub fn getSkimDir(allocator: Allocator) ![]u8 {
    const home = try skim_io.getEnvVarOwned(allocator, "HOME");
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
        const expanded = skim_io.getEnvVarOwned(allocator, var_name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return try allocator.dupe(u8, ""),
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
    // The caller takes ownership of agent_servers; everything else is freed here.
    config.pr_filters.deinit(allocator);
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
    if (agent.approval_policy) |p| allocator.free(p);
    if (agent.sandbox_mode) |mode| allocator.free(mode);
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
    config.deinit(allocator);
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
        \\      "command": "codex",
        \\      "protocol": "codex",
        \\      "approval_policy": "never",
        \\      "sandbox_mode": "workspace-write",
        \\      "web_search": true
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
    try std.testing.expectEqual(Protocol.codex, codex.protocol);
    try std.testing.expectEqualStrings("never", codex.approval_policy.?);
    try std.testing.expectEqualStrings("workspace-write", codex.sandbox_mode.?);
    try std.testing.expect(codex.web_search);
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

test "parse pr_filters default and presets in file order" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "pr_filters": {
        \\    "default": "ready",
        \\    "presets": {
        \\      "ready": "-is:draft review:requested ci:!failure",
        \\      "mine": "author:@me",
        \\      "all": ""
        \\    }
        \\  }
        \\}
    ;

    const config = try parseConfig(allocator, json);
    defer config.deinit(allocator);

    const presets = config.pr_filters.effectivePresets();
    try std.testing.expectEqual(@as(usize, 3), presets.len);
    try std.testing.expectEqualStrings("ready", presets[0].name);
    try std.testing.expectEqualStrings("-is:draft review:requested ci:!failure", presets[0].query);
    try std.testing.expectEqualStrings("mine", presets[1].name);
    try std.testing.expectEqualStrings("author:@me", presets[1].query);
    try std.testing.expectEqualStrings("all", presets[2].name);
    try std.testing.expectEqualStrings("", presets[2].query);
    try std.testing.expectEqualStrings("ready", config.pr_filters.default.?);
    try std.testing.expectEqual(@as(usize, 0), config.pr_filters.defaultIndex());
}

test "pr_filters default picks the named preset's index" {
    const allocator = std.testing.allocator;

    const json =
        \\{"pr_filters": {"default": "mine", "presets": {"ready": "is:ready", "mine": "author:@me"}}}
    ;

    const config = try parseConfig(allocator, json);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.pr_filters.defaultIndex());
}

test "missing pr_filters yields the built-in All open preset as default" {
    const allocator = std.testing.allocator;

    const config = try parseConfig(allocator, "{}");
    defer config.deinit(allocator);

    const presets = config.pr_filters.effectivePresets();
    try std.testing.expectEqual(@as(usize, 1), presets.len);
    try std.testing.expectEqualStrings("All open", presets[0].name);
    try std.testing.expectEqualStrings("", presets[0].query);
    try std.testing.expectEqual(@as(usize, 0), config.pr_filters.defaultIndex());
}

test "default Config has the built-in All open preset" {
    const config = Config{};
    try std.testing.expectEqualStrings("All open", config.pr_filters.effectivePresets()[0].name);
}

test "empty presets object behaves like missing" {
    const allocator = std.testing.allocator;

    const config = try parseConfig(allocator, "{\"pr_filters\": {\"default\": \"all\", \"presets\": {}}}");
    defer config.deinit(allocator);

    const presets = config.pr_filters.effectivePresets();
    try std.testing.expectEqual(@as(usize, 1), presets.len);
    try std.testing.expectEqualStrings("All open", presets[0].name);
    try std.testing.expectEqual(@as(usize, 0), config.pr_filters.defaultIndex());
}

test "non-string preset values are skipped" {
    const allocator = std.testing.allocator;

    const json =
        \\{"pr_filters": {"presets": {"n": 5, "ok": "is:draft", "o": {}, "arr": ["x"], "nil": null, "ok2": "is:ready"}}}
    ;

    const config = try parseConfig(allocator, json);
    defer config.deinit(allocator);

    const presets = config.pr_filters.effectivePresets();
    try std.testing.expectEqual(@as(usize, 2), presets.len);
    try std.testing.expectEqualStrings("ok", presets[0].name);
    try std.testing.expectEqualStrings("ok2", presets[1].name);
}

test "only non-string preset values behaves like missing" {
    const allocator = std.testing.allocator;

    const config = try parseConfig(allocator, "{\"pr_filters\": {\"presets\": {\"n\": 5}}}");
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("All open", config.pr_filters.effectivePresets()[0].name);
}

test "non-object pr_filters is ignored" {
    const allocator = std.testing.allocator;

    for ([_][]const u8{
        "{\"pr_filters\": \"ready\"}",
        "{\"pr_filters\": [1, 2]}",
        "{\"pr_filters\": null}",
        "{\"pr_filters\": {\"default\": 3, \"presets\": [\"x\"]}}",
    }) |json| {
        const config = try parseConfig(allocator, json);
        defer config.deinit(allocator);
        try std.testing.expectEqual(@as(?[]const u8, null), config.pr_filters.default);
        try std.testing.expectEqual(@as(usize, 1), config.pr_filters.effectivePresets().len);
    }
}

test "unknown default name falls back to index 0" {
    const allocator = std.testing.allocator;

    const config = try parseConfig(allocator, "{\"pr_filters\": {\"default\": \"nope\", \"presets\": {\"a\": \"x\", \"b\": \"y\"}}}");
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), config.pr_filters.defaultIndex());
}

test "Config.deinit frees pr_filters when agent_servers is null" {
    const allocator = std.testing.allocator;

    const config = try parseConfig(allocator, "{\"pr_filters\": {\"default\": \"a\", \"presets\": {\"a\": \"is:draft\"}}}");
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const AgentServerConfig, null), config.agent_servers);
    try std.testing.expectEqual(@as(usize, 1), config.pr_filters.presets.len);
}

test "Config.deinit frees both agent_servers and pr_filters" {
    const allocator = std.testing.allocator;

    const json =
        \\{"agent_servers": {"A": {"command": "a", "args": ["x"]}}, "pr_filters": {"presets": {"a": "is:draft"}}}
    ;

    const config = try parseConfig(allocator, json);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.agent_servers.?.len);
    try std.testing.expectEqual(@as(usize, 1), config.pr_filters.presets.len);
}

test "freeConfig frees pr_filters" {
    const allocator = std.testing.allocator;

    const config = try parseConfig(allocator, "{\"pr_filters\": {\"default\": \"a\", \"presets\": {\"a\": \"is:draft\"}}}");
    defer freeConfig(allocator, config);

    try std.testing.expectEqual(@as(usize, 1), config.pr_filters.presets.len);
}

test "parseConfig leaks nothing when allocation fails partway" {
    const json =
        \\{"agent_servers": {"A": {"command": "a"}}, "pr_filters": {"default": "a", "presets": {"a": "is:draft", "b": "is:ready"}}}
    ;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAndDeinit, .{json});
}

fn parseAndDeinit(allocator: Allocator, json: []const u8) !void {
    const config = try parseConfig(allocator, json);
    config.deinit(allocator);
}

test "loadFromPath reads a config larger than 16 KiB" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(&tmp, "config.json");
    defer allocator.free(path);

    const big_query = try allocator.alloc(u8, 20 * 1024);
    defer allocator.free(big_query);
    @memset(big_query, 'x');
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"agent_servers\":{{\"A\":{{\"command\":\"a\"}}}},\"pr_filters\":{{\"presets\":{{\"big\":\"{s}\"}}}}}}",
        .{big_query},
    );
    defer allocator.free(json);
    try writeTestFile(path, json);

    const config = try loadFromPath(allocator, path);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.agent_servers.?.len);
    try std.testing.expectEqual(big_query.len, config.pr_filters.presets[0].query.len);
}

test "loadFromPath on an empty file returns default Config" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(&tmp, "config.json");
    defer allocator.free(path);
    try writeTestFile(path, "");

    const config = try loadFromPath(allocator, path);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const AgentServerConfig, null), config.agent_servers);
    try std.testing.expectEqual(@as(usize, 0), config.pr_filters.presets.len);
}

test "loadFromPath rejects a file over max_config_bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(&tmp, "config.json");
    defer allocator.free(path);

    const bytes = try allocator.alloc(u8, max_config_bytes + 1);
    defer allocator.free(bytes);
    @memset(bytes, ' ');
    try writeTestFile(path, bytes);

    try std.testing.expectError(error.StreamTooLong, loadFromPath(allocator, path));
}

test "loadFromPath on a missing file returns FileNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(&tmp, "absent.json");
    defer allocator.free(path);

    try std.testing.expectError(error.FileNotFound, loadFromPath(allocator, path));
}

fn tmpFilePath(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    defer std.testing.allocator.free(relative);
    return skim_io.absolutePathAlloc(std.testing.allocator, relative);
}

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(skim_io.get(), path, .{ .truncate = true });
    defer file.close(skim_io.get());
    try file.writeStreamingAll(skim_io.get(), bytes);
}
