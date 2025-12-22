const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const state = @import("state.zig");
const AgentState = state.AgentState;
const Message = state.Message;
const InputEditor = @import("input_editor.zig").InputEditor;
const AcpManager = @import("../acp/manager.zig").AcpManager;
const diff_algo = @import("diff.zig");
const DiffLine = diff_algo.DiffLine;

// Import skim's color palette for consistent styling
const rendering_common = @import("../rendering/common.zig");
const Color = rendering_common.Color;

// Gutter width for line numbers in side-by-side diff view
const GUTTER_WIDTH: usize = 5;

// =============================================================================
// Agent Panel Renderer
// =============================================================================

/// Render the agent chat panel
pub fn renderAgentPanel(app: *App, win: vaxis.Window) !void {
    if (win.width == 0 or win.height == 0) return;

    const agent_state = &(app.state.agent_state orelse return);
    const is_focused = app.mode == .agent;

    win.clear();

    // Layout: title (1 row) + messages (variable) + input area (4 rows)
    const title_height: usize = 1;
    const input_height: usize = 4; // Separator + input + blank + footer
    const messages_height = if (win.height > title_height + input_height)
        win.height - title_height - input_height
    else
        1;

    // Render title bar
    try renderTitleBar(app, win, is_focused);

    // Render message history
    const messages_win = win.child(.{
        .x_off = 0,
        .y_off = @intCast(title_height),
        .width = win.width,
        .height = @intCast(messages_height),
    });
    try renderMessages(app, messages_win, agent_state);

    // Render input area
    const input_win = win.child(.{
        .x_off = 0,
        .y_off = @intCast(title_height + messages_height),
        .width = win.width,
        .height = @intCast(input_height),
    });
    try renderInputArea(app, input_win, agent_state.*, is_focused);
}

fn renderTitleBar(app: *App, win: vaxis.Window, is_focused: bool) !void {
    const title = if (is_focused) " Agent [focused] " else " Agent ";

    // Status from ACP connection
    var status_buf: [64]u8 = undefined;
    const status_text = if (app.acp_manager) |mgr| blk: {
        const base_status = switch (mgr.status) {
            .disconnected => " Disconnected",
            .connecting => " Connecting...",
            .connected => " Connected",
            .session_active => " Active",
            .prompting => " Thinking...",
            .failed => " Failed",
        };
        // Show queued message count when prompting
        if (mgr.status == .prompting and mgr.queuedPromptCount() > 0) {
            break :blk std.fmt.bufPrint(&status_buf, " Thinking... ({d} queued)", .{mgr.queuedPromptCount()}) catch base_status;
        }
        break :blk base_status;
    } else " Not connected";

    const title_style = vaxis.Style{
        .fg = .{ .index = 0 }, // black
        .bg = if (is_focused) .{ .index = 5 } else .{ .index = 4 }, // magenta when focused, blue otherwise
        .bold = true,
    };

    // Fill title row with background
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = title_style,
        });
    }

    // Print title
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = title, .style = title_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = 0 });

    // Print status on the right
    const status_style = vaxis.Style{
        .fg = if (app.acp_manager) |mgr|
            switch (mgr.status) {
                .connected, .session_active => .{ .index = 2 }, // green
                .connecting, .prompting => .{ .index = 3 }, // yellow
                .disconnected => .{ .index = 7 }, // white
                .failed => .{ .index = 1 }, // red
            }
        else
            .{ .index = 7 },
        .bg = if (is_focused) .{ .index = 5 } else .{ .index = 4 },
    };

    const status_width = std.unicode.utf8CountCodepoints(status_text) catch status_text.len;
    const title_width = std.unicode.utf8CountCodepoints(title) catch title.len;
    const status_col = if (win.width > title_width + status_width)
        win.width - status_width
    else
        title_width;

    var status_seg = [_]vaxis.Cell.Segment{
        .{ .text = status_text, .style = status_style },
    };
    _ = win.print(&status_seg, .{ .row_offset = 0, .col_offset = @intCast(status_col) });
}

