//! Controller for the in-process TUI server that answers CLI/MCP requests.
//! Owns the request dispatch and session-metadata sync that back skim's
//! `get_context`/`get_diff`/`add_comment`/`list_comments`/`delete_comment`
//! endpoints. App keeps only lifecycle wiring; these free functions reach
//! through the shared `App` services (state, allocator, session manager,
//! render flag) they genuinely need.

const std = @import("std");
const App = @import("../app.zig").App;
const tui_server = @import("tui_server.zig");
const session_mgr = @import("session.zig");
const line_map = @import("../line_map.zig");
const hunk_view = @import("../hunk_view.zig");
const parser = @import("../git/parser.zig");
const comments = @import("../comments/store.zig");
const skim_io = @import("skim_io");

/// Start TUI server and write session file
pub fn startTuiServer(app: *App) !void {
    // Initialize session manager
    var sm = try session_mgr.SessionManager.init(app.allocator);
    errdefer sm.deinit();

    // Create and start TUI server
    var server = tui_server.TuiServer.init(app.allocator, handleTuiServerRequest, app);
    try server.start();

    const port = server.getPort();
    std.log.info("TUI server started on port {d}", .{port});

    app.tui_server = server;
    app.session_manager = sm;

    // Write initial session metadata once server and manager are registered.
    try writeSessionMetadata(app);
}

/// Handle incoming request from CLI/MCP
pub fn handleTuiServerRequest(request: tui_server.Request, user_data: ?*anyopaque) tui_server.Response {
    const app: *App = @ptrCast(@alignCast(user_data.?));

    if (std.mem.eql(u8, request.method, "get_context")) {
        return handleGetContext(app);
    } else if (std.mem.eql(u8, request.method, "get_diff")) {
        return handleGetDiff(app, request.params);
    } else if (std.mem.eql(u8, request.method, "add_comment")) {
        return handleAddComment(app, request.params);
    } else if (std.mem.eql(u8, request.method, "list_comments")) {
        return handleListComments(app);
    } else if (std.mem.eql(u8, request.method, "delete_comment")) {
        return handleDeleteComment(app, request.params);
    } else if (std.mem.eql(u8, request.method, "reply_comment")) {
        return handleReplyComment(app, request.params);
    }

    return tui_server.errorResponse(tui_server.ErrorCode.METHOD_NOT_FOUND, "Unknown method");
}

pub fn syncSessionMetadata(app: *App) void {
    writeSessionMetadata(app) catch |err| {
        std.log.warn("Failed to sync session metadata: {any}", .{err});
    };
}

/// Get session port (for status display)
pub fn getSessionPort(app: *const App) ?u16 {
    if (app.tui_server) |server| {
        return server.port;
    }
    return null;
}

