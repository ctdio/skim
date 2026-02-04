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
// - server.zig: Server process spawning and health checking
// - manager.zig: Session lifecycle management
//
// Usage:
// ```zig
// const opencode = @import("opencode");
//
// // Using OpencodeManager (recommended):
// var manager = opencode.OpencodeManager.init(allocator);
// defer manager.deinit();
// try manager.connect(.{
//     .opencode_path = "/usr/local/bin/opencode",
//     .port = 4096,
// });
// try manager.sendPrompt("Hello!");
// while (manager.poll()) |event| {
//     switch (event) {
//         .message_chunk => |chunk| // handle delta text
//         .message_complete => // response done
//     }
// }
//
// // Or using Client directly:
// var client = try opencode.Client.init(allocator, "http://localhost:4096");
// defer client.deinit();
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
pub const server = @import("server.zig");
pub const manager = @import("manager.zig");

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
pub const ModelSpec = protocol.ModelSpec;
pub const createTextPrompt = protocol.createTextPrompt;

// Re-export manager types
pub const OpencodeManager = manager.OpencodeManager;
pub const Status = manager.Status;
pub const Event = manager.Event;
pub const MessageQueue = manager.MessageQueue;
pub const ConnectConfig = manager.ConnectConfig;
pub const OwnedModelInfo = manager.OwnedModelInfo;

// Re-export server types
pub const ServerConfig = server.ServerConfig;
pub const ServerError = server.ServerError;
pub const spawnServer = server.spawnServer;
pub const waitForHealth = server.waitForHealth;
pub const terminateServer = server.terminateServer;

// =============================================================================
// Tests - Import all module tests
// =============================================================================

test {
    _ = protocol;
    _ = sse;
    _ = client;
    _ = server;
    _ = manager;
}
