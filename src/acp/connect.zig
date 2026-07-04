const std = @import("std");
const App = @import("../app.zig").App;
const acp = @import("acp.zig");
const agent = @import("../agent/agent.zig");
const opencode = @import("../opencode/opencode.zig");
const codex_mod = @import("../codex/codex.zig");
const app_config = @import("../config.zig");
const agent_mode = @import("../modes/agent_mode.zig");

const Allocator = std.mem.Allocator;

/// Context for ACP connection thread
pub const AcpConnectContext = struct {
    app: *App,
    cwd: []const u8,
    agent: ?*const acp.AgentInfo, // Selected agent to connect to (null = use discovery)
    tab_id: u32, // Target tab ID for the connection
};

/// Context for Opencode connection thread
pub const OpencodeConnectContext = struct {
    mgr: *opencode.OpencodeManager,
    opencode_path: []const u8,
    port: u16,
    cwd: ?[]const u8,
};

/// Context for Codex connection thread
pub const CodexConnectContext = struct {
    allocator: Allocator,
    mgr: *codex_mod.CodexManager,
    command: []const u8,
    args: ?[]const []const u8,
    cwd: ?[]const u8,
    model: ?[]const u8,
    mode: ?[]const u8,
    approval_policy: ?[]const u8,
    sandbox_mode: ?[]const u8,
    web_search: bool,
};

/// Unified pending connection state (replaces separate ACP/Opencode fields)
pub const PendingConnection = struct {
    thread: std.Thread,
    tab_id: u32,
    ctx: ConnectContext,

    pub const ConnectContext = union(enum) {
        acp: *AcpConnectContext,
        opencode: *OpencodeConnectContext,
        codex: *CodexConnectContext,
    };
};

const CodexLaunchArgs = struct {
    args: []const []const u8,
    sandbox_override: ?[]const u8, // heap-allocated, must be freed separately
};

/// Start an ACP agent session (non-blocking)
/// If agents are configured, may show selection menu first.
pub fn startAcpSession(app: *App) !void {
    std.log.info("ACP: startAcpSession called", .{});

    // Check if connection already in progress
    if (app.pending_connection != null) {
        std.log.info("ACP: Connection already in progress", .{});
        app.showStatusMessage("Connection already in progress...");
        return;
    }

    // Check if already connected
    if (app.getActiveAcpManager()) |mgr| {
        if (mgr.isConnected()) {
            std.log.info("ACP: Already connected", .{});
            app.showStatusMessage("Agent already connected");
            return;
        }
    }

    // Load configured agents (if not already loaded)
    if (app.state.configured_agents == null) {
        app.state.configured_agents = loadConfiguredAgents(app);
    }

    const agents = app.state.configured_agents orelse {
        // No agents configured - show error in agent panel and stay in agent mode
        std.log.warn("ACP: No agents configured in ~/.skim/config.json", .{});
        if (app.getActiveAgentState()) |agent_state| {
            agent_state.addMessage(.system, "No agents configured. Add agents to ~/.skim/config.json") catch {};
        }
        return;
    };

    // Decision logic for agent selection
    if (agents.len == 0) {
        std.log.warn("ACP: Empty agents list in config", .{});
        if (app.getActiveAgentState()) |agent_state| {
            agent_state.addMessage(.system, "No agents configured. Add agents to ~/.skim/config.json") catch {};
        }
        return;
    }

    // Always show agent selection menu
    std.log.info("ACP: {d} agent(s) configured, showing selection menu", .{agents.len});
    app.state.agent_selection_idx = 0;
    app.mode = .agent_selection;
    app.needs_render = true;
}

