const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const state = @import("state.zig");
const AgentState = state.AgentState;
const OwnedPlanEntry = state.OwnedPlanEntry;
const Message = state.Message;
const MAX_SLASH_MENU_VISIBLE = state.MAX_SLASH_MENU_VISIBLE;
const InputEditor = @import("input_editor.zig").InputEditor;
const AcpManager = @import("../acp/manager.zig").AcpManager;
const diff_algo = @import("diff.zig");
const DiffLine = diff_algo.DiffLine;
const chat_line_map = @import("chat_line_map.zig");
const ChatLineMap = chat_line_map.ChatLineMap;
const ChatLineRecord = chat_line_map.ChatLineRecord;
const SideLineKind = chat_line_map.SideLineKind;
const protocol = @import("../acp/protocol.zig");

// Import skim's color palette for consistent styling
const rendering_common = @import("../rendering/common.zig");
const Color = rendering_common.Color;

// Gutter width for line numbers in side-by-side diff view
const GUTTER_WIDTH: usize = 5;

// Maximum height for the expandable input area (excluding separator and footer)
const MAX_INPUT_LINES: usize = 30;
// Maximum number of input lines to track (must be >= MAX_INPUT_LINES)
const MAX_TRACKED_LINES: usize = 100;

// Maximum number of plan entries to show (additional entries show "+N more")
const MAX_PLAN_ENTRIES: usize = 5;

// Maximum width for slash command menu
const MAX_SLASH_MENU_WIDTH: usize = 120;

// =============================================================================
// Input Line Utilities
// =============================================================================

/// Information about lines in the input text
const InputLineInfo = struct {
    line_count: usize,
    cursor_row: usize,
    cursor_col: usize,
    lines: [MAX_TRACKED_LINES]LineSpan,
};

const LineSpan = struct {
    start: usize,
    end: usize,
};

/// Analyze input text to get line information
fn getInputLineInfo(text: []const u8, cursor_pos: usize) InputLineInfo {
    var info = InputLineInfo{
        .line_count = 1,
        .cursor_row = 0,
        .cursor_col = 0,
        .lines = undefined,
    };

    // Initialize first line
    info.lines[0] = .{ .start = 0, .end = 0 };

    var current_line: usize = 0;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n') {
            // End current line (only if within bounds)
            if (current_line < MAX_TRACKED_LINES) {
                info.lines[current_line].end = i;
            }

            // Check if cursor is on this line
            if (cursor_pos >= line_start and cursor_pos <= i) {
                info.cursor_row = @min(current_line, MAX_TRACKED_LINES - 1);
                info.cursor_col = cursor_pos - line_start;
            }

            // Start new line
            current_line += 1;
            if (current_line < MAX_TRACKED_LINES) {
                info.lines[current_line] = .{ .start = i + 1, .end = i + 1 };
            }
            line_start = i + 1;
            info.line_count += 1;
        }
    }

    // Handle last line
    if (current_line < MAX_TRACKED_LINES) {
        info.lines[current_line].end = text.len;
    }

    // Check if cursor is on the last line (clamp to max tracked line)
    if (cursor_pos >= line_start) {
        info.cursor_row = @min(current_line, MAX_TRACKED_LINES - 1);
        info.cursor_col = cursor_pos - line_start;
    }

    return info;
}

// =============================================================================
// Agent Panel Renderer
// =============================================================================

