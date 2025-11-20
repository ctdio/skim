const std = @import("std");
const vaxis = @import("vaxis");
const rendering_common = @import("rendering/common.zig");
const render_utils = @import("rendering/utils.zig");
const state_helpers = @import("state.zig");
const git = @import("git/diff.zig");

const App = @import("app.zig").App;
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const FrameChars = rendering_common.FrameChars;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;
const DiffSource = git.DiffSource;

pub const DividerPosition = enum {
    top,
    middle,
    bottom,
};

fn formatDiffSource(allocator: std.mem.Allocator, diff_source: DiffSource) ![]const u8 {
    return switch (diff_source) {
        .working_dir => |wd| if (wd.staged)
            try allocator.dupe(u8, "[Staged]")
        else
            try allocator.dupe(u8, "[Working]"),
        .single_ref => |sr| blk: {
            if (sr.staged) {
                break :blk try std.fmt.allocPrint(allocator, "[Staged vs {s}]", .{sr.ref});
            } else {
                break :blk try std.fmt.allocPrint(allocator, "[Working vs {s}]", .{sr.ref});
            }
        },
        .two_refs => |tr| blk: {
            if (tr.use_merge_base) {
                break :blk try std.fmt.allocPrint(allocator, "[{s}...{s}]", .{ tr.ref1, tr.ref2 });
            } else {
                break :blk try std.fmt.allocPrint(allocator, "[{s}..{s}]", .{ tr.ref1, tr.ref2 });
            }
        },
    };
}

