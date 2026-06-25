const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("git/parser.zig");
const line_map = @import("line_map.zig");
const git = @import("git/diff.zig");
const DiffSource = git.DiffSource;
const DiffStats = git.DiffStats;
const state_helpers = @import("state.zig");
const render_utils = @import("rendering/utils.zig");
const Color = @import("rendering/common.zig").Color;

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
    switch_agent: void,
    select_commit: void,
};

pub const Command = struct {
    name: []const u8, // Original full path/name
    display_name: []const u8, // Truncated/formatted for display
    aliases: []const []const u8 = &[_][]const u8{},
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
            const stats = app.getFileDiffStats(idx);

            // Apply smart path truncation for display
            // Leave room for: indicator (2) + spacing (2) + description (12) + stats (~15) + padding (4) = ~35 chars
            const display_path = truncatePath(self.allocator, path, 60) catch path;
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
            .aliases = &[_][]const u8{ ":v", ":view" },
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
            .aliases = &[_][]const u8{ ":e", ":refresh" },
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
            .aliases = &[_][]const u8{ ":h", ":help" },
            .description = "Display help overlay",
            .action = .show_help,
            .category = .help,
            .owns_display_name = false,
            .additions = 0,
            .deletions = 0,
        });

        try self.commands.append(self.allocator, .{
            .name = "Switch Agent",
            .display_name = "Switch Agent",
            .aliases = &[_][]const u8{":agent"},
            .description = "Select a different AI agent",
            .action = .switch_agent,
            .category = .view,
            .owns_display_name = false,
            .additions = 0,
            .deletions = 0,
        });

        try self.commands.append(self.allocator, .{
            .name = "Quit",
            .display_name = "Quit",
            .aliases = &[_][]const u8{ ":q", ":quit", ":qa" },
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
            .aliases = &[_][]const u8{ ":dw", ":working" },
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
            .aliases = &[_][]const u8{ ":ds", ":staged" },
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
            .aliases = &[_][]const u8{ ":dm", ":main" },
            .description = "Compare against main branch",
            .action = .{ .switch_diff_mode = .main },
            .category = .diff,
            .owns_display_name = false,
            .additions = main_stats.additions,
            .deletions = main_stats.deletions,
        });

        try self.commands.append(self.allocator, .{
            .name = "Select Commit...",
            .display_name = "Select Commit...",
            .aliases = &[_][]const u8{ ":dc", ":commit" },
            .description = "Diff against a specific commit",
            .action = .select_commit,
            .category = .diff,
            .owns_display_name = false,
            .additions = 0,
            .deletions = 0,
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
                        containsAlias(cmd.aliases, search_query) or
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

// Truncate path for display using middle-ellipsis strategy
// Example: "apps/platform/app/(settings)/ai-configuration/page.tsx" -> "apps/platform/.../ai-configuration/page.tsx"
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

    if (components.items.len <= 3) return path;

    // Strategy: Keep first 2 components + ellipsis + last 2 components
    // Example: apps/platform/.../ai-configuration/page.tsx
    const ellipsis = "...";
    const keep_left: usize = 2;
    const keep_right: usize = 2;

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    // Add left components
    for (components.items[0..keep_left], 0..) |component, i| {
        if (i > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, component);
    }

    // Add ellipsis
    try result.append(allocator, '/');
    try result.appendSlice(allocator, ellipsis);

    // Add right components
    const right_start = components.items.len - keep_right;
    for (components.items[right_start..]) |component| {
        try result.append(allocator, '/');
        try result.appendSlice(allocator, component);
    }

    // If still too long, fall back to just keeping last 3 components with ellipsis
    if (result.items.len > max_length and components.items.len > 3) {
        result.clearRetainingCapacity();
        try result.appendSlice(allocator, ellipsis);
        const fallback_start = components.items.len - 3;
        for (components.items[fallback_start..]) |component| {
            try result.append(allocator, '/');
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

fn containsAlias(aliases: []const []const u8, query: []const u8) bool {
    for (aliases) |alias| {
        if (containsIgnoreCase(alias, query)) return true;
    }
    return false;
}

// Fixed width for command palette - prevents jarring resize on content change
const COMMAND_PALETTE_WIDTH: usize = 100;
const DIALOG_PADDING: usize = 1; // Horizontal padding inside dialogs

pub fn renderCommandPalette(app: *App, win: vaxis.Window) !void {
    const state = &app.state.command_palette_state;

    // Calculate visible range for rendering
    const calc_start_idx = state.scroll_offset;
    const calc_end_idx = @min(calc_start_idx + CommandPaletteState.max_visible_items, state.filtered_commands.items.len);

    // Use fixed width, capped to window size
    const palette_width = @min(COMMAND_PALETTE_WIDTH, win.width -| 4);

    // Dynamic height based on content: 3 header rows + visible items (min 1 for "no results") + vertical padding
    const header_rows: usize = 3; // title, input, separator
    const visible_items = @max(1, @min(state.filtered_commands.items.len, CommandPaletteState.max_visible_items));
    const content_height = header_rows + visible_items + (DIALOG_PADDING * 2); // add top and bottom padding
    const palette_height = @min(content_height, win.height -| 4);
    const x_offset = if (win.width > palette_width) (win.width - palette_width) / 2 else 0;
    // Calculate y_offset based on where the dialog would be if at max height (centered)
    // This creates a stable anchor point that expands downward
    const max_height = header_rows + CommandPaletteState.max_visible_items + (DIALOG_PADDING * 2);
    const y_offset = if (win.height > max_height) (win.height - max_height) / 2 else 0;

    const palette_win = win.child(.{
        .x_off = x_offset,
        .y_off = @intCast(y_offset),
        .width = @intCast(palette_width),
        .height = @intCast(palette_height),
    });

    // Clear the palette window
    palette_win.clear();

    // Fill with dark gray background to differentiate from main content
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{
            .bg = Color.dialog_bg,
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
        .fg = Color.cyan,
        .bg = Color.dialog_bg,
        .bold = true,
    };
    // Copy into the frame buffer: vaxis cells hold a slice to the grapheme bytes
    // (no copy), and rendering happens after this function returns, so the stack
    // title_buf would be reused out from under the cells.
    var title_segments = [_]vaxis.Cell.Segment{
        .{ .text = try RenderUtils.copyFrameText(app, title), .style = title_style },
    };
    _ = palette_win.print(&title_segments, .{ .row_offset = DIALOG_PADDING, .col_offset = DIALOG_PADDING, .wrap = .none });

    // Line 1: Input field - different prompts for each mode
    // File search: / in yellow, Command mode: > in cyan
    const input_style = vaxis.Style{
        .fg = Color.white,
        .bg = Color.dialog_bg,
    };
    const prompt_char = if (is_command_mode) "> " else "/ ";
    const prompt_color = if (is_command_mode) Color.cyan else Color.yellow;
    const display_text = if (is_command_mode)
        query[1..] // Strip the > prefix - it's shown as the prompt
    else
        query;
    var input_segments = [_]vaxis.Cell.Segment{
        .{ .text = prompt_char, .style = .{ .fg = prompt_color, .bg = Color.dialog_bg } },
        .{ .text = display_text, .style = input_style },
    };
    _ = palette_win.print(&input_segments, .{ .row_offset = DIALOG_PADDING + 1, .col_offset = DIALOG_PADDING, .wrap = .none });

    // Show cursor after the displayed text
    const cursor_col = DIALOG_PADDING + 2 + display_text.len;
    palette_win.showCursor(@intCast(cursor_col), @intCast(DIALOG_PADDING + 1));

    // Line 2: Separator (account for padding on both sides)
    const sep_style = vaxis.Style{
        .fg = Color.dim_gray,
        .bg = Color.dialog_bg,
    };
    if (palette_win.width > DIALOG_PADDING * 2) {
        const sep_width = palette_win.width - (DIALOG_PADDING * 2);
        const sep_text = try RenderUtils.frameTextSlice(app, sep_width);
        @memset(sep_text, '-');
        var sep_segments = [_]vaxis.Cell.Segment{
            .{ .text = sep_text, .style = sep_style },
        };
        _ = palette_win.print(&sep_segments, .{ .row_offset = DIALOG_PADDING + 2, .col_offset = DIALOG_PADDING, .wrap = .none });
    }

    // Lines 3+: Content area
    if (state.filtered_commands.items.len == 0) {
        const no_results = "No matching commands";
        const no_results_style = vaxis.Style{
            .fg = Color.dim_gray,
            .bg = Color.dialog_bg,
        };
        var no_results_segments = [_]vaxis.Cell.Segment{
            .{ .text = no_results, .style = no_results_style },
        };
        _ = palette_win.print(&no_results_segments, .{ .row_offset = DIALOG_PADDING + 3, .col_offset = DIALOG_PADDING, .wrap = .none });
    } else {
        for (calc_start_idx..calc_end_idx) |i| {
            const cmd_idx = state.filtered_commands.items[i];
            const cmd = &state.commands.items[cmd_idx];
            const is_selected = (i == state.selected_idx);

            const row = DIALOG_PADDING + 3 + (i - calc_start_idx);

            // Selection indicator
            const indicator = if (is_selected) "▶ " else "  ";
            const indicator_style = vaxis.Style{
                .fg = if (is_selected) Color.cyan else Color.dim_gray,
                .bg = Color.dialog_bg,
            };

            // Command name
            const name_style = vaxis.Style{
                .fg = if (is_selected) Color.white else Color.white,
                .bg = Color.dialog_bg,
                .bold = is_selected,
            };

            // Description
            const desc_style = vaxis.Style{
                .fg = Color.dim_gray,
                .bg = Color.dialog_bg,
            };

            // Format: "▶ Name             Description" with stats right-justified
            const spacing = "  ";

            // Build left-side segments (indicator, name, description)
            var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            defer segments.deinit(app.allocator);

            try segments.append(app.allocator, .{ .text = indicator, .style = indicator_style });
            try segments.append(app.allocator, .{ .text = cmd.display_name, .style = name_style });
            try segments.append(app.allocator, .{ .text = spacing, .style = .{ .bg = Color.dialog_bg } });
            try segments.append(app.allocator, .{ .text = cmd.description, .style = desc_style });

            // Add colored stats for file commands and diff commands (right-justified)
            // Skip entirely when there is no room: rows clip (wrap = .none), so a
            // half-rendered "+9, -" at the edge would otherwise be all that shows.
            const right_margin = 2;
            const fixed_indicator_width = 2; // "▶ " or "  "
            const current_width = fixed_indicator_width + cmd.display_name.len + spacing.len + cmd.description.len;
            var stats_buf: [32]u8 = undefined;
            const stats_preview = try std.fmt.bufPrint(&stats_buf, "(+{d}, -{d})", .{ cmd.additions, cmd.deletions });
            const stats_width = stats_preview.len;
            const stats_fit = current_width + 2 + stats_width + DIALOG_PADDING <= palette_width;
            if ((cmd.category == .file or cmd.category == .diff) and (cmd.additions > 0 or cmd.deletions > 0) and stats_fit) {
                // Calculate padding needed for right justification
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
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, padding), .style = .{ .bg = Color.dialog_bg } });

                // Add colored stats segments
                const additions_text = try std.fmt.allocPrint(app.allocator, "+{d}", .{cmd.additions});
                defer app.allocator.free(additions_text);
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, additions_text), .style = .{ .fg = Color.green, .bg = Color.dialog_bg, .bold = true } });

                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, ", "), .style = .{ .bg = Color.dialog_bg } });

                const deletions_text = try std.fmt.allocPrint(app.allocator, "-{d}", .{cmd.deletions});
                defer app.allocator.free(deletions_text);
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, deletions_text), .style = .{ .fg = Color.red, .bg = Color.dialog_bg, .bold = true } });
            }

            _ = palette_win.print(segments.items, .{ .row_offset = @intCast(row), .col_offset = DIALOG_PADDING, .wrap = .none });
        }

        // Show scroll indicator if there are more items
        if (calc_end_idx < state.filtered_commands.items.len) {
            const more_text = "...";
            const more_style = vaxis.Style{
                .fg = Color.dim_gray,
                .bg = Color.dialog_bg,
            };
            var more_segments = [_]vaxis.Cell.Segment{
                .{ .text = more_text, .style = more_style },
            };
            const last_row = DIALOG_PADDING + 3 + CommandPaletteState.max_visible_items;
            _ = palette_win.print(&more_segments, .{ .row_offset = @intCast(last_row), .col_offset = DIALOG_PADDING, .wrap = .none });
        }
    }
}