fn renderMessages(app: *App, win: vaxis.Window, agent_state: *AgentState) !void {
    if (win.height == 0) return;

    // If no messages, show placeholder
    if (agent_state.messages.items.len == 0) {
        const placeholder = "No messages yet. Type a prompt and press Enter to send.";
        const placeholder_style = vaxis.Style{
            .fg = .{ .index = 8 }, // dark gray
            .italic = true,
        };
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = placeholder, .style = placeholder_style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(win.height / 2), .col_offset = 1 });
        return;
    }

    // Build wrapped message lines
    var lines: std.ArrayList(MessageLine) = .{};
    defer lines.deinit(app.allocator);

    const wrap_width = if (win.width > 4) win.width - 4 else 1; // Leave margins

    for (agent_state.messages.items) |msg| {
        // Add role header (skip for tool messages - they have their own icon-based header)
        if (msg.role != .tool) {
            try lines.append(app.allocator, .{
                .text = msg.role.label(),
                .style = switch (msg.role) {
                    .user => vaxis.Style{ .fg = .{ .index = 6 }, .bold = true }, // cyan
                    .agent => vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }, // magenta
                    .thinking => vaxis.Style{ .fg = .{ .index = 8 }, .italic = true }, // dark gray italic
                    .system => vaxis.Style{ .fg = .{ .index = 3 }, .bold = true }, // yellow
                    .diff => vaxis.Style{ .fg = .{ .index = 4 }, .bold = true }, // blue
                    .tool => vaxis.Style{ .fg = .{ .index = 2 }, .bold = true }, // green for tools
                },
                .indent = 1,
            });
        }

        // Handle diff messages specially
        if (msg.role == .diff) {
            // Render skim-style file header: "path/to/file.ext  +N -M"
            if (msg.diff_path) |path| {
                if (msg.diff_old) |old_text| {
                    if (msg.diff_new) |new_text| {
                        // Compute stats for file header
                        var diff_result = diff_algo.computeDiff(app.allocator, old_text, new_text) catch {
                            // Fallback to just showing filename
                            try lines.append(app.allocator, .{
                                .text = std.fs.path.basename(path),
                                .style = vaxis.Style{ .fg = Color.white, .bold = true },
                                .indent = 0,
                            });
                            continue;
                        };
                        defer diff_result.deinit();

                        // File header on one line: "path/to/file.ext  +N -M"
                        // This matches skim's file header format
                        var header_buf: [512]u8 = undefined;
                        const header_text = std.fmt.bufPrint(&header_buf, "{s}  +{d} -{d}", .{
                            path,
                            diff_result.additions,
                            diff_result.deletions,
                        }) catch path;

                        try lines.append(app.allocator, .{
                            .text = header_text,
                            .style = vaxis.Style{ .fg = Color.white, .bold = true },
                            .indent = 0,
                        });

                        // Blank line before diff content
                        try lines.append(app.allocator, .{
                            .text = "",
                            .style = .{},
                            .indent = 0,
                        });

                        // Render diff lines with view mode
                        try renderDiffLines(app.allocator, &lines, old_text, new_text, wrap_width, agent_state.diff_view_mode);
                    }
                }
            }
        } else if (msg.role == .tool) {
            // Claude Code style: ⏺ ToolName(args)
            const tool_name = msg.tool_name orelse "Tool";
            const status_icon: []const u8 = switch (msg.tool_status) {
                .pending => "○", // hollow circle for pending
                .running => "◐", // half circle for running
                .completed => "⏺", // filled circle for completed
                .failed => "✗", // X for failed
            };
            const status_style: vaxis.Style = switch (msg.tool_status) {
                .pending => .{ .fg = .{ .index = 3 } }, // yellow
                .running => .{ .fg = .{ .index = 6 } }, // cyan
                .completed => .{ .fg = .{ .index = 2 } }, // green
                .failed => .{ .fg = .{ .index = 1 } }, // red
            };

            // Format: ⏺ Bash(command) or ⏺ Read(file_path)
            var header_buf: [512]u8 = undefined;
            const header_text = blk: {
                if (msg.tool_command) |cmd| {
                    // For Bash: show command (truncate if long)
                    const max_cmd = @min(cmd.len, 60);
                    const truncated = if (cmd.len > 60) "..." else "";
                    break :blk std.fmt.bufPrint(&header_buf, "{s} {s}({s}{s})", .{
                        status_icon,
                        tool_name,
                        cmd[0..max_cmd],
                        truncated,
                    }) catch tool_name;
                } else {
                    // For other tools: show title (usually contains file path)
                    const title = msg.content;
                    break :blk std.fmt.bufPrint(&header_buf, "{s} {s}", .{
                        status_icon,
                        title,
                    }) catch tool_name;
                }
            };
            try lines.append(app.allocator, .{
                .text = header_text,
                .style = status_style,
                .indent = 1,
            });

            // Show result summary: ⎿  (No content) or ⎿  Success
            if (msg.tool_status == .completed or msg.tool_status == .failed) {
                var result_buf: [128]u8 = undefined;
                const result_text = blk: {
                    if (msg.tool_status == .failed) {
                        if (msg.tool_stderr) |stderr| {
                            // Show first line of error
                            var stderr_iter = std.mem.splitScalar(u8, stderr, '\n');
                            if (stderr_iter.next()) |first_line| {
                                const max_len = @min(first_line.len, 80);
                                break :blk std.fmt.bufPrint(&result_buf, "⎿  {s}", .{first_line[0..max_len]}) catch "⎿  Failed";
                            }
                        }
                        break :blk "⎿  Failed";
                    } else {
                        // Completed
                        if (msg.tool_stdout) |stdout| {
                            if (stdout.len == 0) {
                                break :blk "⎿  (No content)";
                            }
                            // Count lines for summary
                            var line_count: usize = 0;
                            var iter = std.mem.splitScalar(u8, stdout, '\n');
                            while (iter.next()) |_| line_count += 1;
                            if (line_count > 1) {
                                break :blk std.fmt.bufPrint(&result_buf, "⎿  ({d} lines)", .{line_count}) catch "⎿  Done";
                            } else {
                                // Single line - show it (truncated)
                                const max_len = @min(stdout.len, 60);
                                const truncated = if (stdout.len > 60) "..." else "";
                                break :blk std.fmt.bufPrint(&result_buf, "⎿  {s}{s}", .{ stdout[0..max_len], truncated }) catch "⎿  Done";
                            }
                        }
                        break :blk "⎿  Done";
                    }
                };
                try lines.append(app.allocator, .{
                    .text = result_text,
                    .style = vaxis.Style{ .fg = .{ .index = 8 } }, // dim
                    .indent = 1,
                });
            }
        } else {
            // Content style (dimmer for thinking)
            const content_style = switch (msg.role) {
                .thinking => vaxis.Style{ .fg = .{ .index = 8 }, .italic = true }, // dark gray italic
                else => vaxis.Style{ .fg = .{ .index = 7 } },
            };

            // Wrap and add content lines
            var content_iter = std.mem.splitScalar(u8, msg.content, '\n');
            while (content_iter.next()) |line| {
                if (line.len == 0) {
                    try lines.append(app.allocator, .{
                        .text = "",
                        .style = .{},
                        .indent = 2,
                    });
                } else {
                    var remaining = line;
                    while (remaining.len > 0) {
                        const chunk_len = @min(remaining.len, wrap_width);
                        try lines.append(app.allocator, .{
                            .text = remaining[0..chunk_len],
                            .style = content_style,
                            .indent = 2,
                        });
                        remaining = remaining[chunk_len..];
                    }
                }
            }
        }

        // Add blank line between messages
        try lines.append(app.allocator, .{
            .text = "",
            .style = .{},
            .indent = 0,
        });
    }

    // Calculate scroll offset
    const max_scroll = if (lines.items.len > win.height)
        lines.items.len - win.height
    else
        0;

    // Use max_scroll if in follow mode, otherwise use stored offset
    const scroll = if (agent_state.follow_bottom)
        max_scroll
    else
        @min(agent_state.scroll_offset, max_scroll);

    // Update stored offset with actual clamped value (for next scroll operation)
    agent_state.updateScrollOffset(scroll, max_scroll);

    // Render visible lines
    const start = scroll;
    const end = @min(start + win.height, lines.items.len);

    var row: usize = 0;
    for (lines.items[start..end]) |line| {
        if (row >= win.height) break;

        var col_offset: usize = line.indent;

        // Fill background for diff lines (entire row) before printing anything
        if (line.fill_bg) {
            for (0..win.width) |col| {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = line.style,
                });
            }
        }

        // Handle unified diff lines - render gutter at render time
        if (line.diff_kind) |kind| {
            // Format: "┃ NNN+ " where NNN is line number, + is sign
            // Gutter style
            const gutter_style: vaxis.Style = switch (kind) {
                .context => .{ .fg = Color.dim },
                .add => .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg },
                .delete => .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg },
            };

            // Print sidebar "┃ "
            var sidebar_seg = [_]vaxis.Cell.Segment{
                .{ .text = "┃ ", .style = .{ .fg = Color.dim } },
            };
            _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 2;

            // Print line number (formatted at render time)
            var num_buf: [8]u8 = undefined;
            const num_text = if (line.diff_line_num) |n|
                std.fmt.bufPrint(&num_buf, "{d:>3}", .{n}) catch "   "
            else
                "   ";
            var num_seg = [_]vaxis.Cell.Segment{
                .{ .text = num_text, .style = gutter_style },
            };
            _ = win.print(&num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Print sign
            if (line.diff_sign) |sign| {
                var sign_buf: [1]u8 = .{sign};
                var sign_seg = [_]vaxis.Cell.Segment{
                    .{ .text = &sign_buf, .style = gutter_style },
                };
                _ = win.print(&sign_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            }
            col_offset += 1;

            // Space after sign
            col_offset += 1;
        } else if (line.sbs_left_kind) |left_kind| {
            // Handle side-by-side diff lines
            const right_kind = line.sbs_right_kind orelse .empty;
            const left_width = line.sbs_left_width;

            // Left gutter style
            const left_gutter_style: vaxis.Style = switch (left_kind) {
                .context, .empty => .{ .fg = Color.dim },
                .delete => .{ .fg = Color.diff_sign_delete },
                .add => .{ .fg = Color.diff_sign_add },
            };

            // Right gutter style
            const right_gutter_style: vaxis.Style = switch (right_kind) {
                .context, .empty => .{ .fg = Color.dim },
                .delete => .{ .fg = Color.diff_sign_delete },
                .add => .{ .fg = Color.diff_sign_add },
            };

            // Left side: "┃ NNN  content"
            var sidebar_seg = [_]vaxis.Cell.Segment{
                .{ .text = "┃ ", .style = .{ .fg = Color.dim } },
            };
            _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 2;

            // Left line number
            var left_num_buf: [8]u8 = undefined;
            const left_num_text = if (line.sbs_left_num) |n|
                std.fmt.bufPrint(&left_num_buf, "{d:>3}", .{n}) catch "   "
            else
                "   ";
            var left_num_seg = [_]vaxis.Cell.Segment{
                .{ .text = left_num_text, .style = left_gutter_style },
            };
            _ = win.print(&left_num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Space after line number
            col_offset += 2;

            // Left content (truncate to width)
            if (line.sbs_left_content) |content| {
                const left_content = if (content.len > left_width) content[0..left_width] else content;
                const left_style: vaxis.Style = if (left_kind == .delete)
                    .{ .fg = Color.white, .bg = Color.diff_delete_bg }
                else
                    .{ .fg = Color.white };
                var left_seg = [_]vaxis.Cell.Segment{
                    .{ .text = left_content, .style = left_style },
                };
                _ = win.print(&left_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            }
            col_offset += left_width;

            // Divider
            var div_seg = [_]vaxis.Cell.Segment{
                .{ .text = "│", .style = .{ .fg = Color.dim } },
            };
            _ = win.print(&div_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 1;

            // Right line number
            var right_num_buf: [8]u8 = undefined;
            const right_num_text = if (line.sbs_right_num) |n|
                std.fmt.bufPrint(&right_num_buf, "{d:>3}", .{n}) catch "   "
            else
                "   ";
            var right_num_seg = [_]vaxis.Cell.Segment{
                .{ .text = right_num_text, .style = right_gutter_style },
            };
            _ = win.print(&right_num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Space after line number
            col_offset += 2;

            // Right content
            if (line.sbs_right_content) |content| {
                const right_style: vaxis.Style = if (right_kind == .add)
                    .{ .fg = Color.white, .bg = Color.diff_add_bg }
                else
                    .{ .fg = Color.white };
                var right_seg = [_]vaxis.Cell.Segment{
                    .{ .text = content, .style = right_style },
                };
                _ = win.print(&right_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            }
            // Don't update col_offset, we're done with this line

            row += 1;
            continue; // Skip normal text rendering for sbs lines
        } else if (line.prefix) |prefix| {
            // Print regular prefix if present
            var prefix_seg = [_]vaxis.Cell.Segment{
                .{ .text = prefix, .style = line.prefix_style orelse line.style },
            };
            _ = win.print(&prefix_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += prefix.len;
        }

        // Print text
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = line.text, .style = line.style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
        row += 1;
    }
}

const MessageLine = struct {
    text: []const u8,
    style: vaxis.Style,
    indent: usize,
    prefix: ?[]const u8 = null, // Optional prefix (e.g., "┃" for diffs)
    prefix_style: ?vaxis.Style = null,
    fill_bg: bool = false, // Fill entire row with background color
    // For unified diff lines: store line number as integer to avoid memory issues
    diff_line_num: ?usize = null, // Line number (formatted at render time)
    diff_sign: ?u8 = null, // '+', '-', or ' '
    diff_kind: ?DiffLine.Kind = null, // For styling
    // For side-by-side diff lines
    sbs_left_num: ?usize = null,
    sbs_left_content: ?[]const u8 = null,
    sbs_left_kind: ?SideLineKind = null,
    sbs_right_num: ?usize = null,
    sbs_right_content: ?[]const u8 = null,
    sbs_right_kind: ?SideLineKind = null,
    sbs_left_width: usize = 0, // Content width for left side
};

const SideLineKind = enum { context, add, delete, empty };

fn renderInputArea(app: *App, win: vaxis.Window, agent_state: AgentState, is_focused: bool) !void {
    if (win.height == 0) return;

    // Check for pending permission prompt
    if (app.acp_manager) |mgr| {
        if (mgr.getPendingPermission()) |perm| {
            try renderPermissionPrompt(win, perm, is_focused);
            return;
        }
    }

    // Layout:
    // Row 0: Separator line
    // Row 1: Prompt "> " and input text
    // Row 2: Footer with mode (left) and keybindings (right) - like vim

    // Row 0: Separator line
    const separator_style = vaxis.Style{ .fg = .{ .index = 8 } };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }

    // Row 1: Prompt and input
    const prompt_style = vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }; // magenta
    var prompt_seg = [_]vaxis.Cell.Segment{
        .{ .text = "> ", .style = prompt_style },
    };
    _ = win.print(&prompt_seg, .{ .row_offset = 1, .col_offset = 1 });

    // Input text
    const text = agent_state.input.getText();
    const input_col: usize = 3;
    const max_input_width = if (win.width > input_col + 2) win.width - input_col - 2 else 1;
    const cursor_pos = agent_state.input.cursor_pos;
    const text_start = if (cursor_pos > max_input_width - 1)
        cursor_pos - (max_input_width - 1)
    else
        0;
    const visible_text = if (text_start < text.len)
        text[text_start..@min(text_start + max_input_width, text.len)]
    else
        "";

    const text_style = vaxis.Style{ .fg = .{ .index = 7 } };
    var text_seg = [_]vaxis.Cell.Segment{
        .{ .text = visible_text, .style = text_style },
    };
    _ = win.print(&text_seg, .{ .row_offset = 1, .col_offset = @intCast(input_col) });

    // Cursor
    if (is_focused) {
        const cursor_screen_pos = cursor_pos - text_start;
        const cursor_col = input_col + cursor_screen_pos;

        if (cursor_col < win.width) {
            const cursor_char = if (cursor_pos < text.len)
                text[cursor_pos .. cursor_pos + 1]
            else
                " ";

            const cursor_style = if (agent_state.input.vim_mode == .insert)
                vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } }
            else
                vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 }, .bold = true };

            win.writeCell(@intCast(cursor_col), 1, .{
                .char = .{ .grapheme = cursor_char, .width = 1 },
                .style = cursor_style,
            });
        }
    }

    // Row 3: Footer with mode (left) and keybindings (right) - vim style
    if (win.height > 3) {
        // Mode text like vim: -- INSERT -- or -- NORMAL --
        const mode_text = switch (agent_state.input.vim_mode) {
            .normal => "-- NORMAL --",
            .insert => "-- INSERT --",
            .visual => "-- VISUAL --",
        };
        const mode_style = vaxis.Style{ .bold = true };

        var mode_seg = [_]vaxis.Cell.Segment{
            .{ .text = mode_text, .style = mode_style },
        };
        _ = win.print(&mode_seg, .{ .row_offset = 3, .col_offset = 0 });

        // Keybindings on the right
        const keybindings = switch (agent_state.input.vim_mode) {
            .insert => "Enter:send  ESC:normal",
            .normal => "i:insert  q:close  v:view  z:fullscreen",
            .visual => "ESC:exit",
        };
        const kb_style = vaxis.Style{ .fg = .{ .index = 8 } };
        const kb_len = keybindings.len;
        const kb_col = if (win.width > kb_len) win.width - kb_len else 0;

        var kb_seg = [_]vaxis.Cell.Segment{
            .{ .text = keybindings, .style = kb_style },
        };
        _ = win.print(&kb_seg, .{ .row_offset = 3, .col_offset = @intCast(kb_col) });
    }
}

