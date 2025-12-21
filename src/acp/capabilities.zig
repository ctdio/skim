const std = @import("std");

// =============================================================================
// Client Capabilities (sent during initialize)
// =============================================================================

/// File system capabilities the client can provide
pub const FileSystemCapabilities = struct {
    /// Client supports fs/read_text_file requests
    read_text_file: bool = false,
    /// Client supports fs/write_text_file requests
    write_text_file: bool = false,
};

/// Client capabilities sent during initialize
pub const ClientCapabilities = struct {
    file_system: FileSystemCapabilities = .{},
    /// Client supports terminal/* methods
    terminal: bool = false,
};

// =============================================================================
// Agent Capabilities (received during initialize)
// =============================================================================

/// Prompt content type support
pub const PromptCapabilities = struct {
    /// Agent accepts ContentBlock::Image
    image: bool = false,
    /// Agent accepts ContentBlock::Audio
    audio: bool = false,
    /// Agent accepts ContentBlock::Resource (embedded context)
    embedded_context: bool = false,
};

/// MCP transport capabilities
pub const McpTransportCapabilities = struct {
    /// Agent supports HTTP transport for MCP servers
    http: bool = false,
    /// Agent supports SSE transport (deprecated)
    sse: bool = false,
};

/// Agent capabilities received during initialize
pub const AgentCapabilities = struct {
    /// Agent supports session/load for resuming sessions
    load_session: bool = false,
    /// Content types the agent accepts in prompts
    prompt: PromptCapabilities = .{},
    /// MCP transport support
    mcp: McpTransportCapabilities = .{},
};

// =============================================================================
// Peer Information
// =============================================================================

/// Information about client or agent
pub const PeerInfo = struct {
    /// Programmatic identifier (used as fallback display name)
    name: []const u8,
    /// Human-readable display name
    title: ?[]const u8 = null,
    /// Version string
    version: []const u8,
};

// =============================================================================
// Skim Defaults
// =============================================================================

/// Returns skim's default client capabilities
/// - Read-only file access (no writes - review mode)
/// - No terminal access
pub fn skimClientCapabilities() ClientCapabilities {
    return .{
        .file_system = .{
            .read_text_file = true,
            .write_text_file = false, // Review is read-only
        },
        .terminal = false, // No shell access
    };
}

/// Returns skim's client info
pub fn skimClientInfo() PeerInfo {
    return .{
        .name = "skim",
        .title = "Skim Diff Viewer",
        .version = "0.1.0",
    };
}

// =============================================================================
// Tests
// =============================================================================

test "skimClientCapabilities" {
    const caps = skimClientCapabilities();
    try std.testing.expect(caps.file_system.read_text_file);
    try std.testing.expect(!caps.file_system.write_text_file);
    try std.testing.expect(!caps.terminal);
}

test "skimClientInfo" {
    const info = skimClientInfo();
    try std.testing.expectEqualStrings("skim", info.name);
    try std.testing.expectEqualStrings("Skim Diff Viewer", info.title.?);
}
