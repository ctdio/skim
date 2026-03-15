const std = @import("std");

// =============================================================================
// Enums
// =============================================================================

pub const TurnStatus = enum {
    in_progress,
    completed,
    interrupted,
    failed,

    pub fn fromString(s: []const u8) ?TurnStatus {
        const map = std.StaticStringMap(TurnStatus).initComptime(.{
            .{ "in_progress", .in_progress },
            .{ "completed", .completed },
            .{ "interrupted", .interrupted },
            .{ "failed", .failed },
        });
        return map.get(s);
    }
};

pub const CommandExecutionStatus = enum {
    pending,
    running,
    completed,
    failed,

    pub fn fromString(s: []const u8) ?CommandExecutionStatus {
        const map = std.StaticStringMap(CommandExecutionStatus).initComptime(.{
            .{ "pending", .pending },
            .{ "running", .running },
            .{ "completed", .completed },
            .{ "failed", .failed },
        });
        return map.get(s);
    }
};

pub const ReasoningEffort = enum {
    low,
    medium,
    high,
    xhigh,

    pub fn fromString(s: []const u8) ?ReasoningEffort {
        const map = std.StaticStringMap(ReasoningEffort).initComptime(.{
            .{ "low", .low },
            .{ "medium", .medium },
            .{ "high", .high },
            .{ "xhigh", .xhigh },
        });
        return map.get(s);
    }

    pub fn toString(self: ReasoningEffort) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
    }
};

pub const ServiceTier = enum {
    fast,
    flex,

    pub fn fromString(s: []const u8) ?ServiceTier {
        const map = std.StaticStringMap(ServiceTier).initComptime(.{
            .{ "fast", .fast },
            .{ "flex", .flex },
        });
        return map.get(s);
    }

    pub fn toString(self: ServiceTier) []const u8 {
        return switch (self) {
            .fast => "fast",
            .flex => "flex",
        };
    }
};

pub const CollaborationMode = enum {
    default,
    plan,

    pub fn fromString(s: []const u8) ?CollaborationMode {
        const map = std.StaticStringMap(CollaborationMode).initComptime(.{
            .{ "default", .default },
            .{ "plan", .plan },
        });
        return map.get(s);
    }

    pub fn toString(self: CollaborationMode) []const u8 {
        return switch (self) {
            .default => "default",
            .plan => "plan",
        };
    }

    pub fn displayName(self: CollaborationMode) []const u8 {
        return switch (self) {
            .default => "Code",
            .plan => "Plan",
        };
    }
};

pub const ApprovalPolicy = enum {
    never,
    unless_trusted,
    always,
    on_request,

    pub fn fromString(s: []const u8) ?ApprovalPolicy {
        const map = std.StaticStringMap(ApprovalPolicy).initComptime(.{
            .{ "never", .never },
            .{ "unless-trusted", .unless_trusted },
            .{ "always", .always },
            .{ "on-request", .on_request },
        });
        return map.get(s);
    }

    pub fn toString(self: ApprovalPolicy) []const u8 {
        return switch (self) {
            .never => "never",
            .unless_trusted => "unless-trusted",
            .always => "always",
            .on_request => "on-request",
        };
    }
};

pub const CommandApprovalDecision = enum {
    accept,
    accept_for_session,
    accept_with_execpolicy_amendment,
    decline,
    cancel,

    pub fn fromString(s: []const u8) ?CommandApprovalDecision {
        const map = std.StaticStringMap(CommandApprovalDecision).initComptime(.{
            .{ "accept", .accept },
            .{ "acceptForSession", .accept_for_session },
            .{ "accept_for_session", .accept_for_session },
            .{ "acceptWithExecpolicyAmendment", .accept_with_execpolicy_amendment },
            .{ "accept_with_execpolicy_amendment", .accept_with_execpolicy_amendment },
            .{ "decline", .decline },
            .{ "cancel", .cancel },
        });
        return map.get(s);
    }

    pub fn toString(self: CommandApprovalDecision) []const u8 {
        return switch (self) {
            .accept => "accept",
            .accept_for_session => "acceptForSession",
            .accept_with_execpolicy_amendment => "acceptWithExecpolicyAmendment",
            .decline => "decline",
            .cancel => "cancel",
        };
    }
};

pub const FileChangeApprovalDecision = enum {
    accept,
    accept_for_session,
    decline,
    cancel,

    pub fn fromString(s: []const u8) ?FileChangeApprovalDecision {
        const map = std.StaticStringMap(FileChangeApprovalDecision).initComptime(.{
            .{ "accept", .accept },
            .{ "acceptForSession", .accept_for_session },
            .{ "accept_for_session", .accept_for_session },
            .{ "decline", .decline },
            .{ "cancel", .cancel },
        });
        return map.get(s);
    }

    pub fn toString(self: FileChangeApprovalDecision) []const u8 {
        return switch (self) {
            .accept => "accept",
            .accept_for_session => "acceptForSession",
            .decline => "decline",
            .cancel => "cancel",
        };
    }
};

// =============================================================================
// Thread / Turn Types
// =============================================================================

pub const GitInfo = struct {
    sha: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    origin_url: ?[]const u8 = null,
};

pub const Thread = struct {
    id: []const u8,
    preview: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    created_at: ?i64 = null,
    updated_at: ?i64 = null,
    path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    cli_version: ?[]const u8 = null,
    source: ?[]const u8 = null,
    git_info: ?GitInfo = null,
    turns: ?[]Turn = null,
};

pub const TurnError = struct {
    message: []const u8,
    code: ?[]const u8 = null,
};

pub const Turn = struct {
    id: []const u8,
    status: ?TurnStatus = null,
    items: ?[]Item = null,
    @"error": ?TurnError = null,
};

