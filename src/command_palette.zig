const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("git/parser.zig");
const line_map = @import("line_map.zig");

const Allocator = std.mem.Allocator;

// Forward declare App type (will be imported by app.zig)
const App = @import("app.zig").App;

pub const Category = enum {
    navigation,
    view,
    file,
    help,
};

pub const CommandAction = union(enum) {
    jump_to_file: usize, // file_idx
    toggle_view_mode: void,
    refresh_diff: void,
    show_help: void,
    quit: void,
};

pub const Command = struct {
    name: []const u8, // Original full path/name
    display_name: []const u8, // Truncated/formatted for display
    description: []const u8,
    action: CommandAction,
    category: Category,
    owns_display_name: bool, // Track if we need to free display_name
};

pub const CommandPaletteState = struct {
    query_buffer: [256]u8,
    query_len: usize,
    commands: std.ArrayList(Command),
    filtered_commands: std.ArrayList(usize), // Indices into commands array
    selected_idx: usize, // Index into filtered_commands
    scroll_offset: usize, // For scrolling long lists
    allocator: Allocator,

    const max_visible_items = 10;

    pub fn init(allocator: Allocator) CommandPaletteState {
        return .{
            .query_buffer = undefined,
            .query_len = 0,
            .commands = std.ArrayList(Command).init(allocator),
            .filtered_commands = std.ArrayList(usize).init(allocator),
            .selected_idx = 0,
            .scroll_offset = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandPaletteState) void {
        // Free owned display names
        for (self.commands.items) |cmd| {
            if (cmd.owns_display_name) {
                self.allocator.free(cmd.display_name);
            }
        }
        self.commands.deinit();
        self.filtered_commands.deinit();
    }

    pub fn reset(self: *CommandPaletteState) void {
        self.query_len = 0;
        self.selected_idx = 0;
        self.scroll_offset = 0;
        // Free owned display names before clearing
        for (self.commands.items) |cmd| {
            if (cmd.owns_display_name) {
                self.allocator.free(cmd.display_name);
            }
        }
        self.commands.clearRetainingCapacity();
        self.filtered_commands.clearRetainingCapacity();
    }

    // Build command registry from current app state (both files and commands)
    pub fn buildCommandRegistry(self: *CommandPaletteState, files: []const parser.FileDiff) !void {
        self.commands.clearRetainingCapacity();

        // Add file navigation commands
        for (files, 0..) |file, idx| {
            const path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Apply smart path truncation for display
            const display_path = truncatePath(self.allocator, path, 70) catch path;
            const owns_display = !std.mem.eql(u8, path, display_path);

            try self.commands.append(.{
                .name = path,
                .display_name = display_path,
                .description = "Jump to file",
                .action = .{ .jump_to_file = idx },
                .category = .file,
                .owns_display_name = owns_display,
            });
        }

        // Add built-in commands
        try self.commands.append(.{
            .name = "Toggle View Mode",
            .display_name = "Toggle View Mode",
            .description = "Switch between unified and side-by-side",
            .action = .toggle_view_mode,
            .category = .view,
            .owns_display_name = false,
        });

        try self.commands.append(.{
            .name = "Refresh Diff",
            .display_name = "Refresh Diff",
            .description = "Reload the diff from git",
            .action = .refresh_diff,
            .category = .view,
            .owns_display_name = false,
        });

        try self.commands.append(.{
            .name = "Show Help",
            .display_name = "Show Help",
            .description = "Display help overlay",
            .action = .show_help,
            .category = .help,
            .owns_display_name = false,
        });

        try self.commands.append(.{
            .name = "Quit",
            .display_name = "Quit",
            .description = "Exit Skim",
            .action = .quit,
            .category = .navigation,
            .owns_display_name = false,
        });

        // Initialize with files by default (no '>' prefix)
        try self.filterCommands();
    }

    // Filter commands based on query (case-insensitive substring matching)
    // VSCode-style: '>' prefix switches to command mode, otherwise file mode
    pub fn filterCommands(self: *CommandPaletteState) !void {
        self.filtered_commands.clearRetainingCapacity();

        const query = self.query_buffer[0..self.query_len];

        // Check if we're in command mode (query starts with '>')
        const is_command_mode = query.len > 0 and query[0] == '>';
        const search_query = if (is_command_mode) query[1..] else query;

        if (search_query.len == 0) {
            // Show all commands in current mode
            for (self.commands.items, 0..) |cmd, idx| {
                const show = if (is_command_mode)
                    cmd.category != .file // Show non-file commands
                else
                    cmd.category == .file; // Show only files

                if (show) {
                    try self.filtered_commands.append(idx);
                }
            }
        } else {
            // Filter based on query and current mode
            for (self.commands.items, 0..) |cmd, idx| {
                const category_matches = if (is_command_mode)
                    cmd.category != .file
                else
                    cmd.category == .file;

                if (category_matches and
                    (containsIgnoreCase(cmd.name, search_query) or
                    containsIgnoreCase(cmd.description, search_query)))
                {
                    try self.filtered_commands.append(idx);
                }
            }
        }

        // Clamp selected index to filtered results
        if (self.filtered_commands.items.len == 0) {
            self.selected_idx = 0;
        } else if (self.selected_idx >= self.filtered_commands.items.len) {
            self.selected_idx = self.filtered_commands.items.len - 1;
        }

        // Adjust scroll offset if needed
        self.adjustScrollOffset();
    }

    pub fn moveSelectionUp(self: *CommandPaletteState) void {
        if (self.filtered_commands.items.len == 0) return;
        if (self.selected_idx > 0) {
            self.selected_idx -= 1;
            self.adjustScrollOffset();
        }
    }

    pub fn moveSelectionDown(self: *CommandPaletteState) void {
        if (self.filtered_commands.items.len == 0) return;
        if (self.selected_idx < self.filtered_commands.items.len - 1) {
            self.selected_idx += 1;
            self.adjustScrollOffset();
        }
    }

    fn adjustScrollOffset(self: *CommandPaletteState) void {
        if (self.filtered_commands.items.len == 0) {
            self.scroll_offset = 0;
            return;
        }

        // Scroll down if selection is below visible area
        if (self.selected_idx >= self.scroll_offset + max_visible_items) {
            self.scroll_offset = self.selected_idx - max_visible_items + 1;
        }

        // Scroll up if selection is above visible area
        if (self.selected_idx < self.scroll_offset) {
            self.scroll_offset = self.selected_idx;
        }
    }

    pub fn getSelectedCommand(self: *const CommandPaletteState) ?*const Command {
        if (self.filtered_commands.items.len == 0) return null;
        const cmd_idx = self.filtered_commands.items[self.selected_idx];
        return &self.commands.items[cmd_idx];
    }
};

// Truncate path for display: keep last 2 components full, truncate rest to first char
// Example: "projects/open-source/skim/src/file.zig" -> "p/o/s/src/file.zig"
fn truncatePath(allocator: Allocator, path: []const u8, max_length: usize) ![]const u8 {
    if (path.len <= max_length) return path;

    // Split path by '/'
    var components = std.ArrayList([]const u8).init(allocator);
    defer components.deinit();

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len > 0) {
            try components.append(component);
        }
    }

    if (components.items.len <= 2) return path;

    // Keep last 2 components full, truncate earlier ones to first char
    const keep_full = 2;
    const truncate_count = components.items.len - keep_full;

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (components.items, 0..) |component, i| {
        if (i > 0) try result.append('/');

        if (i < truncate_count) {
            // Truncate to first character
            if (component.len > 0) {
                try result.append(component[0]);
            }
        } else {
            // Keep full
            try result.appendSlice(component);
        }
    }

    return result.toOwnedSlice();
}