// =============================================================================
// Diff Rendering - Skim Style
// =============================================================================
// Renders diffs exactly like skim's main diff view:
// - Sidebar `┃` on left
// - Line number followed by sign (e.g., `187+`)
// - Hunk header with `↕ old_range → new_range`
// - Proper background colors for add/delete lines

/// Render diff lines using skim's exact visual style
fn renderDiffLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(MessageLine),
    old_text: []const u8,
    new_text: []const u8,
    wrap_width: usize,
    view_mode: AgentState.DiffViewMode,
) !void {
    // Compute line-level diff
    var diff_result = try diff_algo.computeDiff(allocator, old_text, new_text);
    defer diff_result.deinit();

    // Calculate line ranges for hunk header
    var old_start: usize = 0;
    var old_end: usize = 0;
    var new_start: usize = 0;
    var new_end: usize = 0;

    for (diff_result.lines) |line| {
        if (line.old_line_num) |n| {
            if (old_start == 0) old_start = n;
            old_end = n;
        }
        if (line.new_line_num) |n| {
            if (new_start == 0) new_start = n;
            new_end = n;
        }
    }

    // Add hunk header: "┃       ↕ old_start-old_end → new_start-new_end"
    var hunk_buf: [128]u8 = undefined;
    const hunk_text = std.fmt.bufPrint(&hunk_buf, "┃       ↕ {d}-{d} → {d}-{d}", .{
        old_start,
        old_end,
        new_start,
        new_end,
    }) catch "┃       ↕ changes";

    try lines.append(allocator, .{
        .text = hunk_text,
        .style = .{ .fg = Color.dim },
        .indent = 0,
    });

    switch (view_mode) {
        .unified => try renderUnifiedDiff(allocator, lines, diff_result.lines, wrap_width),
        .side_by_side => try renderSideBySideDiff(allocator, lines, diff_result.lines, wrap_width),
    }
}

