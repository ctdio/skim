const std = @import("std");
const vaxis = @import("vaxis");
const state = @import("state.zig");
const OwnedPlanEntry = state.OwnedPlanEntry;

// Import skim's color palette for consistent styling
const rendering_common = @import("../rendering/common.zig");
const Color = rendering_common.Color;

/// Render the plan/todo area with entries
pub fn renderPlanArea(win: vaxis.Window, entries: []const OwnedPlanEntry, expanded: bool) void {
    if (win.height == 0 or entries.len == 0) return;

    var row: usize = 0;
    const header_style = vaxis.Style{ .fg = Color.dim_gray, .bold = true };

    // Clear entire header row first to avoid artifacts
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        });
    }

    // Draw leading dashes at columns 0-2 (extend to edge, align with todo content at col 3)
    for (0..3) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = header_style,
        });
    }

    // Draw " Todos " text starting at column 2 (space at col 2, Todos at col 3 aligns with todo content)
    const title_text = " Todos ";
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = title_text, .style = header_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });

    // Add expansion indicator and "+N more" in header for collapsed view
    const header_end: usize = 9; // col 2 + " Todos " (7 chars) = 9
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
        .pending => .{ .fg = Color.dim_gray },
        .in_progress => .{ .fg = Color.yellow, .bold = true },
        .completed => .{ .fg = Color.green },
    };

    // Content style (dim for completed)
    const content_style: vaxis.Style = switch (entry.status) {
        .completed => .{ .fg = Color.dim_gray },
        else => .{ .fg = Color.white },
    };

    // Print status icon
    var icon_seg = [_]vaxis.Cell.Segment{
        .{ .text = status_icon, .style = status_style },
    };
    _ = win.print(&icon_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

    // Print content (truncate if needed)
    const max_content_len = if (win.width > 5) win.width - 5 else 1;
    const content = if (entry.content.len > max_content_len)
        entry.content[0..max_content_len]
    else
        entry.content;

    var content_seg = [_]vaxis.Cell.Segment{
        .{ .text = content, .style = content_style },
    };
    _ = win.print(&content_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });
}
