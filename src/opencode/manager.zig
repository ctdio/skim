const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const patch = @import("patch.zig");
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

pub const AvailableCommandInput = struct {
    hint: []const u8,
};

pub const AvailableCommand = struct {
    name: []const u8,
    description: []const u8,
    input: ?AvailableCommandInput = null,
};

fn freeAvailableCommand(allocator: Allocator, cmd: AvailableCommand) void {
    allocator.free(cmd.name);
    allocator.free(cmd.description);
    if (cmd.input) |input| {
        allocator.free(input.hint);
    }
}

fn freeAvailableCommands(allocator: Allocator, commands: []const AvailableCommand) void {
    for (commands) |cmd| {
        freeAvailableCommand(allocator, cmd);
    }
    if (commands.len > 0) {
        allocator.free(commands);
    }
}

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

pub const ToolStatus = enum {
    pending,
    running,
    completed,
    failed,
};

/// Event types from the SSE stream
pub const Event = union(enum) {
    /// Delta text chunk from message.part.updated
    message_chunk: MessageChunk,
    /// Delta thinking chunk from message.part.updated
    thinking_chunk: MessageChunk,
    /// Message complete (session.idle)
    message_complete: void,
    /// System message to display in chat
    system_message: []const u8,
    /// Tool call started
    tool_call: ToolCall,
    /// Tool call update (status/output)
    tool_update: ToolUpdate,
    /// Tool diff content (apply_patch)
    tool_diff: ToolDiff,
    /// Question prompt (question.asked)
    question_prompt: QuestionPrompt,
    /// Question resolved (question.resolved)
    question_resolved: void,
    /// Available slash commands update
    commands_update: []const AvailableCommand,
    /// Session context was compacted
    session_compacted: void,
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

    pub const SubagentToolSummary = struct {
        tool_name: []const u8,
        title: ?[]const u8 = null,
        status: ToolStatus = .completed,

        pub fn deinit(self: *SubagentToolSummary, allocator: Allocator) void {
            allocator.free(self.tool_name);
            if (self.title) |t| allocator.free(t);
        }
    };

    pub const SubagentEventInfo = struct {
        description: ?[]const u8 = null,
        agent_type: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
        title: ?[]const u8 = null,
        tool_count: usize = 0,
        summary: []SubagentToolSummary = &.{},
        input_tokens: usize = 0,
        output_tokens: usize = 0,
        reasoning_tokens: usize = 0,
        cache_read_tokens: usize = 0,
        cache_write_tokens: usize = 0,
        start_time_ms: i64 = 0,

        pub fn deinit(self: *SubagentEventInfo, allocator: Allocator) void {
            if (self.description) |d| allocator.free(d);
            if (self.agent_type) |a| allocator.free(a);
            if (self.session_id) |s| allocator.free(s);
            if (self.title) |t| allocator.free(t);
            for (self.summary) |*entry| entry.deinit(allocator);
            if (self.summary.len > 0) allocator.free(self.summary);
        }
    };

    pub const ToolCall = struct {
        tool_call_id: []const u8,
        tool_name: ?[]const u8 = null,
        title: []const u8,
        command: ?[]const u8 = null,
        subagent_info: ?SubagentEventInfo = null,

        pub fn deinit(self: *ToolCall, allocator: Allocator) void {
            allocator.free(self.tool_call_id);
            allocator.free(self.title);
            if (self.tool_name) |name| allocator.free(name);
            if (self.command) |cmd| allocator.free(cmd);
            if (self.subagent_info) |*info| info.deinit(allocator);
        }
    };

    pub const ToolUpdate = struct {
        tool_call_id: []const u8,
        status: ToolStatus,
        stdout: ?[]const u8 = null,
        stderr: ?[]const u8 = null,
        subagent_info: ?SubagentEventInfo = null,

        pub fn deinit(self: *ToolUpdate, allocator: Allocator) void {
            allocator.free(self.tool_call_id);
            if (self.stdout) |out| allocator.free(out);
            if (self.stderr) |err| allocator.free(err);
            if (self.subagent_info) |*info| info.deinit(allocator);
        }
    };

    pub const ToolDiff = struct {
        tool_call_id: ?[]const u8 = null,
        title: []const u8,
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,

        pub fn deinit(self: *ToolDiff, allocator: Allocator) void {
            if (self.tool_call_id) |id| allocator.free(id);
            allocator.free(self.title);
            allocator.free(self.path);
            allocator.free(self.old_text);
            allocator.free(self.new_text);
        }
    };

    pub const QuestionOption = struct {
        label: []const u8,
        description: ?[]const u8 = null,

        fn deinit(self: *QuestionOption, allocator: Allocator) void {
            allocator.free(self.label);
            if (self.description) |desc| allocator.free(desc);
        }
    };

    pub const QuestionItem = struct {
        header: ?[]const u8 = null,
        question: []const u8,
        options: []QuestionOption,
        multiple: bool = false,

        fn deinit(self: *QuestionItem, allocator: Allocator) void {
            if (self.header) |h| allocator.free(h);
            allocator.free(self.question);
            for (self.options) |*opt| opt.deinit(allocator);
            allocator.free(self.options);
        }
    };

    pub const QuestionPrompt = struct {
        id: ?[]const u8 = null,
        tool_call_id: ?[]const u8 = null,
        questions: []QuestionItem,

        fn deinit(self: *QuestionPrompt, allocator: Allocator) void {
            if (self.id) |id| allocator.free(id);
            if (self.tool_call_id) |id| allocator.free(id);
            for (self.questions) |*question| question.deinit(allocator);
            allocator.free(self.questions);
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
            .thinking_chunk => |*chunk| chunk.deinit(allocator),
            .system_message => |msg| allocator.free(msg),
            .tool_call => |*tc| tc.deinit(allocator),
            .tool_update => |*tu| tu.deinit(allocator),
            .tool_diff => |*diff| diff.deinit(allocator),
            .question_prompt => |*prompt| prompt.deinit(allocator),
            .err => |*e| e.deinit(allocator),
            .commands_update => |commands| freeAvailableCommands(allocator, commands),
            .message_complete, .session_compacted, .status_change, .question_resolved => {},
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

    /// Drain all pending events, freeing their resources (thread-safe).
    /// Use event_allocator since events are allocated by the SSE thread.
    pub fn drain(self: *MessageQueue, event_allocator: Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.events.items) |*event| {
            event.deinit(event_allocator);
        }
        self.events.clearRetainingCapacity();
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

/// Token usage tracking for a session (child or parent).
pub const ChildTokens = struct {
    input: usize = 0,
    output: usize = 0,
    reasoning: usize = 0,
    cache_read: usize = 0,
    cache_write: usize = 0,

    fn add(self: ChildTokens, other: ChildTokens) ChildTokens {
        return .{
            .input = self.input + other.input,
            .output = self.output + other.output,
            .reasoning = self.reasoning + other.reasoning,
            .cache_read = self.cache_read + other.cache_read,
            .cache_write = self.cache_write + other.cache_write,
        };
    }
};

/// Accumulates token usage across multiple assistant messages within a session.
/// Deduplicates repeated message.updated events for the same message ID by
/// tracking the current message separately and folding it into a running base
/// total when a new message begins.
const TokenAccumulator = struct {
    /// Sum of all finalized (previous) messages' tokens.
    base: ChildTokens = .{},
    /// The in-progress message's tokens (replaced on each message.updated event).
    current: ChildTokens = .{},
    /// Message ID of the current in-progress message (owned, must be freed).
    current_message_id: ?[]const u8 = null,

    fn total(self: TokenAccumulator) ChildTokens {
        return self.base.add(self.current);
    }

    /// Update with new token data for a given message ID.
    /// If the message ID matches the current one, replaces current tokens (dedup).
    /// If it's a new message, finalizes current into base and starts fresh.
    fn update(self: *TokenAccumulator, allocator: Allocator, msg_id: ?[]const u8, tok: ChildTokens) void {
        if (msg_id) |mid| {
            if (self.current_message_id) |cur_mid| {
                if (std.mem.eql(u8, cur_mid, mid)) {
                    // Same message — replace current (dedup repeated events)
                    self.current = tok;
                    return;
                }
                // New message — finalize previous into base
                self.base = self.base.add(self.current);
                allocator.free(cur_mid);
            }
            self.current_message_id = allocator.dupe(u8, mid) catch null;
        } else {
            // No message ID — just replace current
            if (self.current_message_id) |cur_mid| {
                self.base = self.base.add(self.current);
                allocator.free(cur_mid);
                self.current_message_id = null;
            }
        }
        self.current = tok;
    }

    fn deinitMessageId(self: *TokenAccumulator, allocator: Allocator) void {
        if (self.current_message_id) |mid| {
            allocator.free(mid);
            self.current_message_id = null;
        }
    }
};

/// Manages Opencode agent sessions
pub const OpencodeManager = struct {
    allocator: Allocator,
    event_allocator: Allocator,
    status: Status,
    client: ?*client_mod.Client,
    event_client: ?*client_mod.Client,
    server_process: ?std.process.Child,
    session_id: ?[]const u8,
    message_queue: MessageQueue,
    event_log_file: ?std.fs.File,
    event_log_mutex: std.Thread.Mutex,

    // SSE reader thread
    sse_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    thread_exited: std.atomic.Value(bool),
    thread_was_detached: bool, // If true, don't destroy manager - thread may still access it
    stream_complete: std.atomic.Value(bool),

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

    // Abort tracking (used to avoid treating abort as session error)
    pending_abort: bool,
    pending_abort_since_ms: i64,
    last_event_ms: i64,
    abort_error_grace_until_ms: i64,
    last_diff_tool_call_id: ?[]const u8,
    last_question_call_id: ?[]const u8,

    // Question/permission tracking
    pending_question: bool,
    pending_permission: bool,

    // Compaction tracking
    is_compacting: bool,

    // Deferred completion: set when a parent completion event (session.idle,
    // message.updated, etc.) arrives while subagents are active. Checked after
    // the last child session completes to fire the deferred clearPromptingState().
    deferred_completion: bool,

    // Child session tracking (for subagent display during execution)
    // Maps child sessionID -> number of unique tool calls observed
    child_tool_counts: std.StringHashMapUnmanaged(usize),
    // Maps child sessionID -> last tool name used (owned strings)
    child_last_tool: std.StringHashMapUnmanaged([]const u8),
    // Maps child sessionID -> parent tool_call_id (owned strings)
    child_to_parent_tool: std.StringHashMapUnmanaged([]const u8),
    // Maps child sessionID -> accumulated token usage from message.updated events
    child_tokens: std.StringHashMapUnmanaged(TokenAccumulator),
    // Maps child sessionID -> start timestamp (ms since epoch)
    child_start_times: std.StringHashMapUnmanaged(i64),
    // Atomic count of active child sessions (safe for main thread to read)
    active_child_count: std.atomic.Value(u32),

    // Parent (main agent) accumulated token usage from message.updated events
    parent_tokens: TokenAccumulator,

    // Available models (fetched from server)
    available_models: std.ArrayListUnmanaged(OwnedModelInfo),
    current_model_id: ?[]const u8, // Current model as "provider/model" string

    pub fn init(allocator: Allocator) OpencodeManager {
        return .{
            .allocator = allocator,
            .event_allocator = std.heap.c_allocator,
            .status = .idle,
            .client = null,
            .event_client = null,
            .server_process = null,
            .session_id = null,
            .message_queue = MessageQueue.init(std.heap.c_allocator),
            .event_log_file = null,
            .event_log_mutex = .{},
            .sse_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .thread_exited = std.atomic.Value(bool).init(true), // No thread running initially
            .thread_was_detached = false,
            .stream_complete = std.atomic.Value(bool).init(false),
            .sse_connection = null,
            .sse_conn_mutex = .{},
            .connect_config = null,
            .connect_cwd_owned = null,
            .base_url = null,
            .current_agent = null,
            .current_model = null,
            .current_variant = null,
            .default_model_id = null,
            .pending_abort = false,
            .pending_abort_since_ms = 0,
            .last_event_ms = 0,
            .abort_error_grace_until_ms = 0,
            .last_diff_tool_call_id = null,
            .last_question_call_id = null,
            .pending_question = false,
            .pending_permission = false,
            .is_compacting = false,
            .deferred_completion = false,
            .child_tool_counts = .{},
            .child_last_tool = .{},
            .child_to_parent_tool = .{},
            .child_tokens = .{},
            .child_start_times = .{},
            .active_child_count = std.atomic.Value(u32).init(0),
            .parent_tokens = .{},
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

        // Free child tool counts
        self.clearChildToolCounts();

        // Free available models
        self.clearAvailableModels();

        // Free current model ID
        if (self.current_model_id) |id| {
            self.allocator.free(id);
            self.current_model_id = null;
        }
        if (self.last_diff_tool_call_id) |id| {
            self.allocator.free(id);
            self.last_diff_tool_call_id = null;
        }
        if (self.last_question_call_id) |id| {
            self.allocator.free(id);
            self.last_question_call_id = null;
        }
    }

    /// Clear child session tracking maps, freeing all owned keys and values
    fn clearChildToolCounts(self: *OpencodeManager) void {
        self.deferred_completion = false;
        {
            var iter = self.child_tool_counts.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.child_tool_counts.deinit(self.allocator);
            self.child_tool_counts = .{};
            self.active_child_count.store(0, .release);
        }
        {
            var iter = self.child_last_tool.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.child_last_tool.deinit(self.allocator);
            self.child_last_tool = .{};
        }
        {
            var iter = self.child_to_parent_tool.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.child_to_parent_tool.deinit(self.allocator);
            self.child_to_parent_tool = .{};
        }
        {
            var iter = self.child_tokens.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinitMessageId(self.allocator);
            }
            self.child_tokens.deinit(self.allocator);
            self.child_tokens = .{};
        }
        {
            var iter = self.child_start_times.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.child_start_times.deinit(self.allocator);
            self.child_start_times = .{};
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

        const event_client_ptr = try self.allocator.create(client_mod.Client);
        errdefer self.allocator.destroy(event_client_ptr);
        event_client_ptr.* = try client_mod.Client.init(self.event_allocator, base_url);
        self.event_client = event_client_ptr;

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
        self.ensureEventLog();

        // Start SSE reader thread
        self.should_stop.store(false, .release);
        self.thread_exited.store(false, .release);
        self.sse_thread = std.Thread.spawn(.{}, sseReaderThread, .{self}) catch |err| {
            log.err("Failed to spawn SSE reader thread: {}", .{err});
            self.status = .failed;
            self.thread_exited.store(true, .release);
            return error.ThreadSpawnFailed;
        };

        // Fetch non-critical config before signaling session_active.
        // The main thread joins the connect thread as soon as isInitializing()
        // returns false, so these must complete first to avoid blocking the UI.
        self.fetchDefaultModelConfig() catch |err| {
            log.warn("Failed to fetch default model config: {}", .{err});
        };

        self.fetchDefaultAgentConfig() catch |err| {
            log.warn("Failed to fetch default agent config: {}", .{err});
        };

        self.fetchAvailableModels() catch |err| {
            log.warn("Failed to fetch available models: {}", .{err});
        };

        self.fetchAvailableCommands();

        self.status = .session_active;
        log.info("Connected successfully", .{});
    }

    /// Disconnect from the server
    pub fn disconnect(self: *OpencodeManager) void {
        log.info("Disconnecting...", .{});

        self.pending_abort = false;
        self.pending_abort_since_ms = 0;
        self.abort_error_grace_until_ms = 0;
        self.clearChildToolCounts();

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

        if (!self.thread_was_detached) {
            self.closeEventLog();
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

        // Clean up event client
        if (self.event_client) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.event_client = null;
        }

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

        if (!self.isReadyForPrompt()) {
            return error.InvalidState;
        }

        if (self.pending_question or self.pending_permission) {
            log.info("Clearing pending question/permission due to user prompt", .{});
            self.pending_question = false;
            self.pending_permission = false;
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

        // Clear any pending state from a previous turn
        self.pending_abort = false;
        self.pending_abort_since_ms = 0;
        self.deferred_completion = false;
        self.active_child_count.store(0, .release);
        self.parent_tokens.deinitMessageId(self.allocator);
        self.parent_tokens = .{};

        // Drain stale events from the previous turn. Step-finish pushes
        // message_complete eagerly, and session.idle can arrive much later.
        // Without draining, these stale events would prematurely clear the
        // prompting state for the new prompt.
        self.message_queue.drain(self.event_allocator);

        self.stream_complete.store(false, .release);
        self.last_event_ms = 0;

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

    /// Reply to a pending question via the dedicated question reply endpoint.
    /// `answers` is a 2D slice: one inner slice per question, each containing
    /// the selected option labels (or custom text) for that question.
    pub fn respondToQuestion(self: *OpencodeManager, request_id: []const u8, answers: []const []const []const u8) !void {
        const c = self.client orelse return error.NotConnected;

        // Build JSON: {"answers": [["label1"], ["label2", "label3"]]}
        var json: std.ArrayList(u8) = .{};
        defer json.deinit(self.allocator);
        const w = json.writer(self.allocator);

        try w.writeAll("{\"answers\":[");
        for (answers, 0..) |question_answers, qi| {
            if (qi > 0) try w.writeByte(',');
            try w.writeByte('[');
            for (question_answers, 0..) |label, li| {
                if (li > 0) try w.writeByte(',');
                try w.print("{f}", .{std.json.fmt(label, .{})});
            }
            try w.writeByte(']');
        }
        try w.writeAll("]}");

        try c.replyToQuestion(request_id, json.items);

        self.pending_question = false;

        // Reset prompting state so isThinking() returns true while the agent
        // continues generating after receiving the answer. This mirrors the
        // drain + reset in sendPrompt().
        self.message_queue.drain(self.event_allocator);
        self.active_child_count.store(0, .release);
        self.stream_complete.store(false, .release);
        self.last_event_ms = 0;
    }

    /// Reject/dismiss a pending question.
    pub fn rejectQuestion(self: *OpencodeManager, request_id: []const u8) !void {
        const c = self.client orelse return error.NotConnected;
        try c.rejectQuestion(request_id);
        self.pending_question = false;
    }

    pub fn isThinking(self: *const OpencodeManager) bool {
        return self.status == .prompting and !self.stream_complete.load(.acquire);
    }

    pub fn isCompacting(self: *const OpencodeManager) bool {
        return self.is_compacting and self.isThinking();
    }

    pub fn isReadyForPrompt(self: *const OpencodeManager) bool {
        return self.status == .session_active or
            (self.status == .prompting and self.stream_complete.load(.acquire));
    }

    pub fn isReadyForAutoSend(self: *const OpencodeManager) bool {
        return self.isReadyForPrompt();
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

    /// Fetch default agent from server config; fallback to last session messages
    fn fetchDefaultAgentConfig(self: *OpencodeManager) !void {
        if (self.current_agent != null) return;

        const c = self.client orelse return error.NotConnected;
        const directory = if (self.connect_config) |cfg| cfg.cwd else null;

        var parsed = c.getConfig(directory) catch |err| {
            log.err("Failed to fetch config: {}", .{err});
            return error.FetchFailed;
        };
        defer parsed.deinit();

        if (parsed.value.default_agent) |agent| {
            if (agent.len > 0) {
                try self.setAgent(agent);
                return;
            }
        }

        var global_parsed = c.getGlobalConfig() catch |err| {
            log.warn("Failed to fetch global config: {}", .{err});
            return error.FetchFailed;
        };
        defer global_parsed.deinit();

        if (global_parsed.value.default_agent) |agent| {
            if (agent.len > 0) {
                try self.setAgent(agent);
                return;
            }
        }

        try self.trySetAgentFromSessionHistory();
    }

    fn trySetAgentFromSessionHistory(self: *OpencodeManager) !void {
        if (self.current_agent != null) return;

        const c = self.client orelse return error.NotConnected;
        var parsed = c.listSessions() catch |err| {
            log.warn("Failed to list sessions: {}", .{err});
            return error.FetchFailed;
        };
        defer parsed.deinit();

        const sessions = extractSessionsArray(parsed.value) orelse return;

        var candidates: std.ArrayListUnmanaged(SessionCandidate) = .{};
        defer {
            for (candidates.items) |cand| {
                self.allocator.free(cand.id);
            }
            candidates.deinit(self.allocator);
        }

        for (sessions) |session_val| {
            if (session_val != .object) continue;
            const id = extractStringField(session_val.object, &[_][]const u8{ "id", "sessionID", "sessionId" }) orelse continue;
            const updated = extractSessionTimestamp(session_val.object);

            const owned_id = try self.allocator.dupe(u8, id);
            candidates.append(self.allocator, .{ .id = owned_id, .updated = updated }) catch |err| {
                self.allocator.free(owned_id);
                return err;
            };
        }

        if (candidates.items.len == 0) return;

        std.mem.sort(SessionCandidate, candidates.items, {}, SessionCandidate.moreRecentFirst);

        for (candidates.items) |cand| {
            if (self.session_id != null and std.mem.eql(u8, cand.id, self.session_id.?)) continue;
            if (try self.trySetAgentFromSessionMessages(cand.id)) break;
        }
    }

    fn trySetAgentFromSessionMessages(self: *OpencodeManager, session_id: []const u8) !bool {
        if (self.current_agent != null) return true;

        const c = self.client orelse return error.NotConnected;
        var parsed = c.fetchSessionMessagesRaw(session_id) catch |err| {
            log.warn("Failed to fetch session messages for {s}: {}", .{ session_id, err });
            return false;
        };
        defer parsed.deinit();

        const agent = extractLatestAgentFromMessages(parsed.value) orelse return false;
        if (agent.len == 0) return false;

        try self.setAgent(agent);
        log.info("Agent set from session history: {s}", .{agent});
        return true;
    }

    /// Fetch available slash commands from the server's /command endpoint
    fn fetchAvailableCommands(self: *OpencodeManager) void {
        const c = self.client orelse return;
        const directory = if (self.connect_config) |cfg| cfg.cwd else null;

        var parsed = c.listCommands(directory) catch |err| {
            log.warn("Failed to fetch commands: {}", .{err});
            return;
        };
        defer parsed.deinit();

        // Response is an array of command objects
        if (parsed.value != .array) {
            log.warn("Commands response is not an array", .{});
            return;
        }

        var commands_list: std.ArrayListUnmanaged(AvailableCommand) = .{};
        errdefer {
            for (commands_list.items) |cmd| freeAvailableCommand(self.event_allocator, cmd);
            commands_list.deinit(self.event_allocator);
        }

        for (parsed.value.array.items) |cmd_val| {
            if (cmd_val != .object) continue;
            const obj = cmd_val.object;

            const name_raw = if (obj.get("name")) |v| (if (v == .string) v.string else null) else null;
            if (name_raw == null) continue;

            const desc_raw = if (obj.get("description")) |v| (if (v == .string) v.string else null) else name_raw;

            const name = self.event_allocator.dupe(u8, name_raw.?) catch continue;
            const desc = self.event_allocator.dupe(u8, desc_raw.?) catch {
                self.event_allocator.free(name);
                continue;
            };

            commands_list.append(self.event_allocator, .{
                .name = name,
                .description = desc,
                .input = null,
            }) catch {
                self.event_allocator.free(name);
                self.event_allocator.free(desc);
                continue;
            };
        }

        if (commands_list.items.len == 0) return;

        const commands = commands_list.toOwnedSlice(self.event_allocator) catch return;
        log.info("Fetched {d} available commands", .{commands.len});
        self.message_queue.push(.{ .commands_update = commands });
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

        self.pending_abort = true;
        self.pending_abort_since_ms = std.time.milliTimestamp();
        self.abort_error_grace_until_ms = self.pending_abort_since_ms + 3000;
        if (self.last_event_ms == 0) {
            self.last_event_ms = self.pending_abort_since_ms;
        }

        c.abortSession(sid) catch |err| {
            log.err("Failed to abort session: {}", .{err});
            self.pending_abort = false;
            return false;
        };

        // Stop "Generating..." immediately; queued messages will wait for idle
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

        const c = manager.event_client orelse {
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
                defer e.deinit(manager.event_allocator);

                // Parse the SSE event data
                if (e.data) |data| {
                    log.debug("SSE raw event: {s}", .{data});
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

    fn ensureEventLog(self: *OpencodeManager) void {
        if (self.event_log_file != null) return;
        const sid = self.session_id orelse return;
        const home = std.posix.getenv("HOME") orelse return;

        var path_buf: [512]u8 = undefined;
        const skim_dir = std.fmt.bufPrint(&path_buf, "{s}/.skim", .{home}) catch return;
        std.fs.makeDirAbsolute(skim_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var opencode_buf: [512]u8 = undefined;
        const opencode_dir = std.fmt.bufPrint(&opencode_buf, "{s}/.skim/opencode", .{home}) catch return;
        std.fs.makeDirAbsolute(opencode_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var events_buf: [512]u8 = undefined;
        const events_dir = std.fmt.bufPrint(&events_buf, "{s}/.skim/opencode/events", .{home}) catch return;
        std.fs.makeDirAbsolute(events_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var log_buf: [512]u8 = undefined;
        const log_path = std.fmt.bufPrint(&log_buf, "{s}/.skim/opencode/events/ses_{s}.log", .{ home, sid }) catch return;

        const file = std.fs.createFileAbsolute(log_path, .{ .truncate = false }) catch return;
        file.seekFromEnd(0) catch {};
        self.event_log_file = file;
        log.info("Opencode SSE log: {s}", .{log_path});
    }

    fn logSseEvent(self: *OpencodeManager, data: []const u8) void {
        self.event_log_mutex.lock();
        defer self.event_log_mutex.unlock();

        self.ensureEventLog();
        const file = self.event_log_file orelse return;

        const timestamp_ms = std.time.milliTimestamp();
        const seconds = @divFloor(timestamp_ms, 1000);
        const millis = @mod(timestamp_ms, 1000);
        const hours = @mod(@divFloor(seconds, 3600), 24);
        const minutes = @mod(@divFloor(seconds, 60), 60);
        const secs = @mod(seconds, 60);

        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{
            @as(u64, @intCast(hours)),
            @as(u64, @intCast(minutes)),
            @as(u64, @intCast(secs)),
            @as(u64, @intCast(millis)),
        }) catch return;

        _ = file.write(header) catch return;
        _ = file.write(data) catch return;
        _ = file.write("\n") catch return;
    }

    fn closeEventLog(self: *OpencodeManager) void {
        self.event_log_mutex.lock();
        defer self.event_log_mutex.unlock();

        if (self.event_log_file) |file| {
            file.close();
            self.event_log_file = null;
        }
    }

    /// Process SSE event data JSON
    pub fn replayEventData(self: *OpencodeManager, data: []const u8) void {
        self.processEventDataWithLogging(data, false);
    }

    fn processEventData(self: *OpencodeManager, data: []const u8) void {
        self.processEventDataWithLogging(data, true);
    }

    fn processEventDataWithLogging(self: *OpencodeManager, data: []const u8, should_log_event: bool) void {
        if (should_log_event) {
            self.logSseEvent(data);
        }
        // Quick check for events we care about before full JSON parse
        // This avoids expensive parsing for the many session/message update events
        const dominated_events = [_][]const u8{
            "message.created",
            "message.updated",
            "message.deleted",
            "message.part.updated",
            "tool.",
            "tool_call",
            "permission.asked",
            "permission.resolved",
            "question.asked",
            "question.resolved",
            "session.updated",
            "session.idle",
            "session.status",
            "session.error",
            "session.compacted",
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

        // Parse JSON - accept both wrapped (payload) and top-level event shapes
        const ParsedEvent = struct {
            payload: ?struct {
                type: []const u8,
                properties: ?std.json.Value = null,
            } = null,
            type: ?[]const u8 = null,
            properties: ?std.json.Value = null,
        };

        const parsed = std.json.parseFromSlice(ParsedEvent, self.event_allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch {
            log.warn("Failed to parse SSE event JSON", .{});
            return;
        };
        defer parsed.deinit();

        const type_str: []const u8 = if (parsed.value.payload) |payload|
            payload.type
        else if (parsed.value.type) |t|
            t
        else {
            log.warn("SSE event missing type", .{});
            return;
        };

        const properties = if (parsed.value.payload) |payload| payload.properties else parsed.value.properties;

        const event_type = protocol.EventType.fromString(type_str);
        log.debug("SSE event received: {s} -> {}", .{ type_str, event_type });

        // Filter out child session events: the SSE stream forwards ALL events
        // from subagent sessions. We only process events from our own session.
        if (self.session_id) |our_sid| {
            if (properties) |props| {
                if (getEventSessionId(props, event_type)) |event_sid| {
                    if (!std.mem.eql(u8, event_sid, our_sid)) {
                        // Child session event — track tool calls and tokens
                        if (event_type == .message_updated) {
                            self.trackChildTokenUsage(props, event_sid);
                        }
                        self.trackChildToolEvent(props, event_sid);
                        // Child session.idle provides a secondary cleanup path
                        // when the tool result doesn't contain metadata.sessionId.
                        if (event_type == .session_idle) {
                            self.removeChildToolCount(event_sid);
                        }
                        return;
                    }
                }
            }
        }

        switch (event_type) {
            .message_created => {
                if (properties) |props| {
                    if (props == .object) {
                        if (extractMessageStatus(props)) |status| {
                            if (!self.handleMessageStatus(status)) {
                                if (isMessageInProgressStatus(status)) {
                                    self.message_queue.push(.{ .status_change = .prompting });
                                }
                            }
                        }
                    }
                }
            },
            .message_part_updated => {
                log.debug("Processing message.part.updated", .{});
                // Extract delta from properties
                if (properties) |props| {
                    if (props == .object) {
                        var part_obj: ?std.json.ObjectMap = null;
                        var part_type: ?[]const u8 = null;

                        if (props.object.get("part")) |part_val| {
                            if (part_val == .object) {
                                part_obj = part_val.object;
                                if (part_val.object.get("type")) |type_val| {
                                    if (type_val == .string) {
                                        part_type = type_val.string;
                                    }
                                }
                            }
                        }

                        if (part_obj) |_| {
                            if (part_type) |ptype| {
                                // Note: step-finish and text-part-end are intermediate events
                                // in multi-step responses. Do NOT call clearPromptingState() here
                                // as the agent may continue with tool calls and more text.
                                // The definitive completion signals are session.idle,
                                // message_updated with completion status, etc.
                                if (isStepFinishType(ptype)) {
                                    const reason = if (part_obj.?.get("reason")) |reason_val| blk: {
                                        if (reason_val == .string) break :blk reason_val.string;
                                        break :blk null;
                                    } else null;
                                    log.info("Step finished ({s})", .{reason orelse "unknown"});

                                    // Terminal step-finish reasons mean the agent is done with
                                    // this turn. Push message_complete immediately so the UI
                                    // stops showing "Generating..." without waiting for session.idle
                                    // (which can arrive 10-20+ seconds later). If the agent
                                    // continues (multi-step), new content events will re-set
                                    // status to prompting.
                                    //
                                    // However, when subagents are active the parent session
                                    // emits step-finish "stop" prematurely (the parent is idle
                                    // while waiting for the Task tool). Suppress in that case.
                                    if (reason != null and isStepFinishReason(reason.?)) {
                                        if (!self.hasActiveChildSessions()) {
                                            self.message_queue.push(.{ .message_complete = {} });
                                        } else {
                                            self.deferred_completion = true;
                                        }
                                    }
                                } else if (isTextPartType(ptype) and partHasEndTime(part_obj.?)) {
                                    log.info("Text part finished; awaiting session idle", .{});
                                }
                            }
                        }

                        var handled_delta = false;
                        if (part_obj) |obj| {
                            if (part_type) |ptype| {
                                if (isThinkingPartType(ptype)) {
                                    handled_delta = self.handleThinkingPart(obj, props.object);
                                } else if (isToolCallPartType(ptype) or isToolResultPartType(ptype)) {
                                    handled_delta = self.handleToolPart(obj, props.object, ptype);
                                }
                            }
                        }

                        if (!handled_delta) {
                            if (props.object.get("delta")) |delta_val| {
                                if (delta_val == .string) {
                                    const delta = self.event_allocator.dupe(u8, delta_val.string) catch return;
                                    // Content arriving means the agent is actively generating.
                                    // Reset stream_complete to recover from stale completion
                                    // events (e.g. late session.idle from a previous turn).
                                    self.stream_complete.store(false, .release);
                                    self.message_queue.push(.{
                                        .message_chunk = .{ .delta = delta },
                                    });
                                }
                            }
                        }
                    }
                }
            },
            .message_updated => {
                if (properties) |props| {
                    if (props == .object) {
                        // Track parent session token usage
                        self.trackParentTokenUsage(props);

                        if (extractMessageStatus(props)) |status| {
                            _ = self.handleMessageStatus(status);
                        } else if (isAssistantMessageComplete(props)) {
                            if (self.active_child_count.load(.acquire) > 0) {
                                log.info("Message complete via metadata, but subagents active — deferring", .{});
                                self.deferred_completion = true;
                            } else {
                                log.info("Message finished via update metadata", .{});
                                self.clearPromptingState();
                            }
                        }
                    }
                }
            },
            .message_deleted => {
                log.info("Message deleted; clearing prompting state", .{});
                self.clearPromptingState();
            },
            .permission_asked => {
                self.pending_permission = true;
                const detail = if (properties) |props| extractDetailFromProperties(props) else null;
                self.pushSystemMessage(tryBuildSystemMessage(self, "Permission requested", detail));
                self.clearPromptingState();
            },
            .permission_resolved => {
                self.pending_permission = false;
                const detail = if (properties) |props| extractDetailFromProperties(props) else null;
                self.pushSystemMessage(tryBuildSystemMessage(self, "Permission resolved", detail));
                self.clearPromptingState();
            },
            .question_asked => {
                self.pending_question = true;
                if (properties) |props| {
                    if (props == .object) {
                        if (self.parseQuestionPrompt(props.object)) |prompt| {
                            if (prompt.tool_call_id) |id| {
                                if (self.last_question_call_id) |last| {
                                    if (!std.mem.eql(u8, last, id)) {
                                        self.allocator.free(last);
                                        self.last_question_call_id = self.allocator.dupe(u8, id) catch self.last_question_call_id;
                                    }
                                } else {
                                    self.last_question_call_id = self.allocator.dupe(u8, id) catch self.last_question_call_id;
                                }
                            }
                            self.message_queue.push(.{ .question_prompt = prompt });
                        } else {
                            const detail = extractDetailFromProperties(props);
                            self.pushSystemMessage(tryBuildSystemMessage(self, "Question", detail));
                        }
                    }
                }
                self.clearPromptingState();
            },
            .question_resolved => {
                self.pending_question = false;
                self.message_queue.push(.{ .question_resolved = {} });
                self.clearPromptingState();
            },
            .session_updated => {
                // Some servers emit session.updated with state/status=idle instead of session.idle
                if (properties) |props| {
                    if (props == .object) {
                        var status_val = props.object.get("status") orelse props.object.get("state");
                        if (status_val == null) {
                            if (props.object.get("session")) |session_val| {
                                if (session_val == .object) {
                                    status_val = session_val.object.get("status") orelse session_val.object.get("state");
                                }
                            }
                        }
                        if (status_val) |val| {
                            if (val == .string and std.mem.eql(u8, val.string, "idle")) {
                                if (self.hasActiveChildSessions()) {
                                    log.info("Session updated to idle, but subagents active — deferring", .{});
                                    self.deferred_completion = true;
                                } else {
                                    log.info("Session updated to idle", .{});
                                    self.pending_abort = false;
                                    self.pending_abort_since_ms = 0;
                                    self.abort_error_grace_until_ms = 0;
                                    self.message_queue.push(.{ .message_complete = {} });
                                    self.message_queue.push(.{ .status_change = .session_active });
                                }
                            } else if (val == .string and std.mem.eql(u8, val.string, "compacting")) {
                                log.info("Session updated to compacting", .{});
                                self.is_compacting = true;
                            }
                        }
                    }
                }
            },
            .session_status => {
                if (properties) |props| {
                    if (props == .object) {
                        if (extractSessionStatus(props)) |status| {
                            if (isSessionIdleStatus(status)) {
                                if (self.hasActiveChildSessions()) {
                                    log.info("Session status idle, but subagents active — deferring", .{});
                                    self.deferred_completion = true;
                                } else {
                                    log.info("Session status idle", .{});
                                    self.clearPromptingState();
                                }
                            } else if (std.mem.eql(u8, status, "compacting")) {
                                log.info("Session compacting", .{});
                                self.is_compacting = true;
                            }
                        }
                    }
                }
            },
            .session_idle => {
                if (self.hasActiveChildSessions()) {
                    log.info("Session idle received, but subagents active — deferring", .{});
                    self.deferred_completion = true;
                } else {
                    log.info("Session idle received, resetting status to session_active", .{});
                    self.pending_abort = false;
                    self.pending_abort_since_ms = 0;
                    self.abort_error_grace_until_ms = 0;
                    self.message_queue.push(.{ .message_complete = {} });
                    self.message_queue.push(.{ .status_change = .session_active });
                }
            },
            .session_compacted => {
                log.info("Session compacted", .{});
                self.is_compacting = false;
                self.message_queue.push(.{ .session_compacted = {} });
            },
            .session_error => {
                const now_ms = std.time.milliTimestamp();
                if (self.pending_abort or (self.abort_error_grace_until_ms != 0 and now_ms <= self.abort_error_grace_until_ms)) {
                    log.info("Session error after abort; treating as cancelled", .{});
                    self.pending_abort = false;
                    self.pending_abort_since_ms = 0;
                    self.abort_error_grace_until_ms = 0;
                    self.message_queue.push(.{ .message_complete = {} });
                    self.message_queue.push(.{ .status_change = .session_active });
                } else {
                    self.message_queue.push(.{ .err = .{ .code = .session_error } });
                    self.message_queue.push(.{ .status_change = .failed });
                }
            },
            else => {
                // Ignore other event types for now
            },
        }
    }

    fn clearPromptingState(self: *OpencodeManager) void {
        self.pending_abort = false;
        self.pending_abort_since_ms = 0;
        self.abort_error_grace_until_ms = 0;
        self.is_compacting = false;
        self.deferred_completion = false;
        self.stream_complete.store(true, .release);
        self.message_queue.push(.{ .message_complete = {} });
        self.message_queue.push(.{ .status_change = .session_active });
    }

    /// Check if any child sessions (subagents) are currently active.
    /// Safe to call from main thread (uses atomic counter).
    pub fn hasActiveChildSessions(self: *const OpencodeManager) bool {
        return self.active_child_count.load(.acquire) > 0;
    }

    /// Extract the sessionID from an SSE event's properties.
    /// For message.part.updated, the sessionID is in properties.part.sessionID.
    /// For session.idle/session.updated/session.status, it's in properties.sessionID.
    fn getEventSessionId(props: std.json.Value, event_type: protocol.EventType) ?[]const u8 {
        if (props != .object) return null;
        switch (event_type) {
            .message_part_updated, .message_created, .message_updated, .message_deleted => {
                // Check part.sessionID (message.part.updated)
                if (props.object.get("part")) |part_val| {
                    if (part_val == .object) {
                        if (part_val.object.get("sessionID")) |sid_val| {
                            if (sid_val == .string) return sid_val.string;
                        }
                    }
                }
                // Check info.sessionID (message.updated — OpenCode puts message data in "info")
                if (props.object.get("info")) |info_val| {
                    if (info_val == .object) {
                        if (info_val.object.get("sessionID")) |sid_val| {
                            if (sid_val == .string) return sid_val.string;
                        }
                    }
                }
                // Check message.sessionID (message.updated, message.created)
                if (props.object.get("message")) |msg_val| {
                    if (msg_val == .object) {
                        if (msg_val.object.get("sessionID")) |sid_val| {
                            if (sid_val == .string) return sid_val.string;
                        }
                    }
                }
            },
            else => {},
        }
        // Universal fallback: check common sessionID locations for all event types.
        // This catches permission.asked, question.asked, etc. from child sessions
        // that would otherwise leak through the filter.
        if (props.object.get("sessionID")) |sid_val| {
            if (sid_val == .string) return sid_val.string;
        }
        if (props.object.get("session")) |session_val| {
            if (session_val == .object) {
                if (session_val.object.get("sessionID")) |sid_val| {
                    if (sid_val == .string) return sid_val.string;
                }
            }
        }
        return null;
    }

    /// Track tool calls from child sessions for real-time tool count display.
    /// Only counts events with status "pending" (the initial tool call event).
    fn trackChildToolEvent(self: *OpencodeManager, props: std.json.Value, child_sid: []const u8) void {
        if (props != .object) return;
        const part_val = props.object.get("part") orelse return;
        if (part_val != .object) return;
        const part_obj = part_val.object;

        // Only count tool-type parts
        const part_type = if (part_obj.get("type")) |t| (if (t == .string) t.string else null) else null;
        if (part_type == null) return;
        if (!isToolCallPartType(part_type.?) and !isToolResultPartType(part_type.?)) return;

        const state_obj = if (part_obj.get("state")) |state_val| blk: {
            if (state_val == .object) break :blk state_val.object;
            break :blk null;
        } else null;

        // Extract tool name for "last tool" display
        const tool_name = extractToolNameFromObject(part_obj) orelse
            if (state_obj) |obj| extractToolNameFromObject(obj) else null;

        // Track last tool name (update on every tool event, not just pending)
        var name_changed = false;
        if (tool_name) |name| {
            const prev = self.child_last_tool.get(child_sid);
            name_changed = prev == null or !std.mem.eql(u8, prev.?, name);
            self.updateChildLastTool(child_sid, name);
        }

        // Count unique tool calls (pending = first appearance)
        const status = if (state_obj) |obj| blk: {
            if (obj.get("status")) |s| {
                if (s == .string) break :blk s.string;
            }
            break :blk null;
        } else null;

        var count_changed = false;
        if (status) |s| {
            if (parseToolStatus(s)) |ts| {
                if (ts == .pending) {
                    self.incrementChildToolCount(child_sid);
                    count_changed = true;
                }
            }
        }

        // Push UI update when tool name or count changed
        if (name_changed or count_changed) {
            self.pushChildToolUpdate(child_sid);
        }
    }

    /// Extract token usage from a child session's message.updated event.
    /// Accumulates tokens across multiple assistant messages and deduplicates
    /// repeated events for the same message ID.
    fn trackChildTokenUsage(self: *OpencodeManager, props: std.json.Value, child_sid: []const u8) void {
        const info = extractMessageInfo(props) orelse return;

        // Only track assistant messages (they have the token data)
        if (info.get("role")) |role_val| {
            if (role_val != .string or !std.mem.eql(u8, role_val.string, "assistant")) return;
        } else return;

        const tok = extractTokensFromInfo(info) orelse return;
        const msg_id = extractStringFromObject(info, "id");

        if (self.child_tokens.getPtr(child_sid)) |acc| {
            acc.update(self.allocator, msg_id, tok);
        } else {
            var acc = TokenAccumulator{};
            acc.update(self.allocator, msg_id, tok);
            const key = self.allocator.dupe(u8, child_sid) catch return;
            self.child_tokens.put(self.allocator, key, acc) catch {
                acc.deinitMessageId(self.allocator);
                self.allocator.free(key);
                return;
            };
        }

        self.pushChildToolUpdate(child_sid);
    }

    /// Extract token usage from the parent session's message.updated event.
    /// Accumulates tokens across multiple assistant messages in the same turn.
    /// Extract token usage from the parent session's message.updated event.
    /// Accumulates tokens across multiple assistant messages in the same turn,
    /// deduplicating repeated events for the same message ID.
    fn trackParentTokenUsage(self: *OpencodeManager, props: std.json.Value) void {
        const info = extractMessageInfo(props) orelse return;

        // Only track assistant messages
        if (info.get("role")) |role_val| {
            if (role_val != .string or !std.mem.eql(u8, role_val.string, "assistant")) return;
        } else return;

        const tok = extractTokensFromInfo(info) orelse return;
        const msg_id = extractStringFromObject(info, "id");

        self.parent_tokens.update(self.allocator, msg_id, tok);
    }

    /// Get the parent agent's accumulated token usage for the current turn.
    pub fn getParentTokenCounts(self: *const OpencodeManager) ChildTokens {
        return self.parent_tokens.total();
    }

    /// Update the last tool name for a child session.
    fn updateChildLastTool(self: *OpencodeManager, child_sid: []const u8, tool_name: []const u8) void {
        if (self.child_last_tool.getPtr(child_sid)) |val_ptr| {
            // Replace existing value
            self.allocator.free(val_ptr.*);
            val_ptr.* = self.allocator.dupe(u8, tool_name) catch return;
        } else {
            const key = self.allocator.dupe(u8, child_sid) catch return;
            const val = self.allocator.dupe(u8, tool_name) catch {
                self.allocator.free(key);
                return;
            };
            self.child_last_tool.put(self.allocator, key, val) catch {
                self.allocator.free(key);
                self.allocator.free(val);
            };
        }
    }

    /// Register the mapping from child session ID to parent tool_call_id.
    fn registerChildSession(self: *OpencodeManager, child_sid: []const u8, parent_tool_id: []const u8) void {
        if (self.child_to_parent_tool.get(child_sid) != null) return; // Already registered
        const key = self.allocator.dupe(u8, child_sid) catch return;
        const val = self.allocator.dupe(u8, parent_tool_id) catch {
            self.allocator.free(key);
            return;
        };
        self.child_to_parent_tool.put(self.allocator, key, val) catch {
            self.allocator.free(key);
            self.allocator.free(val);
        };
    }

    /// Push a tool_update event with current child session info so the UI
    /// shows the latest tool count and last tool name while the subagent runs.
    fn pushChildToolUpdate(self: *OpencodeManager, child_sid: []const u8) void {
        const parent_tool_id = self.child_to_parent_tool.get(child_sid) orelse return;
        const tool_count = self.child_tool_counts.get(child_sid) orelse 0;
        const last_tool = self.child_last_tool.get(child_sid);

        const id_copy = self.event_allocator.dupe(u8, parent_tool_id) catch return;

        // Include accumulated token usage if available
        const tok = if (self.child_tokens.get(child_sid)) |acc| acc.total() else ChildTokens{};

        var info: Event.SubagentEventInfo = .{
            .tool_count = tool_count,
            .input_tokens = tok.input,
            .output_tokens = tok.output,
            .reasoning_tokens = tok.reasoning,
            .cache_read_tokens = tok.cache_read,
            .cache_write_tokens = tok.cache_write,
            .start_time_ms = self.child_start_times.get(child_sid) orelse 0,
        };

        // Build a single-entry summary with the last tool name
        if (last_tool) |name| {
            var summaries = self.event_allocator.alloc(Event.SubagentToolSummary, 1) catch {
                self.event_allocator.free(id_copy);
                return;
            };
            summaries[0] = .{
                .tool_name = self.event_allocator.dupe(u8, name) catch {
                    self.event_allocator.free(summaries);
                    self.event_allocator.free(id_copy);
                    return;
                },
                .status = .running,
            };
            info.summary = summaries;
        }

        self.message_queue.push(.{ .tool_update = .{
            .tool_call_id = id_copy,
            .status = .running,
            .subagent_info = info,
        } });
    }

    /// Insert or increment the tool count for a child session ID.
    fn incrementChildToolCount(self: *OpencodeManager, child_sid: []const u8) void {
        if (self.child_tool_counts.getPtr(child_sid)) |count_ptr| {
            count_ptr.* += 1;
        } else {
            const key = self.allocator.dupe(u8, child_sid) catch return;
            self.child_tool_counts.put(self.allocator, key, 1) catch {
                self.allocator.free(key);
                return;
            };
            // Record start time for this child session
            const time_key = self.allocator.dupe(u8, child_sid) catch return;
            self.child_start_times.put(self.allocator, time_key, std.time.milliTimestamp()) catch {
                self.allocator.free(time_key);
            };
            // New child session — increment atomic counter
            _ = self.active_child_count.fetchAdd(1, .release);
        }
    }

    /// Remove a child session's entries from all tracking maps.
    /// If this was the last active child and a parent completion was deferred,
    /// fires the deferred clearPromptingState().
    fn removeChildToolCount(self: *OpencodeManager, child_sid: []const u8) void {
        var was_tracked = false;
        if (self.child_tool_counts.fetchRemove(child_sid)) |entry| {
            self.allocator.free(entry.key);
            if (self.active_child_count.load(.acquire) > 0) {
                _ = self.active_child_count.fetchSub(1, .release);
            }
            was_tracked = true;
        }
        if (self.child_last_tool.fetchRemove(child_sid)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        if (self.child_to_parent_tool.fetchRemove(child_sid)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        if (self.child_tokens.fetchRemove(child_sid)) |entry| {
            self.allocator.free(entry.key);
            var acc = entry.value;
            acc.deinitMessageId(self.allocator);
        }
        if (self.child_start_times.fetchRemove(child_sid)) |entry| {
            self.allocator.free(entry.key);
        }

        // If this was the last child and a completion was deferred, fire it now
        if (was_tracked and self.active_child_count.load(.acquire) == 0 and self.deferred_completion) {
            log.info("Last child session completed — firing deferred completion", .{});
            self.deferred_completion = false;
            self.clearPromptingState();
        }
    }

    fn handleMessageStatus(self: *OpencodeManager, status: []const u8) bool {
        if (isMessageCompletionStatus(status)) {
            if (self.active_child_count.load(.acquire) > 0) {
                log.info("Message status {s}, but subagents active — deferring", .{status});
                self.deferred_completion = true;
                return true;
            }
            log.info("Message status complete: {s}", .{status});
            self.clearPromptingState();
            return true;
        }
        if (isMessageErrorStatus(status)) {
            log.warn("Message status error: {s}", .{status});
            self.message_queue.push(.{ .err = .{ .code = .session_error } });
            self.message_queue.push(.{ .status_change = .failed });
            return true;
        }
        return false;
    }

    fn extractMessageStatus(props: std.json.Value) ?[]const u8 {
        if (props != .object) return null;
        var status_val = props.object.get("status") orelse props.object.get("state");
        if (status_val == null) {
            if (props.object.get("message")) |message_val| {
                if (message_val == .object) {
                    status_val = message_val.object.get("status") orelse message_val.object.get("state");
                }
            }
        }
        if (status_val) |val| {
            if (val == .string) return val.string;
        }
        return null;
    }

    fn isAssistantMessageComplete(props: std.json.Value) bool {
        const info = extractMessageInfo(props) orelse return false;

        const role = if (info.get("role")) |role_val| blk: {
            if (role_val == .string) break :blk role_val.string;
            break :blk null;
        } else null;

        if (role == null or !std.mem.eql(u8, role.?, "assistant")) return false;

        if (info.get("finish")) |finish_val| {
            if (finish_val == .string) return true;
        }

        if (info.get("time")) |time_val| {
            if (time_val == .object) {
                if (time_val.object.get("completed")) |completed_val| {
                    return switch (completed_val) {
                        .integer, .float, .string => true,
                        else => false,
                    };
                }
            }
        }

        return false;
    }

    fn extractMessageInfo(props: std.json.Value) ?std.json.ObjectMap {
        if (props != .object) return null;
        if (props.object.get("info")) |info_val| {
            if (info_val == .object) return info_val.object;
        }
        if (props.object.get("message")) |message_val| {
            if (message_val == .object) return message_val.object;
        }
        return null;
    }

    /// Extract a ChildTokens struct from a message info object's "tokens" field.
    /// Handles input, output, reasoning, and cache.{read,write}.
    /// Returns null if no meaningful token data is present.
    fn extractTokensFromInfo(info: std.json.ObjectMap) ?ChildTokens {
        const tokens_obj = if (info.get("tokens")) |v| (if (v == .object) v.object else null) else null;
        const tokens = tokens_obj orelse return null;

        var tok: ChildTokens = .{};
        inline for (.{ .{ "input", "input" }, .{ "output", "output" }, .{ "reasoning", "reasoning" } }) |pair| {
            if (tokens.get(pair[0])) |v| {
                @field(tok, pair[1]) = switch (v) {
                    .integer => |i| if (i >= 0) @intCast(i) else 0,
                    .float => |f| if (f >= 0) @intFromFloat(f) else 0,
                    else => 0,
                };
            }
        }
        if (tokens.get("cache")) |cache_val| {
            if (cache_val == .object) {
                if (cache_val.object.get("read")) |v| {
                    tok.cache_read = switch (v) {
                        .integer => |i| if (i >= 0) @intCast(i) else 0,
                        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
                        else => 0,
                    };
                }
                if (cache_val.object.get("write")) |v| {
                    tok.cache_write = switch (v) {
                        .integer => |i| if (i >= 0) @intCast(i) else 0,
                        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
                        else => 0,
                    };
                }
            }
        }

        if (tok.input == 0 and tok.output == 0) return null;
        return tok;
    }

    /// Extract a string value from a JSON object by key name.
    fn extractStringFromObject(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        if (obj.get(key)) |val| {
            if (val == .string) return val.string;
        }
        return null;
    }

    fn extractSessionStatus(props: std.json.Value) ?[]const u8 {
        if (props != .object) return null;

        if (props.object.get("status")) |status_val| {
            switch (status_val) {
                .string => |s| return s,
                .object => |obj| {
                    if (obj.get("type")) |type_val| {
                        if (type_val == .string) return type_val.string;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn extractDetailFromProperties(props: std.json.Value) ?[]const u8 {
        if (props != .object) return null;

        const detail_keys = [_][]const u8{
            "prompt",
            "question",
            "text",
            "title",
            "description",
            "reason",
            "message",
        };

        if (findDetailInObject(props.object, &detail_keys)) |detail| return detail;

        const nested_keys = [_][]const u8{
            "permission",
            "question",
            "message",
        };
        for (nested_keys) |key| {
            if (props.object.get(key)) |val| {
                if (extractStringFromValue(val, &detail_keys)) |detail| return detail;
            }
        }

        return null;
    }

    fn extractStringFromValue(val: std.json.Value, keys: []const []const u8) ?[]const u8 {
        switch (val) {
            .string => |s| return s,
            .object => |obj| return findDetailInObject(obj, keys),
            else => return null,
        }
    }

    fn findDetailInObject(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
        for (keys) |key| {
            if (obj.get(key)) |val| {
                if (extractStringFromValue(val, keys)) |detail| return detail;
            }
        }
        return null;
    }

    fn isThinkingPartType(part_type: []const u8) bool {
        return std.ascii.eqlIgnoreCase(part_type, "thinking") or
            std.ascii.eqlIgnoreCase(part_type, "thought") or
            std.ascii.eqlIgnoreCase(part_type, "reasoning") or
            std.ascii.eqlIgnoreCase(part_type, "analysis");
    }

    fn isToolCallPartType(part_type: []const u8) bool {
        return std.ascii.eqlIgnoreCase(part_type, "tool_call") or
            std.ascii.eqlIgnoreCase(part_type, "tool-call") or
            std.ascii.eqlIgnoreCase(part_type, "tool_call_delta") or
            std.ascii.eqlIgnoreCase(part_type, "tool-call-delta") or
            std.ascii.eqlIgnoreCase(part_type, "tool") or
            std.ascii.eqlIgnoreCase(part_type, "tool_use") or
            std.ascii.eqlIgnoreCase(part_type, "tool-use");
    }

    fn isToolResultPartType(part_type: []const u8) bool {
        return std.ascii.eqlIgnoreCase(part_type, "tool_result") or
            std.ascii.eqlIgnoreCase(part_type, "tool-result") or
            std.ascii.eqlIgnoreCase(part_type, "tool_result_delta") or
            std.ascii.eqlIgnoreCase(part_type, "tool-result-delta") or
            std.ascii.eqlIgnoreCase(part_type, "tool_output") or
            std.ascii.eqlIgnoreCase(part_type, "tool-output") or
            std.ascii.eqlIgnoreCase(part_type, "tool_response") or
            std.ascii.eqlIgnoreCase(part_type, "tool-response");
    }

    fn extractStringField(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
        for (keys) |key| {
            if (obj.get(key)) |val| {
                if (val == .string) return val.string;
            }
        }
        return null;
    }

    fn extractIntField(obj: std.json.ObjectMap, keys: []const []const u8) ?i64 {
        for (keys) |key| {
            if (obj.get(key)) |val| {
                switch (val) {
                    .integer => |n| return n,
                    .float => |n| return @intFromFloat(n),
                    else => {},
                }
            }
        }
        return null;
    }

    fn extractObjectField(obj: std.json.ObjectMap, keys: []const []const u8) ?std.json.ObjectMap {
        for (keys) |key| {
            if (obj.get(key)) |val| {
                if (val == .object) return val.object;
            }
        }
        return null;
    }

    fn extractValueField(obj: std.json.ObjectMap, keys: []const []const u8) ?std.json.Value {
        for (keys) |key| {
            if (obj.get(key)) |val| return val;
        }
        return null;
    }

    const SessionCandidate = struct {
        id: []const u8,
        updated: i64,

        pub fn moreRecentFirst(_: void, a: SessionCandidate, b: SessionCandidate) bool {
            return a.updated > b.updated;
        }
    };

    fn extractSessionsArray(root: std.json.Value) ?[]const std.json.Value {
        switch (root) {
            .array => |arr| return arr.items,
            .object => |obj| {
                if (obj.get("sessions")) |val| if (val == .array) return val.array.items;
                if (obj.get("data")) |val| if (val == .array) return val.array.items;
            },
            else => {},
        }
        return null;
    }

    fn extractMessagesArray(root: std.json.Value) ?[]const std.json.Value {
        switch (root) {
            .array => |arr| return arr.items,
            .object => |obj| {
                if (obj.get("messages")) |val| if (val == .array) return val.array.items;
                if (obj.get("data")) |val| if (val == .array) return val.array.items;
            },
            else => {},
        }
        return null;
    }

    fn extractSessionTimestamp(obj: std.json.ObjectMap) i64 {
        if (extractObjectField(obj, &[_][]const u8{"time"})) |time_obj| {
            if (extractIntField(time_obj, &[_][]const u8{ "updated", "created" })) |ts| return ts;
        }
        return 0;
    }

    fn extractLatestAgentFromMessages(root: std.json.Value) ?[]const u8 {
        const messages = extractMessagesArray(root) orelse return null;
        var fallback: ?[]const u8 = null;

        var i: usize = messages.len;
        while (i > 0) {
            i -= 1;
            const msg_val = messages[i];
            if (msg_val != .object) continue;

            const msg_obj = msg_val.object;
            const info_obj = extractObjectField(msg_obj, &[_][]const u8{"info"});
            var role: ?[]const u8 = null;
            var agent: ?[]const u8 = null;

            if (info_obj) |info| {
                role = extractStringField(info, &[_][]const u8{"role"});
                agent = extractStringField(info, &[_][]const u8{"agent"});
            }

            if (agent == null) {
                agent = extractStringField(msg_obj, &[_][]const u8{"agent"});
            }

            if (role == null) {
                role = extractStringField(msg_obj, &[_][]const u8{"role"});
            }

            if (agent == null) continue;

            if (role == null or std.mem.eql(u8, role.?, "assistant")) {
                return agent;
            }

            if (fallback == null) fallback = agent;
        }

        return fallback;
    }

    fn extractToolCallIdFromObject(obj: std.json.ObjectMap) ?[]const u8 {
        // callID/callId must come before "id" — tool parts have both a part
        // "id" (e.g. "prt_...") and a "callID" (e.g. "question:0"), and we
        // need the call ID, not the part ID.
        const keys = [_][]const u8{ "tool_call_id", "toolCallId", "callID", "callId", "call_id", "id" };
        return extractStringField(obj, &keys);
    }

    fn extractToolNameFromObject(obj: std.json.ObjectMap) ?[]const u8 {
        const keys = [_][]const u8{ "tool_name", "toolName", "name" };
        if (extractStringField(obj, &keys)) |name| return name;

        if (obj.get("tool")) |tool_val| {
            switch (tool_val) {
                .string => |s| return s,
                .object => |tool_obj| {
                    if (extractStringField(tool_obj, &keys)) |name| return name;
                },
                else => {},
            }
        }

        if (obj.get("function")) |func_val| {
            if (func_val == .object) {
                if (extractStringField(func_val.object, &[_][]const u8{"name"})) |name| return name;
            }
        }

        return null;
    }

    fn extractToolArgsValue(obj: std.json.ObjectMap) ?std.json.Value {
        const keys = [_][]const u8{ "arguments", "args", "input", "params" };
        if (extractValueField(obj, &keys)) |val| return val;

        if (obj.get("function")) |func_val| {
            if (func_val == .object) {
                if (extractValueField(func_val.object, &[_][]const u8{"arguments"})) |val| return val;
            }
        }

        return null;
    }

    fn extractPatchTextFromValue(val: std.json.Value) ?[]const u8 {
        switch (val) {
            .string => |s| return s,
            .object => |obj| {
                const keys = [_][]const u8{ "patch", "diff", "text", "content", "patchText", "patch_text" };
                if (extractStringField(obj, &keys)) |s| return s;
            },
            else => {},
        }
        return null;
    }

    fn extractToolCommandFromArgs(tool_name: ?[]const u8, val: ?std.json.Value) ?[]const u8 {
        if (val == null) return null;

        switch (val.?) {
            .string => |s| {
                if (tool_name) |name| {
                    if (std.ascii.eqlIgnoreCase(name, "bash") or std.ascii.eqlIgnoreCase(name, "shell")) return s;
                }
                return null;
            },
            .object => |obj| {
                const keys = [_][]const u8{ "command", "cmd", "shell" };
                return extractStringField(obj, &keys);
            },
            else => return null,
        }
    }

    fn parseToolStatus(status: []const u8) ?ToolStatus {
        if (std.ascii.eqlIgnoreCase(status, "pending") or std.ascii.eqlIgnoreCase(status, "queued")) return .pending;
        if (std.ascii.eqlIgnoreCase(status, "running") or std.ascii.eqlIgnoreCase(status, "in_progress") or std.ascii.eqlIgnoreCase(status, "started")) return .running;
        if (std.ascii.eqlIgnoreCase(status, "completed") or std.ascii.eqlIgnoreCase(status, "success") or std.ascii.eqlIgnoreCase(status, "succeeded") or std.ascii.eqlIgnoreCase(status, "done")) return .completed;
        if (std.ascii.eqlIgnoreCase(status, "failed") or std.ascii.eqlIgnoreCase(status, "error") or std.ascii.eqlIgnoreCase(status, "cancelled") or std.ascii.eqlIgnoreCase(status, "canceled")) return .failed;
        return null;
    }

    fn extractToolStatusFromObject(obj: std.json.ObjectMap) ?ToolStatus {
        const keys = [_][]const u8{ "status", "state" };
        if (extractStringField(obj, &keys)) |s| {
            return parseToolStatus(s);
        }
        return null;
    }

    fn extractToolOutputFromObject(obj: std.json.ObjectMap) ?[]const u8 {
        const keys = [_][]const u8{ "stdout", "output", "content", "text", "result" };
        return extractStringField(obj, &keys);
    }

    fn extractToolErrorFromObject(obj: std.json.ObjectMap) ?[]const u8 {
        const keys = [_][]const u8{ "stderr", "error", "message" };
        return extractStringField(obj, &keys);
    }

    fn extractToolTitleFromObject(obj: std.json.ObjectMap) ?[]const u8 {
        const keys = [_][]const u8{ "title", "summary" };
        return extractStringField(obj, &keys);
    }

    fn parseSubagentEventInfo(self: *OpencodeManager, state_obj: std.json.ObjectMap) ?Event.SubagentEventInfo {
        var info: Event.SubagentEventInfo = .{};
        var has_any = false;

        // Extract state.input.description and state.input.subagent_type
        if (extractObjectField(state_obj, &[_][]const u8{"input"})) |input_obj| {
            if (extractStringField(input_obj, &[_][]const u8{"description"})) |desc| {
                info.description = self.event_allocator.dupe(u8, desc) catch null;
                if (info.description != null) has_any = true;
            }
            if (extractStringField(input_obj, &[_][]const u8{ "subagent_type", "subagentType" })) |at| {
                info.agent_type = self.event_allocator.dupe(u8, at) catch null;
                if (info.agent_type != null) has_any = true;
            }
        }

        // Extract state.title
        if (extractStringField(state_obj, &[_][]const u8{"title"})) |t| {
            info.title = self.event_allocator.dupe(u8, t) catch null;
            if (info.title != null) has_any = true;
        }

        // Extract state.metadata.sessionId and state.metadata.summary
        if (extractObjectField(state_obj, &[_][]const u8{"metadata"})) |metadata_obj| {
            if (extractStringField(metadata_obj, &[_][]const u8{ "sessionId", "session_id" })) |sid| {
                info.session_id = self.event_allocator.dupe(u8, sid) catch null;
                if (info.session_id != null) has_any = true;
            }

            if (extractValueField(metadata_obj, &[_][]const u8{"summary"})) |summary_val| {
                if (summary_val == .array) {
                    info.tool_count = summary_val.array.items.len;
                    has_any = true;
                    var summaries: std.ArrayList(Event.SubagentToolSummary) = .{};
                    for (summary_val.array.items) |entry_val| {
                        if (entry_val != .object) continue;
                        const entry_obj = entry_val.object;

                        const tool_name_str = extractStringField(entry_obj, &[_][]const u8{"tool"}) orelse continue;
                        const owned_tool_name = self.event_allocator.dupe(u8, tool_name_str) catch continue;

                        var summary_entry: Event.SubagentToolSummary = .{ .tool_name = owned_tool_name };

                        // Extract state.title and state.status from entry
                        if (extractObjectField(entry_obj, &[_][]const u8{"state"})) |entry_state| {
                            if (extractStringField(entry_state, &[_][]const u8{"title"})) |st| {
                                summary_entry.title = self.event_allocator.dupe(u8, st) catch null;
                            }
                            if (extractToolStatusFromObject(entry_state)) |s| {
                                summary_entry.status = s;
                            }
                        }

                        summaries.append(self.event_allocator, summary_entry) catch {
                            self.event_allocator.free(owned_tool_name);
                            if (summary_entry.title) |t| self.event_allocator.free(t);
                            continue;
                        };
                    }
                    if (summaries.items.len > 0) {
                        info.summary = summaries.toOwnedSlice(self.event_allocator) catch blk: {
                            for (summaries.items) |*entry| {
                                entry.deinit(self.event_allocator);
                            }
                            summaries.deinit(self.event_allocator);
                            break :blk &.{};
                        };
                    }
                }
            }
        }

        // If we have a session_id but no tool_count from summary, use our tracked count
        if (info.tool_count == 0) {
            if (info.session_id) |sid| {
                if (self.child_tool_counts.get(sid)) |count| {
                    info.tool_count = count;
                    has_any = true;
                }
            }
        }

        if (!has_any) return null;
        return info;
    }

    fn parseQuestionItems(self: *OpencodeManager, questions_val: std.json.Value) ?[]Event.QuestionItem {
        if (questions_val != .array) return null;

        var questions_list: std.ArrayList(Event.QuestionItem) = .{};
        errdefer {
            for (questions_list.items) |*item| item.deinit(self.event_allocator);
            questions_list.deinit(self.event_allocator);
        }

        for (questions_val.array.items) |question_val| {
            if (question_val != .object) continue;
            const question_obj = question_val.object;

            const question_text = extractStringField(question_obj, &[_][]const u8{ "question", "prompt", "text" }) orelse continue;
            const header_text = extractStringField(question_obj, &[_][]const u8{ "header", "title", "topic" });

            const multiple: bool = if (question_obj.get("multiple")) |multi_val| blk: {
                if (multi_val == .bool) break :blk multi_val.bool;
                break :blk false;
            } else false;

            var options_list: std.ArrayList(Event.QuestionOption) = .{};
            errdefer {
                for (options_list.items) |*opt| opt.deinit(self.event_allocator);
                options_list.deinit(self.event_allocator);
            }

            if (question_obj.get("options")) |options_val| {
                if (options_val == .array) {
                    for (options_val.array.items) |opt_val| {
                        if (opt_val != .object) continue;
                        const opt_obj = opt_val.object;
                        const label = extractStringField(opt_obj, &[_][]const u8{ "label", "name", "value", "text" }) orelse continue;
                        const desc = extractStringField(opt_obj, &[_][]const u8{ "description", "detail", "hint" });

                        const label_copy = self.event_allocator.dupe(u8, label) catch continue;
                        const desc_copy: ?[]const u8 = if (desc) |d|
                            self.event_allocator.dupe(u8, d) catch null
                        else
                            null;

                        options_list.append(self.event_allocator, .{
                            .label = label_copy,
                            .description = desc_copy,
                        }) catch {
                            self.event_allocator.free(label_copy);
                            if (desc_copy) |d| self.event_allocator.free(d);
                        };
                    }
                }
            }

            const question_copy = self.event_allocator.dupe(u8, question_text) catch continue;
            const header_copy: ?[]const u8 = if (header_text) |h|
                self.event_allocator.dupe(u8, h) catch null
            else
                null;

            const options_slice = options_list.toOwnedSlice(self.event_allocator) catch {
                if (header_copy) |h| self.event_allocator.free(h);
                self.event_allocator.free(question_copy);
                continue;
            };

            questions_list.append(self.event_allocator, .{
                .header = header_copy,
                .question = question_copy,
                .options = options_slice,
                .multiple = multiple,
            }) catch {
                if (header_copy) |h| self.event_allocator.free(h);
                self.event_allocator.free(question_copy);
                for (options_slice) |*opt| opt.deinit(self.event_allocator);
                self.event_allocator.free(options_slice);
            };
        }

        if (questions_list.items.len == 0) {
            return null;
        }

        return questions_list.toOwnedSlice(self.event_allocator) catch null;
    }

    fn parseQuestionPrompt(self: *OpencodeManager, props: std.json.ObjectMap) ?Event.QuestionPrompt {
        const questions_val = props.get("questions") orelse return null;
        const questions_slice = self.parseQuestionItems(questions_val) orelse return null;

        const id = extractStringField(props, &[_][]const u8{ "id", "questionID", "question_id" });
        const tool_call_id = if (props.get("tool")) |tool_val| blk: {
            if (tool_val == .object) {
                break :blk extractStringField(tool_val.object, &[_][]const u8{ "callID", "callId", "call_id", "tool_call_id" });
            }
            break :blk null;
        } else null;

        const id_copy: ?[]const u8 = if (id) |value|
            self.event_allocator.dupe(u8, value) catch null
        else
            null;
        const tool_call_id_copy: ?[]const u8 = if (tool_call_id) |value|
            self.event_allocator.dupe(u8, value) catch null
        else
            null;

        return .{
            .id = id_copy,
            .tool_call_id = tool_call_id_copy,
            .questions = questions_slice,
        };
    }

    fn parseQuestionPromptFromTool(self: *OpencodeManager, tool_call_id: ?[]const u8, state_obj: std.json.ObjectMap) ?Event.QuestionPrompt {
        const input_val = state_obj.get("input") orelse return null;
        if (input_val != .object) return null;

        const input_obj = input_val.object;
        const questions_val = input_obj.get("questions") orelse return null;
        const questions_slice = self.parseQuestionItems(questions_val) orelse return null;

        const tool_call_id_copy: ?[]const u8 = if (tool_call_id) |value|
            self.event_allocator.dupe(u8, value) catch null
        else
            null;

        return .{
            .id = null,
            .tool_call_id = tool_call_id_copy,
            .questions = questions_slice,
        };
    }

    fn isApplyPatchTool(tool_name: ?[]const u8, patch_text: []const u8) bool {
        if (tool_name) |name| {
            if (std.ascii.eqlIgnoreCase(name, "apply_patch") or std.ascii.eqlIgnoreCase(name, "applyPatch")) return true;
        }
        return std.mem.indexOf(u8, patch_text, "*** Begin Patch") != null;
    }

    fn handleThinkingPart(self: *OpencodeManager, part_obj: std.json.ObjectMap, props_obj: std.json.ObjectMap) bool {
        _ = part_obj;
        const delta = if (props_obj.get("delta")) |delta_val| blk: {
            if (delta_val == .string) break :blk delta_val.string;
            break :blk null;
        } else null;

        // Only emit thinking content from the delta field. Finalization events
        // carry the full accumulated text in part.text but no delta — emitting
        // that would duplicate all previously-streamed thinking content.
        // Return false when no delta exists so the fallback text handler can try.
        if (delta) |text| {
            if (text.len > 0) {
                const chunk = self.event_allocator.dupe(u8, text) catch return true;
                self.stream_complete.store(false, .release);
                self.message_queue.push(.{ .thinking_chunk = .{ .delta = chunk } });
            }
            return true;
        }
        return false;
    }

    fn handleToolPart(self: *OpencodeManager, part_obj: std.json.ObjectMap, props_obj: std.json.ObjectMap, part_type: []const u8) bool {
        const state_obj = extractObjectField(part_obj, &[_][]const u8{"state"}) orelse extractObjectField(props_obj, &[_][]const u8{"state"});
        const tool_id = extractToolCallIdFromObject(part_obj) orelse extractToolCallIdFromObject(props_obj) orelse if (state_obj) |obj| extractToolCallIdFromObject(obj) else null;
        const tool_name = extractToolNameFromObject(part_obj) orelse extractToolNameFromObject(props_obj);
        const args_val = if (state_obj) |obj|
            extractToolArgsValue(obj)
        else
            extractToolArgsValue(part_obj) orelse extractToolArgsValue(props_obj);
        const title_val = if (state_obj) |obj| extractToolTitleFromObject(obj) else null;
        const patch_text = if (args_val) |val| extractPatchTextFromValue(val) else null;

        var status = if (state_obj) |obj| extractToolStatusFromObject(obj) else null;
        if (status == null) status = extractToolStatusFromObject(part_obj) orelse extractToolStatusFromObject(props_obj);

        const is_result = isToolResultPartType(part_type);

        if (tool_name != null and std.ascii.eqlIgnoreCase(tool_name.?, "question")) {
            if (state_obj) |obj| {
                if (tool_id) |id| {
                    if (self.last_question_call_id) |last| {
                        if (std.mem.eql(u8, last, id)) return true;
                    }
                }
                if (self.parseQuestionPromptFromTool(tool_id, obj)) |prompt| {
                    if (prompt.tool_call_id) |id| {
                        if (self.last_question_call_id) |last| self.allocator.free(last);
                        self.last_question_call_id = self.allocator.dupe(u8, id) catch self.last_question_call_id;
                    }
                    self.message_queue.push(.{ .question_prompt = prompt });
                    return true;
                }
            }
        }

        if (patch_text) |patch_value| {
            if (isApplyPatchTool(tool_name, patch_value)) {
                if (status == null or status.? == .running or status.? == .completed) {
                    if (self.emitApplyPatchDiff(tool_id, patch_value)) {
                        return true;
                    }
                }
            }
        }

        if (tool_id) |id| {
            // Detect task tools for subagent info parsing
            const is_task_tool = tool_name != null and std.ascii.eqlIgnoreCase(tool_name.?, "task");

            if (!is_result) {
                const title = if (title_val) |raw| blk: {
                    if (tool_name) |name| {
                        break :blk std.fmt.allocPrint(self.event_allocator, "{s} {s}", .{ name, raw }) catch self.event_allocator.dupe(u8, raw) catch return true;
                    }
                    break :blk self.event_allocator.dupe(u8, raw) catch return true;
                } else if (tool_name) |name| blk: {
                    break :blk self.event_allocator.dupe(u8, name) catch return true;
                } else blk: {
                    break :blk self.event_allocator.dupe(u8, "Tool") catch return true;
                };
                const id_copy = self.event_allocator.dupe(u8, id) catch {
                    self.event_allocator.free(title);
                    return true;
                };
                const name_copy: ?[]const u8 = if (tool_name) |name|
                    self.event_allocator.dupe(u8, name) catch null
                else
                    null;
                const cmd = extractToolCommandFromArgs(tool_name, args_val);
                const cmd_copy: ?[]const u8 = if (cmd) |c| self.event_allocator.dupe(u8, c) catch null else null;

                // Parse subagent info for task tool calls (each parse allocates its own copies)
                const tc_subagent: ?Event.SubagentEventInfo = if (is_task_tool and state_obj != null)
                    self.parseSubagentEventInfo(state_obj.?)
                else
                    null;

                // Register child session → parent tool mapping for live updates
                if (tc_subagent) |info| {
                    if (info.session_id) |child_sid| {
                        self.registerChildSession(child_sid, id);
                    }
                }

                self.message_queue.push(.{
                    .tool_call = .{
                        .tool_call_id = id_copy,
                        .tool_name = name_copy,
                        .title = title,
                        .command = cmd_copy,
                        .subagent_info = tc_subagent,
                    },
                });
            }

            const stdout = if (state_obj) |obj|
                extractToolOutputFromObject(obj)
            else
                extractToolOutputFromObject(part_obj) orelse extractToolOutputFromObject(props_obj);
            const stderr = if (state_obj) |obj|
                extractToolErrorFromObject(obj)
            else
                extractToolErrorFromObject(part_obj) orelse extractToolErrorFromObject(props_obj);

            if (status == null and (stdout != null or stderr != null or is_result)) {
                status = .completed;
            }

            if (status) |s| {
                const id_copy = self.event_allocator.dupe(u8, id) catch return true;
                const stdout_copy: ?[]const u8 = if (stdout) |out| self.event_allocator.dupe(u8, out) catch null else null;
                const stderr_copy: ?[]const u8 = if (stderr) |err| self.event_allocator.dupe(u8, err) catch null else null;

                // Parse subagent info for task tool updates (separate allocation from tool_call)
                const tu_subagent: ?Event.SubagentEventInfo = if (is_task_tool and state_obj != null)
                    self.parseSubagentEventInfo(state_obj.?)
                else
                    null;

                // Register child session → parent tool mapping for live updates
                if (tu_subagent) |info| {
                    if (info.session_id) |child_sid| {
                        self.registerChildSession(child_sid, id);
                    }
                }

                self.message_queue.push(.{ .tool_update = .{
                    .tool_call_id = id_copy,
                    .status = s,
                    .stdout = stdout_copy,
                    .stderr = stderr_copy,
                    .subagent_info = tu_subagent,
                } });

                // Clean up child tool count when task completes
                if (is_task_tool and (s == .completed or s == .failed)) {
                    if (state_obj) |obj| {
                        if (extractObjectField(obj, &[_][]const u8{"metadata"})) |metadata_obj| {
                            if (extractStringField(metadata_obj, &[_][]const u8{ "sessionId", "session_id" })) |child_sid| {
                                self.removeChildToolCount(child_sid);
                            }
                        }
                    }
                }
            }
            return true;
        }

        // No tool_id found and no question/patch was handled — return false so
        // the fallback text delta handler gets a chance to extract content.
        return false;
    }

    fn emitApplyPatchDiff(self: *OpencodeManager, tool_call_id: ?[]const u8, patch_text: []const u8) bool {
        if (tool_call_id) |id| {
            if (self.last_diff_tool_call_id) |last| {
                if (std.mem.eql(u8, last, id)) {
                    return true;
                }
            }
        }

        const files = patch.parseApplyPatch(self.event_allocator, patch_text) catch |err| {
            log.warn("Failed to parse apply_patch text: {any}", .{err});
            return false;
        };
        defer {
            for (files) |*file| file.deinit(self.event_allocator);
            self.event_allocator.free(files);
        }

        var any_diff = false;
        for (files) |file| {
            const display_path = file.new_path orelse file.path;
            const applied = patch.buildOldNewFromHunks(self.event_allocator, file.hunks) catch |err| {
                log.warn("apply_patch diff build failed for {s}: {any}", .{ display_path, err });
                continue;
            };

            const title = std.fmt.allocPrint(self.event_allocator, "Edit {s}", .{display_path}) catch blk: {
                break :blk self.event_allocator.dupe(u8, "Edit") catch {
                    self.event_allocator.free(applied.old_text);
                    self.event_allocator.free(applied.new_text);
                    continue;
                };
            };

            const path_copy = self.event_allocator.dupe(u8, display_path) catch {
                self.event_allocator.free(title);
                self.event_allocator.free(applied.old_text);
                self.event_allocator.free(applied.new_text);
                continue;
            };

            const id_copy: ?[]const u8 = if (tool_call_id) |id|
                self.event_allocator.dupe(u8, id) catch null
            else
                null;

            self.message_queue.push(.{ .tool_diff = .{
                .tool_call_id = id_copy,
                .title = title,
                .path = path_copy,
                .old_text = applied.old_text,
                .new_text = applied.new_text,
            } });

            any_diff = true;
        }

        if (any_diff) {
            if (tool_call_id) |id| {
                if (self.last_diff_tool_call_id) |last| {
                    self.allocator.free(last);
                    self.last_diff_tool_call_id = null;
                }
                self.last_diff_tool_call_id = self.allocator.dupe(u8, id) catch null;
            }
        }

        return any_diff;
    }

    fn tryBuildSystemMessage(self: *OpencodeManager, prefix: []const u8, detail: ?[]const u8) ?[]const u8 {
        if (detail) |d| {
            return std.fmt.allocPrint(self.event_allocator, "{s}: {s}", .{ prefix, d }) catch null;
        }
        return std.fmt.allocPrint(self.event_allocator, "{s}.", .{prefix}) catch null;
    }

    fn pushSystemMessage(self: *OpencodeManager, message: ?[]const u8) void {
        if (message) |msg| {
            self.message_queue.push(.{ .system_message = msg });
        }
    }

    fn isMessageCompletionStatus(status: []const u8) bool {
        return std.mem.eql(u8, status, "completed") or
            std.mem.eql(u8, status, "complete") or
            std.mem.eql(u8, status, "done") or
            std.mem.eql(u8, status, "finished") or
            std.mem.eql(u8, status, "cancelled") or
            std.mem.eql(u8, status, "canceled") or
            std.mem.eql(u8, status, "interrupted");
    }

    fn isMessageInProgressStatus(status: []const u8) bool {
        return std.mem.eql(u8, status, "in_progress") or
            std.mem.eql(u8, status, "running") or
            std.mem.eql(u8, status, "started") or
            std.mem.eql(u8, status, "streaming");
    }

    fn isSessionIdleStatus(status: []const u8) bool {
        return std.mem.eql(u8, status, "idle") or
            std.mem.eql(u8, status, "ready");
    }

    fn isSessionBusyStatus(status: []const u8) bool {
        return std.mem.eql(u8, status, "busy") or
            std.mem.eql(u8, status, "working");
    }

    fn isStepFinishType(step_type: []const u8) bool {
        return std.mem.eql(u8, step_type, "step-finish") or
            std.mem.eql(u8, step_type, "step_finish");
    }

    fn isStepFinishReason(reason: []const u8) bool {
        return std.mem.eql(u8, reason, "stop") or
            std.mem.eql(u8, reason, "complete") or
            std.mem.eql(u8, reason, "completed") or
            std.mem.eql(u8, reason, "end_turn") or
            std.mem.eql(u8, reason, "cancelled") or
            std.mem.eql(u8, reason, "canceled") or
            std.mem.eql(u8, reason, "interrupted");
    }

    fn isTextPartType(part_type: []const u8) bool {
        return std.mem.eql(u8, part_type, "text");
    }

    fn partHasEndTime(part_obj: std.json.ObjectMap) bool {
        if (part_obj.get("time")) |time_val| {
            if (time_val == .object) {
                if (time_val.object.get("end")) |end_val| {
                    return switch (end_val) {
                        .integer, .float, .string => true,
                        else => false,
                    };
                }
            }
        }
        return false;
    }

    fn isMessageErrorStatus(status: []const u8) bool {
        return std.mem.eql(u8, status, "error") or
            std.mem.eql(u8, status, "failed");
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

    // Test system_message deinit
    const sys = try allocator.dupe(u8, "system");
    var event4 = Event{ .system_message = sys };
    event4.deinit(allocator);
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

test "opencode event: session_error after abort treated as cancelled" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.pending_abort = true;
    manager.pending_abort_since_ms = std.time.milliTimestamp();
    manager.abort_error_grace_until_ms = manager.pending_abort_since_ms + 3000;

    const data = "{\"payload\":{\"type\":\"session.error\",\"properties\":{}}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .status_change => |status| try std.testing.expectEqual(Status.session_active, status),
        else => try std.testing.expect(false),
    }

    try std.testing.expect(!manager.pending_abort);
}

test "opencode event: session_error without abort yields error" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    const data = "{\"payload\":{\"type\":\"session.error\",\"properties\":{}}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .err => |err_info| try std.testing.expectEqual(Event.EventError.ErrorCode.session_error, err_info.code),
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .status_change => |status| try std.testing.expectEqual(Status.failed, status),
        else => try std.testing.expect(false),
    }
}

test "opencode event: session.updated idle clears abort" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.pending_abort = true;
    manager.pending_abort_since_ms = std.time.milliTimestamp();
    manager.abort_error_grace_until_ms = manager.pending_abort_since_ms + 3000;

    const data = "{\"payload\":{\"type\":\"session.updated\",\"properties\":{\"session\":{\"status\":\"idle\"}}}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .status_change => |status| try std.testing.expectEqual(Status.session_active, status),
        else => try std.testing.expect(false),
    }

    try std.testing.expect(!manager.pending_abort);
}

test "opencode event: top-level session.idle clears status" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    const data = "{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_123\"}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .status_change => |status| try std.testing.expectEqual(Status.session_active, status),
        else => try std.testing.expect(false),
    }
}

test "opencode event: message.updated completion clears status" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    const data = "{\"payload\":{\"type\":\"message.updated\",\"properties\":{\"message\":{\"status\":\"completed\"}}}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .status_change => |status| try std.testing.expectEqual(Status.session_active, status),
        else => try std.testing.expect(false),
    }
}

test "opencode event: permission.asked emits system message and clears status" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    const data = "{\"payload\":{\"type\":\"permission.asked\",\"properties\":{\"prompt\":\"Allow access?\"}}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .system_message => |msg| {
            try std.testing.expect(std.mem.indexOf(u8, msg, "Permission requested") != null);
        },
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }

    const ev3_opt = manager.poll();
    try std.testing.expect(ev3_opt != null);
    var ev3 = ev3_opt.?;
    defer ev3.deinit(manager.event_allocator);
    switch (ev3) {
        .status_change => |status| try std.testing.expectEqual(Status.session_active, status),
        else => try std.testing.expect(false),
    }
}

test "opencode event: session.status idle clears status" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    const data = "{\"payload\":{\"type\":\"session.status\",\"properties\":{\"status\":{\"type\":\"idle\"}}}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .status_change => |status| try std.testing.expectEqual(Status.session_active, status),
        else => try std.testing.expect(false),
    }
}

test "opencode event: step-finish with terminal reason pushes message_complete" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    const data = "{\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"type\":\"step-finish\",\"reason\":\"stop\"}}}}";
    manager.processEventData(data);

    // step-finish with a terminal reason ("stop", "end_turn", etc.) pushes
    // message_complete so the UI stops showing "Generating..." immediately
    // rather than waiting 10-20s for session.idle.
    const ev_opt = manager.poll();
    try std.testing.expect(ev_opt != null);
    switch (ev_opt.?) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }
    // status is NOT changed by processEventData (main thread handles that)
    try std.testing.expectEqual(Status.prompting, manager.status);

    // No further events
    try std.testing.expect(manager.poll() == null);
}

test "opencode event: step-finish without terminal reason does not push events" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    // step-finish with a non-terminal reason (e.g., tool_use) should NOT
    // push message_complete — the agent will continue with tool calls.
    const data = "{\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"type\":\"step-finish\",\"reason\":\"tool_use\"}}}}";
    manager.processEventData(data);

    const ev_opt = manager.poll();
    try std.testing.expect(ev_opt == null);
    try std.testing.expectEqual(Status.prompting, manager.status);
}

test "opencode event: text part end does not clear status (intermediate event)" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    const data = "{\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"type\":\"text\",\"time\":{\"start\":123,\"end\":456}}}}}";
    manager.processEventData(data);

    // text part end is an intermediate event; the response may continue
    // with tool calls and more text. Only session.idle should clear state.
    const ev_opt = manager.poll();
    try std.testing.expect(ev_opt == null);
    try std.testing.expectEqual(Status.prompting, manager.status);
}

test "opencode event: message.updated finish clears status" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.status = .prompting;

    const data = "{\"payload\":{\"type\":\"message.updated\",\"properties\":{\"info\":{\"role\":\"assistant\",\"finish\":\"stop\"}}}}";
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }

    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);
    switch (ev2) {
        .status_change => |status| try std.testing.expectEqual(Status.session_active, status),
        else => try std.testing.expect(false),
    }
}

test "commands_update event round-trips through message queue" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Simulate what fetchAvailableCommands does: build commands and push to queue
    const name = try manager.event_allocator.dupe(u8, "status");
    errdefer manager.event_allocator.free(name);
    const desc = try manager.event_allocator.dupe(u8, "Show status");
    errdefer manager.event_allocator.free(desc);

    const commands = try manager.event_allocator.alloc(AvailableCommand, 1);
    errdefer manager.event_allocator.free(commands);
    commands[0] = .{ .name = name, .description = desc, .input = null };

    manager.message_queue.push(.{ .commands_update = commands });

    const ev_opt = manager.poll();
    try std.testing.expect(ev_opt != null);
    var ev = ev_opt.?;
    defer ev.deinit(manager.event_allocator);

    switch (ev) {
        .commands_update => |cmds| {
            try std.testing.expectEqual(@as(usize, 1), cmds.len);
            try std.testing.expectEqualStrings("status", cmds[0].name);
            try std.testing.expectEqualStrings("Show status", cmds[0].description);
            try std.testing.expect(cmds[0].input == null);
        },
        else => try std.testing.expect(false),
    }
}

