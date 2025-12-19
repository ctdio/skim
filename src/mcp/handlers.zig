const std = @import("std");
const mcp_client = @import("client.zig");
const mcp_protocol = @import("protocol.zig");
const mcp_line_resolver = @import("line_resolver.zig");
const mcp_registry = @import("registry.zig");
const parser = @import("../git/parser.zig");
const comments = @import("../comments/store.zig");
const git = @import("../git/diff.zig");

const Allocator = std.mem.Allocator;
const DiffSource = git.DiffSource;

/// Send hello message to MCP server to register this client
pub fn sendHello(
    allocator: Allocator,
    mcp: *mcp_client.McpClient,
    files: []parser.FileDiff,
    diff_source: DiffSource,
) !void {
    // Build file info list
    var file_infos = std.ArrayList(mcp_protocol.FileInfo).init(allocator);
    defer file_infos.deinit();

    for (files) |file| {
        const path = if (file.new_path.len > 0) file.new_path else file.old_path;
        const old_path = file.old_path;
        try file_infos.append(.{
            .path = path,
            .old_path = old_path,
            .hunk_count = file.hunks.len,
        });
    }

    // Get diff ref string
    const diff_ref = getDiffRef(diff_source);

    // Generate session ID
    const session_id = mcp_registry.generateSessionId();

    // Get current working directory
    const cwd_allocated = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    defer if (cwd_allocated) |c| allocator.free(c);
    const cwd = cwd_allocated orelse ".";

    try mcp.sendHello(.{
        .id = &session_id,
        .cwd = cwd,
        .diff_ref = diff_ref,
        .files = file_infos.items,
    });
}

/// Handle add_comment request from MCP server
/// Returns the comment index if successful, null otherwise
pub fn handleAddComment(
    allocator: Allocator,
    mcp: *mcp_client.McpClient,
    ac: mcp_protocol.AddCommentPayload,
    files: []parser.FileDiff,
    comment_store: *comments.CommentStore,
) !?usize {
    // Use LineResolver with explicit line_type selection
    const resolver = mcp_line_resolver.LineResolver.init(allocator, files);

    // Choose resolution method based on line_type
    const resolved = if (std.mem.eql(u8, ac.line_type, "new"))
        resolver.resolveNewLine(ac.file, ac.line)
    else if (std.mem.eql(u8, ac.line_type, "old"))
        resolver.resolveOldLine(ac.file, ac.line)
    else
        null; // Invalid line_type - should have been caught earlier

    if (resolved == null) {
        // Build descriptive error message with available lines
        const line_info = try resolver.getLineNumbersForFile(allocator, ac.file);
        defer if (line_info) |info| {
            allocator.free(info.new_lines);
            allocator.free(info.old_lines);
        };

        var error_msg = std.ArrayList(u8).init(allocator);
        defer error_msg.deinit();

        const writer = error_msg.writer();
        try writer.print("Line {d} not found in {s} version of {s}", .{
            ac.line,
            ac.line_type,
            ac.file,
        });

        if (line_info) |info| {
            const target_lines = if (std.mem.eql(u8, ac.line_type, "new"))
                info.new_lines
            else
                info.old_lines;

            if (target_lines.len > 0) {
                try writer.writeAll(". Lines in diff: ");
                try formatLineRanges(writer, target_lines);
            } else {
                try writer.writeAll(". No lines of this type in diff");
            }
        }

        const error_str = try error_msg.toOwnedSlice();
        defer allocator.free(error_str);

        try mcp.sendCommentAdded(false, null, error_str);
        return null;
    }

    const resolved_line = resolved.?;

    // Get line context
    const file = &files[resolved_line.file_idx];
    const hunk = &file.hunks[resolved_line.hunk_idx];
    const line = &hunk.lines[resolved_line.line_idx];
    const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

    // Add the comment
    try comment_store.addComment(
        file_path,
        resolved_line.hunk_idx,
        resolved_line.line_idx,
        ac.text,
        line.line_type,
        line.content,
        line.old_lineno,
        line.new_lineno,
    );

    // Get the new comment index (last one added)
    const comment_count = comment_store.comments.items.len;
    const comment_idx = if (comment_count > 0) comment_count - 1 else 0;

    // Send success response
    try mcp.sendCommentAdded(true, comment_idx, null);

    return comment_idx;
}

/// Helper function to format line ranges (e.g., "10-50, 100-120, 200")
fn formatLineRanges(writer: anytype, lines: []const u32) !void {
    if (lines.len == 0) return;

    var i: usize = 0;
    var range_count: usize = 0;

    while (i < lines.len) {
        if (range_count > 0) try writer.writeAll(", ");

        const start = lines[i];
        var end = start;

        // Find consecutive lines
        while (i + 1 < lines.len and lines[i + 1] == lines[i] + 1) {
            i += 1;
            end = lines[i];
        }

        if (start == end) {
            try writer.print("{d}", .{start});
        } else {
            try writer.print("{d}-{d}", .{ start, end });
        }

        i += 1;
        range_count += 1;
    }
}

/// Handle get_comments request - send all comments back
pub fn handleGetComments(
    allocator: Allocator,
    mcp: *mcp_client.McpClient,
    comment_store: *comments.CommentStore,
) !void {
    var comment_infos = std.ArrayList(mcp_protocol.CommentInfo).init(allocator);
    defer comment_infos.deinit();

    const all_comments = comment_store.comments.items;
    for (all_comments, 0..) |comment, idx| {
        // Determine which line number and type flag to use
        const line_number: u32 = if (comment.new_lineno) |new| new else comment.old_lineno orelse 0;
        const line_type_flag: []const u8 = if (comment.new_lineno != null) "new" else "old";

        try comment_infos.append(.{
            .idx = idx,
            .file_path = comment.file_path,
            .line = line_number,
            .text = comment.text,
            .line_type = @tagName(comment.line_type),
            .line_type_flag = line_type_flag,
        });
    }

    try mcp.sendComments(comment_infos.items);
}

