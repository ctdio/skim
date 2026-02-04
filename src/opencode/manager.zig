const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const server = @import("server.zig");

// =============================================================================
// Opencode Manager
// =============================================================================
//
// Session lifecycle management for Opencode AI agents.
// Mirrors the AcpManager pattern for consistent integration.
//
// Architecture:
// - Manager owns server process lifecycle
// - SSE reader thread pushes events to MessageQueue
// - Main thread polls for events via poll()
//
// =============================================================================

const log = std.log.scoped(.opencode);

/// Manager status enum - tracks connection state
pub const Status = enum {
    idle,
    starting_server,
    connecting,
    session_active,
    prompting,
    disconnected,
    failed,
};

/// Event types from the SSE stream
pub const Event = union(enum) {
    /// Delta text chunk from message.part.updated
    message_chunk: MessageChunk,
    /// Message complete (session.idle)
    message_complete: void,
    /// Status changed
    status_change: Status,
    /// Error occurred
    err: EventError,

    pub const MessageChunk = struct {
        delta: []const u8,

        pub fn deinit(self: *MessageChunk, allocator: Allocator) void {
            allocator.free(self.delta);
        }
    };

    pub const EventError = struct {
        code: ErrorCode,
        message: ?[]const u8 = null,

        pub const ErrorCode = enum {
            connection_failed,
            parse_error,
            server_error,
            session_error,
        };

        pub fn deinit(self: *EventError, allocator: Allocator) void {
            if (self.message) |m| allocator.free(m);
        }
    };

    pub fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .message_chunk => |*chunk| chunk.deinit(allocator),
            .err => |*e| e.deinit(allocator),
            .message_complete, .status_change => {},
        }
    }
};

