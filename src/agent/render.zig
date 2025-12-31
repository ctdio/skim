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

// Import utilities for word-aware wrapping
const rendering_utils = @import("../rendering/utils.zig");
const RenderUtils = rendering_utils.RenderUtils;

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
// File Reference Detection
// =============================================================================

/// A range representing an @file reference in the input text
const FileRefRange = struct {
    start: usize, // Position of @
    end: usize, // Position after the file path
};

/// Find all valid @file references in the input text (files that exist)
/// Returns a list of ranges. Caller owns the returned slice.
fn findFileRefRanges(allocator: std.mem.Allocator, text: []const u8) ![]FileRefRange {
    var ranges: std.ArrayList(FileRefRange) = .{};
    errdefer ranges.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@') {
            // Check word boundary
            const at_word_boundary = (i == 0 or
                text[i - 1] == ' ' or
                text[i - 1] == '\n' or
                text[i - 1] == '\t');

            if (at_word_boundary) {
                const path_start = i + 1;
                var path_end = path_start;
                while (path_end < text.len and
                    text[path_end] != ' ' and
                    text[path_end] != '\n' and
                    text[path_end] != '\t')
                {
                    path_end += 1;
                }

                const file_path = text[path_start..path_end];
                if (file_path.len > 0) {
                    // Check if file exists
                    const cwd = std.fs.cwd();
                    if (cwd.access(file_path, .{})) {
                        try ranges.append(allocator, .{ .start = i, .end = path_end });
                        i = path_end;
                        continue;
                    } else |_| {}
                }
            }
        }
        i += 1;
    }

    return ranges.toOwnedSlice(allocator);
}

/// Check if a position is within any file reference range
fn isInFileRef(pos: usize, ranges: []const FileRefRange) bool {
    for (ranges) |r| {
        if (pos >= r.start and pos < r.end) return true;
    }
    return false;
}

// =============================================================================
// Scrollbar
// =============================================================================

const ScrollbarInfo = struct {
    thumb_start: usize,
    thumb_end: usize,
    show_top_arrow: bool,
    show_bottom_arrow: bool,
};

fn calculateScrollbar(
    viewport_height: usize,
    total_lines: usize,
    scroll_offset: usize,
) ScrollbarInfo {
    // Thumb size: proportional to viewport vs total
    const thumb_size = @max(1, (viewport_height * viewport_height) / total_lines);

    // Thumb position: proportional to scroll offset
    const scrollable_range = if (total_lines > viewport_height)
        total_lines - viewport_height
    else
        0;

    const thumb_pos = if (scrollable_range > 0)
        (scroll_offset * (viewport_height - thumb_size)) / scrollable_range
    else
        0;

    return .{
        .thumb_start = thumb_pos,
        .thumb_end = thumb_pos + thumb_size,
        .show_top_arrow = scroll_offset > 0,
        .show_bottom_arrow = scroll_offset < scrollable_range,
    };
}

fn renderScrollbar(win: vaxis.Window, info: ScrollbarInfo) void {
    const col = win.width - 1; // Rightmost column
    const track_style = vaxis.Style{ .fg = .{ .index = 8 }, .dim = true }; // very dim gray
    const thumb_style = vaxis.Style{ .fg = .{ .index = 8 } }; // dim gray (no bold)
    const arrow_style = vaxis.Style{ .fg = .{ .index = 8 } }; // dim gray

    for (0..win.height) |row| {
        var char: []const u8 = undefined;
        var style: vaxis.Style = undefined;

        // Inset arrows by 1 row to avoid covering content at edges
        if (row == 1 and info.show_top_arrow) {
            char = "▴"; // Smaller, subtler arrow
            style = arrow_style;
        } else if (row == win.height - 2 and info.show_bottom_arrow and win.height > 2) {
            char = "▾"; // Smaller, subtler arrow
            style = arrow_style;
        } else if (row >= info.thumb_start and row < info.thumb_end) {
            char = "│"; // Lighter bar for thumb
            style = thumb_style;
        } else {
            char = "│"; // Light vertical line for track
            style = track_style;
        }

        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = char, .width = 1 },
            .style = style,
        });
    }
}

// =============================================================================
// Unified Inline Menu Renderer
// =============================================================================

/// Generic menu item for unified rendering
const MenuItem = struct {
    name: []const u8,
    description: []const u8,
};