/// Handle get_diff_context request - send lightweight diff metadata
pub fn handleGetDiffContext(
    allocator: Allocator,
    mcp: *mcp_client.McpClient,
    files: []parser.FileDiff,
    diff_source: DiffSource,
    git_repo_root: []const u8,
) !void {
    var file_summaries = std.ArrayList(mcp_protocol.DiffFileSummary).init(allocator);
    defer file_summaries.deinit();

    for (files) |file| {
        var additions: usize = 0;
        var deletions: usize = 0;

        // Count additions and deletions
        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .add => additions += 1,
                    .delete => deletions += 1,
                    .context => {},
                }
            }
        }

        // Determine file status
        const status: []const u8 = getFileStatus(file);

        try file_summaries.append(.{
            .path = if (file.new_path.len > 0 and !std.mem.eql(u8, file.new_path, "/dev/null"))
                file.new_path
            else
                file.old_path,
            .old_path = file.old_path,
            .status = status,
            .additions = additions,
            .deletions = deletions,
            .hunk_count = file.hunks.len,
        });
    }

    // Get diff_ref string (use ref1 for two_refs to show the base)
    const diff_ref: []const u8 = switch (diff_source) {
        .working_dir => |wd| if (wd.staged) "staged" else "working",
        .single_ref => |sr| sr.ref,
        .two_refs => |tr| tr.ref1,
    };

    try mcp.sendDiffContext(.{
        .diff_ref = diff_ref,
        .cwd = git_repo_root,
        .files = file_summaries.items,
    });
}

/// Handle get_file_diff request - send full diff content for a specific file
pub fn handleGetFileDiff(
    allocator: Allocator,
    mcp: *mcp_client.McpClient,
    files: []parser.FileDiff,
    requested_file: []const u8,
) !void {
    // Find the requested file in our diff
    var found_file: ?*const parser.FileDiff = null;
    for (files) |*file| {
        const file_path = if (file.new_path.len > 0 and !std.mem.eql(u8, file.new_path, "/dev/null"))
            file.new_path
        else
            file.old_path;

        if (std.mem.eql(u8, file_path, requested_file)) {
            found_file = file;
            break;
        }
    }

    const file = found_file orelse {
        // File not found - send empty response
        try mcp.sendFileDiff(.{
            .file = requested_file,
            .old_file = "",
            .status = "not_found",
            .hunks = &[_]mcp_protocol.DiffHunkInfo{},
        });
        return;
    };

    // Determine file status
    const status: []const u8 = getFileStatus(file.*);

    // Build hunk info array
    var hunks = std.ArrayList(mcp_protocol.DiffHunkInfo).init(allocator);
    defer {
        for (hunks.items) |hunk| {
            allocator.free(hunk.header);
            allocator.free(hunk.lines);
        }
        hunks.deinit();
    }

    for (file.hunks) |hunk| {
        // Build lines array for this hunk
        var lines = std.ArrayList(mcp_protocol.DiffLineInfo).init(allocator);
        errdefer lines.deinit();

        for (hunk.lines) |line| {
            const line_type_str: []const u8 = switch (line.line_type) {
                .add => "add",
                .delete => "delete",
                .context => "context",
            };

            try lines.append(.{
                .line_type = line_type_str,
                .content = line.content,
                .old_lineno = line.old_lineno,
                .new_lineno = line.new_lineno,
            });
        }

        // Build header string like "@@ -10,5 +10,7 @@"
        var header_buf: [128]u8 = undefined;
        const header_slice = std.fmt.bufPrint(&header_buf, "@@ -{d},{d} +{d},{d} @@", .{
            hunk.header.old_start,
            hunk.header.old_count,
            hunk.header.new_start,
            hunk.header.new_count,
        }) catch "@@ ... @@";
        const header_str = try allocator.dupe(u8, header_slice);
        errdefer allocator.free(header_str);

        try hunks.append(.{
            .header = header_str,
            .old_start = hunk.header.old_start,
            .old_count = hunk.header.old_count,
            .new_start = hunk.header.new_start,
            .new_count = hunk.header.new_count,
            .lines = try lines.toOwnedSlice(),
        });
    }

    const file_path = if (file.new_path.len > 0 and !std.mem.eql(u8, file.new_path, "/dev/null"))
        file.new_path
    else
        file.old_path;

    try mcp.sendFileDiff(.{
        .file = file_path,
        .old_file = file.old_path,
        .status = status,
        .hunks = hunks.items,
    });
}

// ===== Helper functions =====

/// Get diff reference string from DiffSource
pub fn getDiffRef(diff_source: DiffSource) []const u8 {
    return switch (diff_source) {
        .working_dir => |wd| if (wd.staged) "staged" else "working",
        .single_ref => |sr| sr.ref,
        .two_refs => |tr| tr.ref2,
    };
}

/// Determine file status string from file diff
fn getFileStatus(file: parser.FileDiff) []const u8 {
    if (file.old_path.len == 0 or std.mem.eql(u8, file.old_path, "/dev/null")) {
        return "added";
    } else if (file.new_path.len == 0 or std.mem.eql(u8, file.new_path, "/dev/null")) {
        return "deleted";
    } else if (!std.mem.eql(u8, file.old_path, file.new_path)) {
        return "renamed";
    } else {
        return "modified";
    }
}