/// Thread-safe message queue for SSE thread -> main thread communication
pub const MessageQueue = struct {
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayList(Event),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MessageQueue {
        return .{
            .events = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessageQueue) void {
        // Free any remaining events
        for (self.events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
    }

    /// Push an event to the queue (thread-safe)
    pub fn push(self: *MessageQueue, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.append(self.allocator, event) catch {
            // If append fails, clean up the event
            var e = event;
            e.deinit(self.allocator);
        };
    }

    /// Pop an event from the queue (thread-safe)
    /// Returns null if queue is empty
    pub fn pop(self: *MessageQueue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    /// Get the number of pending events (thread-safe)
    pub fn len(self: *MessageQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.items.len;
    }
};

/// Configuration for connecting to opencode
pub const ConnectConfig = struct {
    /// Path to opencode executable
    opencode_path: []const u8,
    /// Port to connect on (or spawn server on)
    port: u16 = 4096,
    /// Working directory
    cwd: ?[]const u8 = null,
    /// Whether to spawn the server (vs connecting to existing)
    spawn_server: bool = true,
    /// Health check timeout in milliseconds
    health_timeout_ms: u64 = 30000,
};

/// Model info for display in picker (owned strings)
/// Compatible with ACP's OwnedModelInfo for unified UI handling
pub const OwnedModelInfo = struct {
    model_id: []const u8, // "provider/model" format for API
    name: ?[]const u8, // Display name (optional, falls back to model_id)
    description: ?[]const u8 = null, // Optional description
    variants: ?[]const []const u8 = null, // Optional variant list

    pub fn deinit(self: *OwnedModelInfo, allocator: Allocator) void {
        allocator.free(self.model_id);
        if (self.name) |n| allocator.free(n);
        if (self.description) |d| allocator.free(d);
        if (self.variants) |variants| {
            for (variants) |v| allocator.free(v);
            allocator.free(variants);
        }
    }
};

/// Manages Opencode agent sessions
pub const OpencodeManager = struct {
    allocator: Allocator,
    status: Status,
    client: ?*client_mod.Client,
    server_process: ?std.process.Child,
    session_id: ?[]const u8,
    message_queue: MessageQueue,

    // SSE reader thread
    sse_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    thread_exited: std.atomic.Value(bool),
    thread_was_detached: bool, // If true, don't destroy manager - thread may still access it

    // SSE connection (stored so we can close it to unblock the reader thread)
    sse_connection: ?*client_mod.Client.EventStreamConnection,
    sse_conn_mutex: std.Thread.Mutex,

    // Connection config (stored for reconnection)
    connect_config: ?ConnectConfig,
    connect_cwd_owned: ?[]const u8,
    base_url: ?[]const u8,

    // Agent and model selection
    current_agent: ?[]const u8, // "build", "plan", or custom agent name
    current_model: ?protocol.ModelSpec, // { providerID, modelID }
    current_variant: ?[]const u8, // Model variant (e.g. "high")
    default_model_id: ?[]const u8, // Default model from server config

    // Available models (fetched from server)
    available_models: std.ArrayListUnmanaged(OwnedModelInfo),
    current_model_id: ?[]const u8, // Current model as "provider/model" string

    pub fn init(allocator: Allocator) OpencodeManager {
        return .{
            .allocator = allocator,
            .status = .idle,
            .client = null,
            .server_process = null,
            .session_id = null,
            .message_queue = MessageQueue.init(allocator),
            .sse_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .thread_exited = std.atomic.Value(bool).init(true), // No thread running initially
            .thread_was_detached = false,
            .sse_connection = null,
            .sse_conn_mutex = .{},
            .connect_config = null,
            .connect_cwd_owned = null,
            .base_url = null,
            .current_agent = null,
            .current_model = null,
            .current_variant = null,
            .default_model_id = null,
            .available_models = .{},
            .current_model_id = null,
        };
    }

    pub fn deinit(self: *OpencodeManager) void {
        self.disconnect();
        // Only clean up message queue if thread was joined cleanly
        // If thread was detached, it may still be accessing the queue
        if (!self.thread_was_detached) {
            self.message_queue.deinit();
        }

        // Free agent and model strings
        if (self.current_agent) |agent| {
            self.allocator.free(agent);
            self.current_agent = null;
        }
        if (self.current_model) |model| {
            self.allocator.free(model.providerID);
            self.allocator.free(model.modelID);
            self.current_model = null;
        }
        if (self.current_variant) |variant| {
            self.allocator.free(variant);
            self.current_variant = null;
        }
        if (self.default_model_id) |id| {
            self.allocator.free(id);
            self.default_model_id = null;
        }
        if (self.connect_cwd_owned) |cwd| {
            self.allocator.free(cwd);
            self.connect_cwd_owned = null;
        }

        // Free available models
        self.clearAvailableModels();

        // Free current model ID
        if (self.current_model_id) |id| {
            self.allocator.free(id);
            self.current_model_id = null;
        }
    }

    /// Clear available models list
    fn clearAvailableModels(self: *OpencodeManager) void {
        for (self.available_models.items) |*model| {
            model.deinit(self.allocator);
        }
        self.available_models.deinit(self.allocator);
        self.available_models = .{};
    }

    /// Check if manager can be safely destroyed.
    /// Returns false if thread was detached (thread may still access manager).
    pub fn canSafelyDestroy(self: *const OpencodeManager) bool {
        return !self.thread_was_detached;
    }

    /// Connect to an opencode server (spawning if configured)
    pub fn connect(self: *OpencodeManager, config: ConnectConfig) !void {
        if (self.status != .idle and self.status != .disconnected and self.status != .failed) {
            return error.AlreadyConnected;
        }

        // Clear any previous owned cwd
        if (self.connect_cwd_owned) |cwd| {
            self.allocator.free(cwd);
            self.connect_cwd_owned = null;
        }

        // Store config for potential reconnection
        var config_copy = config;
        if (config.cwd) |cwd| {
            self.connect_cwd_owned = try self.allocator.dupe(u8, cwd);
            config_copy.cwd = self.connect_cwd_owned;
        }
        self.connect_config = config_copy;

        // Build base URL
        const base_url = try std.fmt.allocPrint(self.allocator, "http://localhost:{d}", .{config.port});
        errdefer self.allocator.free(base_url);
        self.base_url = base_url;

        // Spawn server if requested
        if (config.spawn_server) {
            self.status = .starting_server;
            log.info("Starting opencode server...", .{});

            // Get log file path
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch null;
            defer if (home) |h| self.allocator.free(h);

            const log_file = if (home) |h|
                std.fmt.allocPrint(self.allocator, "{s}/.skim/opencode-server.log", .{h}) catch null
            else
                null;
            defer if (log_file) |f| self.allocator.free(f);

            const server_config = server.ServerConfig{
                .opencode_path = config.opencode_path,
                .port = config.port,
                .cwd = config.cwd,
                .log_file = log_file,
            };

            self.server_process = server.spawnServer(self.allocator, server_config) catch |err| {
                log.err("Failed to spawn server: {}", .{err});
                self.status = .failed;
                return error.SpawnFailed;
            };
        }

        // Connect to server
        self.status = .connecting;
        log.info("Connecting to opencode at {s}...", .{base_url});

        // Create client
        const client_ptr = try self.allocator.create(client_mod.Client);
        errdefer self.allocator.destroy(client_ptr);

        client_ptr.* = try client_mod.Client.init(self.allocator, base_url);
        self.client = client_ptr;

        // Wait for health
        server.waitForHealth(client_ptr, config.health_timeout_ms) catch |err| {
            log.err("Health check failed: {}", .{err});
            self.status = .failed;
            return error.HealthCheckFailed;
        };

        // Create session
        const session_id = client_ptr.createSession() catch |err| {
            log.err("Failed to create session: {}", .{err});
            self.status = .failed;
            return error.SessionFailed;
        };

        self.session_id = try self.allocator.dupe(u8, session_id);
        self.allocator.free(session_id);

        log.info("Session created: {s}", .{self.session_id.?});

        // Start SSE reader thread
        self.should_stop.store(false, .release);
        self.thread_exited.store(false, .release);
        self.sse_thread = std.Thread.spawn(.{}, sseReaderThread, .{self}) catch |err| {
            log.err("Failed to spawn SSE reader thread: {}", .{err});
            self.status = .failed;
            self.thread_exited.store(true, .release);
            return error.ThreadSpawnFailed;
        };

        self.status = .session_active;
        log.info("Connected successfully", .{});

        // Fetch default model config in background (don't fail connect if this fails)
        self.fetchDefaultModelConfig() catch |err| {
            log.warn("Failed to fetch default model config: {}", .{err});
        };

        // Fetch available models in background (don't fail connect if this fails)
        self.fetchAvailableModels() catch |err| {
            log.warn("Failed to fetch available models: {}", .{err});
        };
    }

    /// Disconnect from the server
    pub fn disconnect(self: *OpencodeManager) void {
        log.info("Disconnecting...", .{});

        // Signal SSE thread to stop
        self.should_stop.store(true, .release);

        // Close the SSE connection to unblock the reader thread.
        // We must do this BEFORE joining to avoid deadlock.
        // Set sse_connection to null first so thread's defer knows not to double-free.
        {
            self.sse_conn_mutex.lock();
            const conn = self.sse_connection;
            self.sse_connection = null;
            self.sse_conn_mutex.unlock();

            if (conn) |c| {
                log.info("Closing SSE connection to unblock reader...", .{});
                c.deinit();
            }
        }

        // Wait for SSE thread with timeout
        if (self.sse_thread) |thread| {
            log.info("Waiting for SSE thread to exit...", .{});

            // Poll for thread exit with timeout (500ms total)
            var waited: u32 = 0;
            while (waited < 500) : (waited += 10) {
                if (self.thread_exited.load(.acquire)) {
                    // Thread has exited, safe to join
                    thread.join();
                    self.sse_thread = null;
                    log.info("SSE thread joined", .{});
                    break;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }

            // If thread didn't exit in time, detach it
            if (self.sse_thread != null) {
                log.warn("SSE thread did not exit in time, detaching...", .{});
                thread.detach();
                self.sse_thread = null;
                // Mark that we detached - manager must not be destroyed
                // because the thread may still be accessing it
                self.thread_was_detached = true;
            }
        }

        // Terminate server if we spawned it
        if (self.server_process) |*proc| {
            log.info("Terminating server...", .{});
            server.terminateServer(proc);
            self.server_process = null;
        }

        // Clean up session
        if (self.session_id) |sid| {
            // Note: Session cleanup is handled by server termination.
            // The deleteSession API uses HTTP DELETE which may not work correctly
            // in all Zig versions, so we rely on server shutdown instead.
            self.allocator.free(sid);
            self.session_id = null;
        }

        self.clearDefaultModelId();

        // Clean up client
        if (self.client) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.client = null;
        }

        // Clean up URL
        if (self.base_url) |url| {
            self.allocator.free(url);
            self.base_url = null;
        }

        self.status = .disconnected;
        log.info("Disconnected", .{});
    }

    /// Send a prompt to the agent
    /// Uses current agent and model settings if set
    pub fn sendPrompt(self: *OpencodeManager, text: []const u8) !void {
        const c = self.client orelse return error.NotConnected;
        const sid = self.session_id orelse return error.NoSession;

        if (self.status != .session_active) {
            return error.InvalidState;
        }

        // Create prompt request with current agent and model
        const parts = try self.allocator.alloc(protocol.Part, 1);
        defer self.allocator.free(parts);
        parts[0] = .{ .text = .{ .text = text } };

        const prompt = protocol.PromptAsyncRequest{
            .parts = parts,
            .agent = self.current_agent,
            .model = self.current_model,
            .variant = self.current_variant,
        };

        // Send async
        try c.sendPromptAsync(sid, prompt);

        self.status = .prompting;
        if (self.current_agent) |agent| {
            if (self.current_model) |model| {
                log.info("Sent prompt with agent={s}, model={s}/{s}", .{ agent, model.providerID, model.modelID });
            } else {
                log.info("Sent prompt with agent={s}", .{agent});
            }
        } else if (self.current_model) |model| {
            log.info("Sent prompt with model={s}/{s}", .{ model.providerID, model.modelID });
        } else {
            log.info("Sent prompt", .{});
        }
    }

    /// Set the current agent (mode) for future prompts
    /// Pass null to clear/use default
    pub fn setAgent(self: *OpencodeManager, agent: ?[]const u8) !void {
        // Free existing
        if (self.current_agent) |old| {
            self.allocator.free(old);
        }

        // Set new (dupe if provided)
        if (agent) |a| {
            self.current_agent = try self.allocator.dupe(u8, a);
            log.info("Agent set to: {s}", .{a});
        } else {
            self.current_agent = null;
            log.info("Agent cleared (using default)", .{});
        }
    }

    /// Get the current agent name
    pub fn getAgent(self: *const OpencodeManager) ?[]const u8 {
        return self.current_agent;
    }

    /// Set the current model for future prompts
    /// Pass null to clear/use default
    pub fn setModel(self: *OpencodeManager, provider_id: ?[]const u8, model_id: ?[]const u8) !void {
        // Free existing
        if (self.current_model) |old| {
            self.allocator.free(old.providerID);
            self.allocator.free(old.modelID);
        }

        // Set new (dupe if provided)
        if (provider_id != null and model_id != null) {
            self.current_model = .{
                .providerID = try self.allocator.dupe(u8, provider_id.?),
                .modelID = try self.allocator.dupe(u8, model_id.?),
            };
            log.info("Model set to: {s}/{s}", .{ provider_id.?, model_id.? });
        } else {
            self.current_model = null;
            log.info("Model cleared (using default)", .{});
        }

        // Clear variant when model changes (variants are model-specific)
        self.clearVariant();
    }

    /// Set model from a combined "provider/model" string (e.g., "anthropic/claude-sonnet-4")
    pub fn setModelFromString(self: *OpencodeManager, model_string: []const u8) !void {
        // Find the slash separator
        const slash_idx = std.mem.indexOf(u8, model_string, "/") orelse {
            return error.InvalidModelFormat;
        };

        const provider = model_string[0..slash_idx];
        const model = model_string[slash_idx + 1 ..];

        if (provider.len == 0 or model.len == 0) {
            return error.InvalidModelFormat;
        }

        try self.setModel(provider, model);
    }

    /// Get the current model
    pub fn getModel(self: *const OpencodeManager) ?protocol.ModelSpec {
        return self.current_model;
    }

    /// Get current model as a "provider/model" string
    /// Caller must free the returned string
    pub fn getModelString(self: *const OpencodeManager) !?[]const u8 {
        const model = self.current_model orelse return null;
        return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ model.providerID, model.modelID });
    }

    /// Set the current variant for future prompts
    /// Pass null to clear/use default
    pub fn setVariant(self: *OpencodeManager, variant: ?[]const u8) !void {
        if (self.current_variant) |old| {
            self.allocator.free(old);
        }

        if (variant) |v| {
            self.current_variant = try self.allocator.dupe(u8, v);
            log.info("Variant set to: {s}", .{v});
        } else {
            self.current_variant = null;
            log.info("Variant cleared (using default)", .{});
        }
    }

    /// Get the current variant name
    pub fn getVariant(self: *const OpencodeManager) ?[]const u8 {
        return self.current_variant;
    }

    /// Cycle to the next available variant for the current model
    /// Returns the new variant, or null if no variants available
    pub fn cycleVariant(self: *OpencodeManager) ?[]const u8 {
        const model_id = self.getEffectiveModelId() orelse return null;
        const variants = self.getVariantsForModelId(model_id) orelse return null;
        if (variants.len == 0) return null;

        var next_idx: usize = 0;
        if (self.current_variant) |current| {
            for (variants, 0..) |variant, idx| {
                if (std.mem.eql(u8, variant, current)) {
                    next_idx = (idx + 1) % variants.len;
                    break;
                }
            }
        }

        self.setVariant(variants[next_idx]) catch return null;
        return self.current_variant;
    }

    // =========================================================================
    // Available Models (for model picker UI)
    // =========================================================================

    /// Fetch available models from the server
    /// Call this after connect() to populate the model list
    pub fn fetchAvailableModels(self: *OpencodeManager) !void {
        const c = self.client orelse return error.NotConnected;
        const directory = if (self.connect_config) |cfg| cfg.cwd else null;

        // Fetch providers from server
        var parsed = c.getProviders(directory) catch |err| {
            log.err("Failed to fetch providers: {}", .{err});
            return error.FetchFailed;
        };
        defer parsed.deinit();

        // Clear existing models
        self.clearAvailableModels();

        // Capture default model mapping if provided (provider -> model)
        const default_map = parsed.value.default;

        // Build flat list of models from all providers
        // The API returns models as a JSON object map (keyed by model ID), not an array
        for (parsed.value.providers) |provider| {
            if (provider.models != .object) continue;
            var model_iter = provider.models.object.iterator();
            while (model_iter.next()) |entry| {
                const model_val = entry.value_ptr.*;
                if (model_val != .object) continue;

                // Extract model id from the model object
                const id_val = model_val.object.get("id") orelse continue;
                if (id_val != .string) continue;
                const model_id_raw = id_val.string;

                // Extract optional model name
                const model_name_raw: ?[]const u8 = if (model_val.object.get("name")) |name_val|
                    (if (name_val == .string) name_val.string else null)
                else
                    null;

                // Extract model variants (optional)
                var variants_slice: ?[]const []const u8 = null;
                if (model_val.object.get("variants")) |variants_val| {
                    if (variants_val == .object) {
                        var variants: std.ArrayListUnmanaged([]const u8) = .{};

                        var variant_iter = variants_val.object.iterator();
                        while (variant_iter.next()) |variant_entry| {
                            const variant_name = variant_entry.key_ptr.*;

                            if (variant_entry.value_ptr.* == .object) {
                                if (variant_entry.value_ptr.*.object.get("disabled")) |disabled_val| {
                                    if (disabled_val == .bool and disabled_val.bool) continue;
                                }
                            }

                            const variant_copy = self.allocator.dupe(u8, variant_name) catch continue;
                            variants.append(self.allocator, variant_copy) catch |err| {
                                self.allocator.free(variant_copy);
                                if (err == error.OutOfMemory) break;
                                continue;
                            };
                        }

                        if (variants.items.len > 0) {
                            variants_slice = variants.toOwnedSlice(self.allocator) catch blk: {
                                for (variants.items) |v| self.allocator.free(v);
                                variants.deinit(self.allocator);
                                break :blk null;
                            };
                        } else {
                            variants.deinit(self.allocator);
                        }
                    }
                }

                // Create "provider/model" ID
                const model_id = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
                    provider.id,
                    model_id_raw,
                }) catch continue;
                errdefer self.allocator.free(model_id);

                // Create display name: "ModelName (Provider)" or just model name/id
                const provider_display_name: ?[]const u8 = blk: {
                    if (provider.name) |n| {
                        if (n.len > 0) break :blk n;
                    }
                    if (provider.id.len > 0) break :blk provider.id;
                    break :blk null;
                };
                const name = if (model_name_raw) |n| name_blk: {
                    if (provider_display_name) |pdn| {
                        break :name_blk std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ n, pdn }) catch
                            self.allocator.dupe(u8, n) catch continue;
                    } else {
                        break :name_blk self.allocator.dupe(u8, n) catch continue;
                    }
                } else self.allocator.dupe(u8, model_id) catch continue;
                errdefer self.allocator.free(name);

                self.available_models.append(self.allocator, .{
                    .model_id = model_id,
                    .name = name,
                    .variants = variants_slice,
                }) catch continue;
            }
        }

        log.info("Fetched {d} available models", .{self.available_models.items.len});

        // Fallback: infer default model from providers default map when config didn't specify one
        if (self.default_model_id == null) {
            if (default_map) |map_val| {
                if (map_val == .object and map_val.object.count() > 0) {
                    var chosen_provider: ?[]const u8 = null;

                    if (parsed.value.providers.len == 1) {
                        chosen_provider = parsed.value.providers[0].id;
                    } else if (map_val.object.count() == 1) {
                        var iter = map_val.object.iterator();
                        if (iter.next()) |entry| {
                            chosen_provider = entry.key_ptr.*;
                        }
                    }

                    if (chosen_provider) |provider_id| {
                        if (map_val.object.get(provider_id)) |model_val| {
                            if (model_val == .string) {
                                const model_id = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ provider_id, model_val.string }) catch null;
                                if (model_id) |mid| {
                                    defer self.allocator.free(mid);
                                    self.setDefaultModelId(mid) catch |err| {
                                        log.warn("Failed to set default model from providers: {}", .{err});
                                    };
                                }
                            }
                        }
                    }
                }
            }
        }

        self.clearVariantIfInvalid();
    }

    /// Fetch default model from server config
    fn fetchDefaultModelConfig(self: *OpencodeManager) !void {
        const c = self.client orelse return error.NotConnected;
        const directory = if (self.connect_config) |cfg| cfg.cwd else null;

        var parsed = c.getConfig(directory) catch |err| {
            log.err("Failed to fetch config: {}", .{err});
            return error.FetchFailed;
        };
        defer parsed.deinit();

        if (parsed.value.model) |model| {
            self.setDefaultModelId(model) catch |err| {
                log.warn("Failed to set default model id: {}", .{err});
            };
            return;
        }

        // Fallback to global config if local config doesn't include a model
        var global_parsed = c.getGlobalConfig() catch |err| {
            log.warn("Failed to fetch global config: {}", .{err});
            self.clearDefaultModelId();
            return;
        };
        defer global_parsed.deinit();

        if (global_parsed.value.model) |model| {
            self.setDefaultModelId(model) catch |err| {
                log.warn("Failed to set default model id: {}", .{err});
            };
        } else {
            self.clearDefaultModelId();
        }
    }

    fn getVariantsForModelId(self: *const OpencodeManager, model_id: []const u8) ?[]const []const u8 {
        for (self.available_models.items) |model| {
            if (std.mem.eql(u8, model.model_id, model_id)) {
                return model.variants;
            }
        }
        return null;
    }

    fn getEffectiveModelId(self: *const OpencodeManager) ?[]const u8 {
        return self.current_model_id orelse self.default_model_id;
    }

    fn setDefaultModelId(self: *OpencodeManager, model_id: []const u8) !void {
        if (self.default_model_id) |old| {
            self.allocator.free(old);
        }
        self.default_model_id = try self.allocator.dupe(u8, model_id);
        log.info("Default model set to: {s}", .{model_id});
    }

    fn clearDefaultModelId(self: *OpencodeManager) void {
        if (self.default_model_id) |id| {
            self.allocator.free(id);
            self.default_model_id = null;
        }
    }

    fn clearVariant(self: *OpencodeManager) void {
        if (self.current_variant) |variant| {
            self.allocator.free(variant);
            self.current_variant = null;
        }
    }

    fn clearVariantIfInvalid(self: *OpencodeManager) void {
        const current = self.current_variant orelse return;
        const model_id = self.getEffectiveModelId() orelse {
            self.clearVariant();
            return;
        };
        const variants = self.getVariantsForModelId(model_id) orelse {
            self.clearVariant();
            return;
        };
        for (variants) |variant| {
            if (std.mem.eql(u8, variant, current)) return;
        }
        self.clearVariant();
    }

    /// Get available models for UI display
    /// Returns slice of OwnedModelInfo (do not free - owned by manager)
    pub fn getAvailableModels(self: *const OpencodeManager) []const OwnedModelInfo {
        return self.available_models.items;
    }

    /// Get current model ID (for highlighting in picker)
    pub fn getCurrentModelId(self: *const OpencodeManager) ?[]const u8 {
        return self.getEffectiveModelId();
    }

    /// Get current model display name
    pub fn getCurrentModelName(self: *const OpencodeManager) []const u8 {
        if (self.getEffectiveModelId()) |id| {
            // Find in available models
            for (self.available_models.items) |model| {
                if (std.mem.eql(u8, model.model_id, id)) {
                    return model.name orelse model.model_id;
                }
            }
            return id; // Fallback to ID
        }
        return "Default";
    }

    /// Set model by ID (from picker selection)
    /// This updates both current_model and current_model_id
    pub fn setModelById(self: *OpencodeManager, model_id: []const u8) !void {
        // Parse the "provider/model" format
        try self.setModelFromString(model_id);

        // Update current_model_id
        if (self.current_model_id) |old| {
            self.allocator.free(old);
        }
        self.current_model_id = try self.allocator.dupe(u8, model_id);

        self.clearVariantIfInvalid();
    }

    /// Cancel the current prompt (abort generation)
    /// Returns true if abort was sent, false if no active prompt
    pub fn cancelPrompt(self: *OpencodeManager) bool {
        const c = self.client orelse return false;
        const sid = self.session_id orelse return false;

        // Only cancel if we're currently prompting
        if (self.status != .prompting) {
            return false;
        }

        c.abortSession(sid) catch |err| {
            log.err("Failed to abort session: {}", .{err});
            return false;
        };

        // Reset status back to session_active
        self.status = .session_active;
        log.info("Prompt cancelled", .{});
        return true;
    }

    /// Poll for events from the SSE stream
    /// Returns the next event or null if none available
    pub fn poll(self: *OpencodeManager) ?Event {
        return self.message_queue.pop();
    }

    /// Check if manager has pending events
    pub fn hasPendingEvents(self: *OpencodeManager) bool {
        return self.message_queue.len() > 0;
    }

    /// SSE reader thread function
    fn sseReaderThread(manager: *OpencodeManager) void {
        log.info("SSE reader thread started", .{});

        // Signal thread exit on all return paths
        defer manager.thread_exited.store(true, .release);

        const c = manager.client orelse {
            manager.message_queue.push(.{ .err = .{ .code = .connection_failed } });
            return;
        };

        const conn = c.connectEventStream() catch {
            manager.message_queue.push(.{ .err = .{ .code = .connection_failed } });
            return;
        };

        // Store connection so disconnect() can close it to unblock us
        {
            manager.sse_conn_mutex.lock();
            defer manager.sse_conn_mutex.unlock();
            manager.sse_connection = conn;
        }

        // Clean up connection on exit (unless disconnect() already did)
        defer {
            manager.sse_conn_mutex.lock();
            defer manager.sse_conn_mutex.unlock();
            if (manager.sse_connection) |stored_conn| {
                // We still own the connection, clean it up
                if (stored_conn == conn) {
                    stored_conn.deinit();
                    manager.sse_connection = null;
                }
            }
            // If sse_connection is null, disconnect() already closed it
        }

        while (!manager.should_stop.load(.acquire)) {
            // Try to read an event
            const event_opt = conn.readEvent() catch |err| {
                // Check if we were signaled to stop (connection closed by disconnect)
                if (manager.should_stop.load(.acquire)) {
                    log.info("SSE read interrupted by disconnect", .{});
                    break;
                }
                log.err("SSE read error: {}", .{err});
                manager.message_queue.push(.{ .err = .{ .code = .connection_failed } });
                break;
            };

            if (event_opt) |sse_event| {
                var e = sse_event;
                defer e.deinit(manager.allocator);

                // Parse the SSE event data
                if (e.data) |data| {
                    manager.processEventData(data);
                }
            } else {
                // Connection closed (EOF) - check if intentional
                if (manager.should_stop.load(.acquire)) {
                    log.info("SSE connection closed by disconnect", .{});
                    break;
                }
                // Brief sleep to avoid busy loop on spurious null returns
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        log.info("SSE reader thread exiting", .{});
    }

    /// Process SSE event data JSON
    fn processEventData(self: *OpencodeManager, data: []const u8) void {
        // Quick check for events we care about before full JSON parse
        // This avoids expensive parsing for the many session/message update events
        const dominated_events = [_][]const u8{
            "message.part.updated",
            "\"type\":\"session.idle\"",
            "\"type\":\"session.error\"",
        };
        var dominated = false;
        for (dominated_events) |evt| {
            if (std.mem.indexOf(u8, data, evt) != null) {
                dominated = true;
                break;
            }
        }
        if (!dominated) {
            // Skip parsing events we don't handle
            return;
        }

        // Parse JSON - opencode wraps events in a "payload" object
        const parsed = std.json.parseFromSlice(struct {
            payload: struct {
                type: []const u8,
                properties: ?std.json.Value = null,
            },
        }, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch {
            log.warn("Failed to parse SSE event JSON", .{});
            return;
        };
        defer parsed.deinit();

        const event_type = protocol.EventType.fromString(parsed.value.payload.type);
        log.debug("SSE event received: {s} -> {}", .{ parsed.value.payload.type, event_type });

        switch (event_type) {
            .message_part_updated => {
                log.debug("Processing message.part.updated", .{});
                // Extract delta from properties
                if (parsed.value.payload.properties) |props| {
                    if (props == .object) {
                        if (props.object.get("delta")) |delta_val| {
                            if (delta_val == .string) {
                                const delta = self.allocator.dupe(u8, delta_val.string) catch return;
                                self.message_queue.push(.{
                                    .message_chunk = .{ .delta = delta },
                                });
                            }
                        }
                    }
                }
            },
            .session_idle => {
                log.info("Session idle received, resetting status to session_active", .{});
                self.message_queue.push(.{ .message_complete = {} });
                // Update status back to session_active
                self.status = .session_active;
            },
            .session_error => {
                self.message_queue.push(.{ .err = .{ .code = .session_error } });
                self.status = .failed;
            },
            else => {
                // Ignore other event types for now
            },
        }
    }

    pub const Error = error{
        AlreadyConnected,
        NotConnected,
        NoSession,
        InvalidState,
        SpawnFailed,
        HealthCheckFailed,
        SessionFailed,
        ThreadSpawnFailed,
        InvalidModelFormat,
        FetchFailed,
    } || Allocator.Error;
};

// =============================================================================
// Tests
// =============================================================================

test "MessageQueue push and pop" {
    const allocator = std.testing.allocator;
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();

    // Push events
    const delta1 = try allocator.dupe(u8, "Hello");
    queue.push(.{ .message_chunk = .{ .delta = delta1 } });

    const delta2 = try allocator.dupe(u8, "World");
    queue.push(.{ .message_chunk = .{ .delta = delta2 } });

    queue.push(.{ .message_complete = {} });

    // Pop and verify order
    var event1 = queue.pop();
    try std.testing.expect(event1 != null);
    try std.testing.expectEqualStrings("Hello", event1.?.message_chunk.delta);
    event1.?.deinit(allocator);

    var event2 = queue.pop();
    try std.testing.expect(event2 != null);
    try std.testing.expectEqualStrings("World", event2.?.message_chunk.delta);
    event2.?.deinit(allocator);

    const event3 = queue.pop();
    try std.testing.expect(event3 != null);
    try std.testing.expect(event3.? == .message_complete);

    // Queue should be empty
    try std.testing.expect(queue.pop() == null);
}

test "MessageQueue thread safety" {
    const allocator = std.testing.allocator;
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();

    const num_threads = 4;
    const items_per_thread = 100;

    // Spawn producer threads
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn producer(q: *MessageQueue, alloc: Allocator, thread_id: usize) void {
                for (0..items_per_thread) |j| {
                    const msg = std.fmt.allocPrint(alloc, "t{d}-{d}", .{ thread_id, j }) catch continue;
                    q.push(.{ .message_chunk = .{ .delta = msg } });
                }
            }
        }.producer, .{ &queue, allocator, i });
    }

    // Wait for all threads
    for (&threads) |*t| {
        t.join();
    }

    // Verify all items were pushed
    try std.testing.expectEqual(@as(usize, num_threads * items_per_thread), queue.len());

    // Pop and free all items
    while (queue.pop()) |*event| {
        var e = event.*;
        e.deinit(allocator);
    }
}