// Case-insensitive substring search
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            const h_char = haystack[i + j];
            const n_char = c;
            if (std.ascii.toLower(h_char) != std.ascii.toLower(n_char)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub fn renderCommandPalette(app: *App, win: vaxis.Window) !void {
    // Larger popup for better file path visibility (80% of screen width, up to 100 chars)
    const palette_width = @min(100, (win.width * 80) / 100);
    const palette_height = @min(25, win.height - 4);
    const x_offset = if (win.width > palette_width) (win.width - palette_width) / 2 else 0;
    const y_offset = if (win.height > palette_height) (win.height - palette_height) / 2 else 0;

    const palette_win = win.child(.{
        .x_off = x_offset,
        .y_off = y_offset,
        .width = .{ .limit = palette_width },
        .height = .{ .limit = palette_height },
        .border = .{
            .where = .all,
            .style = .{
                .fg = .{ .index = 6 }, // cyan
            },
        },
    });

    // Clear the palette window
    palette_win.clear();

    // Fill with solid background to prevent text bleeding
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{
            .bg = .{ .index = 0 }, // black background
        },
    };
    palette_win.fill(bg_cell);

    const state = &app.state.command_palette_state;

    // Line 0: Title (dynamic based on mode)
    const query = state.query_buffer[0..state.query_len];
    const is_command_mode = query.len > 0 and query[0] == '>';
    const title = if (is_command_mode) "Command Palette" else "Go to File";
    const title_style = vaxis.Style{
        .fg = .{ .index = 6 }, // cyan
        .bold = true,
    };
    var title_segments = [_]vaxis.Cell.Segment{
        .{ .text = title, .style = title_style },
    };
    _ = try palette_win.print(&title_segments, .{});

    // Line 1: Input field
    const input_style = vaxis.Style{
        .fg = .{ .index = 7 }, // white
    };
    var input_segments = [_]vaxis.Cell.Segment{
        .{ .text = "> ", .style = .{ .fg = .{ .index = 6 } } }, // cyan prompt
        .{ .text = query, .style = input_style },
    };
    _ = try palette_win.print(&input_segments, .{ .row_offset = 1 });

    // Show cursor after the query text
    palette_win.showCursor(2 + query.len, 1);

    // Line 2: Separator
    const sep_style = vaxis.Style{
        .fg = .{ .index = 8 }, // dim
    };
    var sep_text: [60]u8 = undefined;
    for (0..@min(palette_width - 2, sep_text.len)) |i| {
        sep_text[i] = '-';
    }
    var sep_segments = [_]vaxis.Cell.Segment{
        .{ .text = sep_text[0..@min(palette_width - 2, sep_text.len)], .style = sep_style },
    };
    _ = try palette_win.print(&sep_segments, .{ .row_offset = 2 });

    // Lines 3+: Command list
    if (state.filtered_commands.items.len == 0) {
        const no_results = "No matching commands";
        const no_results_style = vaxis.Style{
            .fg = .{ .index = 8 }, // dim
        };
        var no_results_segments = [_]vaxis.Cell.Segment{
            .{ .text = no_results, .style = no_results_style },
        };
        _ = try palette_win.print(&no_results_segments, .{ .row_offset = 3 });
    } else {
        const start_idx = state.scroll_offset;
        const end_idx = @min(start_idx + CommandPaletteState.max_visible_items, state.filtered_commands.items.len);

        for (start_idx..end_idx) |i| {
            const cmd_idx = state.filtered_commands.items[i];
            const cmd = &state.commands.items[cmd_idx];
            const is_selected = (i == state.selected_idx);

            const row = 3 + (i - start_idx);

            // Selection indicator
            const indicator = if (is_selected) "▶ " else "  ";
            const indicator_style = vaxis.Style{
                .fg = if (is_selected) .{ .index = 6 } else .{ .index = 8 }, // cyan or dim
            };

            // Command name
            const name_style = vaxis.Style{
                .fg = if (is_selected) .{ .index = 7 } else .{ .index = 7 }, // white
                .bold = is_selected,
            };

            // Description
            const desc_style = vaxis.Style{
                .fg = .{ .index = 8 }, // dim
            };

            // Format: "▶ Name             Description"
            const spacing = "  ";

            var segments = [_]vaxis.Cell.Segment{
                .{ .text = indicator, .style = indicator_style },
                .{ .text = cmd.display_name, .style = name_style },
                .{ .text = spacing, .style = .{} },
                .{ .text = cmd.description, .style = desc_style },
            };

            _ = try palette_win.print(&segments, .{ .row_offset = row });
        }

        // Show scroll indicator if there are more items
        if (end_idx < state.filtered_commands.items.len) {
            const more_text = "...";
            const more_style = vaxis.Style{
                .fg = .{ .index = 8 }, // dim
            };
            var more_segments = [_]vaxis.Cell.Segment{
                .{ .text = more_text, .style = more_style },
            };
            const last_row = 3 + CommandPaletteState.max_visible_items;
            _ = try palette_win.print(&more_segments, .{ .row_offset = last_row });
        }
    }
}
