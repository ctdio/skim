const std = @import("std");
const types = @import("types.zig");
const caps = @import("capabilities.zig");

// =============================================================================
// Content Blocks
// =============================================================================

/// Text content block
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

/// Resource link content block
pub const ResourceLinkContent = struct {
    type: []const u8 = "resourceLink",
    uri: []const u8,
    name: ?[]const u8 = null,
};

/// Embedded resource (inline file content)
pub const EmbeddedResource = struct {
    uri: []const u8,
    mimeType: []const u8,
    text: []const u8,
};

/// Embedded resource content block
pub const EmbeddedResourceContent = struct {
    type: []const u8 = "resource",
    resource: EmbeddedResource,
};

/// Diff content block (from agent tool calls)
pub const DiffContent = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

/// Content block union - skim supports text, resource_link, embedded_resource, and diff
pub const ContentBlock = union(enum) {
    text: TextContent,
    resource_link: ResourceLinkContent,
    embedded_resource: EmbeddedResourceContent,
    diff: DiffContent,
};

// =============================================================================
// Initialize (Client -> Agent)
// =============================================================================

/// Parameters for initialize request
pub const InitializeParams = struct {
    protocol_version: u32,
    client_capabilities: caps.ClientCapabilities,
    client_info: caps.PeerInfo,
};

/// Auth method (placeholder - varies by agent)
pub const AuthMethod = struct {
    type: []const u8,
};

/// Result from initialize response
pub const InitializeResult = struct {
    protocol_version: u32,
    agent_capabilities: caps.AgentCapabilities,
    agent_info: caps.PeerInfo,
    auth_methods: []const AuthMethod = &.{},
};

// =============================================================================
// Session Management
// =============================================================================

/// MCP server stdio transport configuration
pub const StdioTransport = struct {
    type: []const u8 = "stdio",
    command: []const u8,
    args: []const []const u8 = &.{},
};

/// MCP server HTTP transport configuration
pub const HttpTransport = struct {
    type: []const u8 = "http",
    url: []const u8,
};

/// MCP server configuration for session/new
pub const McpServerConfig = struct {
    name: []const u8,
    /// Transport is either stdio or http (as raw JSON for flexibility)
    transport_json: ?[]const u8 = null,
};

/// Parameters for session/new request
pub const SessionNewParams = struct {
    /// Working directory for the session (absolute path)
    cwd: []const u8,
    /// Optional MCP servers to connect
    mcp_servers: []const McpServerConfig = &.{},
    /// Optional session ID to resume (if agent supports sessionCapabilities.resume)
    /// When set, the agent will load history from the existing session instead of creating new
    @"resume": ?[]const u8 = null,
};

/// Information about an available session mode
pub const ModeInfo = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Session modes configuration
pub const SessionModes = struct {
    current_mode_id: ?[]const u8 = null,
    available_modes: []const ModeInfo = &.{},
};

/// Information about an available model
pub const ModelInfo = struct {
    model_id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Session models configuration
pub const SessionModels = struct {
    current_model_id: ?[]const u8 = null,
    available_models: []const ModelInfo = &.{},
};

/// Result from session/new response
pub const SessionNewResult = struct {
    session_id: types.SessionId,
    modes: ?SessionModes = null,
    models: ?SessionModels = null,
};

/// Parameters for session/load request
/// Used to resume a previous session
pub const SessionLoadParams = struct {
    /// Session ID to resume
    session_id: types.SessionId,
    /// Working directory for the session
    cwd: []const u8,
    /// Optional MCP servers to connect
    mcp_servers: []const McpServerConfig = &.{},
};

/// Result from session/load response
/// Same as session/new - agent replays history via session/update notifications
pub const SessionLoadResult = struct {
    session_id: types.SessionId,
    modes: ?SessionModes = null,
    models: ?SessionModels = null,
};

// =============================================================================
// Prompt Turn
// =============================================================================

/// Parameters for session/prompt request
pub const SessionPromptParams = struct {
    session_id: types.SessionId,
    content: []const ContentBlock,
};

/// Result from session/prompt response
pub const SessionPromptResult = struct {
    stop_reason: types.StopReason,
};

/// Parameters for session/cancel request
pub const SessionCancelParams = struct {
    session_id: types.SessionId,
};

/// Parameters for session/set_mode request
pub const SessionSetModeParams = struct {
    session_id: types.SessionId,
    mode_id: []const u8,
};

/// Parameters for session/set_model request
pub const SessionSetModelParams = struct {
    session_id: types.SessionId,
    model_id: []const u8,
};

// =============================================================================
// Agent Plan
// =============================================================================

/// Priority level for plan entries
pub const PlanEntryPriority = enum {
    high,
    medium,
    low,

    pub fn fromString(s: []const u8) PlanEntryPriority {
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "low")) return .low;
        return .medium; // Default to medium
    }
};

