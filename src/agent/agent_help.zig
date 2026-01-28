const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("../app.zig").App;
const Color = @import("../rendering/common.zig").Color;
const RenderUtils = @import("../rendering/utils.zig").RenderUtils;
const AgentState = @import("state.zig").AgentState;

// Total number of content rows in help popup (approximate)
const HELP_CONTENT_ROWS = 70;
const DIALOG_PADDING: usize = 1; // Horizontal padding inside dialogs

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
    });

    popup_win.clear();

    // Fill with dark gray background to differentiate from main content
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{
            .bg = Color.dialog_bg,
        },
    };
    popup_win.fill(bg_cell);

    // Render fixed header (title + separator) - these don't scroll
    const header_title_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true };
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = "Agent Mode - Keybindings", .style = header_title_style },
    };
    _ = popup_win.print(&title_seg, .{ .row_offset = DIALOG_PADDING, .col_offset = DIALOG_PADDING });

    // Separator line
    if (popup_width > DIALOG_PADDING * 2) {
        const sep_width = popup_width - (DIALOG_PADDING * 2);
        const sep_text = try RenderUtils.frameTextSlice(app, sep_width);
        @memset(sep_text, '-');
        var sep_segments = [_]vaxis.Cell.Segment{
            .{ .text = sep_text, .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
        };
        _ = popup_win.print(&sep_segments, .{ .row_offset = DIALOG_PADDING + 1, .col_offset = DIALOG_PADDING });
    }

    const header_rows: usize = 2; // title + separator (fixed, don't scroll)

    // Build scrollable content lines (excluding title/separator)
    var content_lines: std.ArrayList(ContentLine) = .{};
    defer content_lines.deinit(app.allocator);

    const section_style = vaxis.Style{
        .fg = Color.yellow,
        .bg = Color.dialog_bg,
        .bold = true,
    };
    const key_style = vaxis.Style{
        .fg = Color.cyan,
        .bg = Color.dialog_bg,
    };
    const desc_style = vaxis.Style{
        .fg = Color.white,
        .bg = Color.dialog_bg,
    };

    // GLOBAL section - keybinds that work in any mode
    try content_lines.append(app.allocator, .{ .text = "GLOBAL (any mode)", .style = section_style });

    const global_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Ctrl+E", .desc = "Close panel, return to diff" },
        .{ .key = "Ctrl+G", .desc = "Edit prompt in $EDITOR" },
        .{ .key = "Ctrl+W h/l", .desc = "Focus diff/agent panel" },
        .{ .key = "Ctrl+W w", .desc = "Cycle focus between panels" },
        .{ .key = "Ctrl+W o", .desc = "Toggle full screen" },
        .{ .key = "Ctrl+S", .desc = "Stash/unstash prompt" },
        .{ .key = "Ctrl+T", .desc = "Toggle todo list expansion" },
    };

    for (global_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

    // INSERT MODE section
    try content_lines.append(app.allocator, .{ .text = "INSERT MODE (typing in prompt)", .style = section_style });

    const input_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Enter", .desc = "Send prompt to agent" },
        .{ .key = "Ctrl+J", .desc = "Insert newline in prompt" },
        .{ .key = "ESC/Ctrl+C", .desc = "Exit to normal mode" },
        .{ .key = "/", .desc = "Show slash command menu (at start)" },
        .{ .key = "@", .desc = "Show file picker (at start)" },
        .{ .key = "!", .desc = "Toggle shell command mode (empty input)" },
        .{ .key = "Up", .desc = "Restore staged prompt (empty input)" },
    };

    for (input_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

    // NORMAL MODE section
    try content_lines.append(app.allocator, .{ .text = "NORMAL MODE (vim on prompt)", .style = section_style });

    const normal_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "i/a/I/A", .desc = "Enter insert mode" },
        .{ .key = "h/l", .desc = "Move cursor left/right" },
        .{ .key = "w/b/e", .desc = "Word motions" },
        .{ .key = "0/$", .desc = "Line start/end" },
        .{ .key = "gg/G", .desc = "Jump to top/bottom of input" },
        .{ .key = "Ctrl+D/U", .desc = "Half-page down/up in input" },
        .{ .key = "x/dd", .desc = "Delete char/line" },
        .{ .key = ":", .desc = "Open command palette" },
        .{ .key = "?", .desc = "Show this help" },
        .{ .key = "gb", .desc = "Enter history mode" },
        .{ .key = "gt/gT", .desc = "Next/previous tab" },
        .{ .key = "Space+b", .desc = "Enter history mode" },
        .{ .key = "Space+f", .desc = "Scroll to bottom, enable follow" },
        .{ .key = "V", .desc = "Toggle diff view mode" },
        .{ .key = "Tab", .desc = "Cycle session modes" },
        .{ .key = "ESC ESC", .desc = "Interrupt agent (double-tap)" },
    };

    for (normal_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

    // HISTORY MODE section
    try content_lines.append(app.allocator, .{ .text = "HISTORY MODE (gb or Space+b)", .style = section_style });

    const history_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "j/k", .desc = "Move cursor down/up" },
        .{ .key = "h/l", .desc = "Jump to prev/next message" },
        .{ .key = "gg/G", .desc = "Jump to top/bottom" },
        .{ .key = "Ctrl+D/U", .desc = "Page down/up" },
        .{ .key = "M", .desc = "Move cursor to middle of viewport" },
        .{ .key = "v", .desc = "Enter visual selection mode" },
        .{ .key = "y", .desc = "Yank user message at cursor" },
        .{ .key = "yy", .desc = "Yank current line" },
        .{ .key = "Y", .desc = "Yank entire current message" },
        .{ .key = "Space+f", .desc = "Resume follow mode, exit history" },
        .{ .key = "i", .desc = "Exit to insert mode" },
        .{ .key = "ESC/q", .desc = "Exit to normal mode" },
    };

    for (history_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

    // VISUAL MODE section (in history)
    try content_lines.append(app.allocator, .{ .text = "VISUAL MODE (in history, v)", .style = section_style });

    const visual_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "j/k", .desc = "Extend selection down/up" },
        .{ .key = "y", .desc = "Yank selection to clipboard" },
        .{ .key = "ESC/v", .desc = "Exit visual mode" },
    };

    for (visual_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

    // PERMISSION PROMPT section
    try content_lines.append(app.allocator, .{ .text = "PERMISSION PROMPT", .style = section_style });

    const perm_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "j/k/Up/Down", .desc = "Navigate options" },
        .{ .key = "Ctrl+D/U", .desc = "Scroll message history" },
        .{ .key = "Enter/y", .desc = "Accept selected option" },
        .{ .key = "ESC/n", .desc = "Reject/cancel" },
    };

    for (perm_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

    // MENUS section
    try content_lines.append(app.allocator, .{ .text = "MENUS (/, @, :)", .style = section_style });

    const menu_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Ctrl+N/P", .desc = "Navigate menu items" },
        .{ .key = "Up/Down", .desc = "Navigate (command palette)" },
        .{ .key = "Tab", .desc = "Insert selected (slash/file)" },
        .{ .key = "Enter", .desc = "Execute/insert selected" },
        .{ .key = "ESC", .desc = "Close menu" },
    };

    for (menu_bindings) |binding| {
        try content_lines.append(app.allocator, .{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

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
    try content_lines.append(app.allocator, .{ .text = "", .style = .{ .bg = Color.dialog_bg } });

    // Footer
    try content_lines.append(app.allocator, .{ .text = "j/k: Scroll  |  Ctrl+D/U: Page  |  g/G: Top/Bottom  |  ? or ESC: Close", .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } });

    // Calculate visible range based on scroll offset
    // Account for: top padding + fixed header rows + bottom padding
    const scroll_offset = agent_state.help_scroll_offset;
    const content_area_start = DIALOG_PADDING + header_rows; // Start after padding + header
    const max_visible_rows = popup_height -| (DIALOG_PADDING * 2 + header_rows + 1); // -1 for bottom indicator
    const total_content_rows = content_lines.items.len;
    const visible_start = scroll_offset;
    const visible_end = @min(visible_start + max_visible_rows, total_content_rows);

    // Show scroll indicator at top if scrolled down
    var current_row: usize = content_area_start;
    if (scroll_offset > 0) {
        const indicator = "\xe2\x96\xb2 (scroll up for more)"; // ▲
        var indicator_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
        };
        _ = popup_win.print(&indicator_seg, .{ .row_offset = @intCast(current_row), .col_offset = DIALOG_PADDING });
        current_row += 1;
    }

    // Render visible content
    for (visible_start..visible_end) |content_idx| {
        if (current_row >= popup_height -| (DIALOG_PADDING + 1)) break; // Leave room for bottom padding + indicator

        const line = content_lines.items[content_idx];

        if (line.is_separator) {
            // Render separator
            if (popup_width > DIALOG_PADDING * 2) {
                const local_sep_width = popup_width - (DIALOG_PADDING * 2);
                const local_sep_text = try RenderUtils.frameTextSlice(app, local_sep_width);
                @memset(local_sep_text, '-');
                var sep_segments = [_]vaxis.Cell.Segment{
                    .{ .text = local_sep_text, .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
                };
                _ = popup_win.print(&sep_segments, .{ .row_offset = @intCast(current_row), .col_offset = DIALOG_PADDING });
            }
        } else if (line.key) |key| {
            // Render keybinding
            var segments = [_]vaxis.Cell.Segment{
                .{ .text = "  ", .style = .{ .bg = Color.dialog_bg } },
                .{ .text = key, .style = line.key_style.? },
                .{ .text = "  ", .style = .{ .bg = Color.dialog_bg } },
                .{ .text = line.desc.?, .style = line.desc_style.? },
            };
            _ = popup_win.print(&segments, .{ .row_offset = @intCast(current_row), .col_offset = DIALOG_PADDING });
        } else if (line.text) |text| {
            // Render regular text
            var text_seg = [_]vaxis.Cell.Segment{
                .{ .text = text, .style = line.style },
            };
            _ = popup_win.print(&text_seg, .{ .row_offset = @intCast(current_row), .col_offset = DIALOG_PADDING });
        }

        current_row += 1;
    }

    // Show scroll indicator at bottom if there's more content
    if (visible_end < total_content_rows and current_row < popup_height -| DIALOG_PADDING) {
        const indicator = "\xe2\x96\xbc (scroll down for more)"; // ▼
        var indicator_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
        };
        _ = popup_win.print(&indicator_seg, .{ .row_offset = @intCast(current_row), .col_offset = DIALOG_PADDING });
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