/// Render an inline menu using the model selector style
/// Returns the number of rows used
fn renderInlineMenu(
    win: vaxis.Window,
    title: []const u8,
    items: []const MenuItem,
    selected_idx: usize,
    scroll_offset: usize,
    max_visible: usize,
    footer: []const u8,
) usize {
    if (items.len == 0) return 0;

    const visible_count = @min(items.len - scroll_offset, max_visible);
    var row: usize = 0;

    // Row 0: Separator line
    const separator_style = vaxis.Style{ .fg = .{ .index = 8 } };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }
    row += 1;

    // Row 1: Title
    const title_style = vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }; // magenta
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = title, .style = title_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
    row += 1;

    // Rows 2+: Menu items
    const normal_style = vaxis.Style{ .fg = .{ .index = 7 } };
    const selected_style = vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true }; // black on cyan
    const desc_style = vaxis.Style{ .fg = .{ .index = 8 } };

    // Show scroll indicator at top if there are items above
    if (scroll_offset > 0 and row < win.height) {
        const scroll_ind = "  ↑ more";
        const scroll_style = vaxis.Style{ .fg = .{ .index = 8 } };
        var scroll_seg = [_]vaxis.Cell.Segment{
            .{ .text = scroll_ind, .style = scroll_style },
        };
        _ = win.print(&scroll_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        row += 1;
    }

    for (0..visible_count) |i| {
        if (row >= win.height) break;

        const item_idx = scroll_offset + i;
        if (item_idx >= items.len) break;

        const item = items[item_idx];
        const is_selected = item_idx == selected_idx;
        const style = if (is_selected) selected_style else normal_style;

        // Selection indicator
        const indicator: []const u8 = if (is_selected) "▸ " else "  ";
        var ind_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = style },
        };
        _ = win.print(&ind_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

        // Item name
        var name_seg = [_]vaxis.Cell.Segment{
            .{ .text = item.name, .style = style },
        };
        _ = win.print(&name_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });

        // Description (after name, if space allows)
        const name_end = 3 + item.name.len + 2;
        if (name_end < win.width and item.description.len > 0) {
            var desc_seg = [_]vaxis.Cell.Segment{
                .{ .text = item.description, .style = if (is_selected) style else desc_style },
            };
            _ = win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(name_end) });
        }

        row += 1;
    }

    // Show scroll indicator at bottom if there are more items below
    const has_more_below = scroll_offset + visible_count < items.len;
    if (has_more_below and row < win.height) {
        const scroll_ind = "  ↓ more";
        const scroll_style = vaxis.Style{ .fg = .{ .index = 8 } };
        var scroll_seg = [_]vaxis.Cell.Segment{
            .{ .text = scroll_ind, .style = scroll_style },
        };
        _ = win.print(&scroll_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        row += 1;
    }

    // Footer row with keybindings
    if (row < win.height and footer.len > 0) {
        const kb_style = vaxis.Style{ .fg = .{ .index = 8 } };
        const kb_col = if (win.width > footer.len) win.width - footer.len else 0;

        var kb_seg = [_]vaxis.Cell.Segment{
            .{ .text = footer, .style = kb_style },
        };
        _ = win.print(&kb_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(kb_col) });
        row += 1;
    }

    return row;
}

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

    // Calculate dynamic input height based on content or mode
    const text = agent_state.input.getText();

    // Check if there's a pending permission
    const pending_permission = if (app.acp_manager) |mgr| mgr.getPendingPermission() else null;

    // Calculate height based on mode or pending permission
    const visible_lines = if (app.mode == .model_selection) blk: {
        const model_count = if (app.acp_manager) |mgr| mgr.getAvailableModels().len else 0;
        // Separator (1) + title (1) + models (2 lines each) + footer (1)
        break :blk 3 + (model_count * 2);
    } else if (pending_permission) |perm| blk: {
        // Separator (1) + title (1) + description (0 or 1) + options + footer (1)
        const desc_rows: usize = if (perm.description != null) 1 else 0;
        break :blk 3 + desc_rows + perm.options.len;
    } else blk: {
        // Calculate wrapped line count accounting for panel width
        // This ensures the input area expands properly in side-by-side mode
        // Account for: prompt/continuation (3 chars) + scrollbar (1 char when visible) + margin (1 char)
        const input_col: usize = 3; // After "> " or "  "
        const max_input_width = if (win.width > input_col + 2) win.width - input_col - 2 else 1;
        var total_display_lines: usize = 0;
        var line_iter = std.mem.splitScalar(u8, text, '\n');
        while (line_iter.next()) |text_line| {
            if (text_line.len == 0) {
                total_display_lines += 1; // Empty line still takes one display line
            } else {
                // Calculate how many chunks this line wraps into
                const chunks = (text_line.len + max_input_width - 1) / max_input_width;
                total_display_lines += chunks;
            }
        }
        if (total_display_lines == 0) total_display_lines = 1; // Always show at least one line
        break :blk @max(3, @min(total_display_lines, MAX_INPUT_LINES));
    };

    // Calculate plan height (only if visible and has entries)
    const plan_entry_count = agent_state.plan_entries.items.len;
    const plan_height: usize = if (agent_state.plan_visible and plan_entry_count > 0) blk: {
        // Header (1) + entries (all if expanded, 1 if collapsed)
        const visible_entries: usize = if (agent_state.plan_expanded) plan_entry_count else 1;
        break :blk 1 + visible_entries;
    } else 0;

    // Calculate status area height (shown between messages and plan when agent is thinking)
    // Layout: empty row + "Generating..." + empty row + optional queued message + empty row
    const is_thinking = if (app.acp_manager) |mgr| mgr.status == .prompting else false;
    const status_height: usize = if (is_thinking) blk: {
        var height: usize = 3; // empty + "Generating..." + empty
        // Add queued message height if present
        if (agent_state.hasStagedPrompt()) {
            const staged_text = agent_state.getStagedPrompt();
            var line_count: usize = 0;
            var iter = std.mem.splitScalar(u8, staged_text, '\n');
            while (iter.next()) |_| {
                line_count += 1;
                if (line_count >= 3) break;
            }
            height += 1 + line_count + 1 + 1; // label + content lines + trailing bar + empty spacing
        }
        break :blk height;
    } else 0;

    // Calculate input area height (always shows normal input)
    // In sidebar mode, skip the footer (main status bar is visible)
    const footer_height: usize = if (agent_state.full_screen) 1 else 0;
    const input_height: usize = 1 + visible_lines + footer_height; // Separator + visible lines + footer (if full-screen)

    // Layout: title (1 row) + messages (variable) + status (conditional) + plan (conditional) + input area (dynamic)
    const title_height: usize = 1;
    const fixed_height = title_height + status_height + plan_height + input_height;
    const messages_height = if (win.height > fixed_height)
        win.height - fixed_height
    else
        1;

    // Store viewport height for smart scrolling in key handlers
    agent_state.last_messages_viewport_height = messages_height;

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

    // Render status area (if agent is thinking)
    if (status_height > 0) {
        const status_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(title_height + messages_height),
            .width = win.width,
            .height = @intCast(status_height),
        });
        renderStatusArea(status_win, agent_state);
    }

    // Render plan area (if visible and has entries)
    if (plan_height > 0) {
        const plan_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(title_height + messages_height + status_height),
            .width = win.width,
            .height = @intCast(plan_height),
        });
        renderPlanArea(plan_win, agent_state.plan_entries.items, agent_state.plan_expanded);
    }

    // Render input area (or permission prompt if pending)
    const input_win = win.child(.{
        .x_off = 0,
        .y_off = @intCast(title_height + messages_height + status_height + plan_height),
        .width = win.width,
        .height = @intCast(input_height),
    });
    try renderInputArea(app, input_win, agent_state, is_focused, pending_permission);

    // Render slash command menu as overlay (if visible)
    if (agent_state.slash_menu_visible) {
        try renderSlashMenu(win, agent_state, title_height + messages_height + status_height + plan_height);
    }

    // Render file picker menu as overlay (if visible)
    if (agent_state.file_picker.visible) {
        try renderFilePicker(win, agent_state, title_height + messages_height + status_height + plan_height);
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
        .fg = .{ .index = 7 }, // white
        .bold = true,
    };

    // Clear title row (no background)
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
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
                .discovering, .connecting, .connected, .prompting => .{ .index = 8 }, // dim gray
                .disconnected => .{ .index = 7 }, // white
                .failed => .{ .index = 1 }, // red
            }
        else
            .{ .index = 7 },
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
                .fg = .{ .index = 8 }, // dim gray
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
        return;
    }

    // Get the pre-computed line map (builds if dirty)
    // Reserve 4 cols for indent + 1 col for scrollbar
    const wrap_width = if (win.width > 5) win.width - 5 else 1;
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
        }

        // Render left bar for user messages only (comment-style)
        // Agent messages, tools, and thinking use no bar for a cleaner, more conversational look
        switch (record.line_type) {
            .message_content => {
                // Only draw bar for user messages (comment-style)
                const messages = agent_state.messages.items;
                const msg_idx = record.line_type.message_content.msg_idx;
                if (msg_idx < messages.len) {
                    const msg = messages[msg_idx];
                    if (msg.role == .user) {
                        const bar_style: vaxis.Style = .{ .fg = Color.chat_user, .bg = Color.comment_bg };

                        var bar_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "┃ ", .style = bar_style },
                        };
                        _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
                    }
                }
            },
            .role_header => {
                // Only draw bar for user messages (comment-style)
                const messages = agent_state.messages.items;
                const msg_idx = record.line_type.role_header.msg_idx;
                if (msg_idx < messages.len) {
                    const msg = messages[msg_idx];
                    if (msg.role == .user) {
                        const bar_style: vaxis.Style = .{ .fg = Color.chat_user, .bg = Color.comment_bg };

                        var bar_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "┃ ", .style = bar_style },
                        };
                        _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
                    }
                }
            },
            .diff_header, .diff_hunk_header => {
                // Draw bar for diff headers
                var bar_seg = [_]vaxis.Cell.Segment{
                    .{ .text = "┃ ", .style = .{ .fg = Color.white } },
                };
                _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
            },
            // No bar for tools - they use minimal icon-based design
            else => {},
        }

        // Print regular prefix if present
        if (record.prefix) |prefix| {
            var prefix_seg = [_]vaxis.Cell.Segment{
                .{ .text = prefix, .style = record.prefix_style orelse record.style },
            };
            _ = win.print(&prefix_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += prefix.len;
        }

        // Print text - special handling for tool headers to color just the icon
        switch (record.line_type) {
            .tool_header => |th| {
                // Get icon color from message status
                const messages = agent_state.messages.items;
                const icon_color: vaxis.Color = if (th.msg_idx < messages.len) blk: {
                    const msg = messages[th.msg_idx];
                    break :blk switch (msg.tool_status) {
                        .pending => .{ .index = 3 }, // yellow
                        .running => .{ .index = 6 }, // cyan
                        .completed => .{ .index = 2 }, // green
                        .failed => .{ .index = 1 }, // red
                    };
                } else .{ .index = 7 }; // default white

                // Find first space to split icon from rest
                if (std.mem.indexOf(u8, record.text, " ")) |space_idx| {
                    const icon = record.text[0..space_idx];
                    const rest = record.text[space_idx..];

                    // Print icon with color
                    var icon_seg = [_]vaxis.Cell.Segment{
                        .{ .text = icon, .style = .{ .fg = icon_color } },
                    };
                    const icon_result = win.print(&icon_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });

                    // Print rest with default style
                    var rest_seg = [_]vaxis.Cell.Segment{
                        .{ .text = rest, .style = record.style },
                    };
                    _ = win.print(&rest_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset + icon_result.col) });
                } else {
                    // No space found, print normally
                    var seg = [_]vaxis.Cell.Segment{
                        .{ .text = record.text, .style = record.style },
                    };
                    _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
                }
            },
            else => {
                var seg = [_]vaxis.Cell.Segment{
                    .{ .text = record.text, .style = record.style },
                };
                _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            },
        }
        row += 1;
    }

    // Render scrollbar if content is scrollable
    if (total_lines > win.height) {
        const scrollbar_info = calculateScrollbar(win.height, total_lines, scroll);
        renderScrollbar(win, scrollbar_info);
    }
}