test "opencode event: task tool part populates subagent info on tool_call" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"type":"tool","callID":"task:0","tool":"task",
        \\"state":{"status":"running",
        \\"input":{"description":"Explore architecture","subagent_type":"explore"},
        \\"title":"Explore architecture",
        \\"metadata":{"sessionId":"ses_abc123","summary":[
        \\{"id":"prt_1","tool":"read","state":{"status":"completed","title":"build.zig"}},
        \\{"id":"prt_2","tool":"bash","state":{"status":"completed","title":"List files"}}
        \\]}}}}}}
    ;
    manager.processEventData(data);

    // Should get a tool_call event with subagent info
    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);

    switch (ev1) {
        .tool_call => |tc| {
            try std.testing.expect(tc.subagent_info != null);
            const info = tc.subagent_info.?;
            try std.testing.expectEqualStrings("Explore architecture", info.description.?);
            try std.testing.expectEqualStrings("explore", info.agent_type.?);
            try std.testing.expectEqualStrings("ses_abc123", info.session_id.?);
            try std.testing.expectEqualStrings("Explore architecture", info.title.?);
            try std.testing.expectEqual(@as(usize, 2), info.tool_count);
            try std.testing.expectEqual(@as(usize, 2), info.summary.len);
            try std.testing.expectEqualStrings("read", info.summary[0].tool_name);
            try std.testing.expectEqualStrings("build.zig", info.summary[0].title.?);
            try std.testing.expectEqualStrings("bash", info.summary[1].tool_name);
            try std.testing.expectEqualStrings("List files", info.summary[1].title.?);
        },
        else => try std.testing.expect(false),
    }
}