/// Connect to a specific agent.
/// Agent info is required - no auto-discovery.
/// Manager is stored directly in the target tab (pending_tab_for_selection or active tab).
pub fn connectToAgent(app: *App, agent_info: ?*const acp.AgentInfo) !void {
    // Ensure tab manager exists
    const tm = app.ensureTabManager() catch |err| {
        std.log.err("ACP: Failed to ensure tab manager: {any}", .{err});
        app.showStatusMessage("Failed to initialize tabs");
        return;
    };

    // Find target tab (pending_tab_for_selection or active)
    const target_tab: *agent.AgentTab = blk: {
        if (app.state.pending_tab_for_selection) |pending_id| {
            if (tm.findTabById(pending_id)) |idx| {
                if (tm.getTab(idx)) |tab| {
                    break :blk tab;
                }
            }
        }
        break :blk tm.activeTab() orelse {
            std.log.err("ACP: No target tab found", .{});
            app.showStatusMessage("No tab available");
            return;
        };
    };

    // Check protocol for Opencode/Codex routing
    if (agent_info) |info| {
        if (info.protocol == .opencode) {
            try connectToOpencodeAgent(app, target_tab, info);
            return;
        }
        if (info.protocol == .codex) {
            try connectToCodexAgent(app, target_tab, info);
            return;
        }
    }

    // Clean up any existing manager on target tab
    target_tab.disconnectAll();

    // Create and initialize the manager with discovering status
    const mgr = try app.allocator.create(acp.AcpManager);
    mgr.* = acp.AcpManager.init(app.allocator);
    mgr.status = .discovering;

    // Store server name from config (for display in title bar)
    if (agent_info) |info| {
        mgr.server_name = app.allocator.dupe(u8, info.name) catch null;
    }

    // Store directly in target tab
    target_tab.manager = .{ .acp = mgr };

    // Clear pending tab selection
    app.state.pending_tab_for_selection = null;

    if (agent_info) |info| {
        app.showStatusMessage("Connecting to agent...");
        std.log.info("ACP: Connecting to {s} for tab {d}", .{ info.name, target_tab.id });
    } else {
        app.showStatusMessage("Discovering agent...");
    }
    app.needs_render = true;

    // Store connection context (static lifetime for thread)
    const ctx = try app.allocator.create(AcpConnectContext);
    ctx.* = .{
        .app = app,
        .cwd = app.state.git_repo_root,
        .agent = agent_info,
        .tab_id = target_tab.id,
    };

    // Spawn background thread for connection
    const thread = std.Thread.spawn(.{}, acpConnectThreadFn, .{ctx}) catch |err| {
        std.log.err("Failed to spawn ACP connect thread: {any}", .{err});
        app.showStatusMessage("Failed to start connection");
        app.allocator.destroy(ctx);
        // Clean up the manager we stored in the tab
        target_tab.manager = null;
        mgr.deinit();
        app.allocator.destroy(mgr);
        return;
    };

    app.pending_connection = .{
        .thread = thread,
        .tab_id = target_tab.id,
        .ctx = .{ .acp = ctx },
    };
}

/// Connect to the currently selected agent in the selection menu
pub fn connectToSelectedAgent(app: *App) !void {
    const agents = app.state.configured_agents orelse return;
    if (app.state.agent_selection_idx >= agents.len) return;
    app.pending_agent_connect_idx = null;
    try connectToAgent(app, &agents[app.state.agent_selection_idx]);
}

/// Queue the selected agent to connect after the next render, entering agent mode.
pub fn queueSelectedAgentConnection(app: *App) void {
    const agents = app.state.configured_agents orelse return;
    if (app.state.agent_selection_idx >= agents.len) return;

    app.pending_agent_connect_idx = app.state.agent_selection_idx;
    app.mode = .agent;
    app.needs_render = true;
}

/// Start the connection queued via `queueSelectedAgentConnection`.
pub fn startQueuedAgentConnection(app: *App) !void {
    const idx = app.pending_agent_connect_idx orelse return;
    const agents = app.state.configured_agents orelse {
        app.pending_agent_connect_idx = null;
        return;
    };
    if (idx >= agents.len) {
        app.pending_agent_connect_idx = null;
        return;
    }

    app.state.agent_selection_idx = idx;
    try connectToSelectedAgent(app);
}

