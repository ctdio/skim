const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("git/parser.zig");
const line_map = @import("line_map.zig");
const git = @import("git/diff.zig");
const DiffSource = git.DiffSource;
const DiffStats = git.DiffStats;
const state_helpers = @import("state.zig");
const render_utils = @import("rendering/utils.zig");
const app_config = @import("config.zig");

const Allocator = std.mem.Allocator;
const StateHelpers = state_helpers.StateHelpers;
const RenderUtils = render_utils.RenderUtils;

// Forward declare App type (will be imported by app.zig)
const App = @import("app.zig").App;

pub const Category = enum {
    navigation,
    view,
    file,
    help,
    diff,
};

pub const DiffMode = enum {
    working,
    staged,
    main,
};

pub const CommandAction = union(enum) {
    jump_to_file: usize, // file_idx
    toggle_view_mode: void,
    refresh_diff: void,
    show_help: void,
    quit: void,
    switch_diff_mode: DiffMode,
    show_mcp_status: void,
    switch_agent: void,
};

pub const Command = struct {
    name: []const u8, // Original full path/name
    display_name: []const u8, // Truncated/formatted for display
    description: []const u8,
    action: CommandAction,
    category: Category,
    owns_display_name: bool, // Track if we need to free display_name
    additions: usize, // For file commands - number of additions
    deletions: usize, // For file commands - number of deletions
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
            .commands = .{},
            .filtered_commands = .{},
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
        self.commands.deinit(self.allocator);
        self.filtered_commands.deinit(self.allocator);
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
    pub fn buildCommandRegistry(self: *CommandPaletteState, app: *App, files: []const parser.FileDiff) !void {
        self.commands.clearRetainingCapacity();

        // Pre-fetch stats for all diff sources (fast with --shortstat)
        const working_stats = git.getDiffStats(self.allocator, DiffSource{ .working_dir = .{ .staged = false } }) catch DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
        const staged_stats = git.getDiffStats(self.allocator, DiffSource{ .working_dir = .{ .staged = true } }) catch DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        // For main branch, try to detect default branch
        const default_branch = git.detectDefaultBranch(self.allocator) catch null;
        const main_stats = if (default_branch) |branch| blk: {
            const stats = git.getDiffStats(self.allocator, DiffSource{ .single_ref = .{ .ref = branch, .staged = false } }) catch DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
            self.allocator.free(branch);
            break :blk stats;
        } else DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        // Add file navigation commands with stats
        for (files, 0..) |*file, idx| {
            const path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Calculate stats for this file
            const stats = StateHelpers.calculateDiffStats(app, file);

            // Apply smart path truncation for display
            const display_path = truncatePath(self.allocator, path, 70) catch path;
            const owns_display = !std.mem.eql(u8, path, display_path);

            try self.commands.append(self.allocator, .{
                .name = path,
                .display_name = display_path,
                .description = "Jump to file",
                .action = .{ .jump_to_file = idx },
                .category = .file,
                .owns_display_name = owns_display,
                .additions = stats.additions,
                .deletions = stats.deletions,
            });
        }

        // Add built-in commands (no stats for non-file commands)
        try self.commands.append(self.allocator, .{
            .name = "Toggle View Mode",
            .display_name = "Toggle View Mode",
            .description = "Switch between unified and side-by-side",
            .action = .toggle_view_mode,
            .category = .view,
            .owns_display_name = false,
            .additions = 0,
            .deletions = 0,
        });

        try self.commands.append(self.allocator, .{
            .name = "Refresh Diff",
            .display_name = "Refresh Diff",
            .description = "Reload the diff from git",
            .action = .refresh_diff,
            .category = .view,
            .owns_display_name = false,
            .additions = 0,
            .deletions = 0,
        });

        try self.commands.append(self.allocator, .{
            .name = "Show Help",
            .display_name = "Show Help",
            .description = "Display help overlay",
            .action = .show_help,
            .category = .help,
            .owns_display_name = false,
            .additions = 0,
            .deletions = 0,
        });

        // Only show daemon status and agent commands if MCP is enabled
        if (app_config.isMcpEnabled(self.allocator)) {
            try self.commands.append(self.allocator, .{
                .name = "Daemon Status",
                .display_name = "Daemon Status",
                .description = "Show daemon connection status",
                .action = .show_mcp_status,
                .category = .help,
                .owns_display_name = false,
                .additions = 0,
                .deletions = 0,
            });

            try self.commands.append(self.allocator, .{
                .name = "Switch Agent",
                .display_name = "Switch Agent",
                .description = "Select a different AI agent",
                .action = .switch_agent,
                .category = .view,
                .owns_display_name = false,
                .additions = 0,
                .deletions = 0,
            });
        }

        try self.commands.append(self.allocator, .{
            .name = "Quit",
            .display_name = "Quit",
            .description = "Exit Skim",
            .action = .quit,
            .category = .navigation,
            .owns_display_name = false,
            .additions = 0,
            .deletions = 0,
        });

        // Diff mode switching commands with stats
        try self.commands.append(self.allocator, .{
            .name = "diff:working",
            .display_name = "diff:working",
            .description = "Switch to working directory changes",
            .action = .{ .switch_diff_mode = .working },
            .category = .diff,
            .owns_display_name = false,
            .additions = working_stats.additions,
            .deletions = working_stats.deletions,
        });

        try self.commands.append(self.allocator, .{
            .name = "diff:staged",
            .display_name = "diff:staged",
            .description = "Switch to staged changes",
            .action = .{ .switch_diff_mode = .staged },
            .category = .diff,
            .owns_display_name = false,
            .additions = staged_stats.additions,
            .deletions = staged_stats.deletions,
        });

        try self.commands.append(self.allocator, .{
            .name = "diff:main",
            .display_name = "diff:main",
            .description = "Compare against main branch",
            .action = .{ .switch_diff_mode = .main },
            .category = .diff,
            .owns_display_name = false,
            .additions = main_stats.additions,
            .deletions = main_stats.deletions,
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
                    try self.filtered_commands.append(self.allocator, idx);
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
                    try self.filtered_commands.append(self.allocator, idx);
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
        self.selected_idx = if (self.selected_idx == 0) self.filtered_commands.items.len - 1 else self.selected_idx - 1;
        self.adjustScrollOffset();
    }

    pub fn moveSelectionDown(self: *CommandPaletteState) void {
        if (self.filtered_commands.items.len == 0) return;
        self.selected_idx = (self.selected_idx + 1) % self.filtered_commands.items.len;
        self.adjustScrollOffset();
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
    var components: std.ArrayList([]const u8) = .{};
    defer components.deinit(allocator);

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len > 0) {
            try components.append(allocator, component);
        }
    }

    if (components.items.len <= 2) return path;

    // Keep last 2 components full, truncate earlier ones to first char
    const keep_full = 2;
    const truncate_count = components.items.len - keep_full;

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    for (components.items, 0..) |component, i| {
        if (i > 0) try result.append(allocator, '/');

        if (i < truncate_count) {
            // Truncate to first character
            if (component.len > 0) {
                try result.append(allocator, component[0]);
            }
        } else {
            // Keep full
            try result.appendSlice(allocator, component);
        }
    }

    return result.toOwnedSlice(allocator);
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
    const state = &app.state.command_palette_state;

    // Calculate required width based on visible commands
    var max_content_width: usize = 60; // Minimum width
    const calc_start_idx = state.scroll_offset;
    const calc_end_idx = @min(calc_start_idx + CommandPaletteState.max_visible_items, state.filtered_commands.items.len);

    for (calc_start_idx..calc_end_idx) |i| {
        const cmd_idx = state.filtered_commands.items[i];
        const cmd = &state.commands.items[cmd_idx];

        // Calculate total width needed for this command: indicator + name + spacing + description + stats
        const indicator_width: usize = 2; // "▶ " or "  "
        const spacing_width: usize = 2; // "  "
        const stats_width: usize = if ((cmd.category == .file or cmd.category == .diff) and (cmd.additions > 0 or cmd.deletions > 0))
            32 // Approximate: " (+123, -456)" with padding
        else
            0;

        const line_width = indicator_width + cmd.display_name.len + spacing_width + cmd.description.len + stats_width;
        if (line_width > max_content_width) {
            max_content_width = line_width;
        }
    }

    // Add padding for borders and margins
    const border_padding: usize = 4;
    const desired_width = max_content_width + border_padding;

    // Use calculated width, but cap at 95% of screen width to leave room for status bar
    const palette_width = @min(desired_width, (win.width * 95) / 100);
    const palette_height = @min(25, win.height - 4);
    const x_offset = if (win.width > palette_width) (win.width - palette_width) / 2 else 0;
    const y_offset = if (win.height > palette_height) (win.height - palette_height) / 2 else 0;

    const palette_win = win.child(.{
        .x_off = x_offset,
        .y_off = y_offset,
        .width = @intCast(palette_width),
        .height = @intCast(palette_height),
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

    // Line 0: Title (dynamic based on mode) with stats
    const query = state.query_buffer[0..state.query_len];
    const is_command_mode = query.len > 0 and query[0] == '>';

    // Calculate stats for title
    const stats = StateHelpers.calculateTotalDiffStats(app, app.state.files);

    // Format title with stats
    var title_buf: [256]u8 = undefined;
    const title = if (is_command_mode)
        try std.fmt.bufPrint(&title_buf, "Command Palette ({d} files, +{d}, -{d})", .{ stats.files, stats.additions, stats.deletions })
    else
        try std.fmt.bufPrint(&title_buf, "Go to File ({d} files, +{d}, -{d})", .{ stats.files, stats.additions, stats.deletions });

    const title_style = vaxis.Style{
        .fg = .{ .index = 6 }, // cyan
        .bold = true,
    };
    var title_segments = [_]vaxis.Cell.Segment{
        .{ .text = title, .style = title_style },
    };
    _ = palette_win.print(&title_segments, .{});

    // Line 1: Input field
    const input_style = vaxis.Style{
        .fg = .{ .index = 7 }, // white
    };
    var input_segments = [_]vaxis.Cell.Segment{
        .{ .text = "> ", .style = .{ .fg = .{ .index = 6 } } }, // cyan prompt
        .{ .text = query, .style = input_style },
    };
    _ = palette_win.print(&input_segments, .{ .row_offset = 1  });

    // Show cursor after the query text
    palette_win.showCursor(@intCast(2 + query.len), 1);

    // Line 2: Separator (account for border width like help.zig does)
    const sep_style = vaxis.Style{
        .fg = .{ .index = 8 }, // dim
    };
    if (palette_win.width > 2) {
        // Subtract 2 for border padding (1 on each side)
        const sep_width = palette_win.width - 2;
        const sep_text = try RenderUtils.frameTextSlice(app, sep_width);
        @memset(sep_text, '-');
        var sep_segments = [_]vaxis.Cell.Segment{
            .{ .text = sep_text, .style = sep_style },
        };
        _ = palette_win.print(&sep_segments, .{ .row_offset = 2  });
    }

    // Lines 3+: Command list
    if (state.filtered_commands.items.len == 0) {
        const no_results = "No matching commands";
        const no_results_style = vaxis.Style{
            .fg = .{ .index = 8 }, // dim
        };
        var no_results_segments = [_]vaxis.Cell.Segment{
            .{ .text = no_results, .style = no_results_style },
        };
        _ = palette_win.print(&no_results_segments, .{ .row_offset = 3  });
    } else {
        // Use the already-declared calc_start_idx and calc_end_idx from above (line 393)

        for (calc_start_idx..calc_end_idx) |i| {
            const cmd_idx = state.filtered_commands.items[i];
            const cmd = &state.commands.items[cmd_idx];
            const is_selected = (i == state.selected_idx);

            const row = 3 + (i - calc_start_idx);

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

            // Format: "▶ Name             Description" with stats right-justified
            const spacing = "  ";

            // Build left-side segments (indicator, name, description)
            var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            defer segments.deinit(app.allocator);

            try segments.append(app.allocator, .{ .text = indicator, .style = indicator_style });
            try segments.append(app.allocator, .{ .text = cmd.display_name, .style = name_style });
            try segments.append(app.allocator, .{ .text = spacing, .style = .{} });
            try segments.append(app.allocator, .{ .text = cmd.description, .style = desc_style });

            // Add colored stats for file commands and diff commands (right-justified)
            if ((cmd.category == .file or cmd.category == .diff) and (cmd.additions > 0 or cmd.deletions > 0)) {
                // Calculate actual stats text width
                var stats_buf: [32]u8 = undefined;
                const stats_preview = try std.fmt.bufPrint(&stats_buf, "(+{d}, -{d})", .{ cmd.additions, cmd.deletions });
                const stats_width = stats_preview.len;

                // Calculate padding needed for right justification
                const right_margin = 2;
                const fixed_indicator_width = 2; // "▶ " or "  "

                // Calculate current line width (use fixed width for indicator to avoid shift when selected)
                const current_width = fixed_indicator_width + cmd.display_name.len + spacing.len + cmd.description.len;
                const available_width = if (palette_width > right_margin + stats_width)
                    palette_width - right_margin - stats_width
                else
                    palette_width - stats_width;

                const padding_needed = if (available_width > current_width)
                    available_width - current_width
                else
                    2; // Minimum spacing

                // Add padding before stats
                var padding_buf: [100]u8 = undefined;
                @memset(&padding_buf, ' ');
                const padding = padding_buf[0..@min(padding_needed, padding_buf.len)];
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, padding), .style = .{} });

                // Add colored stats segments
                const additions_text = try std.fmt.allocPrint(app.allocator, "+{d}", .{cmd.additions});
                defer app.allocator.free(additions_text);
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, additions_text), .style = .{ .fg = .{ .index = 2 }, .bold = true } });

                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, ", "), .style = .{} });

                const deletions_text = try std.fmt.allocPrint(app.allocator, "-{d}", .{cmd.deletions});
                defer app.allocator.free(deletions_text);
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, deletions_text), .style = .{ .fg = .{ .index = 1 }, .bold = true } });
            }

            _ = palette_win.print(segments.items, .{ .row_offset = @intCast(row ) });
        }

        // Show scroll indicator if there are more items
        if (calc_end_idx < state.filtered_commands.items.len) {
            const more_text = "...";
            const more_style = vaxis.Style{
                .fg = .{ .index = 8 }, // dim
            };
            var more_segments = [_]vaxis.Cell.Segment{
                .{ .text = more_text, .style = more_style },
            };
            const last_row = 3 + CommandPaletteState.max_visible_items;
            _ = palette_win.print(&more_segments, .{ .row_offset = @intCast(last_row ) });
        }
    }
}