test "opencode event: task tool part populates subagent info on tool_update" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"type":"tool","callID":"task:0","tool":"task",
        \\"state":{"status":"running",
        \\"input":{"description":"Run tests","subagent_type":"general-purpose"},
        \\"title":"Run tests",
        \\"metadata":{"sessionId":"ses_xyz"}}}}}}
    ;
    manager.processEventData(data);

    // Drain tool_call first
    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);

    // tool_update should also have subagent info
    const ev2_opt = manager.poll();
    try std.testing.expect(ev2_opt != null);
    var ev2 = ev2_opt.?;
    defer ev2.deinit(manager.event_allocator);

    switch (ev2) {
        .tool_update => |tu| {
            try std.testing.expect(tu.subagent_info != null);
            const info = tu.subagent_info.?;
            try std.testing.expectEqualStrings("Run tests", info.description.?);
            try std.testing.expectEqualStrings("general-purpose", info.agent_type.?);
            try std.testing.expectEqualStrings("ses_xyz", info.session_id.?);
        },
        else => try std.testing.expect(false),
    }
}

test "opencode event: non-task tool has no subagent info" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"type":"tool","callID":"bash:0","tool":"bash",
        \\"state":{"status":"running","title":"echo hello"}}}}}
    ;
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);

    switch (ev1) {
        .tool_call => |tc| {
            try std.testing.expect(tc.subagent_info == null);
        },
        else => try std.testing.expect(false),
    }
}