/// Load configured agents from config file.
/// Returns null if no agents are configured.
pub fn loadConfiguredAgents(app: *App) ?[]acp.AgentInfo {
    // Try to load from config - now uses standard agent_servers format
    const cfg_agents = app_config.getConfiguredAgents(app.allocator) catch null;

    if (cfg_agents) |agents| {
        if (agents.len > 0) {
            // Convert config.AgentServerConfig to acp.ConfigAgent
            const acp_agents = app.allocator.alloc(acp.ConfigAgent, agents.len) catch {
                app_config.freeAgentServers(app.allocator, agents);
                return null;
            };
            defer app.allocator.free(acp_agents);

            for (agents, 0..) |cfg, i| {
                // Convert env vars
                const env_slice: ?[]const acp.ConfigEnvVar = if (cfg.env) |env| blk: {
                    const env_copy = app.allocator.alloc(acp.ConfigEnvVar, env.len) catch {
                        app_config.freeAgentServers(app.allocator, agents);
                        return null;
                    };
                    for (env, 0..) |ev, j| {
                        env_copy[j] = .{ .name = ev.name, .value = ev.value };
                    }
                    break :blk env_copy;
                } else null;

                // Convert skim extensions
                const skim_ext: ?acp.SkimAgentExtensions = if (cfg.skim) |s|
                    .{ .default = s.default, .mode = s.mode, .model = s.model }
                else
                    null;

                // Convert protocol enum
                const protocol: acp.AcpManager.Protocol = switch (cfg.protocol) {
                    .acp => .acp,
                    .opencode => .opencode,
                    .codex => .codex,
                };

                acp_agents[i] = .{
                    .name = cfg.name,
                    .command = cfg.command,
                    .args = cfg.args,
                    .env = env_slice,
                    .skim = skim_ext,
                    .protocol = protocol,
                    .approval_policy = cfg.approval_policy,
                    .sandbox_mode = cfg.sandbox_mode,
                    .web_search = cfg.web_search,
                };
            }

            // loadAgentList will dupe all strings and expand env vars
            const result = (acp.loadAgentList(app.allocator, acp_agents) catch null) orelse {
                // Free converted env slices
                for (acp_agents) |a| {
                    if (a.env) |e| app.allocator.free(e);
                }
                app_config.freeAgentServers(app.allocator, agents);
                return null;
            };

            // Free converted env slices
            for (acp_agents) |a| {
                if (a.env) |e| app.allocator.free(e);
            }
            // Clean up config agents (loadAgentList made copies)
            app_config.freeAgentServers(app.allocator, agents);
            return result;
        }
        app_config.freeAgentServers(app.allocator, agents);
    }

    // No agents configured
    return null;
}

/// Disconnect from the ACP agent for the active tab
pub fn stopAcpSession(app: *App) void {
    if (app.tab_manager) |*tm| {
        if (tm.activeTab()) |tab| {
            if (tab.manager != null) {
                tab.disconnectAll();
                app.showStatusMessage("Disconnected from agent");
                app.needs_render = true;
            }
        }
    }
}

/// Check ACP agent status for the active tab
pub fn getAcpStatus(app: *App) ?acp.AcpManager.Status {
    if (app.getActiveAcpManager()) |mgr| {
        return mgr.status;
    }
    return null;
}

/// Poll all managers: check connection thread, then poll each tab's manager.
pub fn pollAllManagers(app: *App) void {
    const connection_active = pollConnectionThread(app);

    // Don't poll tabs while an ACP or Codex connection thread is active — it would clear
    // messages that waitForResponse() in the background thread needs.
    if (connection_active) {
        if (app.pending_connection) |conn| {
            switch (conn.ctx) {
                .acp, .codex => return,
                .opencode => {},
            }
        }
    }

    // Poll all tabs via unified ManagerHandle.pollEvents
    if (app.tab_manager) |*tm| {
        for (tm.tabs.items, 0..) |*tab, tab_idx| {
            const handle = tab.manager orelse continue;
            pollTabManager(app, handle, &tab.agent_state, tab_idx == tm.active_idx);
        }
    }
}

// =========================================================================
// Helpers
// =========================================================================