/// Render the agent chat panel
pub fn renderAgentPanel(app: *App, win: vaxis.Window) !void {
    if (win.width == 0 or win.height == 0) return;

    const agent_state = &(app.state.agent_state orelse return);
    const is_focused = app.mode == .agent;

    win.clear();

    // Calculate dynamic input height based on content
    const text = agent_state.input.getText();
    const line_info = getInputLineInfo(text, agent_state.input.vim.cursor_pos);
    const visible_lines = @max(3, @min(line_info.line_count, MAX_INPUT_LINES));

    // Calculate plan height (only if visible and has entries)
    const plan_entry_count = agent_state.plan_entries.items.len;
    const plan_height: usize = if (agent_state.plan_visible and plan_entry_count > 0) blk: {
        // Header (1) + entries (up to MAX_PLAN_ENTRIES) + optional "+N more" line (1)
        const visible_entries = @min(plan_entry_count, MAX_PLAN_ENTRIES);
        const has_more = plan_entry_count > MAX_PLAN_ENTRIES;
        break :blk 1 + visible_entries + @as(usize, if (has_more) 1 else 0);
    } else 0;

    // Calculate input area height (always shows normal input)
    // In sidebar mode, skip the footer (main status bar is visible)
    const footer_height: usize = if (agent_state.full_screen) 1 else 0;
    const input_height: usize = 1 + visible_lines + footer_height; // Separator + visible lines + footer (if full-screen)

    // Layout: title (1 row) + messages (variable) + plan (conditional) + input area (dynamic)
    const title_height: usize = 1;
    const fixed_height = title_height + plan_height + input_height;
    const messages_height = if (win.height > fixed_height)
        win.height - fixed_height
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

    // Render plan area (if visible and has entries)
    if (plan_height > 0) {
        const plan_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(title_height + messages_height),
            .width = win.width,
            .height = @intCast(plan_height),
        });
        renderPlanArea(plan_win, agent_state.plan_entries.items);
    }

    // Render input area
    const input_win = win.child(.{
        .x_off = 0,
        .y_off = @intCast(title_height + messages_height + plan_height),
        .width = win.width,
        .height = @intCast(input_height),
    });
    try renderInputArea(app, input_win, agent_state, is_focused, line_info);

    // Render slash command menu as overlay (if visible)
    if (agent_state.slash_menu_visible) {
        try renderSlashMenu(win, agent_state, title_height + messages_height + plan_height);
    }

    // Render permission prompt as overlay (if pending)
    if (app.acp_manager) |mgr| {
        if (mgr.getPendingPermission()) |perm| {
            try renderPermissionOverlay(win, perm, title_height + messages_height);
        }
    }
}

