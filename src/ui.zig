const std = @import("std");
const vaxis = @import("vaxis");
const rendering_common = @import("rendering/common.zig");
const render_utils = @import("rendering/utils.zig");
const state_helpers = @import("state.zig");
const git = @import("git/diff.zig");
const sessions = @import("acp/sessions.zig");

const App = @import("app.zig").App;
const graphite = @import("git/graphite.zig");
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
        .stdin => try allocator.dupe(u8, "[Stdin]"),
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
        _ = win.print(&left_seg, .{ .row_offset = @intCast(0 )});

        // Print horizontal line
        if (h_line.len > 0) {
            var h_seg = [_]vaxis.Cell.Segment{.{
                .text = h_line,
                .style = .{ .fg = Color.dim },
            }};
            _ = win.print(&h_seg, .{ .row_offset = 0, .col_offset = @intCast(1 )});
        }

        // Print right corner
        var right_seg = [_]vaxis.Cell.Segment{.{
            .text = right_corner,
            .style = .{ .fg = Color.dim },
        }};
        _ = win.print(&right_seg, .{ .row_offset = 0, .col_offset = @intCast(win.width -| 1 )});
    }

    pub fn renderEmptyMenu(app: *App, win: vaxis.Window) !void {
        const title = "No changes to review";
        const subtitle = "Select a diff source:";

        // Start async stats fetch on first render (non-blocking)
        app.startMenuStatsFetch();

        // Get cached stats if available, otherwise null
        const stats_ready = app.state.menu_stats_cached;
        const working_stats: ?git.DiffStats = if (stats_ready) app.state.working_stats else null;
        const staged_stats: ?git.DiffStats = if (stats_ready) app.state.staged_stats else null;
        const main_stats: ?git.DiffStats = if (stats_ready) app.state.main_stats else null;

        // Get default branch name (use cached if available, otherwise "main")
        const default_branch = app.state.default_branch_name orelse "main";

        const MenuItem = struct {
            label: []const u8,
            description: []const u8,
            stats: ?git.DiffStats,
        };

        const menu_items = [_]MenuItem{
            .{ .label = "Working directory", .description = "Uncommitted changes", .stats = working_stats },
            .{ .label = "Staged changes", .description = "Changes ready to commit", .stats = staged_stats },
            .{ .label = "Main branch", .description = default_branch, .stats = main_stats },
            .{ .label = "Select branch...", .description = "Choose a specific branch", .stats = null },
            .{ .label = "Graphite stack", .description = "Review branches in current stack", .stats = null },
            .{ .label = "Refresh", .description = "Reload current diff source", .stats = null },
            .{ .label = "Quit", .description = "Exit Skim", .stats = null },
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
        _ = win.print(&title_seg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(title_col) });

        // Subtitle
        const subtitle_col = (win.width -| subtitle.len) / 2;
        const subtitle_copy = try RenderUtils.copyFrameText(app, subtitle);
        var subtitle_seg = [_]vaxis.Cell.Segment{.{
            .text = subtitle_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = win.print(&subtitle_seg, .{ .row_offset = @intCast(start_row + 2), .col_offset = @intCast(subtitle_col )});

        // Menu items - find longest item to center the block
        const separator = " - ";
        var max_len: usize = 0;
        for (menu_items) |item| {
            // Estimate length including stats if present
            const stats_len: usize = if (item.stats != null) 25 else 0;
            const item_len = item.label.len + separator.len + item.description.len + stats_len;
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
            const item_col = menu_start_col;

            // Build segments dynamically
            var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            defer segments.deinit(app.allocator);

            // Label
            const label_copy = try RenderUtils.copyFrameText(app, item.label);
            try segments.append(app.allocator, .{ .text = label_copy, .style = .{ .fg = if (is_selected) Color.white else Color.dim, .bold = is_selected } });

            // Separator
            const separator_copy = try RenderUtils.copyFrameText(app, separator);
            try segments.append(app.allocator, .{ .text = separator_copy, .style = .{ .fg = Color.dim } });

            // Description
            const desc_copy = try RenderUtils.copyFrameText(app, item.description);
            try segments.append(app.allocator, .{ .text = desc_copy, .style = .{ .fg = Color.dim } });

            // Add stats if available
            if (item.stats) |stats| {
                const stats_open = try RenderUtils.copyFrameText(app, " (");
                try segments.append(app.allocator, .{ .text = stats_open, .style = .{ .fg = Color.dim } });

                var files_buf: [32]u8 = undefined;
                const files_text = try std.fmt.bufPrint(&files_buf, "{d} files, ", .{stats.files});
                const files_copy = try RenderUtils.copyFrameText(app, files_text);
                try segments.append(app.allocator, .{ .text = files_copy, .style = .{ .fg = Color.dim } });

                var additions_buf: [16]u8 = undefined;
                const additions_text = try std.fmt.bufPrint(&additions_buf, "+{d}", .{stats.additions});
                const additions_copy = try RenderUtils.copyFrameText(app, additions_text);
                try segments.append(app.allocator, .{ .text = additions_copy, .style = .{ .fg = Color.diff_sign_add, .bold = true } });

                var deletions_buf: [16]u8 = undefined;
                const deletions_text = try std.fmt.bufPrint(&deletions_buf, ", -{d}", .{stats.deletions});
                const deletions_copy = try RenderUtils.copyFrameText(app, deletions_text);
                try segments.append(app.allocator, .{ .text = deletions_copy, .style = .{ .fg = Color.diff_sign_delete, .bold = true } });

                const stats_close = try RenderUtils.copyFrameText(app, ")");
                try segments.append(app.allocator, .{ .text = stats_close, .style = .{ .fg = Color.dim } });
            }

            _ = win.print(segments.items, .{ .row_offset = @intCast(row), .col_offset = @intCast(item_col )});

            // Render caret to the left of selected item
            if (is_selected and item_col >= caret_offset) {
                const caret_copy = try RenderUtils.copyFrameText(app, "▶");
                var caret_seg = [_]vaxis.Cell.Segment{.{
                    .text = caret_copy,
                    .style = .{ .fg = Color.cyan },
                }};
                _ = win.print(&caret_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(item_col - caret_offset )});
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
        _ = win.print(&instr_seg, .{ .row_offset = @intCast(instr_row), .col_offset = @intCast(instr_col )});
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
        _ = win.print(&title_seg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(title_col) });

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
        _ = win.print(&search_seg, .{ .row_offset = @intCast(start_row + 2), .col_offset = @intCast(search_col )});

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
            _ = win.print(&no_matches_seg, .{ .row_offset = @intCast(start_row + 4), .col_offset = @intCast(no_matches_col )});
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

                // Use cached stats (only fetch once per branch, not on every render)
                const branch_stats = app.state.branch_stats_cache.get(branch_idx) orelse blk: {
                    const stats = git.getDiffStats(app.allocator, .{ .two_refs = .{ .ref1 = branch, .ref2 = "HEAD", .use_merge_base = true } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
                    app.state.branch_stats_cache.put(branch_idx, stats) catch {};
                    break :blk stats;
                };

                // Build segments with colored stats
                var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
                defer segments.deinit(app.allocator);

                // Branch name
                const branch_copy = try RenderUtils.copyFrameText(app, branch);
                try segments.append(app.allocator, .{ .text = branch_copy, .style = .{ .fg = if (is_selected) Color.white else Color.dim, .bold = is_selected } });

                // Stats with colors
                const opening_paren = try RenderUtils.copyFrameText(app, "  (");
                try segments.append(app.allocator, .{ .text = opening_paren, .style = .{ .fg = Color.dim } });

                var files_buf: [32]u8 = undefined;
                const files_text = try std.fmt.bufPrint(&files_buf, "{d} files, ", .{branch_stats.files});
                const files_copy = try RenderUtils.copyFrameText(app, files_text);
                try segments.append(app.allocator, .{ .text = files_copy, .style = .{ .fg = Color.dim } });

                var additions_buf: [16]u8 = undefined;
                const additions_text = try std.fmt.bufPrint(&additions_buf, "+{d}", .{branch_stats.additions});
                const additions_copy = try RenderUtils.copyFrameText(app, additions_text);
                try segments.append(app.allocator, .{ .text = additions_copy, .style = .{ .fg = Color.diff_sign_add, .bold = true } });

                var deletions_buf: [16]u8 = undefined;
                const deletions_text = try std.fmt.bufPrint(&deletions_buf, ", -{d}", .{branch_stats.deletions});
                const deletions_copy = try RenderUtils.copyFrameText(app, deletions_text);
                try segments.append(app.allocator, .{ .text = deletions_copy, .style = .{ .fg = Color.diff_sign_delete, .bold = true } });

                const closing_paren = try RenderUtils.copyFrameText(app, ")");
                try segments.append(app.allocator, .{ .text = closing_paren, .style = .{ .fg = Color.dim } });

                // Render branch with colored stats
                _ = win.print(segments.items, .{ .row_offset = @intCast(row), .col_offset = @intCast(menu_start_col )});

                // Render caret for selected branch
                if (is_selected and menu_start_col >= caret_offset) {
                    const caret_copy = try RenderUtils.copyFrameText(app, "▶");
                    var caret_seg = [_]vaxis.Cell.Segment{.{
                        .text = caret_copy,
                        .style = .{ .fg = Color.cyan },
                    }};
                    _ = win.print(&caret_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(menu_start_col - caret_offset )});
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
        _ = win.print(&instr_seg, .{ .row_offset = @intCast(instr_row), .col_offset = @intCast(instr_col )});
    }

    pub fn renderGraphiteStackDialog(app: *App, win: vaxis.Window) !void {
        const stack = app.state.graphite_stack orelse return;

        const branch_count = stack.branches.len;

        // Calculate dialog dimensions
        var max_branch_len: usize = 0;
        for (stack.branches) |branch| {
            const indicator_len: usize = if (branch.needs_restack) " (needs restack)".len else 0;
            const current_indicator_len: usize = 12; // " ← current"
            const item_len = branch.name.len + indicator_len + current_indicator_len + 6; // "▶ ◯ " prefix
            if (item_len > max_branch_len) {
                max_branch_len = item_len;
            }
        }

        const title = " Graphite Stack ";
        const instructions = "j/k:Navigate  Enter:Select  ESC:Close";
        const dialog_width = @max(@max(max_branch_len + 4, title.len + 4), instructions.len + 4);
        const dialog_height = branch_count + 5; // title + branches + instructions + padding

        const popup_width = @min(dialog_width, win.width - 4);
        const popup_height = @min(dialog_height, win.height - 4);
        const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
        const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

        const popup_win = win.child(.{
            .x_off = x_offset,
            .y_off = y_offset,
            .width = @intCast(popup_width),
            .height = @intCast(popup_height),
            .border = .{
                .where = .all,
                .style = .{ .fg = Color.cyan },
            },
        });

        popup_win.clear();

        // Fill with solid background
        const bg_cell = vaxis.Cell{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = .{ .index = 0 } }, // black background
        };
        popup_win.fill(bg_cell);

        // Title
        const title_copy = try RenderUtils.copyFrameText(app, title);
        var title_seg = [_]vaxis.Cell.Segment{.{
            .text = title_copy,
            .style = .{ .fg = Color.cyan, .bold = true },
        }};
        _ = popup_win.print(&title_seg, .{ .row_offset = @intCast(0 )});

        // Render stack branches (tip at top, trunk at bottom)
        for (0..branch_count) |visual_idx| {
            const array_idx = branch_count - 1 - visual_idx;
            const branch = stack.branches[array_idx];
            const row = visual_idx + 2;
            const is_selected = array_idx == app.state.graphite_stack_selection;
            const is_current = array_idx == stack.current_idx;

            var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            defer segments.deinit(app.allocator);

            // Selection caret
            const caret = if (is_selected) "▶ " else "  ";
            const caret_copy = try RenderUtils.copyFrameText(app, caret);
            try segments.append(app.allocator, .{ .text = caret_copy, .style = .{ .fg = Color.cyan } });

            // Tree symbol (trunk at bottom, tip branches at top)
            const is_tip = array_idx == branch_count - 1;
            const tree_symbol = if (branch.is_trunk) "◉ " else if (is_tip) "◇ " else "○ ";
            const tree_copy = try RenderUtils.copyFrameText(app, tree_symbol);
            try segments.append(app.allocator, .{ .text = tree_copy, .style = .{ .fg = if (is_current) Color.green else Color.dim } });

            // Branch name
            const name_copy = try RenderUtils.copyFrameText(app, branch.name);
            try segments.append(app.allocator, .{ .text = name_copy, .style = .{ .fg = if (is_selected) Color.white else Color.dim, .bold = is_selected } });

            // Current indicator
            if (is_current) {
                const current_copy = try RenderUtils.copyFrameText(app, " ← you");
                try segments.append(app.allocator, .{ .text = current_copy, .style = .{ .fg = Color.green } });
            }

            // Needs restack indicator
            if (branch.needs_restack) {
                const restack_copy = try RenderUtils.copyFrameText(app, " !");
                try segments.append(app.allocator, .{ .text = restack_copy, .style = .{ .fg = Color.yellow, .bold = true } });
            }

            _ = popup_win.print(segments.items, .{ .row_offset = @intCast(row), .col_offset = @intCast(1 )});
        }

        // Instructions at bottom
        const instr_copy = try RenderUtils.copyFrameText(app, instructions);
        var instr_seg = [_]vaxis.Cell.Segment{.{
            .text = instr_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = popup_win.print(&instr_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(1 )});
    }

    pub fn renderModelSelectionDialog(app: *App, win: vaxis.Window) !void {
        // Get models from ACP manager
        const mgr = app.acp_manager orelse return;
        const models = mgr.getAvailableModels();
        const model_count = models.len;
        if (model_count == 0) return;

        const current_model_id = mgr.getCurrentModelId();

        // Calculate dialog dimensions (2 lines per model: name + description)
        const title = " Switch Model ";
        const instructions = "j/k:Navigate  Enter:Select  ESC:Cancel";

        // Find max width needed for model entries
        var max_name_len: usize = 0;
        var max_desc_len: usize = 0;
        for (models) |model| {
            const name_len = if (model.name) |n| n.len else model.model_id.len;
            if (name_len > max_name_len) max_name_len = name_len;
            const desc_len = if (model.description) |d| d.len else 0;
            if (desc_len > max_desc_len) max_desc_len = desc_len;
        }

        const content_width = @max(@max(max_name_len + 8, max_desc_len + 6), instructions.len);
        const dialog_width = @max(content_width + 4, title.len + 4);
        // Height: title(1) + empty(1) + models(2 each) + empty(1) + instructions(1) + border(2)
        const ideal_height = 3 + (model_count * 2) + 2;
        const max_height = win.height - 4;

        const popup_width = @min(dialog_width, win.width - 4);
        const popup_height = @min(ideal_height, max_height);
        const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
        const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

        const popup_win = win.child(.{
            .x_off = x_offset,
            .y_off = y_offset,
            .width = @intCast(popup_width),
            .height = @intCast(popup_height),
            .border = .{
                .where = .all,
                .style = .{ .fg = Color.cyan },
            },
        });

        popup_win.clear();

        // Fill with solid background
        const bg_cell = vaxis.Cell{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = .{ .index = 0 } }, // black background
        };
        popup_win.fill(bg_cell);

        // Title
        const title_copy = try RenderUtils.copyFrameText(app, title);
        var title_seg = [_]vaxis.Cell.Segment{.{
            .text = title_copy,
            .style = .{ .fg = Color.cyan, .bold = true },
        }};
        _ = popup_win.print(&title_seg, .{ .row_offset = @intCast(0) });

        // Calculate scroll offset for many models
        const rows_for_models = if (popup_height > 5) popup_height - 5 else 2;
        const max_visible = rows_for_models / 2;
        var scroll_offset: usize = 0;
        if (max_visible > 0 and model_count > max_visible) {
            if (app.state.model_selection >= max_visible) {
                scroll_offset = app.state.model_selection - max_visible + 1;
            }
            if (scroll_offset + max_visible > model_count) {
                scroll_offset = model_count - max_visible;
            }
        }

        // Render model options (2 lines each: name + description)
        const visible_count = @min(model_count - scroll_offset, max_visible);
        var row: usize = 2;
        for (0..visible_count) |i| {
            const model_idx = scroll_offset + i;
            if (model_idx >= model_count) break;
            if (row + 1 >= popup_height - 1) break;

            const model = models[model_idx];
            const is_selected = model_idx == app.state.model_selection;
            const is_current = if (current_model_id) |cid| std.mem.eql(u8, model.model_id, cid) else false;

            // Line 1: Selection caret + model name + current marker
            var name_segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            defer name_segments.deinit(app.allocator);

            const caret = if (is_selected) "▶ " else "  ";
            const caret_copy = try RenderUtils.copyFrameText(app, caret);
            try name_segments.append(app.allocator, .{ .text = caret_copy, .style = .{ .fg = Color.cyan } });

            const model_name = model.name orelse model.model_id;
            const name_copy = try RenderUtils.copyFrameText(app, model_name);
            try name_segments.append(app.allocator, .{ .text = name_copy, .style = .{ .fg = if (is_selected) Color.white else Color.dim, .bold = is_selected } });

            if (is_current) {
                const check_copy = try RenderUtils.copyFrameText(app, " ✓");
                try name_segments.append(app.allocator, .{ .text = check_copy, .style = .{ .fg = Color.green } });
            }

            _ = popup_win.print(name_segments.items, .{ .row_offset = @intCast(row) });
            row += 1;

            // Line 2: Description (indented)
            if (model.description) |desc| {
                if (desc.len > 0 and row < popup_height - 1) {
                    const max_len = if (popup_width > 6) popup_width - 6 else 1;
                    const truncated = if (desc.len > max_len) desc[0..max_len] else desc;
                    const desc_copy = try RenderUtils.copyFrameText(app, truncated);
                    var desc_seg = [_]vaxis.Cell.Segment{.{
                        .text = desc_copy,
                        .style = .{ .fg = Color.dim },
                    }};
                    _ = popup_win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = 4 });
                }
            }
            row += 1;
        }

        // Instructions at bottom
        const instr_copy = try RenderUtils.copyFrameText(app, instructions);
        var instr_seg = [_]vaxis.Cell.Segment{.{
            .text = instr_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = popup_win.print(&instr_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(1) });

        // Scroll indicators
        if (scroll_offset > 0) {
            const up_copy = try RenderUtils.copyFrameText(app, "↑");
            var up_seg = [_]vaxis.Cell.Segment{.{ .text = up_copy, .style = .{ .fg = Color.dim } }};
            _ = popup_win.print(&up_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(popup_width - 4) });
        }
        if (scroll_offset + visible_count < model_count) {
            const down_copy = try RenderUtils.copyFrameText(app, "↓");
            var down_seg = [_]vaxis.Cell.Segment{.{ .text = down_copy, .style = .{ .fg = Color.dim } }};
            _ = popup_win.print(&down_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(popup_width - 2) });
        }
    }

    pub fn renderAgentSelectionDialog(app: *App, win: vaxis.Window) !void {
        const agents = app.state.configured_agents orelse return;
        if (agents.len == 0) return;

        const agent_count = agents.len;

        // Calculate dialog dimensions
        const title = " Select Agent ";
        const instructions = "j/k:Navigate  Enter:Select  ESC:Cancel";

        // Find max width needed for agent entries
        var max_entry_len: usize = 0;
        for (agents) |agt| {
            const entry_len = 4 + agt.name.len + 3 + agt.command.len; // "▶ " + name + " (" + command + ")"
            if (entry_len > max_entry_len) {
                max_entry_len = entry_len;
            }
        }

        const dialog_width = @max(@max(max_entry_len + 4, title.len + 4), instructions.len + 4);
        const dialog_height = agent_count + 5; // title + agents + instructions + padding

        const popup_width = @min(dialog_width, win.width - 4);
        const popup_height = @min(dialog_height, win.height - 4);
        const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
        const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

        const popup_win = win.child(.{
            .x_off = x_offset,
            .y_off = y_offset,
            .width = @intCast(popup_width),
            .height = @intCast(popup_height),
            .border = .{
                .where = .all,
                .style = .{ .fg = Color.cyan },
            },
        });

        popup_win.clear();

        // Fill with solid background
        const bg_cell = vaxis.Cell{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = .{ .index = 0 } }, // black background
        };
        popup_win.fill(bg_cell);

        // Title
        const title_copy = try RenderUtils.copyFrameText(app, title);
        var title_seg = [_]vaxis.Cell.Segment{.{
            .text = title_copy,
            .style = .{ .fg = Color.cyan, .bold = true },
        }};
        _ = popup_win.print(&title_seg, .{ .row_offset = @intCast(0) });

        // Render agent options
        for (agents, 0..) |agt, idx| {
            const row = idx + 2;
            const is_selected = idx == app.state.agent_selection_idx;

            var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            defer segments.deinit(app.allocator);

            // Selection caret
            const caret = if (is_selected) "▶ " else "  ";
            const caret_copy = try RenderUtils.copyFrameText(app, caret);
            try segments.append(app.allocator, .{ .text = caret_copy, .style = .{ .fg = Color.cyan } });

            // Agent name
            const name_copy = try RenderUtils.copyFrameText(app, agt.name);
            try segments.append(app.allocator, .{ .text = name_copy, .style = .{ .fg = if (is_selected) Color.white else Color.dim, .bold = is_selected } });

            // Separator
            const sep_copy = try RenderUtils.copyFrameText(app, " (");
            try segments.append(app.allocator, .{ .text = sep_copy, .style = .{ .fg = Color.dim } });

            // Command
            const cmd_copy = try RenderUtils.copyFrameText(app, agt.command);
            try segments.append(app.allocator, .{ .text = cmd_copy, .style = .{ .fg = Color.dim } });

            // Close paren
            const close_copy = try RenderUtils.copyFrameText(app, ")");
            try segments.append(app.allocator, .{ .text = close_copy, .style = .{ .fg = Color.dim } });

            _ = popup_win.print(segments.items, .{ .row_offset = @intCast(row) });
        }

        // Instructions at bottom
        const instr_copy = try RenderUtils.copyFrameText(app, instructions);
        var instr_seg = [_]vaxis.Cell.Segment{.{
            .text = instr_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = popup_win.print(&instr_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(1) });
    }

    pub fn renderSessionPickerDialog(app: *App, win: vaxis.Window) !void {
        const session_list = app.state.session_list;
        const session_count = session_list.len;
        if (session_count == 0) return;

        // Calculate dialog dimensions
        const title = " Resume Session ";
        const instructions = "j/k:Navigate  Enter:Load  ESC:Cancel";

        // Find max width needed for session entries
        var max_display_len: usize = 0;
        var max_branch_len: usize = 0;
        for (session_list) |session| {
            if (session.display.len > max_display_len) max_display_len = session.display.len;
            if (session.branch) |branch| {
                if (branch.len > max_branch_len) max_branch_len = branch.len;
            }
        }

        // Width: time (12) + branch + display text + padding
        const branch_space = if (max_branch_len > 0) max_branch_len + 2 else 0;
        const content_width = @max(max_display_len + branch_space + 16, instructions.len);
        const dialog_width = @max(content_width + 4, title.len + 4);
        // Height: title(1) + empty(1) + sessions (2 rows each for last_message) + empty(1) + instructions(1) + border(2)
        const ideal_height = 3 + (session_count * 2) + 2;
        const max_height = win.height - 4;

        const popup_width = @min(dialog_width, win.width - 4);
        const popup_height = @min(ideal_height, max_height);
        const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
        const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

        const popup_win = win.child(.{
            .x_off = x_offset,
            .y_off = y_offset,
            .width = @intCast(popup_width),
            .height = @intCast(popup_height),
            .border = .{
                .where = .all,
                .style = .{ .fg = Color.cyan },
            },
        });

        popup_win.clear();

        // Fill with solid background
        const bg_cell = vaxis.Cell{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = .{ .index = 0 } },
        };
        popup_win.fill(bg_cell);

        // Title
        const title_copy = try RenderUtils.copyFrameText(app, title);
        var title_seg = [_]vaxis.Cell.Segment{.{
            .text = title_copy,
            .style = .{ .fg = Color.cyan, .bold = true },
        }};
        _ = popup_win.print(&title_seg, .{ .row_offset = @intCast(0) });

        // Calculate scroll offset for many sessions (2 rows per session)
        const rows_for_sessions = if (popup_height > 5) popup_height - 5 else 4;
        const max_visible = @max(rows_for_sessions / 2, 1); // Each session takes 2 rows
        var scroll_offset: usize = 0;
        if (max_visible > 0 and session_count > max_visible) {
            if (app.state.session_selection >= max_visible) {
                scroll_offset = app.state.session_selection - max_visible + 1;
            }
            if (scroll_offset + max_visible > session_count) {
                scroll_offset = session_count - max_visible;
            }
        }

        // Render session options
        const visible_count = @min(session_count - scroll_offset, max_visible);
        var row: usize = 2;
        for (0..visible_count) |i| {
            const session_idx = scroll_offset + i;
            if (session_idx >= session_count) break;
            if (row >= popup_height - 1) break;

            const session = session_list[session_idx];
            const is_selected = session_idx == app.state.session_selection;

            // Format relative time
            var time_buf: [32]u8 = undefined;
            const time_str = session.formatRelativeTime(&time_buf);

            // Build line: caret + time + display
            var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            defer segments.deinit(app.allocator);

            const caret = if (is_selected) "▶ " else "  ";
            const caret_copy = try RenderUtils.copyFrameText(app, caret);
            try segments.append(app.allocator, .{ .text = caret_copy, .style = .{ .fg = Color.cyan } });

            // Display text (truncated if needed) - show first
            const max_display = if (popup_width > 40) popup_width - 40 else 20;
            const display_text = if (session.display.len > max_display) session.display[0..max_display] else session.display;
            const display_copy = try RenderUtils.copyFrameText(app, display_text);
            try segments.append(app.allocator, .{ .text = display_copy, .style = .{ .fg = Color.white, .bold = is_selected } });

            // Time in dim color
            const time_copy = try RenderUtils.copyFrameText(app, time_str);
            try segments.append(app.allocator, .{ .text = "  ", .style = .{} });
            try segments.append(app.allocator, .{ .text = time_copy, .style = .{ .fg = Color.dim } });

            // Message count
            if (session.message_count > 0) {
                var msg_buf: [32]u8 = undefined;
                const msg_str = std.fmt.bufPrint(&msg_buf, " · {d} messages", .{session.message_count}) catch " · ? messages";
                const msg_copy = try RenderUtils.copyFrameText(app, msg_str);
                try segments.append(app.allocator, .{ .text = msg_copy, .style = .{ .fg = Color.dim } });
            }

            // Branch (if available)
            if (session.branch) |branch| {
                const branch_sep_copy = try RenderUtils.copyFrameText(app, " · ");
                try segments.append(app.allocator, .{ .text = branch_sep_copy, .style = .{ .fg = Color.dim } });
                const branch_copy = try RenderUtils.copyFrameText(app, branch);
                try segments.append(app.allocator, .{ .text = branch_copy, .style = .{ .fg = Color.yellow } });
            }

            _ = popup_win.print(segments.items, .{ .row_offset = @intCast(row) });
            row += 1;

            // Show last message preview on second line
            if (session.last_message) |last_msg| {
                if (row < popup_height - 1) {
                    const preview_max = if (popup_width > 9) popup_width - 9 else 30;
                    const is_truncated = last_msg.len > preview_max;
                    const preview_text = if (is_truncated) last_msg[0..preview_max] else last_msg;
                    const preview_copy = try RenderUtils.copyFrameText(app, preview_text);
                    if (is_truncated) {
                        var preview_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "  ↳ ", .style = .{ .fg = Color.dim } },
                            .{ .text = preview_copy, .style = .{ .fg = Color.dim } },
                            .{ .text = "...", .style = .{ .fg = Color.dim } },
                        };
                        _ = popup_win.print(&preview_seg, .{ .row_offset = @intCast(row) });
                    } else {
                        var preview_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "  ↳ ", .style = .{ .fg = Color.dim } },
                            .{ .text = preview_copy, .style = .{ .fg = Color.dim } },
                        };
                        _ = popup_win.print(&preview_seg, .{ .row_offset = @intCast(row) });
                    }
                    row += 1;
                }
            }
        }

        // Instructions at bottom
        const instr_copy = try RenderUtils.copyFrameText(app, instructions);
        var instr_seg = [_]vaxis.Cell.Segment{.{
            .text = instr_copy,
            .style = .{ .fg = Color.dim },
        }};
        _ = popup_win.print(&instr_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(1) });

        // Scroll indicators
        if (scroll_offset > 0) {
            const up_copy = try RenderUtils.copyFrameText(app, "↑");
            var up_seg = [_]vaxis.Cell.Segment{.{ .text = up_copy, .style = .{ .fg = Color.dim } }};
            _ = popup_win.print(&up_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(popup_width - 4) });
        }
        if (scroll_offset + visible_count < session_count) {
            const down_copy = try RenderUtils.copyFrameText(app, "↓");
            var down_seg = [_]vaxis.Cell.Segment{.{ .text = down_copy, .style = .{ .fg = Color.dim } }};
            _ = popup_win.print(&down_seg, .{ .row_offset = @intCast(popup_height - 2), .col_offset = @intCast(popup_width - 2) });
        }
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

        _ = win.print(&segments, .{ .row_offset = 0, .col_offset = @intCast(0 )});
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
                    if (input.vim.pending_find) |find_cmd| {
                        const find_str = switch (find_cmd) {
                            .f => "-- f? --",
                            .t => "-- t? --",
                            .F => "-- F? --",
                            .T => "-- T? --",
                        };
                        break :blk find_str;
                    }

                    // Check if waiting for motion after operator
                    if (input.vim.pending_operator) |operator| {
                        const operator_str = switch (operator) {
                            .d => "-- d (motion) --",
                            .y => "-- y (motion) --",
                            .c => "-- c (motion) --",
                        };
                        break :blk operator_str;
                    }

                    break :blk switch (input.vim.vim_mode) {
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
            .mcp_status => "-- MCP STATUS --",
            .graphite_stack => "-- GRAPHITE STACK --",
            .model_selection => "-- MODEL SELECTION --",
            .agent_selection => "-- AGENT SELECTION --",
            .session_picker => "-- RESUME SESSION --",
            .agent => blk: {
                // Show vim mode when in agent mode
                if (app.state.agent_state) |agent_state| {
                    break :blk switch (agent_state.input.vim.vim_mode) {
                        .normal => "-- NORMAL (agent) --",
                        .insert => "-- INSERT (agent) --",
                        .visual => "-- VISUAL (agent) --",
                        .command => "-- COMMAND (agent) --",
                    };
                }
                break :blk "-- AGENT --";
            },
        };

        const view_str = switch (app.state.view_mode) {
            .unified => "[Unified]",
            .side_by_side => "[Side-by-Side]",
        };

        // Hunk view mode with symbol
        const hunk_view_symbol = app.state.hunk_view_mode.toSymbol();

        // Context-aware keybindings based on cursor position and mode
        const keybindings = switch (app.mode) {
            .normal => "j/k:Move  |  ? for help",
            .comment => blk: {
                if (app.state.active_comment_input) |input| {
                    break :blk switch (input.vim.vim_mode) {
                        .normal => "i:Insert  |  :wq:Save  |  ESC:Cancel",
                        .insert => "INSERT  |  ESC:Normal",
                        .visual => "VISUAL  |  ESC:Exit",
                        .command => ":w :q :wq  |  Enter:Execute  |  ESC:Cancel",
                    };
                }
                break :blk "Enter:Save  |  ESC:Cancel";
            },
            .search => "Type to search  |  Enter:Execute  |  ESC:Cancel",
            .visual => "j/k:Extend  |  y:Yank  |  ESC:Exit",
            .command_palette => "Type to filter  |  '>':Commands  |  ↑↓:Select  |  ESC:Cancel",
            .help => "j/k:Scroll  |  Ctrl-d/u:Page  |  ?/ESC:Close",
            .branch_selection => "j/k:Move  |  Enter:Select  |  ESC:Back",
            .mcp_status => "q/ESC:Close",
            .graphite_stack => "j/k:Move  |  Enter:Select  |  ESC:Back  |  [s/]s:Navigate",
            .model_selection => "j/k:Move  |  Enter:Select  |  ESC:Cancel",
            .agent_selection => "j/k:Move  |  Enter:Select  |  ESC:Cancel",
            .session_picker => "j/k:Move  |  Enter:Load  |  ESC:Cancel",
            .agent => blk: {
                if (app.state.agent_state) |agent_state| {
                    break :blk switch (agent_state.input.vim.vim_mode) {
                        .normal => "i:Insert  |  z:Full  |  q:Close  |  ,d:Diff",
                        .insert => "INSERT  |  Enter:Send  |  ESC:Normal",
                        .visual => "VISUAL  |  ESC:Exit",
                        .command => "Enter:Execute  |  ESC:Cancel",
                    };
                }
                break :blk ",d:Close";
            },
        };

        // Get file position info (line number shown via scrollbar)
        const total_files = app.state.files.len;
        const current_file = app.state.current_file_idx + 1; // Display 1-indexed

        // Build status bar using segments with colors
        var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        defer segments.deinit(app.allocator);

        if (app.mode == .comment and app.state.active_comment_input != null and
            app.state.active_comment_input.?.vim.vim_mode == .command)
        {
            // In command mode, show command line like vim
            const input = app.state.active_comment_input.?;
            const command = input.vim.command_buffer[0..input.vim.command_len];

            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, ":"), .style = .{ .bold = true } });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, command), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "_"), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "  "), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        } else if (app.mode == .search) {
            // In search mode, show search prompt with current query
            const query = app.state.search_state.query_buffer[0..app.state.search_state.query_len];
            const match_count = app.state.search_state.matches.items.len;

            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, mode_str), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "  /"), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, query), .style = .{} });

            if (match_count > 0) {
                const current_match = if (app.state.search_state.current_match_idx) |idx| idx + 1 else 0;
                var buf: [64]u8 = undefined;
                const match_info = try std.fmt.bufPrint(&buf, "  ({d} of {d} matches)  ", .{ current_match, match_count });
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, match_info), .style = .{} });
            } else if (app.state.search_state.query_len > 0) {
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "_  "), .style = .{} });
            } else {
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "_  "), .style = .{} });
            }

            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        } else {
            // Normal mode status bar with colored hunk view mode
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, mode_str), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " "), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, view_str), .style = .{} });

            // Show diff source mode
            const diff_str = try formatDiffSource(app.allocator, app.state.diff_source);
            defer app.allocator.free(diff_str);
            const diff_str_copy = try RenderUtils.copyFrameText(app, diff_str);
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " "), .style = .{} });
            try segments.append(app.allocator, .{ .text = diff_str_copy, .style = .{ .fg = Color.cyan } });

            // Show graphite stack position if in a stack
            if (app.state.graphite_stack) |stack| {
                var stack_buf: [64]u8 = undefined;
                const stack_pos = try std.fmt.bufPrint(&stack_buf, " [{d}/{d} in stack]", .{ stack.current_idx + 1, stack.branches.len });
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, stack_pos), .style = .{ .fg = Color.magenta } });
            }

            // Only show hunk view mode indicator in unified view (where filtering applies)
            if (app.state.view_mode == .unified) {
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " ["), .style = .{} });

                // Add colored hunk view symbol
                if (app.state.hunk_view_mode == .all) {
                    // For "+/-" mode, color + green and - red
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "+"), .style = .{ .fg = Color.green, .bold = true } });
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "/"), .style = .{ .bold = true } });
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "-"), .style = .{ .fg = Color.red, .bold = true } });
                } else {
                    // For single mode, use appropriate color
                    const hunk_view_style: vaxis.Style = switch (app.state.hunk_view_mode) {
                        .all => unreachable, // Already handled above
                        .old => .{ .fg = Color.red, .bold = true },
                        .new => .{ .fg = Color.green, .bold = true },
                    };
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, hunk_view_symbol), .style = hunk_view_style });
                }
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "]"), .style = .{} });
            }

            if (app.state.count_prefix) |count| {
                var buf: [64]u8 = undefined;
                const count_str = try std.fmt.bufPrint(&buf, " [{d}]", .{count});
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, count_str), .style = .{} });
            }

            // Only show file position (line number shown via scrollbar)
            var buf: [64]u8 = undefined;
            const pos_info = try std.fmt.bufPrint(&buf, "  File {d}/{d}", .{ current_file, total_files });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, pos_info), .style = .{} });

            // Show search info if there are active matches in normal mode
            if (app.state.search_state.hasMatches()) {
                const match_count = app.state.search_state.matches.items.len;
                const current_match = if (app.state.search_state.current_match_idx) |idx| idx + 1 else 0;
                var match_buf: [64]u8 = undefined;
                const match_info = try std.fmt.bufPrint(&match_buf, "  [{d}/{d} matches]", .{ current_match, match_count });
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, match_info), .style = .{} });
            }

            // Show temporary status message (if any)
            if (app.state.status_message) |msg| {
                var msg_buf: [128]u8 = undefined;
                const formatted = std.fmt.bufPrint(&msg_buf, "  [{s}]", .{msg}) catch msg;
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, formatted), .style = .{ .fg = Color.magenta } });
            }

            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "  "), .style = .{} });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        }

        _ = win.print(segments.items, .{ .row_offset = @intCast(0 )});
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
        _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(0 )});
    }

    /// Render a vertical divider line
    pub fn renderVerticalDivider(win: vaxis.Window) !void {
        const divider_style = vaxis.Style{
            .fg = .{ .index = 8 }, // dark gray
        };

        for (0..win.height) |row| {
            var seg = [_]vaxis.Cell.Segment{
                .{ .text = "│", .style = divider_style },
            };
            _ = win.print(&seg, .{ .row_offset = @intCast(row )});
        }
    }

};