/// Background thread function for ACP connection
fn acpConnectThreadFn(ctx: *AcpConnectContext) void {
    std.log.info("ACP: Background connection thread started for tab {d}", .{ctx.tab_id});

    // Get the manager from the target tab
    const mgr: *acp.AcpManager = blk: {
        if (ctx.app.tab_manager) |*tm| {
            if (tm.findTabById(ctx.tab_id)) |idx| {
                if (tm.getTab(idx)) |tab| {
                    if (tab.getActiveAcpManager()) |m| {
                        break :blk m;
                    }
                }
            }
        }
        std.log.err("ACP: No manager found for tab {d}", .{ctx.tab_id});
        return;
    };

    // Get agent info from context (required - no auto-discovery)
    const agent_info: acp.AgentInfo = if (ctx.agent) |a| a.* else {
        std.log.err("ACP: No agent provided in context", .{});
        mgr.status = .failed;
        return;
    };
    std.log.info("ACP: Using agent: {s}", .{agent_info.name});

    // Update status to connecting
    mgr.status = .connecting;

    // Convert AgentInfo.EnvVar to AcpManager.EnvVar for connect call
    const mgr_env = ctx.app.allocator.alloc(acp.AcpManager.EnvVar, agent_info.env.len) catch {
        std.log.err("ACP: Failed to allocate env vars", .{});
        return;
    };
    defer ctx.app.allocator.free(mgr_env);
    for (agent_info.env, 0..) |ev, i| {
        mgr_env[i] = .{ .name = ev.name, .value = ev.value };
    }

    // Connect to agent (spawn + initialize)
    mgr.connect(agent_info.command, agent_info.args, ctx.cwd, mgr_env) catch |err| {
        std.log.err("ACP: Connect failed: {}", .{err});
        return;
    };
    std.log.info("ACP: Connected, now creating session...", .{});

    // Create session
    mgr.createSession(ctx.cwd) catch |err| {
        std.log.err("ACP: CreateSession failed: {}, status now={s}", .{ err, mgr.getStatusString() });
        return;
    };
    std.log.info("ACP: Session created successfully! status={s}", .{mgr.getStatusString()});

    // Apply configured mode if set (e.g., "plan", "bypassPermissions")
    if (agent_info.mode) |mode_id| {
        std.log.info("ACP: Applying configured mode: {s}", .{mode_id});
        mgr.setMode(mode_id) catch |err| {
            std.log.warn("ACP: Failed to set mode: {}", .{err});
        };
    }

    // Apply configured model if set and matches an available model
    if (agent_info.model) |model_name| {
        std.log.info("ACP: Applying configured model: {s}", .{model_name});
        _ = mgr.applyConfiguredModel(model_name);
    }
}

/// Connect to an Opencode agent for the given tab (non-blocking)
fn connectToOpencodeAgent(app: *App, target_tab: *agent.AgentTab, agent_info: *const acp.AgentInfo) !void {
    // Clean up any existing managers on target tab
    target_tab.disconnectAll();

    // Clear pending tab selection
    app.state.pending_tab_for_selection = null;

    // Create Opencode manager and store it in the tab immediately (enables rendering)
    const mgr = try target_tab.createOpencodeManager();

    app.showStatusMessage("Connecting to Opencode...");
    std.log.info("Opencode: Connecting to {s} for tab {d}", .{ agent_info.name, target_tab.id });
    app.needs_render = true;

    // Store connection context (static lifetime for thread)
    const ctx = try app.allocator.create(OpencodeConnectContext);
    ctx.* = .{
        .mgr = mgr,
        .opencode_path = agent_info.command,
        .port = 4096,
        .cwd = app.state.git_repo_root,
    };

    // Spawn background thread for connection
    const thread = std.Thread.spawn(.{}, opcConnectThreadFn, .{ctx}) catch |err| {
        std.log.err("Failed to spawn Opencode connect thread: {any}", .{err});
        app.showStatusMessage("Failed to start connection");
        app.allocator.destroy(ctx);
        target_tab.manager = null;
        mgr.deinit();
        app.allocator.destroy(mgr);
        return;
    };

    app.pending_connection = .{
        .thread = thread,
        .tab_id = target_tab.id,
        .ctx = .{ .opencode = ctx },
    };
}

fn opcConnectThreadFn(ctx: *OpencodeConnectContext) void {
    std.log.info("Opencode: Background connection thread started", .{});

    ctx.mgr.connect(.{
        .opencode_path = ctx.opencode_path,
        .port = ctx.port,
        .cwd = ctx.cwd,
        .spawn_server = true,
    }) catch |err| {
        std.log.err("Opencode: Connect failed: {}", .{err});
        return;
    };

    std.log.info("Opencode: Connected successfully", .{});
}

