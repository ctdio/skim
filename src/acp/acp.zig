//! Agent Client Protocol (ACP) implementation for skim.
//!
//! ACP enables skim to communicate with AI coding agents like Claude Code,
//! Gemini CLI, and Codex. This module implements the client side of the
//! protocol, allowing skim to spawn agents, send prompts, and receive
//! streaming responses.
//!
//! Protocol specification: https://agentclientprotocol.com

// Re-export submodules
pub const types = @import("types.zig");
pub const capabilities = @import("capabilities.zig");
pub const protocol = @import("protocol.zig");
pub const codec = @import("codec.zig");
pub const process = @import("process.zig");
pub const transport = @import("transport.zig");
pub const client = @import("client.zig");
pub const manager = @import("manager.zig");

// Convenience re-exports for common types
pub const PROTOCOL_VERSION = types.PROTOCOL_VERSION;
pub const StopReason = types.StopReason;
pub const ToolCallStatus = types.ToolCallStatus;
pub const ToolCallKind = types.ToolCallKind;

pub const ContentBlock = protocol.ContentBlock;
pub const TextContent = protocol.TextContent;

pub const JsonRpcId = codec.JsonRpcId;
pub const Encoder = codec.Encoder;
pub const Decoder = codec.Decoder;
pub const DecodedMessage = codec.DecodedMessage;

// Phase 2: Agent lifecycle
pub const AgentProcess = process.AgentProcess;
pub const SpawnConfig = process.SpawnConfig;
pub const StdioTransport = transport.StdioTransport;
pub const Client = client.Client;

// Phase 3: TUI integration
pub const AcpManager = manager.AcpManager;
pub const AgentInfo = manager.AcpManager.AgentInfo;
pub const ConfigAgent = manager.ConfigAgent;
pub const ConfigEnvVar = manager.ConfigEnvVar;
pub const SkimAgentExtensions = manager.SkimAgentExtensions;
pub const loadAgentList = manager.loadAgentList;
pub const freeAgentList = manager.freeAgentList;
pub const findDefaultOrFirst = manager.findDefaultOrFirst;

// =============================================================================
// Tests
// =============================================================================

test {
    // Run all submodule tests
    @import("std").testing.refAllDecls(@This());
}