/// Status of a plan entry
pub const PlanEntryStatus = enum {
    pending,
    in_progress,
    completed,

    pub fn fromString(s: []const u8) PlanEntryStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        return .pending; // Default to pending
    }
};

/// A single entry in the agent's plan (todo item)
pub const PlanEntry = struct {
    content: []const u8,
    priority: PlanEntryPriority = .medium,
    status: PlanEntryStatus = .pending,
};

/// Plan update in session/update notification
pub const PlanUpdate = struct {
    entries: []const PlanEntry,
};

// =============================================================================
// Session Update (Notification from Agent)
// =============================================================================

/// File location referenced by tool calls
pub const FileLocation = struct {
    path: []const u8,
    line: ?u32 = null,
};

/// Message update in session/update notification
pub const MessageUpdate = struct {
    type: []const u8 = "message_update",
    content: []const ContentBlock,
};

/// Tool call in session/update notification
pub const ToolCall = struct {
    tool_call_id: types.ToolCallId,
    title: ?[]const u8 = null,
    kind: types.ToolCallKind = .other,
    status: types.ToolCallStatus = .pending,
    locations: []const FileLocation = &.{},
    content: []const ContentBlock = &.{},
    raw_input: ?[]const u8 = null,
    raw_output: ?[]const u8 = null,
    // Claude Code specific fields
    tool_name: ?[]const u8 = null, // "Bash", "Edit", "Read", etc.
    command: ?[]const u8 = null, // For Bash tools: the command being executed
    description: ?[]const u8 = null, // For Bash tools: short description
};

/// Tool call update in session/update notification
pub const ToolCallUpdate = struct {
    tool_call_id: types.ToolCallId,
    status: ?types.ToolCallStatus = null,
    content: []const ContentBlock = &.{},
    // Claude Code specific fields for tool responses
    tool_name: ?[]const u8 = null,
    stdout: ?[]const u8 = null, // For Bash tools: command output
    stderr: ?[]const u8 = null, // For Bash tools: error output
    interrupted: bool = false, // For Bash tools: was the command interrupted
    terminal_id: ?[]const u8 = null, // For terminal-based tools: reference to terminal output
};

/// Type of session update notification
pub const SessionUpdateType = enum {
    agent_message_chunk,
    agent_thought_chunk,
    tool_call,
    tool_call_update,
    plan,
    current_mode_update,
    available_commands_update,
    unknown,

    pub fn fromString(s: []const u8) SessionUpdateType {
        if (std.mem.eql(u8, s, "agent_message_chunk")) return .agent_message_chunk;
        if (std.mem.eql(u8, s, "agent_thought_chunk")) return .agent_thought_chunk;
        if (std.mem.eql(u8, s, "tool_call")) return .tool_call;
        if (std.mem.eql(u8, s, "tool_call_update")) return .tool_call_update;
        if (std.mem.eql(u8, s, "plan")) return .plan;
        if (std.mem.eql(u8, s, "current_mode_update")) return .current_mode_update;
        if (std.mem.eql(u8, s, "available_commands_update")) return .available_commands_update;
        return .unknown;
    }
};

/// Current mode update in session/update notification
pub const CurrentModeUpdate = struct {
    mode_id: []const u8,
};

// =============================================================================
// Slash Commands
// =============================================================================

/// Input specification for a slash command
pub const AvailableCommandInput = struct {
    /// Hint to display when input hasn't been provided
    hint: []const u8,
};

/// A slash command advertised by the agent
pub const AvailableCommand = struct {
    /// Command identifier (e.g., "web", "test", "plan")
    name: []const u8,
    /// Human-readable description of what the command does
    description: []const u8,
    /// Optional input specification
    input: ?AvailableCommandInput = null,
};

/// Available commands update in session/update notification
pub const AvailableCommandsUpdate = struct {
    commands: []const AvailableCommand,
};