/// Render diff in unified view (like skim's unified mode)
/// Format: ┃ 187+ content here (sign immediately after number)
fn renderUnifiedDiff(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(MessageLine),
    diff_lines: []const DiffLine,
    wrap_width: usize,
) !void {
    _ = wrap_width; // We'll render full lines, let the terminal wrap

    for (diff_lines) |diff_line| {
        // Get line number
        const line_num: ?usize = switch (diff_line.kind) {
            .context, .delete => diff_line.old_line_num,
            .add => diff_line.new_line_num,
        };
        const sign: u8 = switch (diff_line.kind) {
            .context => ' ',
            .add => '+',
            .delete => '-',
        };

        // Styles
        const line_style: vaxis.Style = switch (diff_line.kind) {
            .context => .{ .fg = Color.white },
            .add => .{ .fg = Color.white, .bg = Color.diff_add_bg },
            .delete => .{ .fg = Color.white, .bg = Color.diff_delete_bg },
        };

        const should_fill = diff_line.kind != .context;

        // Store content directly (it's already allocated in diff_result)
        // The rendering loop will format: ┃ NNN+ content
        try lines.append(allocator, .{
            .text = diff_line.content,
            .style = line_style,
            .indent = 0,
            .prefix = null,
            .prefix_style = null,
            .fill_bg = should_fill,
            .diff_line_num = line_num,
            .diff_sign = sign,
            .diff_kind = diff_line.kind,
        });
    }
}

