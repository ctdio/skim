const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Agent Types
// =============================================================================

/// Supported agent types for session discovery
pub const AgentType = enum {
    claude_code,
    codex,

    pub fn displayName(self: AgentType) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .codex => "Codex",
        };
    }
};

// =============================================================================
// Session Info
// =============================================================================

/// Information about a discoverable session
pub const SessionInfo = struct {
    allocator: Allocator,

    /// Unique session identifier
    id: []const u8,

    /// Which agent this session belongs to
    agent_type: AgentType,

    /// Project path where session was created
    project_path: []const u8,

    /// First prompt or summary text for display
    display: []const u8,

    /// Session timestamp in Unix milliseconds (last activity)
    timestamp: i64,

    /// Number of messages in the session
    message_count: usize = 0,

    /// Git branch (optional, mainly for Codex)
    branch: ?[]const u8 = null,

    pub fn deinit(self: *SessionInfo) void {
        self.allocator.free(self.id);
        self.allocator.free(self.project_path);
        self.allocator.free(self.display);
        if (self.branch) |b| self.allocator.free(b);
    }

    /// Format timestamp as relative time (e.g., "2 hours ago", "yesterday")
    pub fn formatRelativeTime(self: SessionInfo, buf: []u8) []const u8 {
        const now_ms = std.time.milliTimestamp();
        const diff_ms = now_ms - self.timestamp;
        const diff_secs = @divFloor(diff_ms, 1000);
        const diff_mins = @divFloor(diff_secs, 60);
        const diff_hours = @divFloor(diff_mins, 60);
        const diff_days = @divFloor(diff_hours, 24);

        if (diff_mins < 1) {
            return "just now";
        } else if (diff_mins < 60) {
            return std.fmt.bufPrint(buf, "{d} min ago", .{diff_mins}) catch "recently";
        } else if (diff_hours < 24) {
            return std.fmt.bufPrint(buf, "{d}h ago", .{diff_hours}) catch "today";
        } else if (diff_days == 1) {
            return "yesterday";
        } else if (diff_days < 7) {
            return std.fmt.bufPrint(buf, "{d} days ago", .{diff_days}) catch "this week";
        } else {
            // Format as date
            const epoch_secs: i64 = @divFloor(self.timestamp, 1000);
            const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(epoch_secs, 86400)) };
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const month_names = [_][]const u8{
                "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            };
            const month_idx = @intFromEnum(month_day.month) - 1;
            const month_name = if (month_idx < 12) month_names[month_idx] else "???";
            return std.fmt.bufPrint(buf, "{s} {d}", .{ month_name, month_day.day_index + 1 }) catch "older";
        }
    }

    /// Truncate display text for UI
    pub fn truncatedDisplay(self: SessionInfo, max_len: usize) []const u8 {
        if (self.display.len <= max_len) {
            return self.display;
        }
        return self.display[0..max_len];
    }
};

/// List of session info items with cleanup
pub const SessionList = struct {
    allocator: Allocator,
    items: []SessionInfo,

    pub fn deinit(self: *SessionList) void {
        for (self.items) |*item| {
            item.deinit();
        }
        self.allocator.free(self.items);
    }
};

// =============================================================================
// Errors
// =============================================================================

pub const SessionDiscoveryError = error{
    HomeDirectoryNotFound,
    SessionDirectoryNotFound,
    InvalidJsonFormat,
    OutOfMemory,
    IoError,
};

// =============================================================================
// Tests
// =============================================================================

test "AgentType displayName" {
    try std.testing.expectEqualStrings("Claude Code", AgentType.claude_code.displayName());
    try std.testing.expectEqualStrings("Codex", AgentType.codex.displayName());
}

test "SessionInfo formatRelativeTime" {
    const allocator = std.testing.allocator;

    var info = SessionInfo{
        .allocator = allocator,
        .id = "",
        .agent_type = .claude_code,
        .project_path = "",
        .display = "",
        .timestamp = std.time.milliTimestamp() - (2 * 60 * 60 * 1000), // 2 hours ago
    };

    var buf: [32]u8 = undefined;
    const result = info.formatRelativeTime(&buf);
    try std.testing.expectEqualStrings("2h ago", result);
}