/// Connect to a Codex agent for the given tab (non-blocking)
fn connectToCodexAgent(app: *App, target_tab: *agent.AgentTab, agent_info: *const acp.AgentInfo) !void {
    // Clean up any existing managers on target tab
    target_tab.disconnectAll();

    // Clear pending tab selection
    app.state.pending_tab_for_selection = null;

    // Create Codex manager and store it in the tab immediately (enables rendering)
    const mgr = try target_tab.createCodexManager();

    app.showStatusMessage("Connecting to Codex...");
    std.log.info("Codex: Connecting to {s} for tab {d}", .{ agent_info.name, target_tab.id });
    app.needs_render = true;

    // Store connection context (static lifetime for thread)
    const ctx = try app.allocator.create(CodexConnectContext);
    ctx.* = .{
        .allocator = app.allocator,
        .mgr = mgr,
        .command = agent_info.command,
        .args = agent_info.args,
        .cwd = app.state.git_repo_root,
        .model = agent_info.model,
        .mode = agent_info.mode,
        .approval_policy = agent_info.approval_policy,
        .sandbox_mode = agent_info.sandbox_mode,
        .web_search = agent_info.web_search,
    };

    // Spawn background thread for connection
    const thread = std.Thread.spawn(.{}, codexConnectThreadFn, .{ctx}) catch |err| {
        std.log.err("Failed to spawn Codex connect thread: {any}", .{err});
        app.showStatusMessage("Failed to start connection");
        app.allocator.destroy(ctx);
        target_tab.manager = null;
        mgr.deinit();
        app.allocator.destroy(mgr);
        return;
    };

    app.pending_connection = .{
        .thread = thread,
        .tab_id = target_tab.id,
        .ctx = .{ .codex = ctx },
    };
}

fn codexConnectThreadFn(ctx: *CodexConnectContext) void {
    std.log.info("Codex: Background connection thread started", .{});

    applyCodexSessionConfig(ctx.mgr, ctx.mode, ctx.approval_policy);

    const launch = buildCodexLaunchArgs(
        ctx.allocator,
        ctx.command,
        ctx.args,
        ctx.sandbox_mode,
        ctx.web_search,
    ) catch |err| {
        std.log.err("Codex: Failed to build launch args: {}", .{err});
        return;
    };
    defer ctx.allocator.free(launch.args);
    defer if (launch.sandbox_override) |s| ctx.allocator.free(s);

    // Connect to codex app-server (spawn process, handshake)
    ctx.mgr.connect(ctx.command, launch.args, ctx.cwd) catch |err| {
        std.log.err("Codex: Connect failed: {}", .{err});
        return;
    };

    std.log.info("Codex: Connected, starting thread...", .{});

    // Start a thread (creates conversation context)
    ctx.mgr.startThread(ctx.model, ctx.cwd) catch |err| {
        std.log.err("Codex: StartThread failed: {}", .{err});
        return;
    };

    std.log.info("Codex: Thread started successfully", .{});
}