test "Status enum values" {
    // Test initial status
    const mgr = OpencodeManager.init(std.testing.allocator);
    defer @constCast(&mgr).deinit();

    try std.testing.expectEqual(Status.idle, mgr.status);
}

test "OpencodeManager init" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(Status.idle, manager.status);
    try std.testing.expect(manager.client == null);
    try std.testing.expect(manager.server_process == null);
    try std.testing.expect(manager.session_id == null);
}

test "Event deinit" {
    const allocator = std.testing.allocator;

    // Test message_chunk deinit
    const delta = try allocator.dupe(u8, "test delta");
    var event1 = Event{ .message_chunk = .{ .delta = delta } };
    event1.deinit(allocator);

    // Test error deinit
    const msg = try allocator.dupe(u8, "error message");
    var event2 = Event{ .err = .{ .code = .connection_failed, .message = msg } };
    event2.deinit(allocator);

    // Test message_complete deinit (no-op)
    var event3 = Event{ .message_complete = {} };
    event3.deinit(allocator);
}

test "setAgent and getAgent" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Initially null
    try std.testing.expect(manager.getAgent() == null);

    // Set agent
    try manager.setAgent("plan");
    try std.testing.expectEqualStrings("plan", manager.getAgent().?);

    // Change agent
    try manager.setAgent("build");
    try std.testing.expectEqualStrings("build", manager.getAgent().?);

    // Clear agent
    try manager.setAgent(null);
    try std.testing.expect(manager.getAgent() == null);
}