fn renderTitleBar(app: *App, win: vaxis.Window, is_focused: bool) !void {
    const title = if (is_focused) " Agent [focused] " else " Agent ";

    // Status from ACP connection
    var status_buf: [64]u8 = undefined;
    const status_text = if (app.acp_manager) |mgr| blk: {
        const base_status = switch (mgr.status) {
            .disconnected => " Disconnected",
            .discovering => " Discovering...",
            .connecting => " Connecting...",
            .connected => " Creating session...",
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
                .session_active => .{ .index = 2 }, // green
                .discovering, .connecting, .connected, .prompting => .{ .index = 3 }, // yellow (still loading)
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

    // Clear the message area to remove any overlay artifacts
    win.clear();

    // Check agent connection status
    const is_thinking = if (app.acp_manager) |mgr| mgr.status == .prompting else false;
    // Note: .connected is included because createSession() still runs after connect() sets .connected
    const is_loading = if (app.acp_manager) |mgr| mgr.status == .discovering or mgr.status == .connecting or mgr.status == .connected else false;

    // If no messages, show status-aware placeholder
    if (agent_state.messages.items.len == 0) {
        if (is_loading) {
            // Show prominent loading status in center
            const loading_text = if (app.acp_manager) |mgr| switch (mgr.status) {
                .discovering => "Discovering agent...",
                .connecting => "Connecting to agent...",
                .connected => "Creating session...",
                else => "Initializing...",
            } else "Initializing...";
            const loading_style = vaxis.Style{
                .fg = .{ .index = 3 }, // yellow
                .bold = true,
            };
            var seg = [_]vaxis.Cell.Segment{
                .{ .text = loading_text, .style = loading_style },
            };
            const text_len = loading_text.len;
            const col = if (win.width > text_len) (win.width - text_len) / 2 else 0;
            _ = win.print(&seg, .{ .row_offset = @intCast(win.height / 2), .col_offset = @intCast(col) });
        } else if (!is_thinking) {
            const placeholder = "Type a prompt and press Enter to send.";
            const placeholder_style = vaxis.Style{
                .fg = .{ .index = 8 }, // dark gray
                .italic = true,
            };
            var seg = [_]vaxis.Cell.Segment{
                .{ .text = placeholder, .style = placeholder_style },
            };
            const text_len = placeholder.len;
            const col = if (win.width > text_len) (win.width - text_len) / 2 else 0;
            _ = win.print(&seg, .{ .row_offset = @intCast(win.height / 2), .col_offset = @intCast(col) });
        }
        // Show thinking indicator at bottom when thinking (even with no messages)
        if (is_thinking and win.height > 0) {
            renderThinkingIndicator(win, win.height - 1);
        }
        return;
    }

    // Get the pre-computed line map (builds if dirty)
    const wrap_width = if (win.width > 4) win.width - 4 else 1;
    const line_map = agent_state.ensureLineMap(wrap_width) catch {
        // Fallback: show error message
        var err_seg = [_]vaxis.Cell.Segment{
            .{ .text = "Error building line map", .style = .{ .fg = .{ .index = 1 } } },
        };
        _ = win.print(&err_seg, .{ .row_offset = 0, .col_offset = 1 });
        return;
    };

    // Calculate scroll offset
    const total_lines = line_map.getTotalLines();
    const max_scroll = if (total_lines > win.height)
        total_lines - win.height
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
    const end = @min(start + win.height, total_lines);

    var row: usize = 0;
    for (start..end) |line_idx| {
        if (row >= win.height) break;

        const record = line_map.getLineRecord(line_idx) orelse continue;

        var col_offset: usize = record.indent;

        // Fill background for diff lines (entire row) before printing anything
        if (record.fill_bg) {
            for (0..win.width) |col| {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = record.style,
                });
            }
        }

        // Handle unified diff lines - render gutter at render time
        if (record.diff_kind) |kind| {
            // Format: "┃ NNN+ " where NNN is line number, + is sign
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

            // Print line number (use pre-formatted string to avoid buffer reuse issues)
            const num_text = record.diff_line_num_str orelse "   ";
            var num_seg = [_]vaxis.Cell.Segment{
                .{ .text = num_text, .style = gutter_style },
            };
            _ = win.print(&num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Print sign (use static string to avoid buffer reuse issues)
            const sign_text: []const u8 = if (record.diff_sign) |sign| switch (sign) {
                '+' => "+",
                '-' => "-",
                else => " ",
            } else " ";
            var sign_seg = [_]vaxis.Cell.Segment{
                .{ .text = sign_text, .style = gutter_style },
            };
            _ = win.print(&sign_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 1;

            // Space after sign
            col_offset += 1;
        } else if (record.sbs_left_kind) |left_kind| {
            // Handle side-by-side diff lines
            const right_kind = record.sbs_right_kind orelse .empty;
            const left_width = record.sbs_left_width;

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

            // Left line number (use pre-formatted string to avoid buffer reuse issues)
            const left_num_text = record.sbs_left_num_str orelse "   ";
            var left_num_seg = [_]vaxis.Cell.Segment{
                .{ .text = left_num_text, .style = left_gutter_style },
            };
            _ = win.print(&left_num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Space after line number
            col_offset += 2;

            // Left content (truncate to width)
            if (record.sbs_left_content) |content| {
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

            // Right line number (use pre-formatted string to avoid buffer reuse issues)
            const right_num_text = record.sbs_right_num_str orelse "   ";
            var right_num_seg = [_]vaxis.Cell.Segment{
                .{ .text = right_num_text, .style = right_gutter_style },
            };
            _ = win.print(&right_num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Space after line number
            col_offset += 2;

            // Right content
            if (record.sbs_right_content) |content| {
                const right_style: vaxis.Style = if (right_kind == .add)
                    .{ .fg = Color.white, .bg = Color.diff_add_bg }
                else
                    .{ .fg = Color.white };
                var right_seg = [_]vaxis.Cell.Segment{
                    .{ .text = content, .style = right_style },
                };
                _ = win.print(&right_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            }

            row += 1;
            continue; // Skip normal text rendering for sbs lines
        } else if (record.prefix) |prefix| {
            // Print regular prefix if present
            var prefix_seg = [_]vaxis.Cell.Segment{
                .{ .text = prefix, .style = record.prefix_style orelse record.style },
            };
            _ = win.print(&prefix_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += prefix.len;
        }

        // Print text
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = record.text, .style = record.style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
        row += 1;
    }

    // Show thinking indicator at the bottom of the message area (just above input)
    if (is_thinking and win.height > 0) {
        renderThinkingIndicator(win, win.height - 1);
    }
}

/// Render a shimmering "Generating..." indicator
fn renderThinkingIndicator(win: vaxis.Window, row: usize) void {
    if (win.width < 20 or row >= win.height) return;

    const now = std.time.milliTimestamp();
    const text = "Generating...";
    const shimmer_speed: i64 = 80;
    const phase: usize = @intCast(@mod(@divFloor(now, shimmer_speed), 10));

    var col: usize = 2;
    for (text, 0..) |_, idx| {
        if (col >= win.width) break;

        // Wave of brightness that travels across the text
        const pos_offset = (idx + phase) % 10;
        const brightness: u8 = switch (pos_offset) {
            0 => 255,
            1 => 230,
            2 => 190,
            3 => 150,
            4, 5 => 120,
            6 => 150,
            7 => 190,
            8 => 230,
            9 => 255,
            else => 120,
        };

        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = text[idx .. idx + 1], .width = 1 },
            .style = .{ .fg = .{ .rgb = .{ brightness, brightness, brightness } } },
        });
        col += 1;
    }
}

// =============================================================================
// Slash Command Menu
// =============================================================================

/// Render the slash command menu as a popup above the input area
fn renderSlashMenu(win: vaxis.Window, agent_state: *AgentState, input_top: usize) !void {
    // Get filtered commands
    var indices: [32]usize = undefined;
    const filtered_count = agent_state.getFilteredCommandIndices(&indices);

    if (filtered_count == 0) return;

    // Calculate menu dimensions with scroll support
    const visible_count = @min(filtered_count, MAX_SLASH_MENU_VISIBLE);
    const max_scroll = if (filtered_count > visible_count) filtered_count - visible_count else 0;
    const scroll_offset = @min(agent_state.slash_menu_scroll_offset, max_scroll);
    const menu_height = visible_count + 2; // +2 for top/bottom border
    const menu_width = @min(win.width -| 4, MAX_SLASH_MENU_WIDTH); // leave some margin

    // Position menu just above the input area
    const menu_y = if (input_top > menu_height) input_top - menu_height else 0;
    const menu_x: usize = 2; // Small left margin

    // Create menu window
    const menu_win = win.child(.{
        .x_off = @intCast(menu_x),
        .y_off = @intCast(menu_y),
        .width = @intCast(menu_width),
        .height = @intCast(menu_height),
    });

    // Draw menu background and border (neutral colors)
    const border_style = vaxis.Style{ .fg = .{ .index = 8 } }; // gray
    const bg_style = vaxis.Style{ .bg = .{ .index = 0 } }; // black background

    // Fill background
    for (0..menu_height) |row| {
        for (0..menu_width) |col| {
            menu_win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = bg_style,
            });
        }
    }

    // Top border: ┌─ Commands ─────────────────────────────┐
    // Add scroll indicator (▲) if there are items above
    const has_more_above = scroll_offset > 0;
    menu_win.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = border_style });
    menu_win.writeCell(@intCast(menu_width - 1), 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = border_style });

    // Draw header: "─ Commands " then fill rest with "─", add scroll indicator at end
    const header_parts = [_][]const u8{ "─", " ", "C", "o", "m", "m", "a", "n", "d", "s", " " };
    for (1..menu_width - 1) |col| {
        const char_idx = col - 1;
        // Show ▲ indicator near the right if there are more items above
        const char: []const u8 = if (has_more_above and col == menu_width - 4)
            "▲"
        else if (char_idx < header_parts.len)
            header_parts[char_idx]
        else
            "─";
        menu_win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = char, .width = 1 },
            .style = border_style,
        });
    }

    // Bottom border - add scroll indicator (▼) if there are items below
    const has_more_below = scroll_offset + visible_count < filtered_count;
    menu_win.writeCell(0, @intCast(menu_height - 1), .{ .char = .{ .grapheme = "└", .width = 1 }, .style = border_style });
    menu_win.writeCell(@intCast(menu_width - 1), @intCast(menu_height - 1), .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = border_style });
    for (1..menu_width - 1) |col| {
        // Show ▼ indicator near the right if there are more items below
        const char: []const u8 = if (has_more_below and col == menu_width - 4) "▼" else "─";
        menu_win.writeCell(@intCast(col), @intCast(menu_height - 1), .{
            .char = .{ .grapheme = char, .width = 1 },
            .style = border_style,
        });
    }

    // Side borders
    for (1..menu_height - 1) |row| {
        menu_win.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
        menu_win.writeCell(@intCast(menu_width - 1), @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
    }

    // Clamp selection to valid range
    const selection = @min(agent_state.slash_menu_selection, filtered_count - 1);

    // Render command items (with scroll offset applied)
    for (0..visible_count) |i| {
        const item_idx = scroll_offset + i;
        if (item_idx >= filtered_count) break;

        const cmd_idx = indices[item_idx];
        const cmd = &agent_state.available_commands.items[cmd_idx];
        const is_selected = (item_idx == selection);
        const row = i + 1; // +1 for top border

        // Style based on selection (neutral colors)
        const name_style: vaxis.Style = if (is_selected)
            .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 }, .bold = true } // inverted white
        else
            .{ .fg = .{ .index = 7 }, .bold = true }; // white

        const desc_style: vaxis.Style = if (is_selected)
            .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } } // inverted
        else
            .{ .fg = .{ .index = 8 } }; // dim

        // Fill row background if selected
        if (is_selected) {
            for (1..menu_width - 1) |col| {
                menu_win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = .{ .index = 7 } }, // white background
                });
            }
        }

        // Format: " /command  description"
        var col: usize = 2;

        // Print "/" prefix
        var slash_seg = [_]vaxis.Cell.Segment{
            .{ .text = "/", .style = name_style },
        };
        _ = menu_win.print(&slash_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        col += 1;

        // Print command name (truncate if needed)
        const max_name_len = @min(cmd.name.len, 20);
        const name_text = cmd.name[0..max_name_len];
        var name_seg = [_]vaxis.Cell.Segment{
            .{ .text = name_text, .style = name_style },
        };
        _ = menu_win.print(&name_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        col += max_name_len + 2; // +2 for spacing

        // Print description (truncate to fit)
        const remaining_width = if (menu_width > col + 3) menu_width - col - 3 else 0;
        if (remaining_width > 0 and cmd.description.len > 0) {
            const desc_len = @min(cmd.description.len, remaining_width);
            const desc_text = cmd.description[0..desc_len];
            var desc_seg = [_]vaxis.Cell.Segment{
                .{ .text = desc_text, .style = desc_style },
            };
            _ = menu_win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        }
    }
}