test "opencode event: task tool with missing metadata has partial subagent info" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Task tool with no metadata section
    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"type":"tool","callID":"task:0","tool":"task",
        \\"state":{"status":"running",
        \\"input":{"description":"Explore"},
        \\"title":"Explore"}}}}}
    ;
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);

    switch (ev1) {
        .tool_call => |tc| {
            try std.testing.expect(tc.subagent_info != null);
            const info = tc.subagent_info.?;
            try std.testing.expectEqualStrings("Explore", info.description.?);
            try std.testing.expectEqualStrings("Explore", info.title.?);
            try std.testing.expect(info.session_id == null);
            try std.testing.expectEqual(@as(usize, 0), info.tool_count);
            try std.testing.expectEqual(@as(usize, 0), info.summary.len);
        },
        else => try std.testing.expect(false),
    }
}

test "opencode event: task tool with empty summary array" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"type":"tool","callID":"task:0","tool":"task",
        \\"state":{"status":"running",
        \\"input":{"description":"Build"},
        \\"title":"Build",
        \\"metadata":{"sessionId":"ses_empty","summary":[]}}}}}}
    ;
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);

    switch (ev1) {
        .tool_call => |tc| {
            try std.testing.expect(tc.subagent_info != null);
            const info = tc.subagent_info.?;
            try std.testing.expectEqualStrings("Build", info.description.?);
            try std.testing.expectEqual(@as(usize, 0), info.tool_count);
            try std.testing.expectEqual(@as(usize, 0), info.summary.len);
        },
        else => try std.testing.expect(false),
    }
}