fn buildCodexLaunchArgs(
    allocator: Allocator,
    command: []const u8,
    args: ?[]const []const u8,
    sandbox_mode: ?[]const u8,
    web_search: bool,
) Allocator.Error!CodexLaunchArgs {
    const base_args = args orelse &.{};
    const is_native_codex = isCodexCommand(command);
    const app_server_index = if (is_native_codex) findArg(base_args, "app-server") else null;
    const should_append_app_server = is_native_codex and app_server_index == null;

    // Use -c config overrides so settings propagate into app-server mode.
    // Top-level CLI flags like --sandbox don't reliably reach the app-server subprocess.
    const sandbox_override: ?[]const u8 = if (sandbox_mode != null and is_native_codex)
        try std.fmt.allocPrint(allocator, "sandbox_mode=\"{s}\"", .{sandbox_mode.?})
    else
        null;
    errdefer if (sandbox_override) |s| allocator.free(s);

    const extra_count: usize =
        (if (sandbox_override != null) @as(usize, 2) else 0) +
        (if (web_search and is_native_codex) @as(usize, 1) else 0) +
        (if (should_append_app_server) @as(usize, 1) else 0);

    const result = try allocator.alloc([]const u8, base_args.len + extra_count);
    errdefer allocator.free(result);

    const insert_at = app_server_index orelse base_args.len;
    var next_index: usize = 0;

    for (base_args[0..insert_at]) |arg| {
        result[next_index] = arg;
        next_index += 1;
    }

    if (sandbox_override) |override| {
        result[next_index] = "-c";
        next_index += 1;
        result[next_index] = override;
        next_index += 1;
    }

    if (web_search and is_native_codex) {
        result[next_index] = "--search";
        next_index += 1;
    }

    for (base_args[insert_at..]) |arg| {
        result[next_index] = arg;
        next_index += 1;
    }

    if (should_append_app_server) {
        result[next_index] = "app-server";
    }

    return .{ .args = result, .sandbox_override = sandbox_override };
}

fn isCodexCommand(command: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(command), "codex");
}

fn findArg(args: []const []const u8, needle: []const u8) ?usize {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, needle)) return index;
    }
    return null;
}

fn applyCodexSessionConfig(
    mgr: *codex_mod.CodexManager,
    mode: ?[]const u8,
    approval_policy: ?[]const u8,
) void {
    mgr.requested_collaboration_mode = if (mode) |mode_id|
        codex_mod.protocol.CollaborationMode.fromString(mode_id)
    else
        null;

    mgr.requested_approval_policy = if (approval_policy) |policy_id|
        codex_mod.protocol.ApprovalPolicy.fromString(policy_id)
    else
        null;
}

/// Check if the pending connection thread completed and handle success/failure.
/// Returns true if a connection thread is still active.
fn pollConnectionThread(app: *App) bool {
    const conn = app.pending_connection orelse return false;

    const tab = getConnectingTab(app) orelse {
        // Tab disappeared — clean up connection state
        conn.thread.join();
        switch (conn.ctx) {
            .acp => |ctx| app.allocator.destroy(ctx),
            .opencode => |ctx| app.allocator.destroy(ctx),
            .codex => |ctx| app.allocator.destroy(ctx),
        }
        app.pending_connection = null;
        return false;
    };

    const handle = tab.manager orelse {
        // Manager was removed from the tab — clean up
        conn.thread.join();
        switch (conn.ctx) {
            .acp => |ctx| app.allocator.destroy(ctx),
            .opencode => |ctx| app.allocator.destroy(ctx),
            .codex => |ctx| app.allocator.destroy(ctx),
        }
        app.pending_connection = null;
        return false;
    };

    // Check if the manager is still initializing (thread still working)
    if (handle.isInitializing()) return true;

    // Thread is done — join and clean up
    conn.thread.join();

    switch (conn.ctx) {
        .acp => |ctx| {
            app.allocator.destroy(ctx);
            switch (handle) {
                .acp => |mgr| {
                    if (mgr.status == .session_active) {
                        const agent_name = mgr.getAgentDisplayName();
                        const model_name = mgr.getCurrentModelName();
                        const msg = if (model_name.len > 0)
                            std.fmt.allocPrint(app.allocator, "Connected to {s} · {s}", .{ agent_name, model_name }) catch "Connected"
                        else
                            std.fmt.allocPrint(app.allocator, "Connected to {s}", .{agent_name}) catch "Connected";
                        defer if (!std.mem.eql(u8, msg, "Connected")) app.allocator.free(msg);
                        app.showStatusMessage(msg);

                        maybeAddConnectionSystemMessage(getConnectingAgentState(app), true);

                        std.log.info("ACP: Connection complete for tab {d}", .{conn.tab_id});
                        mgr.sendNextQueuedPrompt();
                    } else if (mgr.status == .failed) {
                        app.showStatusMessage("Failed to connect to agent");
                        maybeAddConnectionSystemMessage(getConnectingAgentState(app), false);
                        tab.manager = null;
                        mgr.deinit();
                        app.allocator.destroy(mgr);
                    }
                },
                .opencode, .codex => {},
            }
        },
        .opencode => |ctx| {
            app.allocator.destroy(ctx);
            switch (handle) {
                .opencode => |mgr| {
                    if (mgr.status == .session_active) {
                        app.showStatusMessage("Connected to Opencode");
                        maybeAddConnectionSystemMessage(getConnectingAgentState(app), true);
                        std.log.info("Opencode: Connection complete for tab {d}", .{conn.tab_id});
                    } else if (mgr.status == .failed or mgr.status == .disconnected) {
                        app.showStatusMessage("Failed to connect to Opencode");
                        maybeAddConnectionSystemMessage(getConnectingAgentState(app), false);
                        tab.manager = null;
                        mgr.deinit();
                        app.allocator.destroy(mgr);
                    }
                },
                .acp, .codex => {},
            }
        },
        .codex => |ctx| {
            app.allocator.destroy(ctx);
            switch (handle) {
                .codex => |mgr| {
                    if (mgr.status == .thread_active) {
                        const model_name = mgr.model orelse "Codex";
                        const msg = std.fmt.allocPrint(app.allocator, "Connected to Codex · {s}", .{model_name}) catch "Connected to Codex";
                        defer if (!std.mem.eql(u8, msg, "Connected to Codex")) app.allocator.free(msg);
                        app.showStatusMessage(msg);

                        maybeAddConnectionSystemMessage(getConnectingAgentState(app), true);

                        std.log.info("Codex: Connection complete for tab {d}", .{conn.tab_id});
                    } else if (mgr.status == .@"error" or mgr.status == .disconnected) {
                        app.showStatusMessage("Failed to connect to Codex");
                        maybeAddConnectionSystemMessage(getConnectingAgentState(app), false);
                        tab.manager = null;
                        mgr.deinit();
                        app.allocator.destroy(mgr);
                    }
                },
                .acp, .opencode => {},
            }
        },
    }

    app.pending_connection = null;
    app.needs_render = true;
    return false;
}

