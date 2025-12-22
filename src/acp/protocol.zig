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

/// Diff content block (from agent tool calls)
pub const DiffContent = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

/// Content block union - skim supports text, resource_link, and diff
pub const ContentBlock = union(enum) {
    text: TextContent,
    resource_link: ResourceLinkContent,
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
};

/// Result from session/new response
pub const SessionNewResult = struct {
    session_id: types.SessionId,
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
};

/// Type of session update notification
pub const SessionUpdateType = enum {
    agent_message_chunk,
    agent_thought_chunk,
    tool_call,
    tool_call_update,
    unknown,

    pub fn fromString(s: []const u8) SessionUpdateType {
        if (std.mem.eql(u8, s, "agent_message_chunk")) return .agent_message_chunk;
        if (std.mem.eql(u8, s, "agent_thought_chunk")) return .agent_thought_chunk;
        if (std.mem.eql(u8, s, "tool_call")) return .tool_call;
        if (std.mem.eql(u8, s, "tool_call_update")) return .tool_call_update;
        return .unknown;
    }
};

/// Parameters for session/update notification
pub const SessionUpdateParams = struct {
    session_id: types.SessionId,
    update_type: SessionUpdateType = .unknown,
    message: ?MessageUpdate = null,
    tool_call: ?ToolCall = null,
    tool_call_update: ?ToolCallUpdate = null,
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
/// Note: Skim does not support this (read-only)
pub const WriteTextFileParams = struct {
    session_id: types.SessionId,
    path: []const u8,
    content: []const u8,
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