/// Render the status area shown between messages and plan when agent is thinking
/// Layout: empty row + "Generating..." + empty row + optional queued message
fn renderStatusArea(win: vaxis.Window, agent_state: *AgentState) void {
    if (win.height == 0) return;

    var row: usize = 0;

    // Row 0: empty padding
    row += 1;

    // Row 1: "Generating..." indicator with shimmer
    if (row < win.height) {
        renderThinkingIndicator(win, row);
        row += 1;
    }

    // Row 2: empty padding
    row += 1;

    // Rows 3+: Queued message preview (if present)
    if (agent_state.hasStagedPrompt() and row < win.height) {
        const staged_text = agent_state.getStagedPrompt();
        renderStagedMessagePreview(win, staged_text, row);
    }
}

/// Render a preview of the staged message (up to 3 lines)
/// Uses the same visual style as user messages (with bar and background)
fn renderStagedMessagePreview(win: vaxis.Window, text: []const u8, start_row: usize) void {
    if (text.len == 0 or start_row >= win.height) return;

    const max_preview_lines: usize = 3;
    // Use user message style (same as user messages in chat)
    const bar_style = vaxis.Style{ .fg = Color.chat_user, .bg = Color.comment_bg };
    const text_style = vaxis.Style{ .fg = Color.white, .bg = Color.comment_bg };
    const label_style = vaxis.Style{ .fg = Color.chat_user, .bg = Color.comment_bg, .bold = true };

    var row: usize = start_row;

    // Show label: "Queued:" with bar (same style as user messages)
    // Fill background for this row
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = Color.comment_bg },
        });
    }
    // Draw bar
    var bar_seg = [_]vaxis.Cell.Segment{
        .{ .text = "┃ ", .style = bar_style },
    };
    _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
    // Draw label
    var label_seg = [_]vaxis.Cell.Segment{
        .{ .text = "Queued:", .style = label_style },
    };
    _ = win.print(&label_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
    row += 1;

    // Extract up to 3 lines from staged text
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    var lines_shown: usize = 0;

    while (line_iter.next()) |line| {
        if (lines_shown >= max_preview_lines or row >= win.height) break;

        // Fill background for this row
        for (0..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = Color.comment_bg },
            });
        }

        // Draw bar
        var line_bar_seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃ ", .style = bar_style },
        };
        _ = win.print(&line_bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });

        // Truncate line to fit window width (leave room for "┃ " prefix)
        const max_line_len = if (win.width > 4) win.width - 4 else 1;
        const display_line = if (line.len > max_line_len) line[0..max_line_len] else line;

        // Print line content
        var line_seg = [_]vaxis.Cell.Segment{
            .{ .text = display_line, .style = text_style },
        };
        _ = win.print(&line_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });

        row += 1;
        lines_shown += 1;
    }

    // If there are more lines, show "..." with same style
    if (line_iter.next() != null and row < win.height) {
        // Fill background
        for (0..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = Color.comment_bg },
            });
        }
        // Draw bar and ellipsis
        var more_bar_seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃ ", .style = bar_style },
        };
        _ = win.print(&more_bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
        var more_seg = [_]vaxis.Cell.Segment{
            .{ .text = "...", .style = text_style },
        };
        _ = win.print(&more_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
        row += 1;
    }

    // Add trailing empty line with background (matches chat message style)
    if (row < win.height) {
        // fill background
        for (0..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = Color.comment_bg },
            });
        }

        var final_bar_seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃ ", .style = bar_style },
        };

        _ = win.print(&final_bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
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

/// Render file picker menu overlay
fn renderFilePicker(win: vaxis.Window, agent_state: *AgentState, input_top: usize) !void {
    const filtered_count = agent_state.file_picker.getFilteredCount();

    if (filtered_count == 0) return;

    // Calculate menu dimensions with scroll support
    const visible_count = @min(filtered_count, state.MAX_FILE_MENU_VISIBLE);
    const max_scroll = if (filtered_count > visible_count) filtered_count - visible_count else 0;
    const scroll_offset = @min(agent_state.file_picker.scroll_offset, max_scroll);
    const menu_height = visible_count + 2; // +2 for top/bottom border
    const menu_width = @min(win.width -| 4, 80); // max 80 chars wide

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

    // Top border: ┌─ Files ─────────────────────────────┐
    const has_more_above = scroll_offset > 0;
    menu_win.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = border_style });
    menu_win.writeCell(@intCast(menu_width - 1), 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = border_style });

    // Draw header: "─ Files " then fill rest with "─"
    const header_parts = [_][]const u8{ "─", " ", "F", "i", "l", "e", "s", " " };
    for (1..menu_width - 1) |col| {
        const char_idx = col - 1;
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

    // Bottom border with scroll indicator
    const has_more_below = scroll_offset + visible_count < filtered_count;
    menu_win.writeCell(0, @intCast(menu_height - 1), .{ .char = .{ .grapheme = "└", .width = 1 }, .style = border_style });
    menu_win.writeCell(@intCast(menu_width - 1), @intCast(menu_height - 1), .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = border_style });
    for (1..menu_width - 1) |col| {
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
    const selection = @min(agent_state.file_picker.selection, filtered_count - 1);

    // Render file items (with scroll offset applied)
    for (0..visible_count) |i| {
        const item_idx = scroll_offset + i;
        if (item_idx >= filtered_count) break;

        const file_idx = agent_state.file_picker.filtered_indices.items[item_idx];
        const file_path = agent_state.file_picker.files.items[file_idx];
        const is_selected = (item_idx == selection);
        const row = i + 1; // +1 for top border

        // Style based on selection
        const path_style: vaxis.Style = if (is_selected)
            .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 }, .bold = true } // inverted white
        else
            .{ .fg = .{ .index = 7 } }; // white

        // Fill row background if selected
        if (is_selected) {
            for (1..menu_width - 1) |col| {
                menu_win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = .{ .index = 7 } },
                });
            }
        }

        // Print file path with @ prefix
        var col: usize = 2;

        // Print "@" prefix
        var at_seg = [_]vaxis.Cell.Segment{
            .{ .text = "@", .style = path_style },
        };
        _ = menu_win.print(&at_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        col += 1;

        // Print file path (truncate if needed)
        const max_path_len = if (menu_width > col + 3) menu_width - col - 3 else 1;
        const path_len = @min(file_path.len, max_path_len);
        const path_text = file_path[0..path_len];
        var path_seg = [_]vaxis.Cell.Segment{
            .{ .text = path_text, .style = path_style },
        };
        _ = menu_win.print(&path_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    }
}

