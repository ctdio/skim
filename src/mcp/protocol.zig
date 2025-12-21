const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Internal Protocol Messages (skim TUI <-> MCP Server)
// =============================================================================

/// File info sent during hello handshake
pub const FileInfo = struct {
    path: []const u8,
    old_path: []const u8,
    hunk_count: usize,
};

/// Hello message from skim TUI to server on connect
pub const HelloPayload = struct {
    id: []const u8,
    cwd: []const u8,
    diff_ref: []const u8,
    files: []const FileInfo,
};

/// Welcome response from server to skim TUI
pub const WelcomePayload = struct {
    id: []const u8,
};

/// Add comment request from server to skim TUI
pub const AddCommentPayload = struct {
    file: []const u8,
    line: u32,
    line_type: []const u8, // "new" or "old" - which file version
    text: []const u8,
};

/// Comment added confirmation from skim TUI to server
pub const CommentAddedPayload = struct {
    success: bool,
    comment_idx: ?usize,
    @"error": ?[]const u8,
};

/// Comment info for get_comments response
pub const CommentInfo = struct {
    idx: usize,
    file_path: []const u8,
    line: u32,
    text: []const u8,
    line_type: []const u8, // "add", "delete", "context"
    line_type_flag: []const u8, // "new" or "old" - which file version
};

/// Comments list response from skim TUI to server
pub const CommentsPayload = struct {
    comments: []const CommentInfo,
};

/// Comment changed notification from skim TUI to server
pub const CommentChangedPayload = struct {
    action: []const u8, // "added", "updated", "deleted"
    comment: CommentInfo,
};

/// File summary for get_diff_context response
pub const DiffFileSummary = struct {
    path: []const u8,
    old_path: []const u8,
    status: []const u8, // "added", "modified", "deleted", "renamed"
    additions: usize,
    deletions: usize,
    hunk_count: usize,
};

/// Diff context response from skim TUI to server
pub const DiffContextPayload = struct {
    diff_ref: []const u8,
    cwd: []const u8,
    files: []const DiffFileSummary,
};

/// Error response
pub const ErrorPayload = struct {
    code: []const u8,
    message: []const u8,
};

/// Get file diff request from server to skim TUI
pub const GetFileDiffPayload = struct {
    file: []const u8,
};

/// Line info for file_diff response
pub const DiffLineInfo = struct {
    line_type: []const u8, // "add", "delete", "context"
    content: []const u8,
    old_lineno: ?u32,
    new_lineno: ?u32,
};

/// Hunk info for file_diff response
pub const DiffHunkInfo = struct {
    header: []const u8, // e.g., "@@ -10,5 +10,7 @@"
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []const DiffLineInfo,
};

/// File diff response from skim TUI to server
pub const FileDiffPayload = struct {
    file: []const u8,
    old_file: []const u8,
    status: []const u8, // "added", "modified", "deleted", "renamed"
    hunks: []const DiffHunkInfo,
};

/// Internal protocol message types
pub const MessageType = enum {
    hello,
    welcome,
    add_comment,
    comment_added,
    get_comments,
    comments,
    comment_changed,
    get_diff_context,
    diff_context,
    get_file_diff,
    file_diff,
    @"error",
    ping,
    pong,
};

/// File summary for raw message parsing (diff_context)
pub const RawDiffFileSummary = struct {
    path: []const u8,
    old_path: []const u8,
    status: []const u8,
    additions: usize,
    deletions: usize,
    hunk_count: usize,
};

/// Line info for raw message parsing (file_diff)
pub const RawDiffLineInfo = struct {
    line_type: []const u8,
    content: []const u8,
    old_lineno: ?u32 = null,
    new_lineno: ?u32 = null,
};

/// Hunk info for raw message parsing (file_diff)
pub const RawDiffHunkInfo = struct {
    header: []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []const RawDiffLineInfo,
};

