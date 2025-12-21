const std = @import("std");

// =============================================================================
// ACP Protocol Constants
// =============================================================================

/// Current ACP protocol version (major version only per spec)
pub const PROTOCOL_VERSION: u32 = 1;

// =============================================================================
// Core Type Aliases
// =============================================================================

/// Session identifier returned by agent
pub const SessionId = []const u8;

/// Tool call identifier (unique within session)
pub const ToolCallId = []const u8;

// =============================================================================
// Enums
// =============================================================================

/// Stop reasons for prompt completion
pub const StopReason = enum {
    end_turn,
    max_tokens,
    max_turn_requests,
    refusal,
    cancelled,

    pub fn fromString(s: []const u8) ?StopReason {
        const map = std.StaticStringMap(StopReason).initComptime(.{
            .{ "end_turn", .end_turn },
            .{ "max_tokens", .max_tokens },
            .{ "max_turn_requests", .max_turn_requests },
            .{ "refusal", .refusal },
            .{ "cancelled", .cancelled },
        });
        return map.get(s);
    }

    pub fn toString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_tokens => "max_tokens",
            .max_turn_requests => "max_turn_requests",
            .refusal => "refusal",
            .cancelled => "cancelled",
        };
    }
};

/// Tool call execution status
pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,

    pub fn fromString(s: []const u8) ?ToolCallStatus {
        const map = std.StaticStringMap(ToolCallStatus).initComptime(.{
            .{ "pending", .pending },
            .{ "in_progress", .in_progress },
            .{ "completed", .completed },
            .{ "failed", .failed },
        });
        return map.get(s);
    }

    pub fn toString(self: ToolCallStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

/// Tool call categories
pub const ToolCallKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn fromString(s: []const u8) ToolCallKind {
        const map = std.StaticStringMap(ToolCallKind).initComptime(.{
            .{ "read", .read },
            .{ "edit", .edit },
            .{ "delete", .delete },
            .{ "move", .move },
            .{ "search", .search },
            .{ "execute", .execute },
            .{ "think", .think },
            .{ "fetch", .fetch },
            .{ "other", .other },
        });
        return map.get(s) orelse .other;
    }

    pub fn toString(self: ToolCallKind) []const u8 {
        return switch (self) {
            .read => "read",
            .edit => "edit",
            .delete => "delete",
            .move => "move",
            .search => "search",
            .execute => "execute",
            .think => "think",
            .fetch => "fetch",
            .other => "other",
        };
    }
};

/// Permission option kinds
pub const PermissionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,

    pub fn fromString(s: []const u8) ?PermissionKind {
        const map = std.StaticStringMap(PermissionKind).initComptime(.{
            .{ "allow_once", .allow_once },
            .{ "allow_always", .allow_always },
            .{ "reject_once", .reject_once },
            .{ "reject_always", .reject_always },
        });
        return map.get(s);
    }

    pub fn toString(self: PermissionKind) []const u8 {
        return switch (self) {
            .allow_once => "allow_once",
            .allow_always => "allow_always",
            .reject_once => "reject_once",
            .reject_always => "reject_always",
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "StopReason.fromString" {
    try std.testing.expectEqual(StopReason.end_turn, StopReason.fromString("end_turn").?);
    try std.testing.expectEqual(StopReason.cancelled, StopReason.fromString("cancelled").?);
    try std.testing.expectEqual(@as(?StopReason, null), StopReason.fromString("unknown"));
}

test "ToolCallStatus.fromString" {
    try std.testing.expectEqual(ToolCallStatus.pending, ToolCallStatus.fromString("pending").?);
    try std.testing.expectEqual(ToolCallStatus.completed, ToolCallStatus.fromString("completed").?);
    try std.testing.expectEqual(@as(?ToolCallStatus, null), ToolCallStatus.fromString("unknown"));
}

test "ToolCallKind.fromString with unknown" {
    try std.testing.expectEqual(ToolCallKind.read, ToolCallKind.fromString("read"));
    try std.testing.expectEqual(ToolCallKind.other, ToolCallKind.fromString("unknown_kind"));
}

test "PermissionKind roundtrip" {
    const kind = PermissionKind.allow_once;
    const str = kind.toString();
    try std.testing.expectEqual(kind, PermissionKind.fromString(str).?);
}
