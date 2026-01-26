const std = @import("std");
const agent_helpers = @import("agent_test_helpers.zig");
const TestAgentStateBuilder = agent_helpers.TestAgentStateBuilder;
const ToolStatus = agent_helpers.ToolStatus;
const PlanEntry = agent_helpers.PlanEntry;
const PlanEntryPriority = agent_helpers.PlanEntryPriority;
const PlanEntryStatus = agent_helpers.PlanEntryStatus;

const Allocator = std.mem.Allocator;

// =============================================================================
// ACP Log Entry Types
// =============================================================================

/// JSON structure for plan entries in ACP logs (used during parsing)
const PlanEntryJson = struct {
    content: []const u8,
    priority: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

/// JSON structure for log entries (used during parsing)
const AcpLogEntryJson = struct {
    kind: []const u8,
    content: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_status: ?[]const u8 = null,
    tool_command: ?[]const u8 = null,
    tool_stdout: ?[]const u8 = null,
    plan_entries: ?[]const PlanEntryJson = null,
};

/// Plan entry with owned strings
pub const OwnedPlanEntry = struct {
    content: []const u8,
    priority: ?[]const u8,
    status: ?[]const u8,
};

/// A single entry from an ACP output log (owns all strings)
pub const AcpLogEntry = struct {
    kind: []const u8,
    content: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_status: ?[]const u8 = null,
    tool_command: ?[]const u8 = null,
    tool_stdout: ?[]const u8 = null,
    plan_entries: ?[]OwnedPlanEntry = null,
};

// =============================================================================
// Log Loading
// =============================================================================

/// Load ACP log entries from a JSONL file.
/// Each line is a separate JSON object.
/// Returns a slice of AcpLogEntry (caller owns the memory).
pub fn loadLog(allocator: Allocator, path: []const u8) ![]AcpLogEntry {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return &[_]AcpLogEntry{};
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
    defer allocator.free(content);

    return parseJsonl(allocator, content);
}

/// Load ACP log from embedded content (for testing).
pub fn loadLogFromString(allocator: Allocator, content: []const u8) ![]AcpLogEntry {
    return parseJsonl(allocator, content);
}

/// Parse JSONL content into AcpLogEntry slice
fn parseJsonl(allocator: Allocator, content: []const u8) ![]AcpLogEntry {
    var entries: std.ArrayList(AcpLogEntry) = .{};
    errdefer {
        for (entries.items) |*entry| {
            freeLogEntry(allocator, entry);
        }
        entries.deinit(allocator);
    }

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(AcpLogEntryJson, allocator, trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch continue; // Skip malformed lines
        defer parsed.deinit();

        // Copy all strings to create owned entry
        const owned_entry = try cloneLogEntry(allocator, &parsed.value);
        try entries.append(allocator, owned_entry);
    }

    return entries.toOwnedSlice(allocator);
}

/// Clone a parsed entry, duplicating all strings
fn cloneLogEntry(allocator: Allocator, json: *const AcpLogEntryJson) !AcpLogEntry {
    var entry = AcpLogEntry{
        .kind = try allocator.dupe(u8, json.kind),
    };
    errdefer allocator.free(entry.kind);

    if (json.content) |c| {
        entry.content = try allocator.dupe(u8, c);
    }
    errdefer if (entry.content) |c| allocator.free(c);

    if (json.tool_name) |n| {
        entry.tool_name = try allocator.dupe(u8, n);
    }
    errdefer if (entry.tool_name) |n| allocator.free(n);

    if (json.tool_status) |s| {
        entry.tool_status = try allocator.dupe(u8, s);
    }
    errdefer if (entry.tool_status) |s| allocator.free(s);

    if (json.tool_command) |c| {
        entry.tool_command = try allocator.dupe(u8, c);
    }
    errdefer if (entry.tool_command) |c| allocator.free(c);

    if (json.tool_stdout) |s| {
        entry.tool_stdout = try allocator.dupe(u8, s);
    }
    errdefer if (entry.tool_stdout) |s| allocator.free(s);

    if (json.plan_entries) |json_entries| {
        var owned_entries: std.ArrayList(OwnedPlanEntry) = .{};
        errdefer {
            for (owned_entries.items) |pe| {
                allocator.free(pe.content);
                if (pe.priority) |p| allocator.free(p);
                if (pe.status) |s| allocator.free(s);
            }
            owned_entries.deinit(allocator);
        }

        for (json_entries) |pe| {
            var owned_pe = OwnedPlanEntry{
                .content = try allocator.dupe(u8, pe.content),
                .priority = null,
                .status = null,
            };
            if (pe.priority) |p| owned_pe.priority = try allocator.dupe(u8, p);
            if (pe.status) |s| owned_pe.status = try allocator.dupe(u8, s);
            try owned_entries.append(allocator, owned_pe);
        }
        entry.plan_entries = try owned_entries.toOwnedSlice(allocator);
    }

    return entry;
}

/// Free a single log entry
fn freeLogEntry(allocator: Allocator, entry: *AcpLogEntry) void {
    allocator.free(entry.kind);
    if (entry.content) |c| allocator.free(c);
    if (entry.tool_name) |n| allocator.free(n);
    if (entry.tool_status) |s| allocator.free(s);
    if (entry.tool_command) |c| allocator.free(c);
    if (entry.tool_stdout) |s| allocator.free(s);
    if (entry.plan_entries) |entries| {
        for (entries) |pe| {
            allocator.free(pe.content);
            if (pe.priority) |p| allocator.free(p);
            if (pe.status) |s| allocator.free(s);
        }
        allocator.free(entries);
    }
}

/// Free a slice of log entries
pub fn freeLogEntries(allocator: Allocator, entries: []AcpLogEntry) void {
    for (entries) |*entry| {
        freeLogEntry(allocator, entry);
    }
    allocator.free(entries);
}

// =============================================================================
// Replay into Builder
// =============================================================================

/// Apply ACP log entries to a TestAgentStateBuilder.
/// This replays a session, adding messages in order.
pub fn replayIntoBuilder(entries: []const AcpLogEntry, builder: *TestAgentStateBuilder) !void {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.kind, "user_message")) {
            if (entry.content) |content| {
                _ = builder.addUserMessage(content);
            }
        } else if (std.mem.eql(u8, entry.kind, "agent_message")) {
            if (entry.content) |content| {
                _ = builder.addAgentMessage(content);
            }
        } else if (std.mem.eql(u8, entry.kind, "tool_call") or std.mem.eql(u8, entry.kind, "tool_update")) {
            const name = entry.tool_name orelse "Unknown";
            const status = parseToolStatus(entry.tool_status);
            _ = builder.addToolCall(name, entry.tool_command, status, entry.tool_stdout);
        } else if (std.mem.eql(u8, entry.kind, "plan_update")) {
            if (entry.plan_entries) |owned_entries| {
                // Convert owned entries to PlanEntry
                var plan_entries: std.ArrayList(PlanEntry) = .{};
                defer plan_entries.deinit(builder.allocator);

                for (owned_entries) |oe| {
                    try plan_entries.append(builder.allocator, .{
                        .content = oe.content,
                        .priority = parsePriority(oe.priority),
                        .status = parsePlanStatus(oe.status),
                    });
                }
                _ = builder.addPlanSnapshot(plan_entries.items);
            }
        }
    }
}