/// Parameters for session/update notification
pub const SessionUpdateParams = struct {
    session_id: types.SessionId,
    update_type: SessionUpdateType = .unknown,
    message: ?MessageUpdate = null,
    tool_call: ?ToolCall = null,
    tool_call_update: ?ToolCallUpdate = null,
    plan: ?PlanUpdate = null,
    current_mode_update: ?CurrentModeUpdate = null,
    available_commands: ?AvailableCommandsUpdate = null,
};

// =============================================================================
// Permission Request (Request from Agent)
// =============================================================================

/// Permission option presented to user
pub const PermissionOption = struct {
    option_id: []const u8,
    name: []const u8,
    kind: types.PermissionKind,
};

/// Parameters for session/request_permission request (agent -> client)
pub const RequestPermissionParams = struct {
    session_id: types.SessionId,
    tool_call_id: types.ToolCallId,
    title: []const u8,
    description: ?[]const u8 = null,
    options: []const PermissionOption,
};

/// Result for session/request_permission (client -> agent)
pub const RequestPermissionResult = union(enum) {
    selected: struct {
        selected_option: []const u8,
    },
    cancelled: void,
};

// =============================================================================
// File System (Request from Agent)
// =============================================================================

/// Parameters for fs/read_text_file request (agent -> client)
pub const ReadTextFileParams = struct {
    session_id: types.SessionId,
    path: []const u8,
    /// Starting line number (1-based)
    line: ?u32 = null,
    /// Maximum lines to read
    limit: ?u32 = null,
};

/// Result for fs/read_text_file (client -> agent)
pub const ReadTextFileResult = struct {
    content: []const u8,
};

/// Parameters for fs/write_text_file request (agent -> client)
pub const WriteTextFileParams = struct {
    session_id: types.SessionId,
    path: []const u8,
    content: []const u8,
};

// =============================================================================
// Terminal (Request from Agent)
// =============================================================================

/// Environment variable for terminal
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Parameters for terminal/create request (agent -> client)
pub const TerminalCreateParams = struct {
    session_id: types.SessionId,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const EnvVar = &.{},
    cwd: ?[]const u8 = null,
    output_byte_limit: ?u32 = null,
};

/// Result for terminal/create (client -> agent)
pub const TerminalCreateResult = struct {
    terminal_id: []const u8,
};

/// Parameters for terminal/output request (agent -> client)
pub const TerminalOutputParams = struct {
    session_id: types.SessionId,
    terminal_id: []const u8,
};

/// Exit status for terminal
pub const ExitStatus = struct {
    exit_code: ?i32 = null,
    signal: ?[]const u8 = null,
};

/// Result for terminal/output (client -> agent)
pub const TerminalOutputResult = struct {
    output: []const u8,
    truncated: bool = false,
    exit_status: ?ExitStatus = null,
};

/// Parameters for terminal/wait_for_exit request (agent -> client)
pub const TerminalWaitParams = struct {
    session_id: types.SessionId,
    terminal_id: []const u8,
};

/// Result for terminal/wait_for_exit (client -> agent)
pub const TerminalWaitResult = struct {
    exit_code: ?i32 = null,
    signal: ?[]const u8 = null,
};

/// Parameters for terminal/kill request (agent -> client)
pub const TerminalKillParams = struct {
    session_id: types.SessionId,
    terminal_id: []const u8,
};

/// Parameters for terminal/release request (agent -> client)
pub const TerminalReleaseParams = struct {
    session_id: types.SessionId,
    terminal_id: []const u8,
};

// =============================================================================
// Tests
// =============================================================================

test "ContentBlock text" {
    const block = ContentBlock{ .text = .{ .text = "Hello" } };
    switch (block) {
        .text => |t| try std.testing.expectEqualStrings("Hello", t.text),
        else => unreachable,
    }
}

test "InitializeParams construction" {
    const params = InitializeParams{
        .protocol_version = types.PROTOCOL_VERSION,
        .client_capabilities = caps.skimClientCapabilities(),
        .client_info = caps.skimClientInfo(),
    };
    try std.testing.expectEqual(@as(u32, 1), params.protocol_version);
    try std.testing.expectEqualStrings("skim", params.client_info.name);
}

test "ToolCall default values" {
    const tc = ToolCall{
        .tool_call_id = "tc_001",
    };
    try std.testing.expectEqual(types.ToolCallKind.other, tc.kind);
    try std.testing.expectEqual(types.ToolCallStatus.pending, tc.status);
    try std.testing.expect(tc.title == null);
}
