const std = @import("std");

// =============================================================================
// Server-Sent Events (SSE) Parser
// =============================================================================
//
// Parses SSE streams from Opencode's /global/event endpoint.
// SSE format per W3C spec:
//   - Lines starting with ':' are comments (ignored)
//   - Lines starting with 'event:' set the event type
//   - Lines starting with 'data:' append to data buffer
//   - Lines starting with 'id:' set the event ID
//   - Lines starting with 'retry:' set reconnection time
//   - Empty line dispatches the event
//
// Opencode uses `data:` only (no `event:` field). Event type is in JSON:
//   data: {"type":"message.part.updated","properties":{"delta":"Hello"}}
//
// =============================================================================

const Allocator = std.mem.Allocator;

/// A parsed SSE event
pub const SseEvent = struct {
    /// Event type from 'event:' field (rarely used by Opencode)
    event: ?[]const u8 = null,
    /// Data payload (concatenated from all 'data:' lines)
    data: ?[]const u8 = null,
    /// Event ID from 'id:' field
    id: ?[]const u8 = null,
    /// Retry interval from 'retry:' field (milliseconds)
    retry: ?u32 = null,

    pub fn deinit(self: *SseEvent, allocator: Allocator) void {
        if (self.event) |e| allocator.free(e);
        if (self.data) |d| allocator.free(d);
        if (self.id) |i| allocator.free(i);
    }
};

/// SSE stream parser with state machine
pub const SseParser = struct {
    allocator: Allocator,

    // Current event being built
    event_type: ?[]u8 = null,
    data_buffer: std.ArrayList(u8),
    event_id: ?[]u8 = null,
    retry_ms: ?u32 = null,

    // Line buffer for partial lines
    line_buffer: std.ArrayList(u8),

    // Whether we have data to dispatch
    has_data: bool = false,

    pub fn init(allocator: Allocator) SseParser {
        return .{
            .allocator = allocator,
            .data_buffer = .{},
            .line_buffer = .{},
        };
    }

    pub fn deinit(self: *SseParser) void {
        if (self.event_type) |e| self.allocator.free(e);
        if (self.event_id) |i| self.allocator.free(i);
        self.data_buffer.deinit(self.allocator);
        self.line_buffer.deinit(self.allocator);
    }

    /// Reset parser state for next event
    pub fn reset(self: *SseParser) void {
        if (self.event_type) |e| self.allocator.free(e);
        if (self.event_id) |i| self.allocator.free(i);
        self.event_type = null;
        self.event_id = null;
        self.retry_ms = null;
        self.data_buffer.clearRetainingCapacity();
        self.has_data = false;
    }

    /// Feed data to the parser. Returns an event if one is complete.
    /// Call repeatedly until it returns null to process all events in the buffer.
    pub fn feed(self: *SseParser, data: []const u8) !?SseEvent {
        // Append to line buffer
        try self.line_buffer.appendSlice(self.allocator, data);

        // Process complete lines
        while (self.findLine()) |line_info| {
            const line = line_info.line;
            const end_pos = line_info.end_pos;

            // Process this line
            if (line.len == 0) {
                // Empty line = dispatch event
                if (self.has_data or self.data_buffer.items.len > 0) {
                    // Build the event - use has_data flag to decide if data field should exist
                    const event = SseEvent{
                        .event = if (self.event_type) |e| try self.allocator.dupe(u8, e) else null,
                        .data = if (self.has_data)
                            try self.allocator.dupe(u8, self.data_buffer.items)
                        else
                            null,
                        .id = if (self.event_id) |i| try self.allocator.dupe(u8, i) else null,
                        .retry = self.retry_ms,
                    };

                    // Remove processed bytes from line buffer
                    self.removeProcessedBytes(end_pos);

                    // Reset state
                    self.reset();

                    return event;
                }
            } else if (line[0] == ':') {
                // Comment - ignore
            } else {
                // Parse field:value
                try self.processField(line);
            }

            // Remove processed line from buffer
            self.removeProcessedBytes(end_pos);
        }

        return null;
    }

    fn findLine(self: *SseParser) ?struct { line: []const u8, end_pos: usize } {
        const items = self.line_buffer.items;
        for (items, 0..) |c, i| {
            if (c == '\n') {
                // Found end of line - check for \r\n
                const line_end = if (i > 0 and items[i - 1] == '\r') i - 1 else i;
                return .{
                    .line = items[0..line_end],
                    .end_pos = i + 1, // Include the \n
                };
            }
        }
        return null;
    }

    fn removeProcessedBytes(self: *SseParser, end_pos: usize) void {
        // Shift remaining data to front
        const remaining = self.line_buffer.items[end_pos..];
        std.mem.copyForwards(u8, self.line_buffer.items[0..remaining.len], remaining);
        self.line_buffer.shrinkRetainingCapacity(remaining.len);
    }

    fn processField(self: *SseParser, line: []const u8) !void {
        // Find the colon separator
        const colon_pos = std.mem.indexOf(u8, line, ":") orelse {
            // No colon - treat as field with empty value
            return;
        };

        const field = line[0..colon_pos];
        // Value starts after colon, optionally skip one space
        var value = line[colon_pos + 1 ..];
        if (value.len > 0 and value[0] == ' ') {
            value = value[1..];
        }

        if (std.mem.eql(u8, field, "event")) {
            if (self.event_type) |e| self.allocator.free(e);
            self.event_type = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, field, "data")) {
            // Append data (with newline if not first)
            if (self.data_buffer.items.len > 0) {
                try self.data_buffer.append(self.allocator, '\n');
            }
            try self.data_buffer.appendSlice(self.allocator, value);
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "id")) {
            if (self.event_id) |i| self.allocator.free(i);
            self.event_id = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, field, "retry")) {
            self.retry_ms = std.fmt.parseInt(u32, value, 10) catch null;
        }
        // Unknown fields are ignored per spec
    }
};