// Tests
test "truncatePath: short path returns unchanged" {
    const allocator = std.testing.allocator;
    const path = "src/file.zig";
    const result = try truncatePath(allocator, path, 85);
    try std.testing.expectEqualStrings(path, result);
}

test "truncatePath: middle-ellipsis for long paths" {
    const allocator = std.testing.allocator;
    const path = "apps/platform/app/(settings)/ai-configuration/page.tsx";
    const result = try truncatePath(allocator, path, 50);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("apps/platform/.../ai-configuration/page.tsx", result);
}

test "truncatePath: keeps first 2 and last 2 components" {
    const allocator = std.testing.allocator;
    const path = "a/b/c/d/e/f.txt";
    const result = try truncatePath(allocator, path, 20);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a/b/.../e/f.txt", result);
}

test "truncatePath: fallback for very long paths" {
    const allocator = std.testing.allocator;
    // Path with very long component names
    const path = "very-long-dir-name/another-very-long-name/yet-another-long/deeply/nested/file.tsx";
    const result = try truncatePath(allocator, path, 40);
    defer allocator.free(result);
    // Should fall back to last 3 components with ellipsis
    try std.testing.expectEqualStrings(".../deeply/nested/file.tsx", result);
}

test "truncatePath: 3 or fewer components returns unchanged" {
    const allocator = std.testing.allocator;
    const path = "src/components/Button.tsx";
    // Even if it exceeds max_length, with only 3 components we return as-is
    const result = try truncatePath(allocator, path, 10);
    try std.testing.expectEqualStrings(path, result);
}
