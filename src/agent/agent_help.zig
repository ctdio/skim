const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("../app.zig").App;
const Color = @import("../rendering/common.zig").Color;
const RenderUtils = @import("../rendering/utils.zig").RenderUtils;
const AgentState = @import("state.zig").AgentState;

// Total number of content rows in help popup (approximate)
const HELP_CONTENT_ROWS = 45;

/// Render the agent help popup overlay
pub fn renderHelpPopup(app: *App, win: vaxis.Window, agent_state: *AgentState) !void {
    // Calculate popup dimensions - sized for help content
    const popup_width = @min(80, win.width -| 4);
    const popup_height = @min(35, win.height -| 4);
    const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
    const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

    const popup_win = win.child(.{
        .x_off = x_offset,
        .y_off = y_offset,
        .width = @intCast(popup_width),
        .height = @intCast(popup_height),
        .border = .{
            .where = .all,
            .style = .{
                .fg = Color.cyan,
            },
        },
    });

    popup_win.clear();

    // Fill with solid background
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{
            .bg = Color.black,
        },
    };
    popup_win.fill(bg_cell);

    // Build content lines
    var content_lines: std.ArrayList(ContentLine) = .{};
    defer content_lines.deinit(app.allocator);

    // Title
    try content_lines.append(app.allocator, .{ .text = "Agent Mode - Keybindings", .style = .{ .fg = Color.cyan, .bold = true } });

    // Separator
    try content_lines.append(app.allocator, .{ .text = null, .style = .{}, .is_separator = true });

    const section_style = vaxis.Style{
        .fg = Color.yellow,
        .bold = true,
    };
    const key_style = vaxis.Style{
        .fg = Color.cyan,
    };
    const desc_style = vaxis.Style{
        .fg = Color.white,
    };

    // INPUT MODE section
    try content_lines.append(app.allocator, .{ .text = "INPUT (INSERT MODE)", .style = section_style });

    const input_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Enter", .desc = "Send prompt to agent" },
        .{ .key = "Ctrl+J", .desc = "Insert newline in prompt" },
        .{ .key = "Ctrl+C/ESC", .desc = "Exit to normal mode" },
        .{ .key = "/", .desc = "Show slash command menu (at start)" },
        .{ .key = "@", .desc = "Show file picker (at start)" },
        .{ .key = "!", .desc = "Toggle shell command mode (empty input)" },
        .{ .key = "Tab", .desc = "Accept slash command suggestion" },
        .{ .key = "Up", .desc = "Restore last staged prompt (empty input)" },
    };

    for (input_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{} });

    // NORMAL MODE section
    try content_lines.append(app.allocator, .{ .text = "NORMAL MODE (VIM)", .style = section_style });

    const normal_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "i/a/I/A", .desc = "Enter insert mode" },
        .{ .key = "h/l", .desc = "Move cursor left/right" },
        .{ .key = "w/b/e", .desc = "Word motions" },
        .{ .key = "0/$", .desc = "Line start/end" },
        .{ .key = "x/dd", .desc = "Delete char/line" },
        .{ .key = ":", .desc = "Open command palette" },
        .{ .key = "?", .desc = "Show this help" },
    };

    for (normal_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{} });

    // NAVIGATION section
    try content_lines.append(app.allocator, .{ .text = "NAVIGATION", .style = section_style });

    const nav_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Ctrl+D/U", .desc = "Page down/up (any mode)" },
        .{ .key = "gg/G", .desc = "Scroll to top/bottom (normal mode)" },
        .{ .key = "Ctrl+W h/l", .desc = "Focus diff/agent panel" },
        .{ .key = "gt/gT", .desc = "Next/previous tab" },
        .{ .key = "z", .desc = "Toggle full screen (normal mode)" },
        .{ .key = "V", .desc = "Toggle diff view mode (normal mode)" },
    };

    for (nav_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{} });

    // SESSION section
    try content_lines.append(app.allocator, .{ .text = "SESSION", .style = section_style });

    const session_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Tab", .desc = "Cycle session modes (normal mode)" },
        .{ .key = "Ctrl+S", .desc = "Stash/unstash prompt" },
        .{ .key = "Ctrl+L", .desc = "Clear message history" },
        .{ .key = "Ctrl+T", .desc = "Toggle todo list expansion" },
        .{ .key = "Ctrl+E", .desc = "Close panel, return to diff" },
        .{ .key = "ESC ESC", .desc = "Interrupt agent (double-tap)" },
    };

    for (session_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{} });

    // PERMISSION PROMPT section
    try content_lines.append(app.allocator, .{ .text = "PERMISSION PROMPT", .style = section_style });

    const perm_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "j/k or Up/Down", .desc = "Navigate options" },
        .{ .key = "Enter/y", .desc = "Accept selected option" },
        .{ .key = "ESC/n", .desc = "Reject/cancel" },
    };

    for (perm_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{} });

    // SLASH COMMANDS section
    try content_lines.append(app.allocator, .{ .text = "SLASH COMMANDS", .style = section_style });

    const slash_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "/clear", .desc = "Clear session and start fresh" },
        .{ .key = "/model", .desc = "Switch AI model" },
        .{ .key = "/resume", .desc = "Resume previous session" },
    };

    for (slash_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{} });

    // Footer
    try content_lines.append(app.allocator, .{ .text = "j/k: Scroll  |  Ctrl+D/U: Page  |  g/G: Top/Bottom  |  ? or ESC: Close", .style = .{ .fg = Color.dim_gray } });

    // Calculate visible range based on scroll offset
    const scroll_offset = agent_state.help_scroll_offset;
    const max_visible_rows = popup_height -| 2; // Account for borders
    const total_content_rows = content_lines.items.len;
    const visible_start = scroll_offset;
    const visible_end = @min(visible_start + max_visible_rows, total_content_rows);

    // Show scroll indicator at top if scrolled down
    var current_row: usize = 0;
    if (scroll_offset > 0) {
        const indicator = "\xe2\x96\xb2 (scroll up for more)"; // ▲
        var indicator_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = .{ .fg = Color.dim_gray } },
        };
        _ = popup_win.print(&indicator_seg, .{ .row_offset = @intCast(current_row) });
        current_row += 1;
    }

    // Render visible content
    for (visible_start..visible_end) |content_idx| {
        if (current_row >= max_visible_rows -| 1) break; // Leave room for bottom indicator

        const line = content_lines.items[content_idx];

        if (line.is_separator) {
            // Render separator
            if (popup_width > 2) {
                const sep_width = popup_width - 2;
                const sep_text = try RenderUtils.frameTextSlice(app, sep_width);
                @memset(sep_text, '-');
                var sep_segments = [_]vaxis.Cell.Segment{
                    .{ .text = sep_text, .style = .{ .fg = Color.dim_gray } },
                };
                _ = popup_win.print(&sep_segments, .{ .row_offset = @intCast(current_row) });
            }
        } else if (line.key) |key| {
            // Render keybinding
            var segments = [_]vaxis.Cell.Segment{
                .{ .text = "  ", .style = .{} },
                .{ .text = key, .style = line.key_style.? },
                .{ .text = "  ", .style = .{} },
                .{ .text = line.desc.?, .style = line.desc_style.? },
            };
            _ = popup_win.print(&segments, .{ .row_offset = @intCast(current_row) });
        } else if (line.text) |text| {
            // Render regular text
            var text_seg = [_]vaxis.Cell.Segment{
                .{ .text = text, .style = line.style },
            };
            _ = popup_win.print(&text_seg, .{ .row_offset = @intCast(current_row) });
        }

        current_row += 1;
    }

    // Show scroll indicator at bottom if there's more content
    if (visible_end < total_content_rows and current_row < max_visible_rows) {
        const indicator = "\xe2\x96\xbc (scroll down for more)"; // ▼
        var indicator_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = .{ .fg = Color.dim_gray } },
        };
        _ = popup_win.print(&indicator_seg, .{ .row_offset = @intCast(current_row) });
    }
}