/// Parse tool status from string
fn parseToolStatus(status_str: ?[]const u8) ToolStatus {
    const s = status_str orelse return .pending;
    if (std.mem.eql(u8, s, "running")) return .running;
    if (std.mem.eql(u8, s, "completed")) return .completed;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    return .pending;
}

/// Parse plan entry priority from string
fn parsePriority(priority_str: ?[]const u8) PlanEntryPriority {
    const s = priority_str orelse return .medium;
    if (std.mem.eql(u8, s, "high")) return .high;
    if (std.mem.eql(u8, s, "low")) return .low;
    return .medium;
}

/// Parse plan entry status from string
fn parsePlanStatus(status_str: ?[]const u8) PlanEntryStatus {
    const s = status_str orelse return .pending;
    if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, s, "completed")) return .completed;
    return .pending;
}

// =============================================================================
// Tests
// =============================================================================

test "loadLog parses jsonl format" {
    const allocator = std.testing.allocator;

    const jsonl =
        \\{"kind":"user_message","content":"Hello"}
        \\{"kind":"agent_message","content":"Hi there!"}
    ;

    const entries = try loadLogFromString(allocator, jsonl);
    defer freeLogEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("user_message", entries[0].kind);
    try std.testing.expectEqualStrings("Hello", entries[0].content.?);
    try std.testing.expectEqualStrings("agent_message", entries[1].kind);
    try std.testing.expectEqualStrings("Hi there!", entries[1].content.?);
}