// =============================================================================
// Plan Area
// =============================================================================

/// Render the agent plan area (todo list from agent)
fn renderPlanArea(win: vaxis.Window, entries: []const OwnedPlanEntry, expanded: bool) void {
    if (win.height == 0 or entries.len == 0) return;

    var row: usize = 0;
    const header_style = vaxis.Style{ .fg = .{ .index = 8 }, .bold = true };

    // Clear entire header row first to avoid artifacts
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        });
    }

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

    // Add expansion indicator and "+N more" in header for collapsed view
    const header_end: usize = 10;
    const indicator_text: []const u8 = if (expanded) "[-]" else "[+]";
    var indicator_seg = [_]vaxis.Cell.Segment{
        .{ .text = indicator_text, .style = header_style },
    };
    _ = win.print(&indicator_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(header_end) });

    // In collapsed view with multiple entries, show "+N more" after [+]
    var more_end: usize = header_end + indicator_text.len;
    if (!expanded and entries.len > 1) {
        var more_buf: [16]u8 = undefined;
        const remaining = entries.len - 1;
        const more_text = std.fmt.bufPrint(&more_buf, " +{d}", .{remaining}) catch " +?";
        var more_seg = [_]vaxis.Cell.Segment{
            .{ .text = more_text, .style = header_style },
        };
        _ = win.print(&more_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(more_end) });
        more_end += more_text.len;
    }

    // Fill rest of header with ─
    const fill_start = more_end + 1;
    if (win.width > fill_start) {
        for (fill_start..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = header_style,
            });
        }
    }
    row += 1;

    // In collapsed view, show only: active (in_progress) todo, or last completed if none active
    if (!expanded) {
        const entry = findActiveOrLastCompleted(entries);
        renderPlanEntry(win, row, entry);
        return;
    }

    // Expanded view: render all entries
    for (entries) |entry| {
        if (row >= win.height) break;
        renderPlanEntry(win, row, entry);
        row += 1;
    }
}