/// Render diff in side-by-side view (like skim's side-by-side mode)
/// Format: ┃ NNN  left_content        │ NNN  right_content
fn renderSideBySideDiff(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(MessageLine),
    diff_lines: []const DiffLine,
    wrap_width: usize,
) !void {
    // Layout: "┃ NNN  " = 6 chars for left gutter, "│ NNN  " = 6 chars for right gutter
    const gutter_size: usize = 6;
    const divider_size: usize = 1;
    const total_gutter = gutter_size * 2 + divider_size; // 13 chars for gutters + divider
    const remaining = if (wrap_width > total_gutter) wrap_width - total_gutter else 2;
    const left_content_width = remaining / 2;

    // Collect left (old) and right (new) lines separately
    var left_lines: std.ArrayList(SideLine) = .{};
    defer left_lines.deinit(allocator);
    var right_lines: std.ArrayList(SideLine) = .{};
    defer right_lines.deinit(allocator);

    for (diff_lines) |diff_line| {
        switch (diff_line.kind) {
            .context => {
                // Context lines appear on both sides
                try left_lines.append(allocator, .{
                    .content = diff_line.content,
                    .line_num = diff_line.old_line_num,
                    .kind = .context,
                });
                try right_lines.append(allocator, .{
                    .content = diff_line.content,
                    .line_num = diff_line.new_line_num,
                    .kind = .context,
                });
            },
            .delete => {
                // Deleted lines only on left
                try left_lines.append(allocator, .{
                    .content = diff_line.content,
                    .line_num = diff_line.old_line_num,
                    .kind = .delete,
                });
                try right_lines.append(allocator, .{
                    .content = "",
                    .line_num = null,
                    .kind = .empty,
                });
            },
            .add => {
                // Added lines only on right
                try left_lines.append(allocator, .{
                    .content = "",
                    .line_num = null,
                    .kind = .empty,
                });
                try right_lines.append(allocator, .{
                    .content = diff_line.content,
                    .line_num = diff_line.new_line_num,
                    .kind = .add,
                });
            },
        }
    }

    // Render paired lines - store data for render-time formatting
    const max_lines = @max(left_lines.items.len, right_lines.items.len);
    for (0..max_lines) |i| {
        const left = if (i < left_lines.items.len) left_lines.items[i] else SideLine{ .content = "", .line_num = null, .kind = .empty };
        const right = if (i < right_lines.items.len) right_lines.items[i] else SideLine{ .content = "", .line_num = null, .kind = .empty };

        // Determine if this line has changes
        const has_change = left.kind == .delete or right.kind == .add;

        // Convert SideLine.Kind to SideLineKind
        const left_kind: SideLineKind = switch (left.kind) {
            .context => .context,
            .add => .add,
            .delete => .delete,
            .empty => .empty,
        };
        const right_kind: SideLineKind = switch (right.kind) {
            .context => .context,
            .add => .add,
            .delete => .delete,
            .empty => .empty,
        };

        // Store data for render-time formatting (avoid stack buffer issues)
        try lines.append(allocator, .{
            .text = "", // Not used for sbs lines
            .style = .{ .fg = Color.white },
            .indent = 0,
            .fill_bg = has_change,
            .sbs_left_num = left.line_num,
            .sbs_left_content = left.content,
            .sbs_left_kind = left_kind,
            .sbs_right_num = right.line_num,
            .sbs_right_content = right.content,
            .sbs_right_kind = right_kind,
            .sbs_left_width = left_content_width,
        });
    }
}