// =============================================================================
// Plan Area
// =============================================================================

/// Render the agent plan area (todo list from agent)
fn renderPlanArea(win: vaxis.Window, entries: []const OwnedPlanEntry) void {
    if (win.height == 0 or entries.len == 0) return;

    var row: usize = 0;

    // Header line: "── Todos ──"
    const header_style = vaxis.Style{ .fg = .{ .index = 8 }, .bold = true };

    // Draw leading dashes at columns 1-2
    win.writeCell(1, @intCast(row), .{
        .char = .{ .grapheme = "─", .width = 1 },
        .style = header_style,
    });
    win.writeCell(2, @intCast(row), .{
        .char = .{ .grapheme = "─", .width = 1 },
        .style = header_style,
    });

    // Draw " Todos " text starting at column 3
    const title_text = " Todos ";
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = title_text, .style = header_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });

    // Fill rest of header with ─ (starting after "── Todos " = 3 + 7 = 10)
    const header_end: usize = 10;
    if (win.width > header_end) {
        for (header_end..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = header_style,
            });
        }
    }
    row += 1;

    // Render entries (up to MAX_PLAN_ENTRIES)
    const visible_count = @min(entries.len, MAX_PLAN_ENTRIES);
    for (entries[0..visible_count]) |entry| {
        if (row >= win.height) break;

        // Status icon
        const status_icon: []const u8 = switch (entry.status) {
            .pending => "○",
            .in_progress => "◉",
            .completed => "✓",
        };

        // Status color
        const status_style: vaxis.Style = switch (entry.status) {
            .pending => .{ .fg = .{ .index = 8 } }, // dim
            .in_progress => .{ .fg = .{ .index = 3 }, .bold = true }, // yellow
            .completed => .{ .fg = .{ .index = 2 } }, // green
        };

        // Content style (strikethrough for completed)
        const content_style: vaxis.Style = switch (entry.status) {
            .completed => .{ .fg = .{ .index = 8 } }, // dim for completed
            else => .{ .fg = .{ .index = 7 } }, // normal
        };

        // Print status icon
        var icon_seg = [_]vaxis.Cell.Segment{
            .{ .text = status_icon, .style = status_style },
        };
        _ = win.print(&icon_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });

        // Print content (truncate if needed)
        const max_content_len = if (win.width > 6) win.width - 6 else 1;
        const content = if (entry.content.len > max_content_len)
            entry.content[0..max_content_len]
        else
            entry.content;

        var content_seg = [_]vaxis.Cell.Segment{
            .{ .text = content, .style = content_style },
        };
        _ = win.print(&content_seg, .{ .row_offset = @intCast(row), .col_offset = 4 });

        row += 1;
    }

    // "+N more" line if there are hidden entries
    if (entries.len > MAX_PLAN_ENTRIES and row < win.height) {
        var more_buf: [16]u8 = undefined;
        const remaining = entries.len - MAX_PLAN_ENTRIES;
        const more_text = std.fmt.bufPrint(&more_buf, "+{d} more", .{remaining}) catch "+? more";

        const more_style = vaxis.Style{ .fg = .{ .index = 8 }, .italic = true };
        var more_seg = [_]vaxis.Cell.Segment{
            .{ .text = more_text, .style = more_style },
        };
        _ = win.print(&more_seg, .{ .row_offset = @intCast(row), .col_offset = 4 });
    }
}