/// Handle get_context request - returns session state
pub fn handleGetContext(app: *App) tui_server.Response {
    var result: std.json.ObjectMap = .empty;

    // Add diff_ref
    const diff_ref = getDiffRefString(app);
    result.put(app.allocator, "diff_ref", .{ .string = app.allocator.dupe(u8, diff_ref) catch return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed") }) catch {
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed");
    };

    // Add cwd
    result.put(app.allocator, "cwd", .{ .string = app.allocator.dupe(u8, app.state.git_repo_root) catch return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed") }) catch {
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed");
    };

    // Add view_mode
    const view_mode_str = switch (app.state.view_mode) {
        .unified => "unified",
        .side_by_side => "side_by_side",
    };
    result.put(app.allocator, "view_mode", .{ .string = app.allocator.dupe(u8, view_mode_str) catch return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed") }) catch {
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed");
    };

    // Add files array
    var files_arr = std.json.Array.init(app.allocator);
    for (app.state.files) |file| {
        const path = if (file.new_path.len > 0) file.new_path else file.old_path;
        files_arr.append(.{ .string = app.allocator.dupe(u8, path) catch continue }) catch {};
    }
    result.put(app.allocator, "files", .{ .array = files_arr }) catch {};

    // Add comment count
    result.put(app.allocator, "comment_count", .{ .integer = @intCast(app.state.comment_store.comments.items.len) }) catch {};

    return .{ .result = .{ .object = result } };
}

/// Handle get_diff request - returns formatted diff with line numbers
/// Params: { file?: string } - optional file filter
pub fn handleGetDiff(app: *App, params: ?std.json.Value) tui_server.Response {
    // Optional file filter
    const file_filter: ?[]const u8 = blk: {
        const p = params orelse break :blk null;
        if (p != .object) break :blk null;
        const file_val = p.object.get("file") orelse break :blk null;
        if (file_val != .string) break :blk null;
        if (file_val.string.len == 0) break :blk null;
        break :blk file_val.string;
    };

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    const writer = &output.writer;

    for (app.state.files) |*file| {
        const path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Skip if file filter is set and doesn't match
        if (file_filter) |filter| {
            if (!std.mem.eql(u8, path, filter)) continue;
        }

        // File header
        writer.print("=== {s} ===\n", .{path}) catch continue;

        for (file.hunks, 0..) |*hunk, hunk_idx| {
            // Hunk header
            writer.print("\n@@ Hunk {d}: -{d},{d} +{d},{d} @@", .{
                hunk_idx,
                hunk.header.old_start,
                hunk.header.old_count,
                hunk.header.new_start,
                hunk.header.new_count,
            }) catch continue;
            if (hunk.header.context.len > 0) {
                writer.print(" {s}", .{hunk.header.context}) catch {};
            }
            writer.writeAll("\n") catch continue;

            // Lines with line numbers
            for (hunk.lines) |*line| {
                const marker: u8 = switch (line.line_type) {
                    .add => '+',
                    .delete => '-',
                    .context => ' ',
                };

                // Format: "marker old_line new_line | content"
                // e.g. "+     42 | const x = 1;"  (added line, new line 42)
                // e.g. "-  41    | const y = 2;"  (deleted line, old line 41)
                // e.g. "   41 42 | unchanged"     (context line)
                const old_str: []const u8 = if (line.old_lineno) |n| blk: {
                    break :blk std.fmt.allocPrint(app.allocator, "{d: >4}", .{n}) catch "????";
                } else "    ";
                defer if (line.old_lineno != null) app.allocator.free(old_str);

                const new_str: []const u8 = if (line.new_lineno) |n| blk: {
                    break :blk std.fmt.allocPrint(app.allocator, "{d: >4}", .{n}) catch "????";
                } else "    ";
                defer if (line.new_lineno != null) app.allocator.free(new_str);

                writer.print("{c} {s} {s} | {s}\n", .{ marker, old_str, new_str, line.content }) catch continue;
            }
        }
        writer.writeAll("\n") catch {};
    }

    const diff_text = output.toOwnedSlice() catch {
        output.deinit();
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to build diff");
    };

    var result: std.json.ObjectMap = .empty;
    result.put(app.allocator, "diff", .{ .string = diff_text }) catch {
        app.allocator.free(diff_text);
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to build result");
    };
    return .{ .result = .{ .object = result } };
}

/// Handle add_comment request
/// Params: { file: string, line: number, line_type: "new"|"old", text: string }
pub fn handleAddComment(app: *App, params: ?std.json.Value) tui_server.Response {
    const p = params orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing params");
    if (p != .object) return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "params must be object");

    const obj = p.object;

    // Extract parameters
    const file_val = obj.get("file") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'file'");
    const file = if (file_val == .string) file_val.string else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'file' must be string");

    const line_val = obj.get("line") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'line'");
    const line_num: u32 = switch (line_val) {
        .integer => |i| if (i >= 0) @intCast(i) else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line' must be non-negative"),
        else => return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line' must be integer"),
    };

    const line_type_val = obj.get("line_type") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'line_type'");
    const line_type_str = if (line_type_val == .string) line_type_val.string else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line_type' must be string");
    const use_new_lineno = if (std.mem.eql(u8, line_type_str, "new"))
        true
    else if (std.mem.eql(u8, line_type_str, "old"))
        false
    else
        return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line_type' must be 'new' or 'old'");

    const text_val = obj.get("text") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'text'");
    const text = if (text_val == .string) text_val.string else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'text' must be string");

    // Optional: agents identify themselves so the thread reads as an exchange.
    const author = parseAuthor(obj) catch
        return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'author' must be string");

    // Find the file in the diff
    const file_diff = blk: {
        for (app.state.files) |*f| {
            const path = if (f.new_path.len > 0) f.new_path else f.old_path;
            if (std.mem.eql(u8, path, file)) {
                break :blk f;
            }
        }
        return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "File not found in diff");
    };

    // Find the hunk and line by line number
    const line_info: struct { hunk_idx: usize, line_idx: usize, line: *const parser.Line } = blk: {
        for (file_diff.hunks, 0..) |*hunk, hunk_idx| {
            for (hunk.lines, 0..) |*line, line_idx| {
                const target_lineno = if (use_new_lineno) line.new_lineno else line.old_lineno;
                if (target_lineno) |ln| {
                    if (ln == line_num) {
                        break :blk .{ .hunk_idx = hunk_idx, .line_idx = line_idx, .line = line };
                    }
                }
            }
        }
        return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Line not found in diff");
    };

    // Add the comment
    const added_idx = app.state.comment_store.add(.{
        .file_path = file,
        .hunk_idx = line_info.hunk_idx,
        .line_idx = line_info.line_idx,
        .author = author,
        .text = text,
        .line_type = line_info.line.line_type,
        .line_content = line_info.line.content,
        .old_lineno = line_info.line.old_lineno,
        .new_lineno = line_info.line.new_lineno,
    }) catch {
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to add comment");
    };

    // Rebuild LineMap
    app.state.line_map.deinit();
    app.state.line_map = line_map.LineMap.build(
        app.allocator,
        app.state.files,
        &app.state.comment_store,
        hunk_view.convertHunkViewMode(app),
        hunk_view.shouldApplyHunkFiltering(app),
        &app.state.collapsed_folds,
        app.reviewAnchored(),
    ) catch {
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to rebuild line map");
    };
    app.needs_render = true;

    // Auto-scroll to show the new comment (for external callers like CLI/MCP)
    const comment_idx = added_idx;
    if (!userIsTyping(app)) if (app.state.line_map.findLineByCommentIdx(comment_idx)) |comment_line| {
        // Center the comment in the viewport
        const half_viewport = app.state.viewport_height / 2;
        if (comment_line >= half_viewport) {
            app.state.global_scroll_offset = comment_line - half_viewport;
        } else {
            app.state.global_scroll_offset = 0;
        }
        // Also move cursor to the comment line
        app.state.global_cursor_line = comment_line;
    };

    var result: std.json.ObjectMap = .empty;
    result.put(app.allocator, "success", .{ .bool = true }) catch {};
    result.put(app.allocator, "comment_index", .{ .integer = @intCast(comment_idx) }) catch {};
    return .{ .result = .{ .object = result } };
}

/// Handle list_comments request
pub fn handleListComments(app: *App) tui_server.Response {
    var result: std.json.ObjectMap = .empty;

    var comments_arr = std.json.Array.init(app.allocator);
    for (app.state.comment_store.comments.items, 0..) |comment, idx| {
        var comment_obj: std.json.ObjectMap = .empty;
        comment_obj.put(app.allocator, "index", .{ .integer = @intCast(idx) }) catch continue;
        comment_obj.put(app.allocator, "file_path", .{ .string = app.allocator.dupe(u8, comment.file_path) catch continue }) catch continue;
        comment_obj.put(app.allocator, "hunk_idx", .{ .integer = @intCast(comment.hunk_idx) }) catch continue;
        comment_obj.put(app.allocator, "line_idx", .{ .integer = @intCast(comment.line_idx) }) catch continue;
        comment_obj.put(app.allocator, "author", .{ .string = app.allocator.dupe(u8, comment.author) catch continue }) catch continue;
        comment_obj.put(app.allocator, "text", .{ .string = app.allocator.dupe(u8, comment.text) catch continue }) catch continue;

        var replies_arr = std.json.Array.init(app.allocator);
        for (comment.replies.items, 0..) |reply, reply_idx| {
            var reply_obj: std.json.ObjectMap = .empty;
            reply_obj.put(app.allocator, "index", .{ .integer = @intCast(reply_idx) }) catch continue;
            reply_obj.put(app.allocator, "author", .{ .string = app.allocator.dupe(u8, reply.author) catch continue }) catch continue;
            reply_obj.put(app.allocator, "text", .{ .string = app.allocator.dupe(u8, reply.text) catch continue }) catch continue;
            replies_arr.append(.{ .object = reply_obj }) catch {};
        }
        comment_obj.put(app.allocator, "replies", .{ .array = replies_arr }) catch continue;

        comments_arr.append(.{ .object = comment_obj }) catch {};
    }

    result.put(app.allocator, "comments", .{ .array = comments_arr }) catch {};
    return .{ .result = .{ .object = result } };
}

/// Handle reply_comment request - appends a reply to an existing comment thread
/// Params: { index: number, text: string, author?: string }
pub fn handleReplyComment(app: *App, params: ?std.json.Value) tui_server.Response {
    const p = params orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing params");
    if (p != .object) return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "params must be object");

    const obj = p.object;

    const index_val = obj.get("index") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'index'");
    const index: usize = switch (index_val) {
        .integer => |i| if (i >= 0) @intCast(i) else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'index' must be non-negative"),
        else => return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'index' must be integer"),
    };

    const text_val = obj.get("text") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'text'");
    const text = if (text_val == .string) text_val.string else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'text' must be string");
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'text' must not be empty");
    }

    const author = parseAuthor(obj) catch
        return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'author' must be string");

    const reply_idx = app.state.comment_store.addReply(index, author, text) catch |err| switch (err) {
        error.InvalidCommentIndex => return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Invalid comment index"),
        else => return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to add reply"),
    };

    // A reply grows the comment block but does not change the LineMap's record
    // count, so the map stays valid — only the rendered height changes. Expand
    // the thread so the new reply is actually visible.
    if (app.state.comment_store.idAt(index)) |id| {
        app.state.expanded_comments.put(id, {}) catch {};
    }
    app.needs_render = true;

    if (!userIsTyping(app)) if (app.state.line_map.findLineByCommentIdx(index)) |comment_line| {
        app.state.global_cursor_line = comment_line;
        const half_viewport = app.state.viewport_height / 2;
        app.state.global_scroll_offset = if (comment_line >= half_viewport) comment_line - half_viewport else 0;
    };

    var result: std.json.ObjectMap = .empty;
    result.put(app.allocator, "success", .{ .bool = true }) catch {};
    result.put(app.allocator, "reply_index", .{ .integer = @intCast(reply_idx) }) catch {};
    return .{ .result = .{ .object = result } };
}

