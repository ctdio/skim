const std = @import("std");
const vaxis = @import("vaxis");

// Color constants (matching rendering/common.zig)
const Color = struct {
    const cyan: vaxis.Cell.Color = .{ .index = 6 };
    const white: vaxis.Cell.Color = .{ .index = 7 };
    const green: vaxis.Cell.Color = .{ .index = 2 };
    const dim_gray: vaxis.Cell.Color = .{ .index = 8 };
    const dim: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 100, 100 } };
    const dialog_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 22, 22, 22 } };
};

const DIALOG_PADDING: usize = 1;

// =============================================================================
// Data Types
// =============================================================================

pub const ModelEntry = struct {
    model_id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const ModelDialogConfig = struct {
    models: []const ModelEntry,
    selected_index: usize = 0,
    current_model_id: ?[]const u8 = null,
    search_query: []const u8 = "",
    /// If null, all models shown (no filtering)
    filtered_indices: ?[]const usize = null,
};

// =============================================================================
// Rendering Functions
// =============================================================================

/// Fill window with dialog background color
pub fn fillBackground(win: vaxis.Window) void {
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    win.fill(bg_cell);
}

/// Render a model selection dialog matching the command palette layout.
/// Layout: PADDING + title + input + separator + models + instructions + PADDING
/// This is a standalone test helper that doesn't require an App.
pub fn renderModelSelectionDialog(win: vaxis.Window, config: ModelDialogConfig, frame_alloc: std.mem.Allocator) void {
    const models = config.models;
    if (models.len == 0) return;

    // Caller must provide filtered_indices for tests
    const filtered = config.filtered_indices orelse return;
    const filtered_count = filtered.len;

    // Check if any models have descriptions
    var has_descriptions = false;
    for (models) |model| {
        if (model.description) |d| {
            if (d.len > 0) {
                has_descriptions = true;
                break;
            }
        }
    }
    const rows_per_model: usize = if (has_descriptions) 2 else 1;

    const popup_width = win.width;
    const popup_height = win.height;

    // Fill background
    fillBackground(win);

    // Row PADDING: Title
    const title = " Switch Model ";
    const title_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true };
    var title_seg = [_]vaxis.Cell.Segment{.{ .text = title, .style = title_style }};
    _ = win.print(&title_seg, .{ .row_offset = @intCast(DIALOG_PADDING) });

    // Row PADDING+1: Search input with "> " prompt
    const query = config.search_query;
    if (query.len > 0) {
        var search_seg = [_]vaxis.Cell.Segment{
            .{ .text = "> ", .style = .{ .fg = Color.cyan, .bg = Color.dialog_bg } },
            .{ .text = query, .style = .{ .fg = Color.white, .bg = Color.dialog_bg } },
        };
        _ = win.print(&search_seg, .{ .row_offset = @intCast(DIALOG_PADDING + 1), .col_offset = @intCast(DIALOG_PADDING) });
    } else {
        var search_seg = [_]vaxis.Cell.Segment{.{
            .text = "Type to search...",
            .style = .{ .fg = Color.dim, .bg = Color.dialog_bg },
        }};
        _ = win.print(&search_seg, .{ .row_offset = @intCast(DIALOG_PADDING + 1), .col_offset = @intCast(DIALOG_PADDING) });
    }

    // Row PADDING+2: Separator line
    if (popup_width > DIALOG_PADDING * 2) {
        const sep_width = popup_width - (DIALOG_PADDING * 2);
        const sep_text = frame_alloc.alloc(u8, sep_width) catch return;
        @memset(sep_text, '-');
        var sep_seg = [_]vaxis.Cell.Segment{.{
            .text = sep_text,
            .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg },
        }};
        _ = win.print(&sep_seg, .{ .row_offset = @intCast(DIALOG_PADDING + 2), .col_offset = @intCast(DIALOG_PADDING) });
    }

    // Content starts at row PADDING+3
    const content_start_row = DIALOG_PADDING + 3;

    // Models
    if (filtered_count == 0) {
        const no_matches_style = vaxis.Style{ .fg = Color.dim, .bg = Color.dialog_bg };
        var no_seg = [_]vaxis.Cell.Segment{.{ .text = "No matching models", .style = no_matches_style }};
        _ = win.print(&no_seg, .{ .row_offset = @intCast(content_start_row), .col_offset = @intCast(DIALOG_PADDING) });
    } else {
        // Calculate scroll
        const instr_rows: usize = 2 + DIALOG_PADDING; // spacer + instructions + bottom padding
        const available_rows = if (popup_height > content_start_row + instr_rows)
            popup_height - content_start_row - instr_rows
        else
            rows_per_model;
        const max_visible = available_rows / rows_per_model;
        var scroll_offset: usize = 0;
        if (max_visible > 0 and filtered_count > max_visible) {
            if (config.selected_index >= max_visible) {
                scroll_offset = config.selected_index - max_visible + 1;
            }
            if (scroll_offset + max_visible > filtered_count) {
                scroll_offset = filtered_count - max_visible;
            }
        }

        const visible_count = @min(filtered_count - scroll_offset, max_visible);
        var row: usize = content_start_row;
        for (0..visible_count) |i| {
            const selection_idx = scroll_offset + i;
            if (selection_idx >= filtered_count) break;
            if (row >= popup_height - 1 - DIALOG_PADDING) break;

            const actual_model_idx = filtered[selection_idx];
            if (actual_model_idx >= models.len) continue;

            const model = models[actual_model_idx];
            const is_selected = selection_idx == config.selected_index;
            const is_current = if (config.current_model_id) |cid|
                std.mem.eql(u8, model.model_id, cid)
            else
                false;

            // Caret
            const caret = if (is_selected) "▶ " else "  ";
            const caret_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg };

            // Model name
            const model_name = model.name orelse model.model_id;
            const name_style = vaxis.Style{
                .fg = if (is_selected) Color.white else Color.dim,
                .bg = Color.dialog_bg,
                .bold = is_selected,
            };

            if (is_current) {
                var segs = [_]vaxis.Cell.Segment{
                    .{ .text = caret, .style = caret_style },
                    .{ .text = model_name, .style = name_style },
                    .{ .text = " ✓", .style = .{ .fg = Color.green, .bg = Color.dialog_bg } },
                };
                _ = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(DIALOG_PADDING) });
            } else {
                var segs = [_]vaxis.Cell.Segment{
                    .{ .text = caret, .style = caret_style },
                    .{ .text = model_name, .style = name_style },
                };
                _ = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(DIALOG_PADDING) });
            }
            row += 1;

            // Description line (only if any models have descriptions)
            if (has_descriptions) {
                if (model.description) |desc| {
                    if (desc.len > 0 and row < popup_height - 1 - DIALOG_PADDING) {
                        const desc_style = vaxis.Style{ .fg = Color.dim, .bg = Color.dialog_bg };
                        var desc_seg = [_]vaxis.Cell.Segment{.{ .text = desc, .style = desc_style }};
                        _ = win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(DIALOG_PADDING + 3) });
                    }
                }
                row += 1;
            }
        }

        // Scroll indicators
        if (scroll_offset > 0) {
            var up_seg = [_]vaxis.Cell.Segment{.{ .text = "↑", .style = .{ .fg = Color.dim, .bg = Color.dialog_bg } }};
            _ = win.print(&up_seg, .{ .row_offset = @intCast(popup_height - 1 - DIALOG_PADDING), .col_offset = @intCast(popup_width - 4) });
        }
        if (scroll_offset + visible_count < filtered_count) {
            var down_seg = [_]vaxis.Cell.Segment{.{ .text = "↓", .style = .{ .fg = Color.dim, .bg = Color.dialog_bg } }};
            _ = win.print(&down_seg, .{ .row_offset = @intCast(popup_height - 1 - DIALOG_PADDING), .col_offset = @intCast(popup_width - 2) });
        }
    }

    // Instructions at bottom (popup_height - 1 - DIALOG_PADDING)
    const instructions = "Type to search  |  ↑↓/Ctrl-n/p:Navigate  |  Enter:Select  |  ESC:Clear/Cancel";
    const instr_style = vaxis.Style{ .fg = Color.dim, .bg = Color.dialog_bg };
    var instr_seg = [_]vaxis.Cell.Segment{.{ .text = instructions, .style = instr_style }};
    _ = win.print(&instr_seg, .{ .row_offset = @intCast(popup_height - 1 - DIALOG_PADDING), .col_offset = @intCast(DIALOG_PADDING) });
}