pub const UI = struct {
    pub fn renderDivider(app: *App, win: vaxis.Window, position: DividerPosition) !void {
        if (win.width == 0) return;

        const width = win.width;
        const left_char = switch (position) {
            .top => FrameChars.top_left,
            .middle => FrameChars.middle_left,
            .bottom => FrameChars.bottom_left,
        };
        const right_char = switch (position) {
            .top => FrameChars.top_right,
            .middle => FrameChars.middle_right,
            .bottom => FrameChars.bottom_right,
        };

        // Build the divider line
        const left_corner = try RenderUtils.copyFrameText(app, left_char);
        const right_corner = try RenderUtils.copyFrameText(app, right_char);

        // Calculate number of horizontal characters needed (width in cells minus 2 for corners)
        const num_h_chars = if (width > 2) width - 2 else 0;

        // Calculate byte length needed (each horizontal char is 3 bytes in UTF-8)
        const h_line_len = num_h_chars * FrameChars.horizontal.len;

        const h_line = if (h_line_len > 0) blk: {
            const line = try RenderUtils.frameTextSlice(app, h_line_len);
            // Fill with horizontal characters
            var i: usize = 0;
            while (i < num_h_chars) : (i += 1) {
                const pos = i * FrameChars.horizontal.len;
                @memcpy(line[pos .. pos + FrameChars.horizontal.len], FrameChars.horizontal);
            }
            break :blk line;
        } else "";

        // Print left corner
        var left_seg = [_]vaxis.Cell.Segment{.{
            .text = left_corner,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&left_seg, .{ .row_offset = 0 });

        // Print horizontal line
        if (h_line.len > 0) {
            var h_seg = [_]vaxis.Cell.Segment{.{
                .text = h_line,
                .style = .{ .fg = Color.dim },
            }};
            _ = try win.print(&h_seg, .{ .row_offset = 0, .col_offset = 1 });
        }

        // Print right corner
        var right_seg = [_]vaxis.Cell.Segment{.{
            .text = right_corner,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&right_seg, .{ .row_offset = 0, .col_offset = win.width -| 1 });
    }

    pub fn renderEmptyMenu(app: *App, win: vaxis.Window) !void {
        const title = "No changes to review";
        const subtitle = "Select a diff source:";

        // Fetch stats for each menu option
        const working_stats = git.getDiffStats(app.allocator, .{ .working_dir = .{ .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
        const staged_stats = git.getDiffStats(app.allocator, .{ .working_dir = .{ .staged = true } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        // Detect default branch and fetch stats (matches switchDiffMode behavior)
        // Note: detectDefaultBranch always allocates, even for "main", so we must always free
        var default_branch: []const u8 = "main"; // Fallback default
        var branch_allocated = false;
        if (git.detectDefaultBranch(app.allocator)) |branch| {
            default_branch = branch;
            branch_allocated = true;
        } else |_| {}
        defer if (branch_allocated) app.allocator.free(default_branch);

        const main_stats = git.getDiffStats(app.allocator, .{ .single_ref = .{ .ref = default_branch, .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        // MenuItem struct with optional stats for colored rendering
        const MenuItem = struct {
            label: []const u8,
            description_prefix: []const u8,
            stats: ?git.DiffStats,
        };

        var working_label_buf: [128]u8 = undefined;
        const working_label = try std.fmt.bufPrint(&working_label_buf, "Uncommitted changes (", .{});

        var staged_label_buf: [128]u8 = undefined;
        const staged_label = try std.fmt.bufPrint(&staged_label_buf, "Changes ready to commit (", .{});

        var main_label_buf: [128]u8 = undefined;
        const main_label = try std.fmt.bufPrint(&main_label_buf, "Compare against {s} (", .{default_branch});

        const menu_items = [_]MenuItem{
            .{ .label = "Working directory", .description_prefix = working_label, .stats = working_stats },
            .{ .label = "Staged changes", .description_prefix = staged_label, .stats = staged_stats },
            .{ .label = "Main branch", .description_prefix = main_label, .stats = main_stats },
            .{ .label = "Select branch...", .description_prefix = "Choose a specific branch", .stats = null },
            .{ .label = "Refresh", .description_prefix = "Reload current diff source", .stats = null },
            .{ .label = "Quit", .description_prefix = "Exit Skim", .stats = null },
        };

        const center_row = win.height / 2;
        const start_row = if (center_row > 4) center_row - 4 else 0;

        // Title
        const title_col = (win.width -| title.len) / 2;
        const title_copy = try RenderUtils.copyFrameText(app, title);
        var title_seg = [_]vaxis.Cell.Segment{.{
            .text = title_copy,
            .style = .{ .fg = Color.white, .bold = true },
        }};
        _ = try win.print(&title_seg, .{ .row_offset = start_row, .col_offset = title_col });

        // Subtitle
        const subtitle_col = (win.width -| subtitle.len) / 2;
        const subtitle_copy = try RenderUtils.copyFrameText(app, subtitle);
        var subtitle_seg = [_]vaxis.Cell.Segment{.{
            .text = subtitle_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&subtitle_seg, .{ .row_offset = start_row + 2, .col_offset = subtitle_col });

        // Menu items - find longest item to center the block
        const separator = " - ";
        var max_len: usize = 0;
        for (menu_items) |item| {
            // Calculate length including stats if present (e.g., "5 files, +10, -5)")
            const stats_len: usize = if (item.stats) |_| 30 else 0; // Approximate length for stats
            const item_len = item.label.len + separator.len + item.description_prefix.len + stats_len;
            if (item_len > max_len) {
                max_len = item_len;
            }
        }

        // Center the menu block based on longest item
        const menu_start_col = if (win.width > max_len) (win.width - max_len) / 2 else 0;
        const caret_offset = 2; // Space for caret to the left

        for (menu_items, 0..) |item, idx| {
            const row = start_row + 4 + idx;
            const is_selected = idx == app.state.empty_menu_selection;

            // All items start at the same column (left-aligned within centered block)
            const item_col = menu_start_col;

            // Build segments dynamically with colored stats
            var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
            defer segments.deinit();

            // Label
            const label_copy = try RenderUtils.copyFrameText(app, item.label);
            try segments.append(.{ .text = label_copy, .style = .{ .fg = if (is_selected) Color.white else Color.dim, .bold = is_selected } });

            // Separator
            const separator_copy = try RenderUtils.copyFrameText(app, separator);
            try segments.append(.{ .text = separator_copy, .style = .{ .fg = Color.dim } });

            // Description prefix
            const desc_copy = try RenderUtils.copyFrameText(app, item.description_prefix);
            try segments.append(.{ .text = desc_copy, .style = .{ .fg = Color.dim } });

            // Add colored stats if present
            if (item.stats) |stats| {
                var files_buf: [32]u8 = undefined;
                const files_text = try std.fmt.bufPrint(&files_buf, "{d} files, ", .{stats.files});
                const files_copy = try RenderUtils.copyFrameText(app, files_text);
                try segments.append(.{ .text = files_copy, .style = .{ .fg = Color.dim } });

                var additions_buf: [16]u8 = undefined;
                const additions_text = try std.fmt.bufPrint(&additions_buf, "+{d}", .{stats.additions});
                const additions_copy = try RenderUtils.copyFrameText(app, additions_text);
                try segments.append(.{ .text = additions_copy, .style = .{ .fg = Color.diff_sign_add, .bold = true } });

                var deletions_buf: [16]u8 = undefined;
                const deletions_text = try std.fmt.bufPrint(&deletions_buf, ", -{d}", .{stats.deletions});
                const deletions_copy = try RenderUtils.copyFrameText(app, deletions_text);
                try segments.append(.{ .text = deletions_copy, .style = .{ .fg = Color.diff_sign_delete, .bold = true } });

                const closing_paren = try RenderUtils.copyFrameText(app, ")");
                try segments.append(.{ .text = closing_paren, .style = .{ .fg = Color.dim } });
            }

            _ = try win.print(segments.items, .{ .row_offset = row, .col_offset = item_col });

            // Render caret to the left of selected item (if there's space)
            if (is_selected and item_col >= caret_offset) {
                const caret_copy = try RenderUtils.copyFrameText(app, "▶");
                var caret_seg = [_]vaxis.Cell.Segment{.{
                    .text = caret_copy,
                    .style = .{ .fg = Color.cyan },
                }};
                _ = try win.print(&caret_seg, .{ .row_offset = row, .col_offset = item_col - caret_offset });
            }
        }

        // Instructions at bottom
        const instructions = "↑↓/j/k/Ctrl-n/p: Navigate  |  Enter: Select";
        const instr_row = start_row + 4 + menu_items.len + 2;
        const instr_col = (win.width -| instructions.len) / 2;
        const instr_copy = try RenderUtils.copyFrameText(app, instructions);
        var instr_seg = [_]vaxis.Cell.Segment{.{
            .text = instr_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&instr_seg, .{ .row_offset = instr_row, .col_offset = instr_col });
    }

    pub fn renderBranchSelectionMenu(app: *App, win: vaxis.Window) !void {
        const title = "Select a branch";

        const center_row = win.height / 2;
        const start_row = if (center_row > 4) center_row - 4 else 0;

        // Title
        const title_col = (win.width -| title.len) / 2;
        const title_copy = try RenderUtils.copyFrameText(app, title);
        var title_seg = [_]vaxis.Cell.Segment{.{
            .text = title_copy,
            .style = .{ .fg = Color.white, .bold = true },
        }};
        _ = try win.print(&title_seg, .{ .row_offset = start_row, .col_offset = title_col });

        // Search query line
        const query = app.state.branch_search_query[0..app.state.branch_search_len];
        var search_buf: [512]u8 = undefined;
        const search_line = if (query.len > 0)
            try std.fmt.bufPrint(&search_buf, "Search: {s}_", .{query})
        else
            "Type to search...";

        const search_col = (win.width -| search_line.len) / 2;
        const search_copy = try RenderUtils.copyFrameText(app, search_line);
        var search_seg = [_]vaxis.Cell.Segment{.{
            .text = search_copy,
            .style = .{ .fg = if (query.len > 0) Color.cyan else Color.dim },
        }};
        _ = try win.print(&search_seg, .{ .row_offset = start_row + 2, .col_offset = search_col });

        if (app.state.branch_list.len == 0) return;

        // Use filtered branches
        const filtered = app.state.filtered_branches.items;

        // Show "No matches" if filtered list is empty
        if (filtered.len == 0) {
            const no_matches = "No matching branches";
            const no_matches_col = (win.width -| no_matches.len) / 2;
            const no_matches_copy = try RenderUtils.copyFrameText(app, no_matches);
            var no_matches_seg = [_]vaxis.Cell.Segment{.{
                .text = no_matches_copy,
                .style = .{ .fg = Color.dim },
            }};
            _ = try win.print(&no_matches_seg, .{ .row_offset = start_row + 4, .col_offset = no_matches_col });
        } else {
            // Estimate max length including stats (branch name + stats format ~30 chars)
            var max_len: usize = 0;
            for (filtered) |branch_idx| {
                const branch = app.state.branch_list[branch_idx];
                const estimated_len = branch.len + 30; // Approximate space for stats
                if (estimated_len > max_len) {
                    max_len = estimated_len;
                }
            }

            // Center the menu block
            const menu_start_col = if (win.width > max_len) (win.width - max_len) / 2 else 0;
            const caret_offset = 2;

            // Show up to 10 branches at a time (with scrolling)
            const max_visible = 10;
            const start_idx = if (app.state.branch_selection >= max_visible)
                app.state.branch_selection - max_visible + 1
            else
                0;
            const end_idx = @min(start_idx + max_visible, filtered.len);

            for (start_idx..end_idx) |idx| {
                const row = start_row + 4 + (idx - start_idx);
                const branch_idx = filtered[idx];
                const branch = app.state.branch_list[branch_idx];
                const is_selected = idx == app.state.branch_selection;

                // Fetch stats for this branch (compare HEAD to branch)
                const branch_stats = git.getDiffStats(app.allocator, .{ .two_refs = .{ .ref1 = branch, .ref2 = "HEAD", .use_merge_base = true } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

                // Build segments with colored stats
                var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
                defer segments.deinit();

                // Branch name
                const branch_copy = try RenderUtils.copyFrameText(app, branch);
                try segments.append(.{ .text = branch_copy, .style = .{ .fg = if (is_selected) Color.white else Color.dim, .bold = is_selected } });

                // Stats with colors
                const opening_paren = try RenderUtils.copyFrameText(app, "  (");
                try segments.append(.{ .text = opening_paren, .style = .{ .fg = Color.dim } });

                var files_buf: [32]u8 = undefined;
                const files_text = try std.fmt.bufPrint(&files_buf, "{d} files, ", .{branch_stats.files});
                const files_copy = try RenderUtils.copyFrameText(app, files_text);
                try segments.append(.{ .text = files_copy, .style = .{ .fg = Color.dim } });

                var additions_buf: [16]u8 = undefined;
                const additions_text = try std.fmt.bufPrint(&additions_buf, "+{d}", .{branch_stats.additions});
                const additions_copy = try RenderUtils.copyFrameText(app, additions_text);
                try segments.append(.{ .text = additions_copy, .style = .{ .fg = Color.diff_sign_add, .bold = true } });

                var deletions_buf: [16]u8 = undefined;
                const deletions_text = try std.fmt.bufPrint(&deletions_buf, ", -{d}", .{branch_stats.deletions});
                const deletions_copy = try RenderUtils.copyFrameText(app, deletions_text);
                try segments.append(.{ .text = deletions_copy, .style = .{ .fg = Color.diff_sign_delete, .bold = true } });

                const closing_paren = try RenderUtils.copyFrameText(app, ")");
                try segments.append(.{ .text = closing_paren, .style = .{ .fg = Color.dim } });

                // Render branch with colored stats
                _ = try win.print(segments.items, .{ .row_offset = row, .col_offset = menu_start_col });

                // Render caret for selected branch
                if (is_selected and menu_start_col >= caret_offset) {
                    const caret_copy = try RenderUtils.copyFrameText(app, "▶");
                    var caret_seg = [_]vaxis.Cell.Segment{.{
                        .text = caret_copy,
                        .style = .{ .fg = Color.cyan },
                    }};
                    _ = try win.print(&caret_seg, .{ .row_offset = row, .col_offset = menu_start_col - caret_offset });
                }
            }
        }

        // Instructions at bottom
        const instructions = "Type to search  |  ↑↓/j/k: Navigate  |  Enter: Select  |  ESC: Clear/Back";
        const instr_row = start_row + 4 + 10 + 1;
        const instr_col = (win.width -| instructions.len) / 2;
        const instr_copy = try RenderUtils.copyFrameText(app, instructions);
        var instr_seg = [_]vaxis.Cell.Segment{.{
            .text = instr_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&instr_seg, .{ .row_offset = instr_row, .col_offset = instr_col });
    }

    pub fn renderHeader(app: *App, win: vaxis.Window) !void {
        if (win.height == 0 or win.width == 0) return;
        win.clear();

        if (app.state.current_file_idx >= app.state.files.len) return;

        const current_file = &app.state.files[app.state.current_file_idx];
        const stats = StateHelpers.calculateDiffStats(app, current_file);

        const file_path = if (current_file.new_path.len > 0) current_file.new_path else current_file.old_path;

        // First line: File info with stats
        var buf1: [512]u8 = undefined;
        const file_info = try std.fmt.bufPrint(&buf1, "File {d} of {d}  ", .{
            app.state.current_file_idx + 1,
            app.state.files.len,
        });

        var buf2: [64]u8 = undefined;
        const additions_text = try std.fmt.bufPrint(&buf2, "+{d}", .{stats.additions});

        var buf3: [64]u8 = undefined;
        const deletions_text = try std.fmt.bufPrint(&buf3, " -{d}", .{stats.deletions});

        // Copy to frame buffer for proper lifetime
        const file_info_copy = try RenderUtils.copyFrameText(app, file_info);
        const file_path_copy = try RenderUtils.copyFrameText(app, file_path);
        const additions_copy = try RenderUtils.copyFrameText(app, additions_text);
        const deletions_copy = try RenderUtils.copyFrameText(app, deletions_text);
        const spacer = try RenderUtils.copyFrameText(app, "  ");

        // Create segments with different colors
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = file_info_copy, .style = .{ .fg = Color.white } },
            .{ .text = file_path_copy, .style = .{ .fg = Color.white, .bold = true } },
            .{ .text = spacer, .style = .{ .fg = Color.white } },
            .{ .text = additions_copy, .style = .{ .fg = Color.diff_sign_add, .bold = true } },
            .{ .text = deletions_copy, .style = .{ .fg = Color.diff_sign_delete, .bold = true } },
        };

        _ = try win.print(&segments, .{ .row_offset = 0, .col_offset = 0 });
    }

    pub fn renderStatus(app: *App, win: vaxis.Window) !void {
        win.clear();

        const mode_str = switch (app.mode) {
            .normal => blk: {
                // Check if waiting for find character in normal mode
                if (app.state.pending_find) |find_cmd| {
                    const find_str = switch (find_cmd) {
                        .f => "-- f? --",
                        .t => "-- t? --",
                        .F => "-- F? --",
                        .T => "-- T? --",
                    };
                    break :blk find_str;
                }
                break :blk "-- NORMAL --";
            },
            .comment => blk: {
                // Show vim mode when in comment mode
                if (app.state.active_comment_input) |input| {
                    // Check if waiting for find character
                    if (input.pending_find) |find_cmd| {
                        const find_str = switch (find_cmd) {
                            .f => "-- f? --",
                            .t => "-- t? --",
                            .F => "-- F? --",
                            .T => "-- T? --",
                        };
                        break :blk find_str;
                    }

                    // Check if waiting for motion after operator
                    if (input.pending_operator) |operator| {
                        const operator_str = switch (operator) {
                            .d => "-- d (motion) --",
                            .y => "-- y (motion) --",
                            .c => "-- c (motion) --",
                        };
                        break :blk operator_str;
                    }

                    break :blk switch (input.vim_mode) {
                        .normal => "-- NORMAL (comment) --",
                        .insert => "-- INSERT (comment) --",
                        .visual => "-- VISUAL (comment) --",
                        .command => "-- COMMAND --",
                    };
                }
                break :blk "-- COMMENT --";
            },
            .search => "-- SEARCH --",
            .visual => "-- VISUAL --",
            .command_palette => "-- COMMAND PALETTE --",
            .help => "-- HELP --",
            .branch_selection => "-- BRANCH SELECTION --",
        };

        const view_str = switch (app.state.view_mode) {
            .unified => "[Unified]",
            .side_by_side => "[Side-by-Side]",
        };

        // Hunk view mode with symbol
        const hunk_view_symbol = app.state.hunk_view_mode.toSymbol();

        // Context-aware keybindings based on cursor position and mode
        const keybindings = switch (app.mode) {
            .normal => "Press ? for help  |  Ctrl-p:Files  ::Commands  /:Search  v:Visual  [h]h:Hunks  [c]c:Comments  {}:Empty",
            .comment => blk: {
                if (app.state.active_comment_input) |input| {
                    break :blk switch (input.vim_mode) {
                        .normal => "Comment editing (vim mode)  |  i:Insert  :wq:Save&Quit  ESC:Cancel",
                        .insert => "INSERT MODE  |  ESC:Normal  Enter:Newline",
                        .visual => "VISUAL MODE  |  y:Yank  d:Delete  ESC:Exit",
                        .command => ":w (save)  :q (quit)  :wq (save & quit)  Enter:Execute  ESC:Cancel",
                    };
                }
                break :blk "Enter:Save  ESC:Cancel";
            },
            .search => "Type to search  |  Enter:Search  ESC:Cancel  |  Smart case matching",
            .visual => "j/k:Extend selection  |  y:Yank  ESC:Exit",
            .command_palette => "Type to filter ('>':commands)  |  ↑↓/Ctrl-p/n:Select  Enter:Execute  ESC:Cancel",
            .help => "Press any key to close",
            .branch_selection => "↑↓/j/k/Ctrl-n/p:Navigate  |  Enter:Select  |  ESC:Back",
        };

        // Get global position info
        const total_lines = app.getTotalGlobalLines();
        const current_line = app.state.global_cursor_line + 1; // Display 1-indexed
        const total_files = app.state.files.len;
        const current_file = app.state.current_file_idx + 1; // Display 1-indexed

        // Build status bar using segments with colors
        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        if (app.mode == .comment and app.state.active_comment_input != null and
            app.state.active_comment_input.?.vim_mode == .command)
        {
            // In command mode, show command line like vim
            const input = app.state.active_comment_input.?;
            const command = input.command_buffer[0..input.command_len];

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, ":"), .style = .{ .bold = true } });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, command), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "_"), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "  "), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        } else if (app.mode == .search) {
            // In search mode, show search prompt with current query
            const query = app.state.search_state.query_buffer[0..app.state.search_state.query_len];
            const match_count = app.state.search_state.matches.items.len;

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, mode_str), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "  /"), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, query), .style = .{} });

            if (match_count > 0) {
                const current_match = if (app.state.search_state.current_match_idx) |idx| idx + 1 else 0;
                var buf: [64]u8 = undefined;
                const match_info = try std.fmt.bufPrint(&buf, "  ({d} of {d} matches)  ", .{ current_match, match_count });
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, match_info), .style = .{} });
            } else if (app.state.search_state.query_len > 0) {
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "_  "), .style = .{} });
            } else {
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "_  "), .style = .{} });
            }

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        } else {
            // Normal mode status bar with colored hunk view mode
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, mode_str), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, " "), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, view_str), .style = .{} });

            // Show diff source mode
            const diff_str = try formatDiffSource(app.allocator, app.state.diff_source);
            defer app.allocator.free(diff_str);
            const diff_str_copy = try RenderUtils.copyFrameText(app, diff_str);
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, " "), .style = .{} });
            try segments.append(.{ .text = diff_str_copy, .style = .{ .fg = Color.cyan } });

            // Only show hunk view mode indicator in unified view (where filtering applies)
            if (app.state.view_mode == .unified) {
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, " ["), .style = .{} });

                // Add colored hunk view symbol
                if (app.state.hunk_view_mode == .all) {
                    // For "+/-" mode, color + green and - red
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "+"), .style = .{ .fg = Color.green, .bold = true } });
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "/"), .style = .{ .bold = true } });
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "-"), .style = .{ .fg = Color.red, .bold = true } });
                } else {
                    // For single mode, use appropriate color
                    const hunk_view_style: vaxis.Style = switch (app.state.hunk_view_mode) {
                        .all => unreachable, // Already handled above
                        .old => .{ .fg = Color.red, .bold = true },
                        .new => .{ .fg = Color.green, .bold = true },
                    };
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, hunk_view_symbol), .style = hunk_view_style });
                }
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "]"), .style = .{} });
            }

            if (app.state.count_prefix) |count| {
                var buf: [64]u8 = undefined;
                const count_str = try std.fmt.bufPrint(&buf, " [{d}]", .{count});
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, count_str), .style = .{} });
            }

            var buf: [128]u8 = undefined;
            const pos_info = try std.fmt.bufPrint(&buf, "  Line {d}/{d} (File {d}/{d})", .{ current_line, total_lines, current_file, total_files });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, pos_info), .style = .{} });

            // Show search info if there are active matches in normal mode
            if (app.state.search_state.hasMatches()) {
                const match_count = app.state.search_state.matches.items.len;
                const current_match = if (app.state.search_state.current_match_idx) |idx| idx + 1 else 0;
                var match_buf: [64]u8 = undefined;
                const match_info = try std.fmt.bufPrint(&match_buf, "  [{d}/{d} matches]", .{ current_match, match_count });
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, match_info), .style = .{} });
            }

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "  "), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        }

        _ = try win.print(segments.items, .{ .row_offset = 0 });
    }

    pub fn printHeaderLine(app: *App, win: vaxis.Window, row: usize, text: []const u8, style: vaxis.Style) !void {
        if (row >= Layout.header_height) return;
        if (row >= win.height or win.width == 0) return;

        var buffer = &app.header_line_buffers[row];
        const width = @min(win.width, buffer.len);

        if (width == 0) return;

        @memset(buffer[0..width], ' ');

        const copy_len = @min(text.len, width);
        if (copy_len > 0) {
            @memcpy(buffer[0..copy_len], text[0..copy_len]);
        }

        var seg = [_]vaxis.Cell.Segment{.{
            .text = buffer[0..width],
            .style = style,
        }};
        _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 0 });
    }
};