/// Find the active (in_progress) entry, or fallback to last completed entry
fn findActiveOrLastCompleted(entries: []const OwnedPlanEntry) OwnedPlanEntry {
    // First, look for in_progress
    for (entries) |entry| {
        if (entry.status == .in_progress) return entry;
    }
    // Then, find last completed (iterate backwards)
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        if (entries[i].status == .completed) return entries[i];
    }
    // Fallback to first entry
    return entries[0];
}

/// Render a single plan entry at the given row
fn renderPlanEntry(win: vaxis.Window, row: usize, entry: OwnedPlanEntry) void {
    // Clear entire row first to avoid artifacts
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        });
    }

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

    // Content style (dim for completed)
    const content_style: vaxis.Style = switch (entry.status) {
        .completed => .{ .fg = .{ .index = 8 } },
        else => .{ .fg = .{ .index = 7 } },
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
}

fn renderInputArea(app: *App, win: vaxis.Window, agent_state: *AgentState, is_focused: bool, pending_permission: ?*AcpManager.PendingPermission) !void {
    if (win.height == 0) return;

    // Check if we're in model selection mode - render inline picker instead
    if (app.mode == .model_selection) {
        try renderInlineModelPicker(app, win);
        return;
    }

    // Check if there's a pending permission - render inline permission prompt instead
    if (pending_permission) |perm| {
        try renderInlinePermissionPrompt(win, perm);
        return;
    }

    const text = agent_state.input.getText();
    const input_col: usize = 3; // After "> " or "  "

    // Calculate how many display lines we'll have with wrapping
    // We need to do this before rendering to know the input area height
    // Account for: prompt/continuation (3 chars) + scrollbar (1 char when visible) + margin (1 char)
    const max_input_width_for_calc = if (win.width > input_col + 2) win.width - input_col - 2 else 1;
    var total_display_lines: usize = 0;
    var line_iter_calc = std.mem.splitScalar(u8, text, '\n');
    while (line_iter_calc.next()) |text_line| {
        if (text_line.len == 0) {
            total_display_lines += 1; // Empty line still takes one display line
        } else {
            // Calculate how many chunks this line wraps into
            const chunks = (text_line.len + max_input_width_for_calc - 1) / max_input_width_for_calc;
            total_display_lines += chunks;
        }
    }
    if (total_display_lines == 0) total_display_lines = 1; // Always show at least one line

    const visible_lines = @min(total_display_lines, MAX_INPUT_LINES);

    // Calculate cursor's actual display row (accounting for wrapping)
    const cursor_pos = agent_state.input.vim.cursor_pos;
    var cursor_display_row: usize = 0;
    var pos: usize = 0;
    var line_iter_cursor = std.mem.splitScalar(u8, text, '\n');
    while (line_iter_cursor.next()) |text_line| {
        const line_start = pos;
        const line_end = pos + text_line.len;

        if (cursor_pos >= line_start and cursor_pos <= line_end) {
            // Cursor is on this logical line, calculate wrapped row
            const offset_in_line = cursor_pos - line_start;
            const wrapped_rows_before = offset_in_line / max_input_width_for_calc;
            cursor_display_row += wrapped_rows_before;
            break;
        }

        // Count wrapped rows for this line
        if (text_line.len == 0) {
            cursor_display_row += 1;
        } else {
            const chunks = (text_line.len + max_input_width_for_calc - 1) / max_input_width_for_calc;
            cursor_display_row += chunks;
        }

        pos = line_end + 1; // +1 for newline
    }

    // Calculate scroll offset to keep cursor in view
    var scroll_offset = agent_state.input_scroll_offset;

    // Scroll up if cursor is above visible area
    if (cursor_display_row < scroll_offset) {
        scroll_offset = cursor_display_row;
    }
    // Scroll down if cursor is below visible area
    if (cursor_display_row >= scroll_offset + visible_lines) {
        scroll_offset = cursor_display_row - visible_lines + 1;
    }
    // Clamp scroll offset to valid range
    const max_scroll = if (total_display_lines > visible_lines) total_display_lines - visible_lines else 0;
    scroll_offset = @min(scroll_offset, max_scroll);

    // Update stored scroll offset
    agent_state.input_scroll_offset = scroll_offset;

    // Layout:
    // Row 0: Separator line
    // Rows 1..: Input lines with "> " prompt on first line
    // Last row: Footer with mode (left) and keybindings (right)

    // Separator line
    const separator_style = vaxis.Style{ .fg = .{ .index = 8 } };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }

    // Check if we're in shell command mode (using shell_mode flag)
    const is_shell_mode = agent_state.isShellMode();
    
    // Dim prompt when session is not ready
    const session_ready = if (app.acp_manager) |mgr| mgr.status == .session_active or mgr.status == .prompting else false;
    const prompt_style = if (is_shell_mode)
        vaxis.Style{ .fg = .{ .index = 3 }, .bold = true } // yellow for shell mode
    else if (session_ready)
        vaxis.Style{ .fg = .{ .index = 5 }, .bold = true } // magenta when ready
    else
        vaxis.Style{ .fg = .{ .index = 8 } }; // dim gray when not ready
    const text_style = vaxis.Style{ .fg = .{ .index = 7 } };
    const file_ref_style = vaxis.Style{ .fg = .{ .index = 6 }, .bold = true }; // cyan, bold for @file refs

    // Find file reference ranges for highlighting
    const file_ref_ranges = findFileRefRanges(app.allocator, text) catch &[_]FileRefRange{};
    defer if (file_ref_ranges.len > 0) app.allocator.free(file_ref_ranges);
    const has_file_refs = file_ref_ranges.len > 0;
    // Use the same max_input_width as calculated earlier for consistency
    const max_input_width = max_input_width_for_calc;
    // Content starts after separator
    const content_start_row: usize = 1;

    // Split text by newlines and wrap each line
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    var display_row: usize = 0; // Physical display row (including wrapping)
    var visible_row: usize = 0; // Row within the visible window
    var char_offset: usize = 0; // Track absolute position in buffer
    var is_first_line = true;

    var line_num: usize = 0;
    while (line_iter.next()) |text_line| {
        // Stop if we've filled the visible area
        if (visible_row >= visible_lines) break;

        // For lines after the first, account for the newline character before processing the line
        // (splitScalar doesn't include the delimiter, so we need to manually track it)
        if (line_num > 0) {
            char_offset += 1; // Account for '\n' that ended previous line
        }
        line_num += 1;

        // Use word-aware wrapping for this line
        var wrapped_lines = try RenderUtils.wrapText(app.allocator, text_line, max_input_width);
        defer wrapped_lines.deinit(app.allocator);
        
        // Track offset within the original line for cursor positioning
        var segment_offset: usize = 0;
        
        for (wrapped_lines.items) |wrapped_segment| {
            // Stop if we've filled the visible area
            if (visible_row >= visible_lines) break;
            
            const chunk = wrapped_segment;
            const chunk_len = chunk.len;

            // Skip rows that are scrolled out of view
            if (display_row >= scroll_offset) {
                const row = visible_row + content_start_row;

                // First line gets the prompt ("> " for normal, "$ " for shell mode), others get "  " for alignment
                if (is_first_line) {
                    const prompt_char = if (is_shell_mode) "$ " else "> ";
                    var prompt_seg = [_]vaxis.Cell.Segment{
                        .{ .text = prompt_char, .style = prompt_style },
                    };
                    _ = win.print(&prompt_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
                    is_first_line = false;
                } else {
                    var cont_seg = [_]vaxis.Cell.Segment{
                        .{ .text = "  ", .style = text_style },
                    };
                    _ = win.print(&cont_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
                }
            } else {
                // Still need to track is_first_line even for scrolled rows
                if (is_first_line) is_first_line = false;
            }

            // Determine segment start and end positions in the full buffer
            const segment_start = char_offset + segment_offset;
            const segment_end = segment_start + chunk_len;

            // Only render if in visible area
            if (display_row >= scroll_offset) {
                const row = visible_row + content_start_row;

                // Check for visual mode selection highlighting or file references
                const vim_mode = agent_state.input.vim.vim_mode;
                const visual_anchor = agent_state.input.vim.visual_anchor;
                const in_visual_mode = vim_mode == .visual and visual_anchor != null;

                if (in_visual_mode or has_file_refs) {
                    // Character-by-character rendering for visual selection or file refs
                    const anchor = if (in_visual_mode) visual_anchor.? else 0;
                    const cursor = agent_state.input.vim.cursor_pos;
                    const sel_start = if (in_visual_mode) @min(anchor, cursor) else 0;
                    const sel_end = if (in_visual_mode) @max(anchor, cursor) else 0;

                    // Visual selection style
                    const visual_style = vaxis.Style{
                        .fg = .{ .index = 0 },
                        .bg = .{ .index = 6 },
                        .bold = true,
                    };

                    // Render each character with appropriate style
                    for (chunk, 0..) |_, char_idx| {
                        const abs_pos = segment_start + char_idx;
                        const col = input_col + char_idx;
                        if (col >= win.width) break;

                        const in_selection = in_visual_mode and abs_pos >= sel_start and abs_pos <= sel_end;
                        const in_file_ref = isInFileRef(abs_pos, file_ref_ranges);
                        const style = if (in_selection)
                            visual_style
                        else if (in_file_ref)
                            file_ref_style
                        else
                            text_style;

                        win.writeCell(@intCast(col), @intCast(row), .{
                            .char = .{ .grapheme = chunk[char_idx .. char_idx + 1], .width = 1 },
                            .style = style,
                        });
                    }
                } else {
                    // Normal rendering (no visual mode, no file refs)
                    var text_seg = [_]vaxis.Cell.Segment{
                        .{ .text = chunk, .style = text_style },
                    };
                    _ = win.print(&text_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(input_col) });
                }

                // Set terminal cursor if it's in this segment
                if (is_focused and agent_state.input.vim.vim_mode != .command) {
                    const vim_cursor_pos = agent_state.input.vim.cursor_pos;

                    // Determine if cursor is in this segment
                    // For empty text, show cursor at position 0
                    // For empty lines (chunk_len == 0), cursor should be shown if it's exactly at segment_start
                    // For non-empty lines:
                    //   - In normal/visual mode: cursor is ON the character (inclusive end)
                    //   - In insert mode: cursor is BETWEEN characters (exclusive end)
                    const cursor_in_segment = if (text.len == 0)
                        vim_cursor_pos == 0 and segment_start == 0
                    else if (chunk_len == 0)
                        vim_cursor_pos == segment_start
                    else if (vim_mode == .normal or vim_mode == .visual)
                        vim_cursor_pos >= segment_start and vim_cursor_pos < segment_end
                    else
                        vim_cursor_pos >= segment_start and vim_cursor_pos <= segment_end;

                    if (cursor_in_segment) {
                        const cursor_offset_in_segment = if (vim_cursor_pos >= segment_start)
                            @min(vim_cursor_pos - segment_start, chunk_len)
                        else
                            0;
                        const cursor_col = input_col + cursor_offset_in_segment;

                        if (cursor_col < win.width) {
                            // Set cursor shape based on vim mode
                            switch (vim_mode) {
                                .normal, .visual => {
                                    // Block cursor for normal/visual mode
                                    win.setCursorShape(.block);
                                },
                                .insert => {
                                    // Beam/line cursor for insert mode
                                    win.setCursorShape(.beam);
                                },
                                .command => {
                                    // Should never reach here due to outer check
                                    unreachable;
                                },
                            }
                            // Show terminal cursor at position
                            win.showCursor(@intCast(cursor_col), @intCast(row));
                        }
                    }
                }

                visible_row += 1;
            }

            // Update segment_offset to account for this wrapped segment
            segment_offset += chunk_len;
            
            // Account for spaces that were trimmed during wrapping
            while (segment_offset < text_line.len and text_line[segment_offset] == ' ') {
                segment_offset += 1;
            }
            
            display_row += 1;

            // Break after rendering empty line
            if (text_line.len == 0) break;
        }
        
        // Move char_offset to the end of this line
        char_offset += text_line.len;
    }

    // Render scrollbar if input area is scrollable
    if (total_display_lines > visible_lines) {
        const scrollbar_info = calculateScrollbar(visible_lines, total_display_lines, scroll_offset);
        // Render scrollbar in input area (offset by staged message + separator)
        const scrollbar_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(content_start_row),
            .width = win.width,
            .height = @intCast(visible_lines),
        });
        renderScrollbar(scrollbar_win, scrollbar_info);
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
        var session_mode_buf: [64]u8 = undefined;
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
            const sm_style = vaxis.Style{ .fg = .{ .index = 7 } }; // white
            var sm_seg = [_]vaxis.Cell.Segment{
                .{ .text = sm_text, .style = sm_style },
            };
            _ = win.print(&sm_seg, .{ .row_offset = @intCast(footer_row), .col_offset = 13 });
        }

        // Stash indicator (after session mode)
        var next_col: usize = if (session_mode_text) |sm| 13 + sm.len else 13;

        if (agent_state.hasStash()) {
            const stash_style = vaxis.Style{ .fg = .{ .index = 3 }, .bold = true }; // yellow
            var stash_seg = [_]vaxis.Cell.Segment{
                .{ .text = " [stashed]", .style = stash_style },
            };
            _ = win.print(&stash_seg, .{ .row_offset = @intCast(footer_row), .col_offset = @intCast(next_col) });
            next_col += 10; // " [stashed]".len
        }

        // Current model indicator (after stash)
        var model_buf: [48]u8 = undefined;
        if (app.acp_manager) |mgr| {
            if (mgr.hasModels()) {
                const model_name = mgr.getCurrentModelName();
                if (model_name.len > 0) {
                    const model_text = std.fmt.bufPrint(&model_buf, " {s}", .{model_name}) catch null;
                    if (model_text) |mt| {
                        const model_style = vaxis.Style{ .fg = .{ .index = 6 } }; // cyan
                        var model_seg = [_]vaxis.Cell.Segment{
                            .{ .text = mt, .style = model_style },
                        };
                        _ = win.print(&model_seg, .{ .row_offset = @intCast(footer_row), .col_offset = @intCast(next_col) });
                    }
                }
            }
        }

        // Keybindings on the right (include mode hint if modes available)
        // Tab cycles modes only in normal mode
        const has_modes = if (app.acp_manager) |mgr| mgr.hasModes() else false;
        const keybindings = switch (agent_state.input.vim.vim_mode) {
            .insert => "S-Enter:newline  Enter:send  ESC:normal",
            .normal => if (has_modes) "Tab:mode  i:insert  ^E:diff  z:full" else "i:insert  ^E:diff  z:full",
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
// Inline Model Picker
// =============================================================================

/// Render inline model picker with 2-line layout per model (name + description)
fn renderInlineModelPicker(app: *App, win: vaxis.Window) !void {
    const mgr = app.acp_manager orelse return;
    const models = mgr.getAvailableModels();
    const model_count = models.len;
    if (model_count == 0) return;

    const selected = app.state.model_selection;
    const current_model_id = mgr.getCurrentModelId();

    // Layout: separator(1) + title(1) + models(2 lines each) + footer(1)
    // Reserve 3 rows for chrome, rest for models
    const chrome_rows: usize = 3;
    const available_for_models = if (win.height > chrome_rows) win.height - chrome_rows else 1;
    const rows_per_model: usize = 2;
    const max_visible_models = available_for_models / rows_per_model;

    // Calculate scroll offset to keep selected item visible
    var scroll_offset: usize = 0;
    if (max_visible_models > 0 and model_count > max_visible_models) {
        if (selected >= max_visible_models) {
            scroll_offset = selected - max_visible_models + 1;
        }
        // Clamp to valid range
        if (scroll_offset + max_visible_models > model_count) {
            scroll_offset = model_count - max_visible_models;
        }
    }

    var row: usize = 0;
    const separator_style = vaxis.Style{ .fg = .{ .index = 8 } };
    const title_style = vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }; // magenta
    const normal_style = vaxis.Style{ .fg = .{ .index = 7 } };
    const selected_style = vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true }; // black on cyan
    const desc_style = vaxis.Style{ .fg = .{ .index = 8 } };
    const current_style = vaxis.Style{ .fg = .{ .index = 2 } }; // green for current model marker

    // Row 0: Separator line
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }
    row += 1;

    // Row 1: Title with count
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = "Select Model:", .style = title_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
    row += 1;

    // Render visible models (2 lines each)
    const visible_count = @min(model_count - scroll_offset, max_visible_models);
    for (0..visible_count) |i| {
        if (row + 1 >= win.height) break; // Need 2 rows per model

        const model_idx = scroll_offset + i;
        if (model_idx >= model_count) break;

        const model = models[model_idx];
        const is_selected = model_idx == selected;
        const is_current = if (current_model_id) |cid| std.mem.eql(u8, model.model_id, cid) else false;
        const name_style = if (is_selected) selected_style else normal_style;

        // Line 1: Selection indicator + model name + current marker
        const indicator: []const u8 = if (is_selected) "▸ " else "  ";
        var ind_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = name_style },
        };
        _ = win.print(&ind_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

        const model_name = model.name orelse model.model_id;
        var name_seg = [_]vaxis.Cell.Segment{
            .{ .text = model_name, .style = name_style },
        };
        _ = win.print(&name_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });

        // Show ✓ if this is the current model
        if (is_current) {
            const check_col = 3 + model_name.len + 1;
            if (check_col < win.width) {
                var check_seg = [_]vaxis.Cell.Segment{
                    .{ .text = " ✓", .style = current_style },
                };
                _ = win.print(&check_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(check_col) });
            }
        }
        row += 1;

        // Line 2: Description (indented, always dim)
        if (model.description) |desc| {
            if (desc.len > 0 and row < win.height) {
                const desc_indent: usize = 5; // Indent description under name
                const max_desc_len = if (win.width > desc_indent) win.width - desc_indent - 1 else 0;
                const truncated_desc = if (desc.len > max_desc_len) desc[0..max_desc_len] else desc;

                var desc_seg = [_]vaxis.Cell.Segment{
                    .{ .text = truncated_desc, .style = desc_style },
                };
                _ = win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(desc_indent) });
            }
        }
        row += 1;
    }

    // Footer row with keybindings (right-aligned)
    if (row < win.height) {
        const footer = "j/k:navigate  Enter:select  ESC:cancel";
        const kb_style = vaxis.Style{ .fg = .{ .index = 8 } };
        const kb_col = if (win.width > footer.len) win.width - footer.len else 0;

        var kb_seg = [_]vaxis.Cell.Segment{
            .{ .text = footer, .style = kb_style },
        };
        _ = win.print(&kb_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(kb_col) });

        // Show scroll indicators if needed
        if (scroll_offset > 0) {
            var up_seg = [_]vaxis.Cell.Segment{
                .{ .text = "↑", .style = kb_style },
            };
            _ = win.print(&up_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        }
        if (scroll_offset + visible_count < model_count) {
            var down_seg = [_]vaxis.Cell.Segment{
                .{ .text = "↓", .style = kb_style },
            };
            _ = win.print(&down_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });
        }
    }
}

