/// Tagged union wrapping both ACP and OpenCode manager types.
/// Provides a unified interface for operations needed by agent_mode.zig and tab_manager.zig.
/// Protocol-specific features remain accessible via pattern matching on the union.
const std = @import("std");
const AcpManager = @import("../acp/manager.zig").AcpManager;
const OpencodeManager = @import("../opencode/opencode.zig").OpencodeManager;
const OwnedModelInfo = @import("../acp/manager.zig").AcpManager.OwnedModelInfo;

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

    /// Get available models for the model picker.
    /// Note: ACP and OpenCode use different OwnedModelInfo types with the same layout.
    /// Returns as a generic slice for the model picker UI.
    pub fn getAvailableModelsAcp(self: ManagerHandle) ?[]const OwnedModelInfo {
        return switch (self) {
            .acp => |m| m.getAvailableModels(),
            .opencode => null,
        };
    }

    /// Set model by ID (from picker selection).
    pub fn setModelById(self: ManagerHandle, id: []const u8) !void {
        switch (self) {
            .acp => |m| try m.setModel(id),
            .opencode => |m| try m.setModelById(id),
        }
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
