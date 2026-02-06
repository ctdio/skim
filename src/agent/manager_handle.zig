/// Tagged union wrapping both ACP and OpenCode manager types.
/// Provides a unified interface for operations needed by agent_mode.zig and tab_manager.zig.
/// Protocol-specific features remain accessible via pattern matching on the union.
const std = @import("std");
const AcpManager = @import("../acp/manager.zig").AcpManager;
const OpencodeManager = @import("../opencode/opencode.zig").OpencodeManager;
pub const ManagerHandle = union(enum) {
    acp: *AcpManager,
    opencode: *OpencodeManager,

    // =========================================================================
    // Common operations
    // =========================================================================

    /// Cancel the current prompt. Returns true if cancellation was sent.
    pub fn cancelPrompt(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.cancelPrompt(),
            .opencode => |m| m.cancelPrompt(),
        };
    }

    /// Check if the agent is currently thinking/prompting.
    pub fn isPrompting(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.isPrompting(),
            .opencode => |m| m.isThinking(),
        };
    }

    /// Check if the session is ready to accept prompts.
    pub fn isReady(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .session_active or m.status == .prompting,
            .opencode => |m| !m.pending_abort and m.isReadyForPrompt(),
        };
    }

    /// Check if the manager is disconnected.
    pub fn isDisconnected(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .disconnected,
            .opencode => |m| m.status == .disconnected,
        };
    }

    /// Check if the session is initializing (discovering, connecting, etc.).
    pub fn isInitializing(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .discovering or m.status == .connecting or m.status == .connected,
            .opencode => |m| m.pending_abort,
        };
    }

    /// Get the current model ID (for highlighting in model picker).
    pub fn getCurrentModelId(self: ManagerHandle) ?[]const u8 {
        return switch (self) {
            .acp => |m| m.getCurrentModelId(),
            .opencode => |m| m.getCurrentModelId(),
        };
    }

    /// Get the current model display name.
    pub fn getCurrentModelName(self: ManagerHandle) []const u8 {
        return switch (self) {
            .acp => |m| m.getCurrentModelName(),
            .opencode => |m| m.getCurrentModelName(),
        };
    }

    /// Resolved model view for the UI — protocol-independent.
    pub const ModelView = struct {
        model_id: []const u8,
        name: []const u8,
        description: []const u8,
    };

    /// Get the number of available models.
    pub fn getModelCount(self: ManagerHandle) usize {
        return switch (self) {
            .acp => |m| m.getAvailableModels().len,
            .opencode => |m| m.getAvailableModels().len,
        };
    }

    /// Get a resolved model view at the given index.
    pub fn getModelInfo(self: ManagerHandle, idx: usize) ModelView {
        return switch (self) {
            .acp => |m| {
                const model = m.getAvailableModels()[idx];
                return .{
                    .model_id = model.model_id,
                    .name = model.name orelse model.model_id,
                    .description = model.description orelse "",
                };
            },
            .opencode => |m| {
                const model = m.getAvailableModels()[idx];
                return .{
                    .model_id = model.model_id,
                    .name = model.name orelse model.model_id,
                    .description = model.description orelse "",
                };
            },
        };
    }

    /// Set model by ID (from picker selection).
    pub fn setModelById(self: ManagerHandle, id: []const u8) !void {
        switch (self) {
            .acp => |m| try m.setModel(id),
            .opencode => |m| try m.setModelById(id),
        }
    }

    /// Get the pending permission request, if any (ACP only).
    pub fn getPendingPermission(self: ManagerHandle) ?*AcpManager.PendingPermission {
        return switch (self) {
            .acp => |m| m.getPendingPermission(),
            .opencode => null,
        };
    }

    /// Get a display name for the agent/server.
    pub fn getDisplayName(self: ManagerHandle) []const u8 {
        return switch (self) {
            .acp => |m| m.server_name orelse m.agent_name orelse "Agent",
            .opencode => "Opencode",
        };
    }

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Deinitialize the manager.
    pub fn deinit(self: ManagerHandle) void {
        switch (self) {
            .acp => |m| m.deinit(),
            .opencode => |m| m.deinit(),
        }
    }

    /// Check if the manager can be safely destroyed (freed).
    pub fn canSafelyDestroy(self: ManagerHandle) bool {
        return switch (self) {
            .acp => true,
            .opencode => |m| m.canSafelyDestroy(),
        };
    }
};