// =============================================================================
// Inline Permission Prompt
// =============================================================================

/// Helper function to wrap text and render it across multiple rows
fn renderWrappedText(
    win: vaxis.Window,
    text: []const u8,
    start_row: usize,
    col_offset: usize,
    max_width: usize,
    style: vaxis.Style,
) usize {
    if (text.len == 0) return 0;

    var row = start_row;
    var pos: usize = 0;

    while (pos < text.len) {
        if (row >= win.height) break;

        // Calculate how much text fits on this line
        const remaining = text[pos..];
        const chunk_len = @min(remaining.len, max_width);
        var break_at = chunk_len;

        // If we're not at the end, try to break at a word boundary
        if (chunk_len < remaining.len and chunk_len > 10) {
            // Search backwards for a space
            var search_pos = chunk_len;
            while (search_pos > chunk_len / 2) : (search_pos -= 1) {
                if (remaining[search_pos - 1] == ' ') {
                    break_at = search_pos;
                    break;
                }
            }
        }

        const chunk = remaining[0..break_at];
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = chunk, .style = style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });

        pos += break_at;
        // Skip leading space on next line
        if (pos < text.len and text[pos] == ' ') {
            pos += 1;
        }
        row += 1;
    }

    return row - start_row; // Return number of rows used
}