// =============================================================================
// Item Types
// =============================================================================

pub const TextContent = struct {
    text: []const u8,
};

pub const UserMessageItem = struct {
    id: []const u8,
    content: ?[]TextContent = null,
};

pub const AgentMessageItem = struct {
    id: []const u8,
    text: []const u8,
};

pub const ReasoningItem = struct {
    id: []const u8,
    summary: [][]const u8,
    content: [][]const u8,
};

pub const CommandExecutionItem = struct {
    id: []const u8,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    exit_code: ?i32 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    status: CommandExecutionStatus = .pending,
};

pub const FileChangeItem = struct {
    id: []const u8,
    path: ?[]const u8 = null,
    diff: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const McpToolCallItem = struct {
    id: []const u8,
    server_name: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const FunctionCallItem = struct {
    id: []const u8,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const Item = union(enum) {
    user_message: UserMessageItem,
    agent_message: AgentMessageItem,
    reasoning: ReasoningItem,
    command_execution: CommandExecutionItem,
    file_change: FileChangeItem,
    mcp_tool_call: McpToolCallItem,
    function_call: FunctionCallItem,
    unknown: void,
};

// =============================================================================
// Input Types
// =============================================================================

pub const TextInput = struct {
    text: []const u8,
};

pub const ImageInput = struct {
    url: ?[]const u8 = null,
    data: ?[]const u8 = null,
    media_type: ?[]const u8 = null,
};

pub const InputItem = union(enum) {
    text: TextInput,
    image: ImageInput,
};

// =============================================================================
// Request / Response Types
// =============================================================================

pub const InitializeParams = struct {
    client_name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    client_version: ?[]const u8 = null,
    experimental_api: bool = false,
};

pub const InitializeResult = struct {
    user_agent: ?[]const u8 = null,
};

pub const ThreadStartParams = struct {
    model: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    approval_policy: ?ApprovalPolicy = null,
    reasoning_effort: ?ReasoningEffort = null,
    service_tier: ?ServiceTier = null,
    input: ?[]InputItem = null,
};

pub const ThreadStartResult = struct {
    thread: Thread,
    model: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    approval_policy: ?ApprovalPolicy = null,
    sandbox: ?SandboxPolicy = null,
    reasoning_effort: ?ReasoningEffort = null,
    service_tier: ?ServiceTier = null,
};

pub const ThreadResumeParams = struct {
    thread_id: []const u8,
    cwd: ?[]const u8 = null,
};

pub const ThreadResumeResult = struct {
    thread: Thread,
    model: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
};

pub const ThreadForkParams = struct {
    thread_id: []const u8,
    turn_id: ?[]const u8 = null,
};

pub const ThreadForkResult = struct {
    thread: Thread,
};

pub const ThreadListParams = struct {
    status: ?[]const u8 = null,
    limit: ?u32 = null,
};

pub const ThreadListResult = struct {
    data: []Thread,
};

pub const TurnStartParams = struct {
    thread_id: []const u8,
    reasoning_effort: ?ReasoningEffort = null,
    service_tier: ?ServiceTier = null,
    collaboration_mode: ?CollaborationMode = null,
    input: ?[]InputItem = null,
};

pub const TurnSteerParams = struct {
    thread_id: []const u8,
    turn_id: []const u8,
    input: []InputItem,
};

// =============================================================================
// Model Types
// =============================================================================

pub const ModelInfo = struct {
    id: []const u8,
    model: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    supported_reasoning_efforts: ?[]ReasoningEffort = null,
    default_reasoning_effort: ?ReasoningEffort = null,
    is_default: bool = false,
    supports_personality: bool = false,
};

pub const ModelListResult = struct {
    data: []ModelInfo,
};

// =============================================================================
// Policy Types
// =============================================================================

pub const SandboxPolicy = struct {
    type: ?[]const u8 = null,
    writable_roots: ?[]const []const u8 = null,
    network_access: bool = false,
};

// =============================================================================
// Approval Types
// =============================================================================

pub const ExecpolicyAmendment = struct {
    execpolicy_amendment: []const []const u8,
};

pub const CommandApprovalParams = struct {
    thread_id: []const u8,
    turn_id: ?[]const u8 = null,
    command: []const u8,
    cwd: ?[]const u8 = null,
    item_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const FileChangeApprovalParams = struct {
    thread_id: []const u8,
    turn_id: ?[]const u8 = null,
    path: []const u8,
    item_id: ?[]const u8 = null,
};

pub const UserInputOption = struct {
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const UserInputQuestion = struct {
    id: []const u8,
    header: ?[]const u8 = null,
    question: []const u8,
    options: ?[]UserInputOption = null,
    is_other: bool = false,
    is_secret: bool = false,
};

pub const UserInputParams = struct {
    thread_id: []const u8,
    turn_id: ?[]const u8 = null,
    questions: []UserInputQuestion,
};

// =============================================================================
// Metrics Types
// =============================================================================

pub const TokenCounts = struct {
    total_tokens: u64 = 0,
    input_tokens: u64 = 0,
    cached_input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    reasoning_output_tokens: u64 = 0,
};

pub const TokenUsage = struct {
    total: ?TokenCounts = null,
    last: ?TokenCounts = null,
    model_context_window: ?u64 = null,
};

pub const RateLimitEntry = struct {
    used_percent: f64 = 0,
    credits: ?f64 = null,
};

pub const RateLimits = struct {
    primary: RateLimitEntry,
    secondary: RateLimitEntry,
};

// =============================================================================
// Error Type
// =============================================================================

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?[]const u8 = null,
};

// =============================================================================
// Notification Params
// =============================================================================

pub const ItemStartedParams = struct {
    thread_id: []const u8,
    turn_id: []const u8,
    item: Item,
};