fn renderInputArea(app: *App, win: vaxis.Window, agent_state: *AgentState, is_focused: bool, line_info: InputLineInfo) !void {
    if (win.height == 0) return;

    const text = agent_state.input.getText();
    const total_lines = @min(line_info.line_count, MAX_TRACKED_LINES);
    const visible_lines = @min(total_lines, MAX_INPUT_LINES);

    // Calculate scroll offset to keep cursor in view
    var scroll_offset = agent_state.input_scroll_offset;
    const cursor_row = line_info.cursor_row;

    // Scroll up if cursor is above visible area
    if (cursor_row < scroll_offset) {
        scroll_offset = cursor_row;
    }
    // Scroll down if cursor is below visible area (keep 1 line margin at bottom)
    if (cursor_row >= scroll_offset + visible_lines) {
        scroll_offset = cursor_row - visible_lines + 1;
    }
    // Clamp scroll offset to valid range
    const max_scroll = if (total_lines > visible_lines) total_lines - visible_lines else 0;
    scroll_offset = @min(scroll_offset, max_scroll);

    // Update stored scroll offset
    agent_state.input_scroll_offset = scroll_offset;

    // Layout:
    // Row 0: Separator line
    // Rows 1..visible_lines: Input lines with "> " prompt on first line
    // Last row: Footer with mode (left) and keybindings (right)

    // Row 0: Separator line
    const separator_style = vaxis.Style{ .fg = .{ .index = 8 } };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }

    const prompt_style = vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }; // magenta
    const text_style = vaxis.Style{ .fg = .{ .index = 7 } };
    const input_col: usize = 3; // After "> "
    const max_input_width = if (win.width > input_col + 1) win.width - input_col - 1 else 1;

    // Render each visible line
    for (0..visible_lines) |display_idx| {
        const line_idx = scroll_offset + display_idx;
        if (line_idx >= total_lines) break;

        const row = display_idx + 1; // +1 for separator

        // First line in buffer (line_idx == 0) gets the prompt "> "
        if (line_idx == 0) {
            var prompt_seg = [_]vaxis.Cell.Segment{
                .{ .text = "> ", .style = prompt_style },
            };
            _ = win.print(&prompt_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        } else {
            // Continuation lines get "  " for alignment
            var cont_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  ", .style = text_style },
            };
            _ = win.print(&cont_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        }

        // Get this line's content
        const line_span = line_info.lines[line_idx];
        const line_text = if (line_span.start < text.len)
            text[line_span.start..@min(line_span.end, text.len)]
        else
            "";

        // Calculate horizontal scroll for this line (only if cursor is on this line)
        var text_start: usize = 0;
        if (line_idx == line_info.cursor_row and line_info.cursor_col >= max_input_width) {
            text_start = line_info.cursor_col - (max_input_width - 1);
        }

        // Get visible portion of line
        const visible_text = if (text_start < line_text.len)
            line_text[text_start..@min(text_start + max_input_width, line_text.len)]
        else
            "";

        // Check for visual mode selection highlighting
        const vim_mode = agent_state.input.vim.vim_mode;
        const visual_anchor = agent_state.input.vim.visual_anchor;

        if (vim_mode == .visual) {
            if (visual_anchor) |anchor| {
                // Calculate visual selection range
                const cursor = agent_state.input.vim.cursor_pos;
                const sel_start = @min(anchor, cursor);
                const sel_end = @max(anchor, cursor);

                // Visual selection style - cyan background for visibility on black
                const visual_style = vaxis.Style{
                    .fg = .{ .index = 0 }, // black text
                    .bg = .{ .index = 6 }, // cyan background
                    .bold = true,
                };

                // Render each character, applying visual style where needed
                const line_start_abs = line_span.start;
                for (visible_text, 0..) |_, char_idx| {
                    const abs_pos = line_start_abs + text_start + char_idx;
                    const col = input_col + char_idx;
                    if (col >= win.width) break;

                    // Is this character in the visual selection?
                    const in_selection = abs_pos >= sel_start and abs_pos <= sel_end;
                    const style = if (in_selection) visual_style else text_style;

                    win.writeCell(@intCast(col), @intCast(row), .{
                        .char = .{ .grapheme = visible_text[char_idx .. char_idx + 1], .width = 1 },
                        .style = style,
                    });
                }
            } else {
                // No anchor yet, render normally
                var text_seg = [_]vaxis.Cell.Segment{
                    .{ .text = visible_text, .style = text_style },
                };
                _ = win.print(&text_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(input_col) });
            }
        } else {
            // Normal rendering for non-visual modes
            var text_seg = [_]vaxis.Cell.Segment{
                .{ .text = visible_text, .style = text_style },
            };
            _ = win.print(&text_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(input_col) });
        }

        // Render cursor if it's on this line
        if (is_focused and line_idx == line_info.cursor_row) {
            const cursor_screen_col = line_info.cursor_col - text_start;
            const cursor_col = input_col + cursor_screen_col;

            if (cursor_col < win.width) {
                const cursor_char = if (line_info.cursor_col < line_text.len)
                    line_text[line_info.cursor_col .. line_info.cursor_col + 1]
                else
                    " ";

                const cursor_style = if (agent_state.input.vim.vim_mode == .insert)
                    vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } }
                else
                    vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 }, .bold = true };

                win.writeCell(@intCast(cursor_col), @intCast(row), .{
                    .char = .{ .grapheme = cursor_char, .width = 1 },
                    .style = cursor_style,
                });
            }
        }
    }

    // Footer row: mode (left), session mode (center), and keybindings (right)
    // Only render footer in full-screen mode (sidebar mode uses the main status bar)
    if (!agent_state.full_screen) return;

    const footer_row = win.height - 1;
    if (win.height > 1) {
        // Mode text like vim: -- INSERT -- or -- NORMAL --
        const mode_text = switch (agent_state.input.vim.vim_mode) {
            .normal => "-- NORMAL --",
            .insert => "-- INSERT --",
            .visual => "-- VISUAL --",
            .command => "-- COMMAND --",
        };
        const mode_style = vaxis.Style{ .bold = true };

        var mode_seg = [_]vaxis.Cell.Segment{
            .{ .text = mode_text, .style = mode_style },
        };
        _ = win.print(&mode_seg, .{ .row_offset = @intCast(footer_row), .col_offset = 0 });

        // Session mode display (after vim mode) - only if modes are available
        var session_mode_buf: [32]u8 = undefined;
        var session_mode_text: ?[]const u8 = null;

        if (app.acp_manager) |mgr| {
            if (mgr.hasModes()) {
                const mode_name = mgr.getCurrentModeName();
                if (mode_name.len > 0) {
                    session_mode_text = std.fmt.bufPrint(&session_mode_buf, " [{s}]", .{mode_name}) catch null;
                }
            }
        }

        if (session_mode_text) |sm_text| {
            const sm_style = vaxis.Style{ .fg = .{ .index = 6 }, .bold = true }; // cyan
            var sm_seg = [_]vaxis.Cell.Segment{
                .{ .text = sm_text, .style = sm_style },
            };
            _ = win.print(&sm_seg, .{ .row_offset = @intCast(footer_row), .col_offset = 13 });
        }

        // Keybindings on the right (include mode hint if modes available)
        // In normal mode, 'm' cycles modes (S-Tab in insert mode for terminals with kitty keyboard)
        const has_modes = if (app.acp_manager) |mgr| mgr.hasModes() else false;
        const keybindings = switch (agent_state.input.vim.vim_mode) {
            .insert => if (has_modes) "S-Tab:mode  Enter:send  ESC:normal" else "S-Enter:newline  Enter:send  ESC:normal",
            .normal => if (has_modes) "m:mode  i:insert  q:close  ,d:diff" else "i:insert  q:close  ,d:diff  z:full",
            .visual => "ESC:exit",
            .command => "Enter:execute  ESC:cancel",
        };
        const kb_style = vaxis.Style{ .fg = .{ .index = 8 } };
        const kb_len = keybindings.len;
        const kb_col = if (win.width > kb_len) win.width - kb_len else 0;

        var kb_seg = [_]vaxis.Cell.Segment{
            .{ .text = keybindings, .style = kb_style },
        };
        _ = win.print(&kb_seg, .{ .row_offset = @intCast(footer_row), .col_offset = @intCast(kb_col) });
    }
}