fn maybeAddConnectionSystemMessage(agent_state_opt: ?*agent.AgentState, connected: bool) void {
    if (!connected) return;

    if (agent_state_opt) |agent_state_conn| {
        agent_state_conn.addMessage(.system, "Agent ready.") catch {};
    }
}

/// Get the tab being connected (via pending_connection.tab_id)
fn getConnectingTab(app: *App) ?*agent.AgentTab {
    const conn = app.pending_connection orelse return null;
    if (app.tab_manager) |*tm| {
        if (tm.findTabById(conn.tab_id)) |idx| {
            return tm.getTab(idx);
        }
    }
    return null;
}

/// Get the agent state for the tab being connected
fn getConnectingAgentState(app: *App) ?*agent.AgentState {
    if (getConnectingTab(app)) |tab| {
        return &tab.agent_state;
    }
    return null;
}

/// Poll a single tab's manager and route events to its agent state
fn pollTabManager(app: *App, handle: agent.tab_manager.ManagerHandle, agent_state_ptr: *agent.AgentState, is_active_tab: bool) void {
    const was_prompting = handle.isPrompting();

    const result = handle.pollEvents(app.allocator, agent_state_ptr);

    if (result.count > 0) app.needs_render = true;
    if (result.more_pending) app.needs_render = true;
    if (result.status_changed) app.needs_render = true;
    if (result.needs_line_map_dirty) agent_state_ptr.line_map_dirty = true;

    // Auto-execute staged shell commands when agent finishes prompting
    if (was_prompting and !handle.isPrompting()) {
        if (agent_state_ptr.hasStagedPrompt() and agent_state_ptr.isStagedShellCommand()) {
            const staged = agent_state_ptr.getStagedPrompt();
            agent_mode.handleShellCommand(app, agent_state_ptr, staged) catch {};
            agent_state_ptr.clearStagedPrompt();
        }
    }

    // Auto-send staged prompts when manager is ready
    if (handle.isReadyForAutoSend() and agent_state_ptr.hasStagedPrompt()) {
        if (agent_state_ptr.isStagedShellCommand()) {
            const staged = agent_state_ptr.getStagedPrompt();
            agent_mode.handleShellCommand(app, agent_state_ptr, staged) catch {};
            agent_state_ptr.clearStagedPrompt();
        } else if (agent_state_ptr.takeStagedPrompt()) |staged| {
            if (is_active_tab) {
                std.log.info("Agent: Auto-sending staged message ({d} bytes)", .{staged.len});
            }

            agent_state_ptr.addMessage(.user, staged) catch {};

            handle.sendPrompt(staged) catch |err| {
                std.log.err("Agent: Failed to send staged prompt: {any}", .{err});
                agent_state_ptr.addMessage(.system, "Failed to send staged message") catch {};
            };

            app.needs_render = true;
        }
    }
}