/// Handle delete_comment request
pub fn handleDeleteComment(app: *App, params: ?std.json.Value) tui_server.Response {
    const p = params orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing params");
    if (p != .object) return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "params must be object");

    const obj = p.object;

    const index_val = obj.get("index") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'index'");
    const index: usize = switch (index_val) {
        .integer => |i| if (i >= 0) @intCast(i) else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'index' must be non-negative"),
        else => return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'index' must be integer"),
    };

    // Delete comment
    app.state.comment_store.deleteComment(index) catch {
        return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Invalid comment index");
    };

    // Rebuild LineMap
    app.state.line_map.deinit();
    app.state.line_map = line_map.LineMap.build(
        app.allocator,
        app.state.files,
        &app.state.comment_store,
        hunk_view.convertHunkViewMode(app),
        hunk_view.shouldApplyHunkFiltering(app),
        &app.state.collapsed_folds,
        app.reviewAnchored(),
    ) catch {
        return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to rebuild line map");
    };
    app.needs_render = true;

    var result: std.json.ObjectMap = .empty;
    result.put(app.allocator, "success", .{ .bool = true }) catch {};
    return .{ .result = .{ .object = result } };
}

// ===== Helper functions =====

/// True while the user is typing in the comment editor. An agent request that
/// moved the cursor or scroll then would yank the viewport out from under a
/// half-written comment — and because the editor is drawn relative to the
/// cursor's record, it would also tear the box away from the block it belongs
/// to. Agent writes still land; only the camera move is suppressed.
fn userIsTyping(app: *App) bool {
    return app.mode == .comment and app.state.active_comment_input != null;
}