/// Render the permission prompt inline in place of the input area
fn renderInlinePermissionPrompt(win: vaxis.Window, perm: *AcpManager.PendingPermission) !void {
    var row: usize = 0;

    // Row 0: Separator line
    const separator_style = vaxis.Style{ .fg = .{ .index = 8 } };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }
    row += 1;

    // Row 1+: Title (wrapped if needed)
    const title_style = vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }; // magenta
    const max_text_width = if (win.width > 3) win.width - 3 else 1; // Leave margin
    const title_rows = renderWrappedText(win, perm.title, row, 1, max_text_width, title_style);
    row += title_rows;

    // Row N+: Description (wrapped if present)
    if (perm.description) |desc| {
        const desc_style = vaxis.Style{ .fg = .{ .index = 8 }, .italic = true };
        const desc_rows = renderWrappedText(win, desc, row, 1, max_text_width, desc_style);
        row += desc_rows;
    }

    // Rows: Options
    const normal_style = vaxis.Style{ .fg = .{ .index = 7 } };
    const selected_style = vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true }; // black on cyan

    for (perm.options, 0..) |opt, i| {
        if (row >= win.height) break;

        const is_selected = i == perm.selected_index;
        const style = if (is_selected) selected_style else normal_style;

        // Selection indicator
        const indicator: []const u8 = if (is_selected) "▸ " else "  ";
        var ind_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = style },
        };
        _ = win.print(&ind_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

        // Option name
        var name_seg = [_]vaxis.Cell.Segment{
            .{ .text = opt.name, .style = style },
        };
        _ = win.print(&name_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });

        row += 1;
    }

    // Footer row with keybindings
    if (row < win.height) {
        const footer = "j/k:navigate  Enter:confirm  ESC:cancel";
        const kb_style = vaxis.Style{ .fg = .{ .index = 8 } };
        const kb_col = if (win.width > footer.len) win.width - footer.len else 0;

        var kb_seg = [_]vaxis.Cell.Segment{
            .{ .text = footer, .style = kb_style },
        };
        _ = win.print(&kb_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(kb_col) });
    }
}