test "opencode event: task tool with missing input" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Task tool with no input section at all
    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"type":"tool","callID":"task:0","tool":"task",
        \\"state":{"status":"running","title":"Some task"}}}}}
    ;
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);

    switch (ev1) {
        .tool_call => |tc| {
            try std.testing.expect(tc.subagent_info != null);
            const info = tc.subagent_info.?;
            try std.testing.expect(info.description == null);
            try std.testing.expect(info.agent_type == null);
            try std.testing.expectEqualStrings("Some task", info.title.?);
        },
        else => try std.testing.expect(false),
    }
}

test "SubagentEventInfo deinit frees all fields" {
    const allocator = std.testing.allocator;

    var summaries = try allocator.alloc(Event.SubagentToolSummary, 1);
    summaries[0] = .{
        .tool_name = try allocator.dupe(u8, "read"),
        .title = try allocator.dupe(u8, "file.zig"),
    };

    var info: Event.SubagentEventInfo = .{
        .description = try allocator.dupe(u8, "test"),
        .agent_type = try allocator.dupe(u8, "explore"),
        .session_id = try allocator.dupe(u8, "ses_123"),
        .title = try allocator.dupe(u8, "test title"),
        .tool_count = 1,
        .summary = summaries,
    };
    info.deinit(allocator);
}