/// Handle keyboard input when agent help is visible
/// Returns true if key was handled, false to pass through
pub fn handleKey(agent_state: *AgentState, key: vaxis.Key) bool {
    const max_visible: usize = 30;
    const max_scroll: usize = if (HELP_CONTENT_ROWS > max_visible) HELP_CONTENT_ROWS - max_visible else 0;

    switch (key.codepoint) {
        'j', 'J' => {
            if (agent_state.help_scroll_offset < max_scroll) {
                agent_state.help_scroll_offset += 1;
            }
            return true;
        },
        'k', 'K' => {
            if (agent_state.help_scroll_offset > 0) {
                agent_state.help_scroll_offset -= 1;
            }
            return true;
        },
        'd', 'D' => {
            // Page down (half page) - only without modifiers
            if (!key.mods.ctrl) {
                const jump = max_visible / 2;
                agent_state.help_scroll_offset = @min(agent_state.help_scroll_offset + jump, max_scroll);
                return true;
            }
        },
        'u', 'U' => {
            // Page up (half page) - only without modifiers
            if (!key.mods.ctrl) {
                const jump = max_visible / 2;
                if (agent_state.help_scroll_offset >= jump) {
                    agent_state.help_scroll_offset -= jump;
                } else {
                    agent_state.help_scroll_offset = 0;
                }
                return true;
            }
        },
        'g' => {
            // Go to top
            agent_state.help_scroll_offset = 0;
            return true;
        },
        'G' => {
            // Go to bottom
            agent_state.help_scroll_offset = max_scroll;
            return true;
        },
        'q', '?' => {
            // Close help
            agent_state.help_visible = false;
            agent_state.help_scroll_offset = 0;
            return true;
        },
        else => {},
    }

    // Handle Ctrl+D and Ctrl+U for page navigation
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'd' => {
                const jump = max_visible / 2;
                agent_state.help_scroll_offset = @min(agent_state.help_scroll_offset + jump, max_scroll);
                return true;
            },
            'u' => {
                const jump = max_visible / 2;
                if (agent_state.help_scroll_offset >= jump) {
                    agent_state.help_scroll_offset -= jump;
                } else {
                    agent_state.help_scroll_offset = 0;
                }
                return true;
            },
            else => {},
        }
    }

    // Handle ESC to close
    if (key.codepoint == 27) {
        agent_state.help_visible = false;
        agent_state.help_scroll_offset = 0;
        return true;
    }

    // Handle arrow keys
    if (key.matches(vaxis.Key.down, .{})) {
        if (agent_state.help_scroll_offset < max_scroll) {
            agent_state.help_scroll_offset += 1;
        }
        return true;
    } else if (key.matches(vaxis.Key.up, .{})) {
        if (agent_state.help_scroll_offset > 0) {
            agent_state.help_scroll_offset -= 1;
        }
        return true;
    }

    // Block other keys while help is visible
    return true;
}

const ContentLine = struct {
    text: ?[]const u8 = null,
    key: ?[]const u8 = null,
    desc: ?[]const u8 = null,
    style: vaxis.Style = .{},
    key_style: ?vaxis.Style = null,
    desc_style: ?vaxis.Style = null,
    is_separator: bool = false,
};
