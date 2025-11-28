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
    // Use LineResolver to translate file:line to hunk coordinates
    const resolver = mcp_line_resolver.LineResolver.init(allocator, files);
    const resolved = resolver.resolve(ac.file, ac.line) orelse {
        // Line not in diff - send error response
        try mcp.sendCommentAdded(false, null, "Line not in diff");
        return null;
    };

    // Get line context
    const file = &files[resolved.file_idx];
    const hunk = &file.hunks[resolved.hunk_idx];
    const line = &hunk.lines[resolved.line_idx];
    const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

    // Add the comment
    try comment_store.addComment(
        file_path,
        resolved.hunk_idx,
        resolved.line_idx,
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
        // Use new_lineno if available, otherwise old_lineno for deleted lines
        const line_number = comment.new_lineno orelse comment.old_lineno orelse 0;
        try comment_infos.append(.{
            .idx = idx,
            .file_path = comment.file_path,
            .line = line_number,
            .text = comment.text,
            .line_type = @tagName(comment.line_type),
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