test "SubagentEventInfo deinit with null fields" {
    const allocator = std.testing.allocator;
    var info: Event.SubagentEventInfo = .{};
    info.deinit(allocator);
}

test "opencode event: child session message.part.updated is filtered" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    // Set parent session ID
    manager.session_id = try allocator.dupe(u8, "ses_parent_123");

    // Send a text event from a child session (different sessionID in part)
    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_child_456","messageID":"msg_1","type":"text",
        \\"text":"Hello from child"}}}}
    ;
    manager.processEventData(data);

    // No events should be in the queue — child events are filtered
    try std.testing.expect(manager.poll() == null);
}

test "opencode event: child session step-finish is filtered (no premature message_complete)" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");
    manager.status = .prompting;

    // step-finish from child session should NOT trigger message_complete
    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_child_456","type":"step-finish","reason":"stop"}}}}
    ;
    manager.processEventData(data);

    try std.testing.expect(manager.poll() == null);
    try std.testing.expectEqual(Status.prompting, manager.status);
}

test "opencode event: child session.idle is filtered" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");
    manager.status = .prompting;

    // session.idle from child session should NOT clear prompting state
    const data =
        \\{"type":"session.idle","properties":{"sessionID":"ses_child_456"}}
    ;
    manager.processEventData(data);

    try std.testing.expect(manager.poll() == null);
    try std.testing.expectEqual(Status.prompting, manager.status);
}

