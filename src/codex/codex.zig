//! Codex app-server protocol implementation for skim.
//!
//! Codex uses a stdio JSON-RPC protocol (without the "jsonrpc":"2.0" envelope)
//! for communicating with AI coding agents. This module implements the codec
//! (encoder/decoder) and protocol types for the Codex app-server wire format.
//!
//! Key differences from ACP:
//! - No "jsonrpc":"2.0" field in messages
//! - Thread/Turn model instead of Session/Prompt
//! - Server requests (messages with both id AND method) for approval prompts
//! - Item-based content (userMessage, agentMessage, commandExecution, etc.)

pub const protocol = @import("protocol.zig");
pub const codec = @import("codec.zig");

// Convenience re-exports for common types
pub const RequestId = codec.RequestId;
pub const Encoder = codec.Encoder;
pub const Decoder = codec.Decoder;
pub const DecodedMessage = codec.DecodedMessage;
pub const ServerRequest = codec.ServerRequest;
pub const Response = codec.Response;
pub const Notification = codec.Notification;

pub const Thread = protocol.Thread;
pub const Turn = protocol.Turn;
pub const Item = protocol.Item;
pub const TokenUsage = protocol.TokenUsage;
pub const TokenCounts = protocol.TokenCounts;
pub const ModelInfo = protocol.ModelInfo;
pub const ReasoningEffort = protocol.ReasoningEffort;
pub const ApprovalPolicy = protocol.ApprovalPolicy;
pub const ItemStartedParams = protocol.ItemStartedParams;

// =============================================================================
// Tests
// =============================================================================

test {
    @import("std").testing.refAllDecls(@This());
}