const SideLine = struct {
    content: []const u8,
    line_num: ?usize,
    kind: enum { context, add, delete, empty },
};

// =============================================================================
// Permission Prompt
// =============================================================================

/// Render the permission prompt in the input area
fn renderPermissionPrompt(win: vaxis.Window, perm: *AcpManager.PendingPermission, is_focused: bool) !void {
    _ = is_focused;

    // Separator line
    const separator_style = vaxis.Style{ .fg = .{ .index = 8 } };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }

    // Permission badge
    const badge_style = vaxis.Style{
        .fg = .{ .index = 0 },
        .bg = .{ .index = 3 }, // yellow background
        .bold = true,
    };
    var badge_seg = [_]vaxis.Cell.Segment{
        .{ .text = " PERMISSION ", .style = badge_style },
    };
    _ = win.print(&badge_seg, .{ .row_offset = 1, .col_offset = 1 });

    // Title
    const title_style = vaxis.Style{
        .fg = .{ .index = 7 },
        .bold = true,
    };
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = perm.title, .style = title_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = 1, .col_offset = 14 });

    // Description (if present)
    var row: usize = 2;
    if (perm.description) |desc| {
        const desc_style = vaxis.Style{
            .fg = .{ .index = 8 },
            .italic = true,
        };
        // Truncate if too long
        const max_len = if (win.width > 4) win.width - 4 else 1;
        const truncated = if (desc.len > max_len) desc[0..max_len] else desc;
        var desc_seg = [_]vaxis.Cell.Segment{
            .{ .text = truncated, .style = desc_style },
        };
        _ = win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
        row += 1;
    }

    // Options hint
    const hint_style = vaxis.Style{
        .fg = .{ .index = 2 }, // green
        .bold = true,
    };
    var allow_seg = [_]vaxis.Cell.Segment{
        .{ .text = " y ", .style = vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 2 }, .bold = true } },
        .{ .text = " Allow  ", .style = hint_style },
    };
    _ = win.print(&allow_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

    const deny_style = vaxis.Style{
        .fg = .{ .index = 1 }, // red
        .bold = true,
    };
    var deny_seg = [_]vaxis.Cell.Segment{
        .{ .text = " n ", .style = vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 1 }, .bold = true } },
        .{ .text = " Deny", .style = deny_style },
    };
    _ = win.print(&deny_seg, .{ .row_offset = @intCast(row), .col_offset = 13 });
}
