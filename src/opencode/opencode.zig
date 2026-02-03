// =============================================================================
// Opencode Module
// =============================================================================
//
// HTTP-based protocol for communicating with Opencode AI agents.
// Uses REST API + Server-Sent Events (SSE) for streaming.
//
// Architecture:
// - protocol.zig: Request/response types from OpenAPI spec
// - sse.zig: Server-Sent Events stream parser
// - client.zig: HTTP client for Opencode REST API
//
// Usage (Phase 2 will add OpencodeManager):
// ```zig
// const opencode = @import("opencode");
// var client = try opencode.Client.init(allocator, "http://localhost:4096");
// defer client.deinit();
//
// const health = try client.healthCheck();
// const session_id = try client.createSession();
// try client.sendPromptAsync(session_id, prompt_request);
// var event_stream = try client.connectEventStream();
// ```
//
// =============================================================================

pub const protocol = @import("protocol.zig");
pub const sse = @import("sse.zig");
pub const client = @import("client.zig");

// Re-export commonly used types
pub const Client = client.Client;
pub const ClientError = client.ClientError;
pub const SseParser = sse.SseParser;
pub const SseEvent = sse.SseEvent;
pub const EventType = protocol.EventType;
pub const HealthResponse = protocol.HealthResponse;
pub const Session = protocol.Session;
pub const PromptAsyncRequest = protocol.PromptAsyncRequest;
pub const Part = protocol.Part;
pub const createTextPrompt = protocol.createTextPrompt;

// =============================================================================
// Tests - Import all module tests
// =============================================================================

test {
    _ = protocol;
    _ = sse;
    _ = client;
}