/// Raw message envelope for JSON parsing
pub const RawMessage = struct {
    event: []const u8,
    // Optional fields based on event type
    id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    diff_ref: ?[]const u8 = null,
    files: ?[]const FileInfo = null,
    file: ?[]const u8 = null,
    old_file: ?[]const u8 = null,
    line: ?u32 = null,
    line_type: ?[]const u8 = null, // "new" or "old"
    text: ?[]const u8 = null,
    success: ?bool = null,
    comment_idx: ?usize = null,
    @"error": ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    comments: ?[]const CommentInfo = null,
    action: ?[]const u8 = null,
    comment: ?CommentInfo = null,
    status: ?[]const u8 = null,
    // For diff_context response
    diff_files: ?[]const RawDiffFileSummary = null,
    // For file_diff response
    hunks: ?[]const RawDiffHunkInfo = null,
};

// =============================================================================
// JSON-RPC 2.0 Types (for MCP protocol)
// =============================================================================

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    id: ?JsonRpcId = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?JsonRpcId = null,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const JsonRpcId = union(enum) {
    string: []const u8,
    number: i64,
    null_value: void,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !JsonRpcId {
        _ = options;
        const token = try source.next();
        switch (token) {
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .number => |n| {
                if (std.fmt.parseInt(i64, n, 10)) |num| {
                    return .{ .number = num };
                } else |_| {
                    return error.InvalidNumber;
                }
            },
            .null => return .{ .null_value = {} },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: JsonRpcId, options: std.json.StringifyOptions, writer: anytype) !void {
        _ = options;
        switch (self) {
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .number => |n| try writer.print("{d}", .{n}),
            .null_value => try writer.writeAll("null"),
        }
    }
};

// =============================================================================
// MCP Tool Definitions
// =============================================================================

pub const McpTool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

pub const InputSchema = struct {
    type: []const u8 = "object",
    properties: std.json.Value,
    required: []const []const u8,
};

// =============================================================================
// Encoding Functions
// =============================================================================

/// Encode a hello message
pub fn encodeHello(allocator: Allocator, payload: HelloPayload) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"hello\"");
    try writer.writeAll(",\"id\":\"");
    try writer.writeAll(payload.id);
    try writer.writeAll("\",\"cwd\":\"");
    try writeJsonEscaped(writer, payload.cwd);
    try writer.writeAll("\",\"diff_ref\":\"");
    try writeJsonEscaped(writer, payload.diff_ref);
    try writer.writeAll("\",\"files\":[");

    for (payload.files, 0..) |file, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":\"");
        try writeJsonEscaped(writer, file.path);
        try writer.writeAll("\",\"old_path\":\"");
        try writeJsonEscaped(writer, file.old_path);
        try writer.writeAll("\",\"hunk_count\":");
        try writer.print("{d}", .{file.hunk_count});
        try writer.writeByte('}');
    }

    try writer.writeAll("]}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a welcome message
pub fn encodeWelcome(allocator: Allocator, id: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"welcome\",\"id\":\"");
    try writer.writeAll(id);
    try writer.writeAll("\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode an add_comment message
pub fn encodeAddComment(allocator: Allocator, payload: AddCommentPayload) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"add_comment\",\"file\":\"");
    try writeJsonEscaped(writer, payload.file);
    try writer.writeAll("\",\"line\":");
    try writer.print("{d}", .{payload.line});
    try writer.writeAll(",\"line_type\":\"");
    try writeJsonEscaped(writer, payload.line_type);
    try writer.writeAll("\",\"text\":\"");
    try writeJsonEscaped(writer, payload.text);
    try writer.writeAll("\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a comment_added response
pub fn encodeCommentAdded(allocator: Allocator, success: bool, comment_idx: ?usize, err_msg: ?[]const u8) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"comment_added\",\"success\":");
    try writer.writeAll(if (success) "true" else "false");

    if (comment_idx) |idx| {
        try writer.writeAll(",\"comment_idx\":");
        try writer.print("{d}", .{idx});
    }

    if (err_msg) |msg| {
        try writer.writeAll(",\"error\":\"");
        try writeJsonEscaped(writer, msg);
        try writer.writeByte('"');
    }

    try writer.writeAll("}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a get_comments request
pub fn encodeGetComments(allocator: Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, "{\"event\":\"get_comments\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a comments response
pub fn encodeComments(allocator: Allocator, comments: []const CommentInfo) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"comments\",\"comments\":[");

    for (comments, 0..) |comment, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"idx\":");
        try writer.print("{d}", .{comment.idx});
        try writer.writeAll(",\"file_path\":\"");
        try writeJsonEscaped(writer, comment.file_path);
        try writer.writeAll("\",\"line\":");
        try writer.print("{d}", .{comment.line});
        try writer.writeAll(",\"text\":\"");
        try writeJsonEscaped(writer, comment.text);
        try writer.writeAll("\",\"line_type\":\"");
        try writer.writeAll(comment.line_type);
        try writer.writeAll("\",\"line_type_flag\":\"");
        try writeJsonEscaped(writer, comment.line_type_flag);
        try writer.writeAll("\"}");
    }

    try writer.writeAll("]}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode an error message
pub fn encodeError(allocator: Allocator, code: []const u8, message: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"error\",\"code\":\"");
    try writer.writeAll(code);
    try writer.writeAll("\",\"message\":\"");
    try writeJsonEscaped(writer, message);
    try writer.writeAll("\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode ping
pub fn encodePing(allocator: Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"event\":\"ping\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode pong
pub fn encodePong(allocator: Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"event\":\"pong\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a get_diff_context request
pub fn encodeGetDiffContext(allocator: Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"event\":\"get_diff_context\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a get_file_diff request
pub fn encodeGetFileDiff(allocator: Allocator, file: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"get_file_diff\",\"file\":\"");
    try writeJsonEscaped(writer, file);
    try writer.writeAll("\"}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a diff_context response
pub fn encodeDiffContext(allocator: Allocator, payload: DiffContextPayload) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"diff_context\",\"diff_ref\":\"");
    try writeJsonEscaped(writer, payload.diff_ref);
    try writer.writeAll("\",\"cwd\":\"");
    try writeJsonEscaped(writer, payload.cwd);
    try writer.writeAll("\",\"diff_files\":[");

    for (payload.files, 0..) |file, file_idx| {
        if (file_idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":\"");
        try writeJsonEscaped(writer, file.path);
        try writer.writeAll("\",\"old_path\":\"");
        try writeJsonEscaped(writer, file.old_path);
        try writer.writeAll("\",\"status\":\"");
        try writer.writeAll(file.status);
        try writer.writeAll("\",\"additions\":");
        try writer.print("{d}", .{file.additions});
        try writer.writeAll(",\"deletions\":");
        try writer.print("{d}", .{file.deletions});
        try writer.writeAll(",\"hunk_count\":");
        try writer.print("{d}", .{file.hunk_count});
        try writer.writeByte('}');
    }

    try writer.writeAll("]}\n");
    return output.toOwnedSlice(allocator);
}

/// Encode a file_diff response
pub fn encodeFileDiff(allocator: Allocator, payload: FileDiffPayload) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    try writer.writeAll("{\"event\":\"file_diff\",\"file\":\"");
    try writeJsonEscaped(writer, payload.file);
    try writer.writeAll("\",\"old_file\":\"");
    try writeJsonEscaped(writer, payload.old_file);
    try writer.writeAll("\",\"status\":\"");
    try writer.writeAll(payload.status);
    try writer.writeAll("\",\"hunks\":[");

    for (payload.hunks, 0..) |hunk, hunk_idx| {
        if (hunk_idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"header\":\"");
        try writeJsonEscaped(writer, hunk.header);
        try writer.writeAll("\",\"old_start\":");
        try writer.print("{d}", .{hunk.old_start});
        try writer.writeAll(",\"old_count\":");
        try writer.print("{d}", .{hunk.old_count});
        try writer.writeAll(",\"new_start\":");
        try writer.print("{d}", .{hunk.new_start});
        try writer.writeAll(",\"new_count\":");
        try writer.print("{d}", .{hunk.new_count});
        try writer.writeAll(",\"lines\":[");

        for (hunk.lines, 0..) |line, line_idx| {
            if (line_idx > 0) try writer.writeByte(',');
            try writer.writeAll("{\"line_type\":\"");
            try writer.writeAll(line.line_type);
            try writer.writeAll("\",\"content\":\"");
            try writeJsonEscaped(writer, line.content);
            try writer.writeByte('"');
            if (line.old_lineno) |n| {
                try writer.writeAll(",\"old_lineno\":");
                try writer.print("{d}", .{n});
            }
            if (line.new_lineno) |n| {
                try writer.writeAll(",\"new_lineno\":");
                try writer.print("{d}", .{n});
            }
            try writer.writeByte('}');
        }

        try writer.writeAll("]}");
    }

    try writer.writeAll("]}\n");
    return output.toOwnedSlice(allocator);
}

// =============================================================================
// Decoding Functions
// =============================================================================

pub const ParsedMessage = union(enum) {
    hello: HelloPayload,
    welcome: WelcomePayload,
    add_comment: AddCommentPayload,
    comment_added: CommentAddedPayload,
    get_comments: void,
    comments: CommentsPayload,
    get_diff_context: void,
    diff_context: DiffContextPayload,
    get_file_diff: GetFileDiffPayload,
    file_diff: FileDiffPayload,
    @"error": ErrorPayload,
    ping: void,
    pong: void,
    unknown: []const u8,
};

/// Decode a JSON message line
pub fn decode(allocator: Allocator, json_line: []const u8) !ParsedMessage {
    // Trim trailing newline if present
    const trimmed = std.mem.trimRight(u8, json_line, "\n\r");

    const parsed = std.json.parseFromSlice(RawMessage, allocator, trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("JSON parse error: {} for input: {s}", .{ err, trimmed });
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const msg = parsed.value;
    const event = msg.event;

    if (std.mem.eql(u8, event, "hello")) {
        return .{ .hello = .{
            .id = try allocator.dupe(u8, msg.id orelse return error.MissingField),
            .cwd = try allocator.dupe(u8, msg.cwd orelse return error.MissingField),
            .diff_ref = try allocator.dupe(u8, msg.diff_ref orelse return error.MissingField),
            .files = if (msg.files) |files| blk: {
                var duped = try allocator.alloc(FileInfo, files.len);
                for (files, 0..) |f, i| {
                    duped[i] = .{
                        .path = try allocator.dupe(u8, f.path),
                        .old_path = try allocator.dupe(u8, f.old_path),
                        .hunk_count = f.hunk_count,
                    };
                }
                break :blk duped;
            } else &[_]FileInfo{},
        } };
    } else if (std.mem.eql(u8, event, "welcome")) {
        return .{ .welcome = .{
            .id = try allocator.dupe(u8, msg.id orelse return error.MissingField),
        } };
    } else if (std.mem.eql(u8, event, "add_comment")) {
        return .{ .add_comment = .{
            .file = try allocator.dupe(u8, msg.file orelse return error.MissingField),
            .line = msg.line orelse return error.MissingField,
            .line_type = try allocator.dupe(u8, msg.line_type orelse return error.MissingField),
            .text = try allocator.dupe(u8, msg.text orelse return error.MissingField),
        } };
    } else if (std.mem.eql(u8, event, "comment_added")) {
        return .{ .comment_added = .{
            .success = msg.success orelse false,
            .comment_idx = msg.comment_idx,
            .@"error" = if (msg.@"error") |e| try allocator.dupe(u8, e) else null,
        } };
    } else if (std.mem.eql(u8, event, "get_comments")) {
        return .{ .get_comments = {} };
    } else if (std.mem.eql(u8, event, "comments")) {
        const comments = msg.comments orelse &[_]CommentInfo{};
        var duped = try allocator.alloc(CommentInfo, comments.len);
        var initialized: usize = 0;
        errdefer {
            for (duped[0..initialized]) |c| {
                allocator.free(c.file_path);
                allocator.free(c.text);
                allocator.free(c.line_type);
                allocator.free(c.line_type_flag);
            }
            allocator.free(duped);
        }
        for (comments, 0..) |c, i| {
            const file_path = try allocator.dupe(u8, c.file_path);
            errdefer allocator.free(file_path);
            const text = try allocator.dupe(u8, c.text);
            errdefer allocator.free(text);
            const line_type = try allocator.dupe(u8, c.line_type);
            errdefer allocator.free(line_type);
            const line_type_flag = try allocator.dupe(u8, c.line_type_flag);

            duped[i] = .{
                .idx = c.idx,
                .file_path = file_path,
                .line = c.line,
                .text = text,
                .line_type = line_type,
                .line_type_flag = line_type_flag,
            };
            initialized = i + 1;
        }
        return .{ .comments = .{ .comments = duped } };
    } else if (std.mem.eql(u8, event, "get_diff_context")) {
        return .{ .get_diff_context = {} };
    } else if (std.mem.eql(u8, event, "diff_context")) {
        const diff_files = msg.diff_files orelse &[_]RawDiffFileSummary{};
        var duped = try allocator.alloc(DiffFileSummary, diff_files.len);
        var initialized: usize = 0;
        errdefer {
            for (duped[0..initialized]) |f| {
                allocator.free(f.path);
                allocator.free(f.old_path);
                allocator.free(f.status);
            }
            allocator.free(duped);
        }
        for (diff_files, 0..) |f, i| {
            const path = try allocator.dupe(u8, f.path);
            errdefer allocator.free(path);
            const old_path = try allocator.dupe(u8, f.old_path);
            errdefer allocator.free(old_path);
            const status = try allocator.dupe(u8, f.status);

            duped[i] = .{
                .path = path,
                .old_path = old_path,
                .status = status,
                .additions = f.additions,
                .deletions = f.deletions,
                .hunk_count = f.hunk_count,
            };
            initialized = i + 1;
        }

        const diff_ref = try allocator.dupe(u8, msg.diff_ref orelse "");
        errdefer allocator.free(diff_ref);
        const cwd = try allocator.dupe(u8, msg.cwd orelse "");

        return .{ .diff_context = .{
            .diff_ref = diff_ref,
            .cwd = cwd,
            .files = duped,
        } };
    } else if (std.mem.eql(u8, event, "get_file_diff")) {
        return .{ .get_file_diff = .{
            .file = try allocator.dupe(u8, msg.file orelse return error.MissingField),
        } };
    } else if (std.mem.eql(u8, event, "file_diff")) {
        const hunks = msg.hunks orelse &[_]RawDiffHunkInfo{};
        var duped_hunks = try allocator.alloc(DiffHunkInfo, hunks.len);
        var hunks_initialized: usize = 0;
        errdefer {
            // Clean up fully initialized hunks
            for (duped_hunks[0..hunks_initialized]) |hunk| {
                allocator.free(hunk.header);
                for (hunk.lines) |line| {
                    allocator.free(line.line_type);
                    allocator.free(line.content);
                }
                allocator.free(hunk.lines);
            }
            allocator.free(duped_hunks);
        }

        for (hunks, 0..) |h, hi| {
            var duped_lines = try allocator.alloc(DiffLineInfo, h.lines.len);
            var lines_initialized: usize = 0;
            errdefer {
                for (duped_lines[0..lines_initialized]) |line| {
                    allocator.free(line.line_type);
                    allocator.free(line.content);
                }
                allocator.free(duped_lines);
            }

            for (h.lines, 0..) |l, li| {
                const line_type = try allocator.dupe(u8, l.line_type);
                errdefer allocator.free(line_type);
                const content = try allocator.dupe(u8, l.content);

                duped_lines[li] = .{
                    .line_type = line_type,
                    .content = content,
                    .old_lineno = l.old_lineno,
                    .new_lineno = l.new_lineno,
                };
                lines_initialized = li + 1;
            }

            const header = try allocator.dupe(u8, h.header);
            duped_hunks[hi] = .{
                .header = header,
                .old_start = h.old_start,
                .old_count = h.old_count,
                .new_start = h.new_start,
                .new_count = h.new_count,
                .lines = duped_lines,
            };
            hunks_initialized = hi + 1;
        }

        const file = try allocator.dupe(u8, msg.file orelse "");
        errdefer allocator.free(file);
        const old_file = try allocator.dupe(u8, msg.old_file orelse "");
        errdefer allocator.free(old_file);
        const status = try allocator.dupe(u8, msg.status orelse "modified");

        return .{ .file_diff = .{
            .file = file,
            .old_file = old_file,
            .status = status,
            .hunks = duped_hunks,
        } };
    } else if (std.mem.eql(u8, event, "error")) {
        return .{ .@"error" = .{
            .code = try allocator.dupe(u8, msg.code orelse "unknown"),
            .message = try allocator.dupe(u8, msg.message orelse "Unknown error"),
        } };
    } else if (std.mem.eql(u8, event, "ping")) {
        return .{ .ping = {} };
    } else if (std.mem.eql(u8, event, "pong")) {
        return .{ .pong = {} };
    }

    return .{ .unknown = try allocator.dupe(u8, event) };
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Write a string with JSON escaping
fn writeJsonEscaped(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "encode and decode hello" {
    const allocator = std.testing.allocator;

    const files = [_]FileInfo{
        .{ .path = "src/app.zig", .old_path = "src/app.zig", .hunk_count = 3 },
    };

    const encoded = try encodeHello(allocator, .{
        .id = "test-123",
        .cwd = "/tmp/repo",
        .diff_ref = "main..dev",
        .files = &files,
    });
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer {
        switch (decoded) {
            .hello => |h| {
                allocator.free(h.id);
                allocator.free(h.cwd);
                allocator.free(h.diff_ref);
                for (h.files) |f| {
                    allocator.free(f.path);
                    allocator.free(f.old_path);
                }
                allocator.free(h.files);
            },
            else => {},
        }
    }

    try std.testing.expect(decoded == .hello);
    try std.testing.expectEqualStrings("test-123", decoded.hello.id);
    try std.testing.expectEqualStrings("/tmp/repo", decoded.hello.cwd);
    try std.testing.expectEqualStrings("main..dev", decoded.hello.diff_ref);
    try std.testing.expectEqual(@as(usize, 1), decoded.hello.files.len);
}

test "encode and decode add_comment" {
    const allocator = std.testing.allocator;

    const encoded = try encodeAddComment(allocator, .{
        .file = "src/app.zig",
        .line = 150,
        .line_type = "new",
        .text = "This needs error handling",
    });
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer {
        switch (decoded) {
            .add_comment => |ac| {
                allocator.free(ac.file);
                allocator.free(ac.line_type);
                allocator.free(ac.text);
            },
            else => {},
        }
    }

    try std.testing.expect(decoded == .add_comment);
    try std.testing.expectEqualStrings("src/app.zig", decoded.add_comment.file);
    try std.testing.expectEqual(@as(u32, 150), decoded.add_comment.line);
    try std.testing.expectEqualStrings("new", decoded.add_comment.line_type);
    try std.testing.expectEqualStrings("This needs error handling", decoded.add_comment.text);
}

test "add_comment with old line type" {
    const allocator = std.testing.allocator;

    const encoded = try encodeAddComment(allocator, .{
        .file = "deleted.zig",
        .line = 50,
        .line_type = "old",
        .text = "This line was deleted",
    });
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer {
        switch (decoded) {
            .add_comment => |ac| {
                allocator.free(ac.file);
                allocator.free(ac.line_type);
                allocator.free(ac.text);
            },
            else => {},
        }
    }

    try std.testing.expect(decoded == .add_comment);
    try std.testing.expectEqualStrings("old", decoded.add_comment.line_type);
}

test "encode and decode comment_added success" {
    const allocator = std.testing.allocator;

    const encoded = try encodeCommentAdded(allocator, true, 5, null);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    // No defer needed for comment_added with null error

    try std.testing.expect(decoded == .comment_added);
    try std.testing.expect(decoded.comment_added.success);
    try std.testing.expectEqual(@as(?usize, 5), decoded.comment_added.comment_idx);
}

test "json escape special characters" {
    const allocator = std.testing.allocator;

    const encoded = try encodeAddComment(allocator, .{
        .file = "test.zig",
        .line = 1,
        .text = "Line 1\nLine 2\tTabbed \"quoted\"",
    });
    defer allocator.free(encoded);

    // Should contain escaped characters
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\\\"") != null);
}