/// The `author` param, or the local reviewer's label when the caller omits it.
/// Empty strings fall back too — an unlabelled reply is worse than a wrong one.
fn parseAuthor(obj: std.json.ObjectMap) ![]const u8 {
    const val = obj.get("author") orelse return comments.local_author;
    if (val != .string) return error.InvalidAuthor;
    if (val.string.len == 0) return comments.local_author;
    return val.string;
}

fn writeSessionMetadata(app: *App) !void {
    const sm = &(app.session_manager orelse return);
    const server = &(app.tui_server orelse return);

    var file_list: std.ArrayList([]const u8) = .empty;
    defer file_list.deinit(app.allocator);

    for (app.state.files) |file| {
        const path = if (file.new_path.len > 0) file.new_path else file.old_path;
        try file_list.append(app.allocator, path);
    }

    try sm.writeSession(.{
        .pid = session_mgr.getCurrentPid(),
        .port = server.getPort(),
        .cwd = app.state.git_repo_root,
        .diff_ref = getDiffRefString(app),
        .files = file_list.items,
        .started_at = skim_io.timestamp(),
    });
}

/// Get the diff reference string for display
fn getDiffRefString(app: *App) []const u8 {
    return switch (app.state.diff_source) {
        .working_dir => |wd| if (wd.staged) "staged" else "working",
        .single_ref => |sr| sr.ref,
        .two_refs => "refs",
        .stdin => "stdin",
    };
}