test "loadLog handles empty file" {
    const allocator = std.testing.allocator;

    const entries = try loadLogFromString(allocator, "");
    defer freeLogEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "loadLog handles whitespace lines" {
    const allocator = std.testing.allocator;

    const jsonl =
        \\
        \\{"kind":"user_message","content":"Test"}
        \\
        \\
    ;

    const entries = try loadLogFromString(allocator, jsonl);
    defer freeLogEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Test", entries[0].content.?);
}

test "replayIntoBuilder applies user message" {
    const allocator = std.testing.allocator;

    const jsonl =
        \\{"kind":"user_message","content":"What files?"}
    ;

    const entries = try loadLogFromString(allocator, jsonl);
    defer freeLogEntries(allocator, entries);

    var builder = TestAgentStateBuilder.init(allocator);
    try replayIntoBuilder(entries, &builder);
    const messages = builder.build();
    defer agent_helpers.freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent_helpers.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("What files?", messages[0].content);
}

test "replayIntoBuilder applies agent message" {
    const allocator = std.testing.allocator;

    const jsonl =
        \\{"kind":"agent_message","content":"Here is the answer."}
    ;

    const entries = try loadLogFromString(allocator, jsonl);
    defer freeLogEntries(allocator, entries);

    var builder = TestAgentStateBuilder.init(allocator);
    try replayIntoBuilder(entries, &builder);
    const messages = builder.build();
    defer agent_helpers.freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent_helpers.MessageRole.agent, messages[0].role);
    try std.testing.expectEqualStrings("Here is the answer.", messages[0].content);
}

test "replayIntoBuilder applies tool call" {
    const allocator = std.testing.allocator;

    const jsonl =
        \\{"kind":"tool_call","tool_name":"Bash","tool_command":"ls src/","tool_status":"running"}
    ;

    const entries = try loadLogFromString(allocator, jsonl);
    defer freeLogEntries(allocator, entries);

    var builder = TestAgentStateBuilder.init(allocator);
    try replayIntoBuilder(entries, &builder);
    const messages = builder.build();
    defer agent_helpers.freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent_helpers.MessageRole.tool, messages[0].role);
    try std.testing.expectEqualStrings("Bash", messages[0].tool_name.?);
    try std.testing.expectEqualStrings("ls src/", messages[0].tool_command.?);
    try std.testing.expectEqual(agent_helpers.ToolStatus.running, messages[0].tool_status);
}

test "replayIntoBuilder applies tool update with output" {
    const allocator = std.testing.allocator;

    const jsonl =
        \\{"kind":"tool_update","tool_name":"Bash","tool_status":"completed","tool_stdout":"main.zig\napp.zig"}
    ;

    const entries = try loadLogFromString(allocator, jsonl);
    defer freeLogEntries(allocator, entries);

    var builder = TestAgentStateBuilder.init(allocator);
    try replayIntoBuilder(entries, &builder);
    const messages = builder.build();
    defer agent_helpers.freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent_helpers.ToolStatus.completed, messages[0].tool_status);
    try std.testing.expectEqualStrings("main.zig\napp.zig", messages[0].tool_stdout.?);
}

test "replayIntoBuilder applies full session" {
    const allocator = std.testing.allocator;

    const jsonl =
        \\{"kind":"user_message","content":"What files are in src/?"}
        \\{"kind":"tool_call","tool_name":"Bash","tool_command":"ls src/","tool_status":"running"}
        \\{"kind":"tool_update","tool_name":"Bash","tool_status":"completed","tool_stdout":"main.zig\napp.zig"}
        \\{"kind":"agent_message","content":"The src/ directory contains main.zig and app.zig."}
    ;

    const entries = try loadLogFromString(allocator, jsonl);
    defer freeLogEntries(allocator, entries);

    var builder = TestAgentStateBuilder.init(allocator);
    try replayIntoBuilder(entries, &builder);
    const messages = builder.build();
    defer agent_helpers.freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqual(agent_helpers.MessageRole.user, messages[0].role);
    try std.testing.expectEqual(agent_helpers.MessageRole.tool, messages[1].role);
    try std.testing.expectEqual(agent_helpers.MessageRole.tool, messages[2].role);
    try std.testing.expectEqual(agent_helpers.MessageRole.agent, messages[3].role);
}