// =============================================================================
// Tests
// =============================================================================

test "parse simple event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "data: hello\n\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    try std.testing.expect(event.?.event == null);
    try std.testing.expectEqualStrings("hello", event.?.data.?);
    try std.testing.expect(event.?.id == null);
    try std.testing.expect(event.?.retry == null);
}

test "parse event with type" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "event: message\ndata: {\"type\":\"test\"}\n\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    try std.testing.expectEqualStrings("message", event.?.event.?);
    try std.testing.expectEqualStrings("{\"type\":\"test\"}", event.?.data.?);
}

test "parse multiline data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "data: line1\ndata: line2\ndata: line3\n\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    try std.testing.expectEqualStrings("line1\nline2\nline3", event.?.data.?);
}

test "parse multiple events" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "data: first\n\ndata: second\n\n";

    // First event
    var event1 = try parser.feed(input);
    try std.testing.expect(event1 != null);
    defer event1.?.deinit(allocator);
    try std.testing.expectEqualStrings("first", event1.?.data.?);

    // Second event should be available from remaining buffer
    var event2 = try parser.feed("");
    try std.testing.expect(event2 != null);
    defer event2.?.deinit(allocator);
    try std.testing.expectEqualStrings("second", event2.?.data.?);

    // No more events
    const event3 = try parser.feed("");
    try std.testing.expect(event3 == null);
}

test "ignore comments" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = ": this is a comment\ndata: actual data\n: another comment\n\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    try std.testing.expectEqualStrings("actual data", event.?.data.?);
}

test "parse event with id and retry" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "id: evt_123\nretry: 5000\ndata: test\n\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    try std.testing.expectEqualStrings("evt_123", event.?.id.?);
    try std.testing.expectEqual(@as(u32, 5000), event.?.retry.?);
    try std.testing.expectEqualStrings("test", event.?.data.?);
}

test "handle partial data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Feed partial data
    const event1 = try parser.feed("data: hel");
    try std.testing.expect(event1 == null);

    // Feed more partial data
    const event2 = try parser.feed("lo\n");
    try std.testing.expect(event2 == null);

    // Complete the event
    var event3 = try parser.feed("\n");
    try std.testing.expect(event3 != null);

    defer event3.?.deinit(allocator);
    try std.testing.expectEqualStrings("hello", event3.?.data.?);
}

test "parse Opencode-style JSON event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Real Opencode format - data only, type in JSON
    const input = "data: {\"type\":\"message.part.updated\",\"properties\":{\"delta\":\"Hello\"}}\n\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    try std.testing.expect(event.?.event == null); // No event: field
    try std.testing.expect(event.?.data != null);

    // Verify we can parse the JSON data
    const json = event.?.data.?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"message.part.updated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"delta\":\"Hello\"") != null);
}

test "handle CRLF line endings" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "data: hello\r\n\r\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    try std.testing.expectEqualStrings("hello", event.?.data.?);
}

test "handle empty data field" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const input = "data:\n\n";
    var event = try parser.feed(input);
    try std.testing.expect(event != null);

    defer event.?.deinit(allocator);
    // Empty data line still triggers event dispatch, but data is empty string
    // The parser treats this as valid per SSE spec
    try std.testing.expect(event.?.data != null);
    try std.testing.expectEqual(@as(usize, 0), event.?.data.?.len);
}