// =============================================================================
// Permission Prompt Overlay
// =============================================================================

/// Render the permission prompt as an overlay popup above the input/plan area
fn renderPermissionOverlay(win: vaxis.Window, perm: *AcpManager.PendingPermission, overlay_bottom: usize) !void {
    // Calculate menu dimensions
    const desc_rows: usize = if (perm.description != null) 1 else 0;
    const menu_height = 2 + desc_rows + perm.options.len + 2; // border + badge/title + desc + options + hint + border
    const menu_width = @min(win.width -| 4, 70);

    // Position menu just above the overlay_bottom position
    const menu_y = if (overlay_bottom > menu_height) overlay_bottom - menu_height else 0;
    const menu_x: usize = 2; // Small left margin

    // Create menu window
    const menu_win = win.child(.{
        .x_off = @intCast(menu_x),
        .y_off = @intCast(menu_y),
        .width = @intCast(menu_width),
        .height = @intCast(menu_height),
    });

    // Draw menu background and border
    const border_style = vaxis.Style{ .fg = .{ .index = 3 } }; // yellow
    const bg_style = vaxis.Style{ .bg = .{ .index = 0 } }; // black background

    // Fill background
    for (0..menu_height) |row| {
        for (0..menu_width) |col| {
            menu_win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = bg_style,
            });
        }
    }

    // Top border: ┌─ Permission ─────────────────────────────┐
    menu_win.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = border_style });
    menu_win.writeCell(@intCast(menu_width - 1), 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = border_style });

    // Draw header: "─ Permission " then fill rest with "─"
    const header_text = "─ Permission ";
    for (1..menu_width - 1) |col| {
        const char_idx = col - 1;
        const char: []const u8 = if (char_idx < header_text.len) header_text[char_idx .. char_idx + 1] else "─";
        menu_win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = char, .width = 1 },
            .style = border_style,
        });
    }

    // Bottom border
    menu_win.writeCell(0, @intCast(menu_height - 1), .{ .char = .{ .grapheme = "└", .width = 1 }, .style = border_style });
    menu_win.writeCell(@intCast(menu_width - 1), @intCast(menu_height - 1), .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = border_style });
    for (1..menu_width - 1) |col| {
        menu_win.writeCell(@intCast(col), @intCast(menu_height - 1), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = border_style,
        });
    }

    // Side borders
    for (1..menu_height - 1) |row| {
        menu_win.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
        menu_win.writeCell(@intCast(menu_width - 1), @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
    }

    // Row 1: Title
    var row: usize = 1;
    const title_style = vaxis.Style{
        .fg = .{ .index = 7 },
        .bold = true,
    };
    const max_title_len = if (menu_width > 6) menu_width - 6 else 1;
    const truncated_title = if (perm.title.len > max_title_len) perm.title[0..max_title_len] else perm.title;
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = truncated_title, .style = title_style },
    };
    _ = menu_win.print(&title_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
    row += 1;

    // Description (if present)
    if (perm.description) |desc| {
        const desc_style = vaxis.Style{
            .fg = .{ .index = 8 },
            .italic = true,
        };
        const max_desc_len = if (menu_width > 6) menu_width - 6 else 1;
        const truncated_desc = if (desc.len > max_desc_len) desc[0..max_desc_len] else desc;
        var desc_seg = [_]vaxis.Cell.Segment{
            .{ .text = truncated_desc, .style = desc_style },
        };
        _ = menu_win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
        row += 1;
    }

    // Render options
    for (perm.options, 0..) |opt, i| {
        const is_selected = i == perm.selected_index;

        // Fill row background if selected
        if (is_selected) {
            for (1..menu_width - 1) |col| {
                menu_win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = .{ .index = 3 } }, // yellow background
                });
            }
        }

        // Selection indicator
        const indicator = if (is_selected) "▸ " else "  ";
        const indicator_style = vaxis.Style{
            .fg = .{ .index = if (is_selected) 0 else 8 }, // black if selected
            .bg = if (is_selected) .{ .index = 3 } else .{ .index = 0 },
            .bold = is_selected,
        };

        // Option style based on selection
        const option_style = if (is_selected) vaxis.Style{
            .fg = .{ .index = 0 }, // black on yellow
            .bg = .{ .index = 3 },
            .bold = true,
        } else vaxis.Style{
            .fg = .{ .index = 7 }, // normal
        };

        var segs = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = indicator_style },
            .{ .text = opt.name, .style = option_style },
        };
        _ = menu_win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = 2 });
        row += 1;
    }

    // Hint line
    const hint_style = vaxis.Style{ .fg = .{ .index = 8 } };
    var hint_seg = [_]vaxis.Cell.Segment{
        .{ .text = "↑↓ navigate  Enter confirm  Esc cancel", .style = hint_style },
    };
    _ = menu_win.print(&hint_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
}