test "applyCodexSessionConfig enables plan collaboration mode" {
    var mgr = codex_mod.CodexManager.init(std.testing.allocator);
    defer mgr.deinit();

    applyCodexSessionConfig(&mgr, "plan", "never");

    try std.testing.expect(mgr.requested_collaboration_mode != null);
    try std.testing.expect(mgr.requested_collaboration_mode.? == .plan);
    try std.testing.expect(mgr.requested_approval_policy != null);
    try std.testing.expect(mgr.requested_approval_policy.? == .never);
}

test "applyCodexSessionConfig ignores unknown mode" {
    var mgr = codex_mod.CodexManager.init(std.testing.allocator);
    defer mgr.deinit();

    applyCodexSessionConfig(&mgr, "unknown-mode", "on-request");

    try std.testing.expect(mgr.requested_collaboration_mode == null);
    try std.testing.expect(mgr.requested_approval_policy != null);
    try std.testing.expect(mgr.requested_approval_policy.? == .on_request);
}

test "buildCodexLaunchArgs adds app-server and first-class settings" {
    const allocator = std.testing.allocator;

    const launch = try buildCodexLaunchArgs(allocator, "codex", null, "workspace-write", true);
    defer allocator.free(launch.args);
    defer if (launch.sandbox_override) |s| allocator.free(s);

    try std.testing.expectEqual(@as(usize, 4), launch.args.len);
    try std.testing.expectEqualStrings("-c", launch.args[0]);
    try std.testing.expectEqualStrings("sandbox_mode=\"workspace-write\"", launch.args[1]);
    try std.testing.expectEqualStrings("--search", launch.args[2]);
    try std.testing.expectEqualStrings("app-server", launch.args[3]);
}

test "buildCodexLaunchArgs inserts first-class settings before app-server" {
    const allocator = std.testing.allocator;
    const base_args = &[_][]const u8{
        "-c",
        "model=\"gpt-5.4\"",
        "app-server",
        "--listen",
        "stdio://",
    };

    const launch = try buildCodexLaunchArgs(allocator, "codex", base_args, "workspace-write", true);
    defer allocator.free(launch.args);
    defer if (launch.sandbox_override) |s| allocator.free(s);

    try std.testing.expectEqual(@as(usize, 8), launch.args.len);
    try std.testing.expectEqualStrings("-c", launch.args[0]);
    try std.testing.expectEqualStrings("model=\"gpt-5.4\"", launch.args[1]);
    try std.testing.expectEqualStrings("-c", launch.args[2]);
    try std.testing.expectEqualStrings("sandbox_mode=\"workspace-write\"", launch.args[3]);
    try std.testing.expectEqualStrings("--search", launch.args[4]);
    try std.testing.expectEqualStrings("app-server", launch.args[5]);
    try std.testing.expectEqualStrings("--listen", launch.args[6]);
    try std.testing.expectEqualStrings("stdio://", launch.args[7]);
}

test "maybeAddConnectionSystemMessage only emits ready message on success" {
    const allocator = std.testing.allocator;

    var agent_state = agent.AgentState.init(allocator, .right);
    defer agent_state.deinit();

    maybeAddConnectionSystemMessage(&agent_state, false);
    try std.testing.expectEqual(@as(usize, 0), agent_state.messages.items.len);

    maybeAddConnectionSystemMessage(&agent_state, true);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(agent.AgentState.Message.Role.system, agent_state.messages.items[0].role);
    try std.testing.expectEqualStrings("Agent ready.", agent_state.messages.items[0].content);
}