test "opencode event: parent session events still processed normally" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");
    manager.status = .prompting;

    // session.idle from parent session should still work
    const data =
        \\{"type":"session.idle","properties":{"sessionID":"ses_parent_123"}}
    ;
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }
}

test "opencode event: child tool count tracking" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");

    // Send multiple pending tool events from a child session
    const data1 =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_child_789","messageID":"msg_1","type":"tool",
        \\"callID":"call_1","tool":"glob","state":{"status":"pending"}}}}}
    ;
    const data2 =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_child_789","messageID":"msg_1","type":"tool",
        \\"callID":"call_2","tool":"read","state":{"status":"pending"}}}}}
    ;
    const data3 =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_child_789","messageID":"msg_1","type":"tool",
        \\"callID":"call_3","tool":"bash","state":{"status":"pending"}}}}}
    ;

    manager.processEventData(data1);
    manager.processEventData(data2);
    manager.processEventData(data3);

    // No events should be in the queue (child events filtered)
    try std.testing.expect(manager.poll() == null);

    // But child_tool_counts should have tracked them
    try std.testing.expectEqual(@as(usize, 3), manager.child_tool_counts.get("ses_child_789").?);
}

test "opencode event: child running tool status not counted (only pending)" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");

    // Send a pending tool event
    const data_pending =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_child_789","messageID":"msg_1","type":"tool",
        \\"callID":"call_1","tool":"glob","state":{"status":"pending"}}}}}
    ;
    // Send a running tool event (same tool call, status update — should not increment)
    const data_running =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_child_789","messageID":"msg_1","type":"tool",
        \\"callID":"call_1","tool":"glob","state":{"status":"running"}}}}}
    ;

    manager.processEventData(data_pending);
    manager.processEventData(data_running);

    // Only the pending event should have been counted
    try std.testing.expectEqual(@as(usize, 1), manager.child_tool_counts.get("ses_child_789").?);
}