test "setModel and getModel" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Initially null
    try std.testing.expect(manager.getModel() == null);

    // Set model
    try manager.setModel("anthropic", "claude-sonnet-4");
    const model = manager.getModel().?;
    try std.testing.expectEqualStrings("anthropic", model.providerID);
    try std.testing.expectEqualStrings("claude-sonnet-4", model.modelID);

    // Change model
    try manager.setModel("openai", "gpt-4o");
    const model2 = manager.getModel().?;
    try std.testing.expectEqualStrings("openai", model2.providerID);
    try std.testing.expectEqualStrings("gpt-4o", model2.modelID);

    // Clear model
    try manager.setModel(null, null);
    try std.testing.expect(manager.getModel() == null);
}

test "setModelFromString" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Valid format
    try manager.setModelFromString("anthropic/claude-sonnet-4-20250514");
    const model = manager.getModel().?;
    try std.testing.expectEqualStrings("anthropic", model.providerID);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", model.modelID);

    // Invalid format - no slash
    try std.testing.expectError(error.InvalidModelFormat, manager.setModelFromString("invalid"));

    // Invalid format - empty provider
    try std.testing.expectError(error.InvalidModelFormat, manager.setModelFromString("/model"));

    // Invalid format - empty model
    try std.testing.expectError(error.InvalidModelFormat, manager.setModelFromString("provider/"));
}

test "getModelString" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Null when no model set
    const null_str = try manager.getModelString();
    try std.testing.expect(null_str == null);

    // Returns formatted string
    try manager.setModel("anthropic", "claude-sonnet-4");
    const str = (try manager.getModelString()).?;
    defer allocator.free(str);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", str);
}

// Integration tests - skipped in unit test runs (require live server)
test "integration: connect and disconnect" {
    // Skip in normal test runs - requires opencode binary
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    try manager.connect(.{
        .opencode_path = "/usr/local/bin/opencode",
        .port = 14096,
        .spawn_server = true,
    });

    try std.testing.expectEqual(Status.session_active, manager.status);
    try std.testing.expect(manager.session_id != null);

    manager.disconnect();
    try std.testing.expectEqual(Status.disconnected, manager.status);
}