test "opencode event: tool_count populated from tracked counts when no summary" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");

    // Pre-populate child tool counts (as if we tracked 5 tool calls)
    const key = try allocator.dupe(u8, "ses_child_789");
    try manager.child_tool_counts.put(allocator, key, 5);
    _ = manager.active_child_count.fetchAdd(1, .release);

    // Send a task tool event from parent session with metadata.sessionId but no summary
    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_parent_123",
        \\"type":"tool","callID":"task:0","tool":"task",
        \\"state":{"status":"running",
        \\"input":{"description":"Explore code"},
        \\"title":"Explore code",
        \\"metadata":{"sessionId":"ses_child_789"}}}}}}
    ;
    manager.processEventData(data);

    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);

    switch (ev1) {
        .tool_call => |tc| {
            try std.testing.expect(tc.subagent_info != null);
            const info = tc.subagent_info.?;
            try std.testing.expectEqual(@as(usize, 5), info.tool_count);
        },
        else => try std.testing.expect(false),
    }
}

test "opencode event: child tool count cleanup on task completion" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");

    // Pre-populate child tool counts
    const key = try allocator.dupe(u8, "ses_child_789");
    try manager.child_tool_counts.put(allocator, key, 10);
    _ = manager.active_child_count.fetchAdd(1, .release);

    // Send a completed task tool event
    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_parent_123",
        \\"type":"tool","callID":"task:0","tool":"task",
        \\"state":{"status":"completed",
        \\"input":{"description":"Done"},
        \\"title":"Done",
        \\"metadata":{"sessionId":"ses_child_789","summary":[
        \\{"id":"prt_1","tool":"read","state":{"status":"completed","title":"file.zig"}}
        \\]}}}}}}
    ;
    manager.processEventData(data);

    // Drain events
    while (manager.poll()) |*ev| {
        var e = ev.*;
        e.deinit(manager.event_allocator);
    }

    // child_tool_counts should have been cleaned up
    try std.testing.expect(manager.child_tool_counts.get("ses_child_789") == null);
}

test "opencode event: parent session.idle suppressed while subagents active" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");
    manager.status = .prompting;

    // Simulate active child session
    const key = try allocator.dupe(u8, "ses_child_789");
    try manager.child_tool_counts.put(allocator, key, 3);
    _ = manager.active_child_count.fetchAdd(1, .release);

    // Parent session.idle should be suppressed (subagent still running)
    const data =
        \\{"type":"session.idle","properties":{"sessionID":"ses_parent_123"}}
    ;
    manager.processEventData(data);

    // No events — idle was suppressed
    try std.testing.expect(manager.poll() == null);
    try std.testing.expectEqual(Status.prompting, manager.status);
}

test "opencode event: parent session.status idle suppressed while subagents active" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");
    manager.status = .prompting;

    // Simulate active child session
    const key = try allocator.dupe(u8, "ses_child_789");
    try manager.child_tool_counts.put(allocator, key, 3);
    _ = manager.active_child_count.fetchAdd(1, .release);

    // Parent session.status idle should be suppressed
    const data =
        \\{"payload":{"type":"session.status","properties":{"sessionID":"ses_parent_123","status":{"type":"idle"}}}}
    ;
    manager.processEventData(data);

    // No events
    try std.testing.expect(manager.poll() == null);
    try std.testing.expectEqual(Status.prompting, manager.status);
}

test "opencode event: parent step-finish stop suppressed while subagents active" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");
    manager.status = .prompting;

    // Simulate active child session
    const key = try allocator.dupe(u8, "ses_child_789");
    try manager.child_tool_counts.put(allocator, key, 3);
    _ = manager.active_child_count.fetchAdd(1, .release);

    // Parent step-finish with "stop" should NOT push message_complete
    const data =
        \\{"payload":{"type":"message.part.updated","properties":{"part":{
        \\"sessionID":"ses_parent_123","type":"step-finish","reason":"stop"}}}}
    ;
    manager.processEventData(data);

    // No message_complete in queue
    try std.testing.expect(manager.poll() == null);
    try std.testing.expectEqual(Status.prompting, manager.status);
}

test "opencode event: message.updated completion still works during subagent (final signal)" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    manager.session_id = try allocator.dupe(u8, "ses_parent_123");
    manager.status = .prompting;

    // message.updated with finish/completed should NOT be suppressed — it's the
    // definitive completion signal that fires after all tools (including Task) finish
    const data =
        \\{"payload":{"type":"message.updated","properties":{"info":{
        \\"id":"msg_1","sessionID":"ses_parent_123","role":"assistant",
        \\"finish":"stop","time":{"created":123,"completed":456}}}}}
    ;
    manager.processEventData(data);

    // Should have pushed message_complete
    const ev1_opt = manager.poll();
    try std.testing.expect(ev1_opt != null);
    var ev1 = ev1_opt.?;
    defer ev1.deinit(manager.event_allocator);
    switch (ev1) {
        .message_complete => {},
        else => try std.testing.expect(false),
    }
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
