const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");
const parser = @import("../git/parser.zig");
const syntax = @import("../highlighting/core.zig");
const search = @import("../search.zig");
const rendering_common = @import("common.zig");
const render_unified = @import("unified.zig");
const render_side_by_side = @import("side_by_side.zig");
const loading = @import("loading.zig");
const ui_components = @import("../ui.zig");
const agent = @import("../agent/agent.zig");
const command_palette = @import("../command_palette.zig");
const help = @import("../help.zig");

const App = @import("../app.zig").App;
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const UI = ui_components.UI;
const UnifiedRenderer = render_unified.UnifiedRenderer;
const SideBySideRenderer = render_side_by_side.SideBySideRenderer;
const profiling_enabled = build_options.enable_profile;

pub fn render(app: *App, win: vaxis.Window) !void {
    const profile_frame = if (profiling_enabled) app.profile_active_frame else false;
    var total_timer_opt: ?std.time.Timer = if (profile_frame) std.time.Timer.start() catch null else null;
    var header_ns: u64 = 0;
    var content_ns: u64 = 0;
    var status_ns: u64 = 0;
    var agent_ns: u64 = 0;
    var overlay_ns: u64 = 0;
    if (profile_frame) {
        app.profile_counters = .{};
    }

    win.clear();
    app.resetFrameAllocators();

    // Hide cursor by default - comment input will show it when needed
    win.hideCursor();

    if (win.width == 0 or win.height == 0) {
        return;
    }

    // Content height without dividers (continuous mode)
    const content_height = win.height -| Layout.header_height -| Layout.status_height;

    // Check if agent panel should be shown (visible and not full-screen)
    // Don't show when in agent_selection mode (selecting which agent to connect to)
    const show_agent_panel = app.isAgentPanelVisible() and !app.isAgentFullScreen() and app.mode != .agent_selection;

    // Render header and content (or empty/branch menu if no files)
    if (app.state.files.len == 0) {
        // Initial diff still streaming and nothing on screen yet: show a loading
        // indicator instead of the "no changes" menu until the first file lands.
        if (app.state.diff_load.isLoading()) {
            loading.renderLoadingScreen(win);
            return;
        }

        // No files - show empty state or branch selection menu
        // If agent panel is visible, render it as sidebar with empty menu in main area
        if (show_agent_panel) {
            const panel_side = app.getAgentPanelSide();
            const panel_width = win.width * 3 / 10; // 30% for agent panel
            const diff_width = win.width - panel_width;

            if (panel_side == .left) {
                // Agent panel on left
                const agent_win = win.child(.{
                    .x_off = 0,
                    .y_off = Layout.header_height,
                    .width = @intCast(panel_width),
                    .height = @intCast(content_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try agent.renderAgentPanel(app, agent_win);
                    if (timer_opt) |*timer| agent_ns += timer.read();
                } else {
                    try agent.renderAgentPanel(app, agent_win);
                }

                // Empty menu on right
                const content_win = win.child(.{
                    .x_off = @intCast(panel_width),
                    .y_off = 0,
                    .width = @intCast(diff_width),
                    .height = @intCast(win.height),
                });
                if (app.mode == .branch_selection) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderBranchSelectionMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderBranchSelectionMenu(app, content_win);
                    }
                } else if (app.mode == .commit_selection) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderCommitSelectionMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderCommitSelectionMenu(app, content_win);
                    }
                } else if (app.mode == .commit_diff_mode) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderCommitSelectionMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                        timer_opt = std.time.Timer.start() catch null;
                        try UI.renderCommitDiffModeMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderCommitSelectionMenu(app, content_win);
                        try UI.renderCommitDiffModeMenu(app, content_win);
                    }
                } else {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderEmptyMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderEmptyMenu(app, content_win);
                    }
                }
            } else {
                // Empty menu on left
                const content_win = win.child(.{
                    .x_off = 0,
                    .y_off = 0,
                    .width = @intCast(diff_width),
                    .height = @intCast(win.height),
                });
                if (app.mode == .branch_selection) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderBranchSelectionMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderBranchSelectionMenu(app, content_win);
                    }
                } else if (app.mode == .commit_selection) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderCommitSelectionMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderCommitSelectionMenu(app, content_win);
                    }
                } else if (app.mode == .commit_diff_mode) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderCommitSelectionMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                        timer_opt = std.time.Timer.start() catch null;
                        try UI.renderCommitDiffModeMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderCommitSelectionMenu(app, content_win);
                        try UI.renderCommitDiffModeMenu(app, content_win);
                    }
                } else {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderEmptyMenu(app, content_win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderEmptyMenu(app, content_win);
                    }
                }

                // Agent panel on right
                const agent_win = win.child(.{
                    .x_off = @intCast(diff_width),
                    .y_off = Layout.header_height,
                    .width = @intCast(panel_width),
                    .height = @intCast(content_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try agent.renderAgentPanel(app, agent_win);
                    if (timer_opt) |*timer| agent_ns += timer.read();
                } else {
                    try agent.renderAgentPanel(app, agent_win);
                }
            }
        } else {
            // No agent panel - full screen empty menu
            if (app.mode == .branch_selection) {
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try UI.renderBranchSelectionMenu(app, win);
                    if (timer_opt) |*timer| overlay_ns += timer.read();
                } else {
                    try UI.renderBranchSelectionMenu(app, win);
                }
            } else if (app.mode == .commit_selection) {
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try UI.renderCommitSelectionMenu(app, win);
                    if (timer_opt) |*timer| overlay_ns += timer.read();
                } else {
                    try UI.renderCommitSelectionMenu(app, win);
                }
            } else if (app.mode == .commit_diff_mode) {
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try UI.renderCommitSelectionMenu(app, win);
                    if (timer_opt) |*timer| overlay_ns += timer.read();
                    timer_opt = std.time.Timer.start() catch null;
                    try UI.renderCommitDiffModeMenu(app, win);
                    if (timer_opt) |*timer| overlay_ns += timer.read();
                } else {
                    try UI.renderCommitSelectionMenu(app, win);
                    try UI.renderCommitDiffModeMenu(app, win);
                }
            } else {
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try UI.renderEmptyMenu(app, win);
                    if (timer_opt) |*timer| overlay_ns += timer.read();
                } else {
                    try UI.renderEmptyMenu(app, win);
                }
            }
        }
    } else {
        // Normal rendering with header, content, and status bar
        // Split content area based on panels
        if (show_agent_panel) {
            const panel_side = app.getAgentPanelSide();
            const panel_width = win.width * 3 / 10; // 30% for agent panel
            const diff_width = win.width - panel_width;

            if (panel_side == .left) {
                // Agent panel on left (starts at y=0, full height including header area)
                const agent_win = win.child(.{
                    .x_off = 0,
                    .y_off = 0,
                    .width = @intCast(panel_width),
                    .height = @intCast(content_height + Layout.header_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try agent.renderAgentPanel(app, agent_win);
                    if (timer_opt) |*timer| agent_ns += timer.read();
                } else {
                    try agent.renderAgentPanel(app, agent_win);
                }

                // Header above diff content (on right side)
                const header_win = win.child(.{
                    .x_off = @intCast(panel_width),
                    .y_off = 0,
                    .width = @intCast(diff_width),
                    .height = @intCast(Layout.header_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try UI.renderHeader(app, header_win);
                    if (timer_opt) |*timer| header_ns += timer.read();
                } else {
                    try UI.renderHeader(app, header_win);
                }

                // Diff content on right (below header)
                const content_win = win.child(.{
                    .x_off = @intCast(panel_width),
                    .y_off = Layout.header_height,
                    .width = @intCast(diff_width),
                    .height = @intCast(content_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try renderContent(app, content_win);
                    if (timer_opt) |*timer| content_ns += timer.read();
                } else {
                    try renderContent(app, content_win);
                }
            } else {
                // Agent panel on right (default)
                // Header above diff content (on left side)
                const header_win = win.child(.{
                    .x_off = 0,
                    .y_off = 0,
                    .width = @intCast(diff_width),
                    .height = @intCast(Layout.header_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try UI.renderHeader(app, header_win);
                    if (timer_opt) |*timer| header_ns += timer.read();
                } else {
                    try UI.renderHeader(app, header_win);
                }

                // Diff content on left (below header)
                const content_win = win.child(.{
                    .x_off = 0,
                    .y_off = Layout.header_height,
                    .width = @intCast(diff_width),
                    .height = @intCast(content_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try renderContent(app, content_win);
                    if (timer_opt) |*timer| content_ns += timer.read();
                } else {
                    try renderContent(app, content_win);
                }

                // Agent panel on right (starts at y=0, full height including header area)
                const agent_win = win.child(.{
                    .x_off = @intCast(diff_width),
                    .y_off = 0,
                    .width = @intCast(panel_width),
                    .height = @intCast(content_height + Layout.header_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try agent.renderAgentPanel(app, agent_win);
                    if (timer_opt) |*timer| agent_ns += timer.read();
                } else {
                    try agent.renderAgentPanel(app, agent_win);
                }
            }
        } else {
            // Full width - header spans full width
            const header_win = win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = @intCast(win.width),
                .height = @intCast(Layout.header_height),
            });
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderHeader(app, header_win);
                if (timer_opt) |*timer| header_ns += timer.read();
            } else {
                try UI.renderHeader(app, header_win);
            }
            // Full width content
            const content_win = win.child(.{
                .x_off = 0,
                .y_off = Layout.header_height,
                .width = @intCast(win.width),
                .height = @intCast(content_height),
            });
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try renderContent(app, content_win);
                if (timer_opt) |*timer| content_ns += timer.read();
            } else {
                try renderContent(app, content_win);
            }
        }
    }

    // Render unified status bar (handles both diff mode and agent mode content)
    // This is outside the files check so it renders even when there are no files
    const status_win = win.child(.{
        .x_off = 0,
        .y_off = win.height -| Layout.status_height,
        .width = @intCast(win.width),
        .height = @intCast(Layout.status_height),
    });
    if (profile_frame) {
        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
        try UI.renderStatus(app, status_win);
        if (timer_opt) |*timer| status_ns += timer.read();
    } else {
        try UI.renderStatus(app, status_win);
    }

    // Render command palette overlay if in command palette mode
    if (app.mode == .command_palette) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try command_palette.renderCommandPalette(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try command_palette.renderCommandPalette(app, win);
        }
    }

    // Render help overlay if in help mode
    if (app.mode == .help) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try help.renderHelpPopup(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try help.renderHelpPopup(app, win);
        }
    }

    // Render graphite stack dialog if in graphite_stack mode
    if (app.mode == .graphite_stack) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderGraphiteStackDialog(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderGraphiteStackDialog(app, win);
        }
    }

    // Render the PR picker full-screen if in pr_review mode (it clears the
    // window, so it overlays whatever diff was underneath).
    if (app.mode == .pr_review) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderPrReviewDialog(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderPrReviewDialog(app, win);
        }
    }

    // Render submit-review dialog if in review_submit mode
    if (app.mode == .review_submit) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderReviewSubmitDialog(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderReviewSubmitDialog(app, win);
        }
    }

    // Render read-only PR info panel if in pr_info mode
    if (app.mode == .pr_info) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderPrInfoPanel(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderPrInfoPanel(app, win);
        }
    }

    // Render model selection dialog if in model_selection mode
    if (app.mode == .model_selection) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderModelSelectionDialog(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderModelSelectionDialog(app, win);
        }
    }

    // Render permission selection dialog if in permission_selection mode
    if (app.mode == .permission_selection) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderPermissionSelectionDialog(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderPermissionSelectionDialog(app, win);
        }
    }

    // Render agent selection dialog if in agent_selection mode
    if (app.mode == .agent_selection) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderAgentSelectionDialog(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderAgentSelectionDialog(app, win);
        }
    }

    // Render session picker dialog if in session_picker mode
    if (app.mode == .session_picker) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderSessionPickerDialog(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderSessionPickerDialog(app, win);
        }
    }

    // Render commit selection overlay if in commit_selection or commit_diff_mode
    if (app.mode == .commit_selection) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderCommitSelectionMenu(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderCommitSelectionMenu(app, win);
        }
    }
    if (app.mode == .commit_diff_mode) {
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderCommitSelectionMenu(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
            timer_opt = std.time.Timer.start() catch null;
            try UI.renderCommitDiffModeMenu(app, win);
            if (timer_opt) |*timer| overlay_ns += timer.read();
        } else {
            try UI.renderCommitSelectionMenu(app, win);
            try UI.renderCommitDiffModeMenu(app, win);
        }
    }

    // Render agent panel full-screen if in full-screen mode AND in agent mode
    // Only render when actually focused on the agent panel (mode == .agent)
    // Use a child window that excludes the status bar row (status bar is unified)
    if (app.isAgentPanelVisible() and app.isAgentFullScreen() and app.mode == .agent) {
        const agent_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = if (win.height > Layout.status_height) win.height - Layout.status_height else win.height,
        });
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try agent.renderAgentPanel(app, agent_win);
            if (timer_opt) |*timer| agent_ns += timer.read();
        } else {
            try agent.renderAgentPanel(app, agent_win);
        }
    }

    if (profile_frame) {
        const profile_log = std.log.scoped(.profile_render);
        const total_ns: u64 = if (total_timer_opt) |*timer| timer.read() else 0;
        profile_log.debug(
            "render frame {d}: total_ns={d} header_ns={d} content_ns={d} status_ns={d} agent_ns={d} overlay_ns={d} mode={s} view={s} files={d} lines={d}",
            .{ app.profile_frame_counter, total_ns, header_ns, content_ns, status_ns, agent_ns, overlay_ns, @tagName(app.mode), @tagName(app.state.view_mode), app.state.files.len, app.state.line_map.records.len },
        );
        profile_log.debug(
            "render micro: slice_ns={d} slice_calls={d} pad_ns={d} pad_calls={d} gutter_ns={d} gutter_calls={d} highlight_ns={d} highlight_calls={d} overlap_ns={d} overlap_calls={d} build_ns={d} build_calls={d} search_ns={d} search_calls={d}",
            .{
                app.profile_counters.slice_ns,
                app.profile_counters.slice_calls,
                app.profile_counters.pad_ns,
                app.profile_counters.pad_calls,
                app.profile_counters.gutter_ns,
                app.profile_counters.gutter_calls,
                app.profile_counters.highlight_total_ns,
                app.profile_counters.highlight_calls,
                app.profile_counters.highlight_overlap_ns,
                app.profile_counters.highlight_overlap_calls,
                app.profile_counters.highlight_build_ns,
                app.profile_counters.highlight_build_calls,
                app.profile_counters.search_ns,
                app.profile_counters.search_calls,
            },
        );
    }
}

fn renderContent(app: *App, win: vaxis.Window) !void {
    switch (app.state.view_mode) {
        .unified => try UnifiedRenderer.renderContent(app, win),
        .side_by_side => try SideBySideRenderer.renderContent(app, win),
    }
}

// Generate colored segments for a line of text using syntax highlights
// Returns array of segments with syntax colors applied as foreground
// text: the text chunk to render (may be part of a wrapped line)
// full_line_text: the complete line text (for search highlighting)
// text_offset: offset of this chunk within the full line
// line_byte_offset: byte offset for syntax highlighting
pub fn createHighlightedSegments(
    app: *App,
    text: []const u8,
    full_line_text: []const u8,
    text_offset: usize,
    line_byte_offset: usize,
    highlights: ?[]syntax.Highlight,
    line_spans: ?[]const parser.LineHighlightSpan,
    base_style: vaxis.Style,
    global_line: usize,
) ![]vaxis.Cell.Segment {
    var total_timer_opt: ?std.time.Timer = null;
    if (app.profile_active_frame) {
        total_timer_opt = std.time.Timer.start() catch null;
    }
    defer if (total_timer_opt) |*timer| {
        app.profile_counters.highlight_total_ns += timer.read();
        app.profile_counters.highlight_calls += 1;
    };

    const allocator = app.frameSegmentAllocator();

    // Check for merge conflict markers and apply special styling
    if (getConflictMarkerStyle(full_line_text, base_style)) |conflict_style| {
        var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
        segments[0] = .{
            .text = text,
            .style = conflict_style,
        };
        return try applySearchHighlighting(app, segments, text, full_line_text, text_offset, global_line);
    }

    if (text.len == 0) {
        var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
        segments[0] = .{
            .text = text,
            .style = base_style,
        };
        return try applySearchHighlighting(app, segments, text, full_line_text, text_offset, global_line);
    }

    if (line_spans) |spans| {
        if (spans.len == 0) {
            var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{ .text = text, .style = base_style };
            return try applySearchHighlighting(app, segments, text, full_line_text, text_offset, global_line);
        }

        var build_timer_opt: ?std.time.Timer = null;
        if (app.profile_active_frame) {
            build_timer_opt = std.time.Timer.start() catch null;
        }

        var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        errdefer segments.deinit(allocator);

        var pos: usize = 0;
        var span_idx: usize = 0;
        const chunk_start = text_offset;
        const chunk_end = text_offset + text.len;

        while (pos < text.len) {
            const absolute_pos = chunk_start + pos;
            while (span_idx < spans.len and spans[span_idx].end <= absolute_pos) {
                span_idx += 1;
            }

            if (span_idx >= spans.len or spans[span_idx].start >= chunk_end) {
                const chunk = text[pos..];
                try segments.append(allocator, .{ .text = chunk, .style = base_style });
                break;
            }

            const span = spans[span_idx];
            if (span.start > absolute_pos) {
                const end = @min(span.start, chunk_end);
                const chunk = text[pos .. end - chunk_start];
                try segments.append(allocator, .{ .text = chunk, .style = base_style });
                pos = end - chunk_start;
                continue;
            }

            const end = @min(span.end, chunk_end);
            const chunk = text[pos .. end - chunk_start];
            var style = base_style;
            switch (span.category) {
                .keyword => style.fg = Color.syntax_keyword,
                .function => style.fg = Color.syntax_function,
                .type => style.fg = Color.syntax_type,
                .string => style.fg = Color.syntax_string,
                .number, .constant => style.fg = Color.syntax_number,
                .comment => style.fg = Color.syntax_comment,
                .operator => style.fg = Color.syntax_operator,
                .default => {},
            }

            try segments.append(allocator, .{ .text = chunk, .style = style });
            pos = end - chunk_start;
            span_idx += 1;
        }

        if (build_timer_opt) |*timer| {
            app.profile_counters.highlight_build_ns += timer.read();
            app.profile_counters.highlight_build_calls += 1;
        }

        const owned_segments = try segments.toOwnedSlice(allocator);
        return try applySearchHighlighting(app, owned_segments, text, full_line_text, text_offset, global_line);
    }

    if (highlights == null) {
        // No highlights - return single segment
        var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
        segments[0] = .{
            .text = text,
            .style = base_style,
        };
        // Still apply search highlighting even without syntax highlights
        return try applySearchHighlighting(app, segments, text, full_line_text, text_offset, global_line);
    }

    const file_highlights = highlights.?;

    const line_start = line_byte_offset;
    const line_end = line_byte_offset + text.len;

    var overlap_timer_opt: ?std.time.Timer = null;
    if (app.profile_active_frame) {
        overlap_timer_opt = std.time.Timer.start() catch null;
    }
    const start_index = findHighlightStartIndex(file_highlights, line_start);
    if (overlap_timer_opt) |*timer| {
        app.profile_counters.highlight_overlap_ns += timer.read();
        app.profile_counters.highlight_overlap_calls += 1;
    }

    // Build segments by walking highlights in order
    var build_timer_opt: ?std.time.Timer = null;
    if (app.profile_active_frame) {
        build_timer_opt = std.time.Timer.start() catch null;
    }

    var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
    errdefer segments.deinit(allocator);

    var pos: usize = 0;
    var idx = start_index;
    while (pos < text.len) {
        const absolute_pos = line_start + pos;
        while (idx < file_highlights.len and file_highlights[idx].end_byte <= absolute_pos) {
            idx += 1;
        }

        if (idx >= file_highlights.len or file_highlights[idx].start_byte >= line_end) {
            const chunk = text[pos..];
            try segments.append(allocator, .{ .text = chunk, .style = base_style });
            break;
        }

        const h = file_highlights[idx];
        const local_start = if (h.start_byte > line_start) h.start_byte - line_start else 0;
        const local_end = if (h.end_byte < line_end) h.end_byte - line_start else text.len;

        if (local_start > pos) {
            const chunk = text[pos..@min(local_start, text.len)];
            try segments.append(allocator, .{ .text = chunk, .style = base_style });
            pos = @min(local_start, text.len);
            continue;
        }

        if (local_end <= pos) {
            idx += 1;
            continue;
        }

        const end = @min(local_end, text.len);
        const chunk = text[pos..end];

        const color_category = h.getColorCategory();
        var style = base_style;
        switch (color_category) {
            .keyword => style.fg = Color.syntax_keyword,
            .function => style.fg = Color.syntax_function,
            .type => style.fg = Color.syntax_type,
            .string => style.fg = Color.syntax_string,
            .number, .constant => style.fg = Color.syntax_number,
            .comment => style.fg = Color.syntax_comment,
            .operator => style.fg = Color.syntax_operator,
            .default => {},
        }

        try segments.append(allocator, .{ .text = chunk, .style = style });
        pos = end;
        idx += 1;
    }

    if (build_timer_opt) |*timer| {
        app.profile_counters.highlight_build_ns += timer.read();
        app.profile_counters.highlight_build_calls += 1;
    }

    const owned_segments = try segments.toOwnedSlice(allocator);
    return try applySearchHighlighting(app, owned_segments, text, full_line_text, text_offset, global_line);
}

// Detect merge conflict markers and return appropriate style
// Conflict markers: <<<<<<< (ours/HEAD), ======= (separator), >>>>>>> (theirs), ||||||| (base in diff3)
fn getConflictMarkerStyle(line_text: []const u8, base_style: vaxis.Style) ?vaxis.Style {
    // Check for each type of conflict marker at start of line
    if (std.mem.startsWith(u8, line_text, "<<<<<<<")) {
        // "Ours" marker (HEAD/current changes) - blue
        return vaxis.Style{
            .fg = Color.conflict_ours_fg,
            .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_ours_bg,
            .bold = true,
        };
    } else if (std.mem.startsWith(u8, line_text, "=======")) {
        // Separator marker - yellow
        return vaxis.Style{
            .fg = Color.conflict_separator_fg,
            .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_separator_bg,
            .bold = true,
        };
    } else if (std.mem.startsWith(u8, line_text, ">>>>>>>")) {
        // "Theirs" marker (incoming changes) - purple
        return vaxis.Style{
            .fg = Color.conflict_theirs_fg,
            .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_theirs_bg,
            .bold = true,
        };
    } else if (std.mem.startsWith(u8, line_text, "|||||||")) {
        // Base marker (diff3 mode) - gray
        return vaxis.Style{
            .fg = Color.conflict_base_fg,
            .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_base_bg,
            .bold = true,
        };
    }
    return null;
}

fn findHighlightStartIndex(highlights: []syntax.Highlight, line_start: usize) usize {
    var lo: usize = 0;
    var hi: usize = highlights.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (highlights[mid].start_byte < line_start) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo > 0 and highlights[lo - 1].end_byte > line_start) {
        return lo - 1;
    }
    return lo;
}

// Apply search highlighting on top of existing segments
// Uses the search_state.matches as the source of truth for which lines should be highlighted
fn applySearchHighlighting(
    app: *App,
    segments: []vaxis.Cell.Segment,
    chunk_text: []const u8,
    full_line_text: []const u8,
    chunk_offset: usize,
    global_line: usize,
) ![]vaxis.Cell.Segment {
    var search_timer_opt: ?std.time.Timer = null;
    if (app.profile_active_frame) {
        search_timer_opt = std.time.Timer.start() catch null;
    }
    defer if (search_timer_opt) |*timer| {
        app.profile_counters.search_ns += timer.read();
        app.profile_counters.search_calls += 1;
    };
    _ = full_line_text;
    _ = chunk_offset;

    const allocator = app.frameSegmentAllocator();

    // Check if search is active
    const search_state = &app.state.search_state;
    if (search_state.query_len == 0) {
        return segments;
    }

    // KEY OPTIMIZATION: Check if this line is in the matches list
    // If not, no need to search or highlight - just return segments as-is
    const is_match_line = isMatchLine(search_state.matches.items, global_line);

    if (!is_match_line) {
        // This line doesn't match - return segments unchanged
        return segments;
    }

    const query = search_state.query_buffer[0..search_state.query_len];

    if (query.len > chunk_text.len) {
        return segments;
    }

    // Determine case sensitivity (smart case)
    const is_case_sensitive = search.isCaseSensitive(query);

    // Find all matches in the chunk_text (this is the actual text to render)
    var chunk_matches: std.ArrayList(struct { start: usize, end: usize }) = .{};
    defer chunk_matches.deinit(allocator);

    var search_pos: usize = 0;
    while (search_pos <= chunk_text.len - query.len) {
        const slice = chunk_text[search_pos .. search_pos + query.len];
        const is_match = if (is_case_sensitive)
            std.mem.eql(u8, slice, query)
        else
            std.ascii.eqlIgnoreCase(slice, query);

        if (is_match) {
            try chunk_matches.append(allocator, .{ .start = search_pos, .end = search_pos + query.len });
            search_pos += query.len;
        } else {
            search_pos += 1;
        }
    }

    if (chunk_matches.items.len == 0) {
        return segments;
    }

    // Now map the matches from chunk_text coordinates to segment coordinates
    var result_segments: std.ArrayList(vaxis.Cell.Segment) = .{};
    errdefer result_segments.deinit(allocator);

    var text_pos: usize = 0; // Current position in chunk_text
    for (segments) |seg| {
        const seg_start = text_pos;
        const seg_end = text_pos + seg.text.len;

        // Find matches that overlap with this segment
        var seg_matches: std.ArrayList(struct { start: usize, end: usize }) = .{};
        defer seg_matches.deinit(allocator);

        for (chunk_matches.items) |match| {
            if (match.end > seg_start and match.start < seg_end) {
                // Match overlaps this segment - convert to segment-local coordinates
                const local_start = if (match.start > seg_start) match.start - seg_start else 0;
                const local_end = @min(match.end, seg_end) - seg_start;
                try seg_matches.append(allocator, .{ .start = local_start, .end = local_end });
            }
        }

        if (seg_matches.items.len == 0) {
            // No matches in this segment - add as-is
            try result_segments.append(allocator, seg);
        } else {
            // Split segment at match boundaries
            var pos: usize = 0;
            for (seg_matches.items) |match| {
                // Add text before match (if any)
                if (match.start > pos) {
                    const before_text = seg.text[pos..match.start];
                    try result_segments.append(allocator, .{
                        .text = before_text,
                        .style = seg.style,
                    });
                }

                // Add highlighted match
                const match_text = seg.text[match.start..match.end];
                var match_style = seg.style;
                match_style.bg = rendering_common.Color.search_match_bg;
                match_style.fg = rendering_common.Color.search_match_fg;
                match_style.bold = true;
                try result_segments.append(allocator, .{
                    .text = match_text,
                    .style = match_style,
                });

                pos = match.end;
            }

            // Add text after last match (if any)
            if (pos < seg.text.len) {
                const after_text = seg.text[pos..];
                try result_segments.append(allocator, .{
                    .text = after_text,
                    .style = seg.style,
                });
            }
        }

        text_pos += seg.text.len;
    }

    const result = try result_segments.toOwnedSlice(allocator);
    allocator.free(segments);
    return result;
}

fn isMatchLine(matches: []const usize, line: usize) bool {
    if (matches.len == 0) return false;
    var lo: usize = 0;
    var hi: usize = matches.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const value = matches[mid];
        if (value < line) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo < matches.len and matches[lo] == line;
}

// ===== Tests =====
// Search highlighting tests exercise applySearchHighlighting against a real App.

fn searchTestApp(allocator: std.mem.Allocator) App {
    return .{
        .allocator = allocator,
        .vx = undefined,
        .tty = undefined,
        .should_quit = false,
        .last_ctrl_c_time = 0,
        .mode = .normal,
        .state = undefined,
    };
}

test "search highlighting - basic match" {
    const allocator = std.testing.allocator;

    var app = searchTestApp(allocator);

    // Initialize search state
    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    // Set search query
    const query = "test";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 100 to matches (simulate that performSearch found it)
    try app.state.search_state.matches.append(100);

    // Create input segments (single segment with plain text)
    const chunk_text = "this is a test string";
    var input_segments = [_]vaxis.Cell.Segment{
        .{
            .text = chunk_text,
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    // Apply highlighting (pretend we're on global line 100)
    const result = try applySearchHighlighting(
        &app,
        input_copy,
        chunk_text,
        chunk_text,
        0,
        100,
    );
    defer allocator.free(result);

    // Verify: should have 3 segments (before, match, after)
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("this is a ", result[0].text);
    try std.testing.expectEqualStrings("test", result[1].text);
    try std.testing.expectEqualStrings(" string", result[2].text);

    // Verify the match has search highlight style
    try std.testing.expect(result[1].style.bold);
}

test "search highlighting - multiple matches" {
    const allocator = std.testing.allocator;

    var app = searchTestApp(allocator);

    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    const query = "the";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 200 to matches
    try app.state.search_state.matches.append(200);

    const chunk_text = "the quick brown fox jumps over the lazy dog";
    var input_segments = [_]vaxis.Cell.Segment{
        .{
            .text = chunk_text,
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    const result = try applySearchHighlighting(
        &app,
        input_copy,
        chunk_text,
        chunk_text,
        0,
        200,
    );
    defer allocator.free(result);

    // Should have 5 segments: match1, text, match2, text
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("the", result[0].text);
    try std.testing.expectEqualStrings(" quick brown fox jumps over ", result[1].text);
    try std.testing.expectEqualStrings("the", result[2].text);
    try std.testing.expectEqualStrings(" lazy dog", result[3].text);
}

test "search highlighting - case insensitive" {
    const allocator = std.testing.allocator;

    var app = searchTestApp(allocator);

    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    // Lowercase query (should match any case)
    const query = "test";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 300 to matches
    try app.state.search_state.matches.append(300);

    const chunk_text = "Test TEST test";
    var input_segments = [_]vaxis.Cell.Segment{
        .{
            .text = chunk_text,
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    const result = try applySearchHighlighting(
        &app,
        input_copy,
        chunk_text,
        chunk_text,
        0,
        300,
    );
    defer allocator.free(result);

    // Should match all 3 occurrences
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("Test", result[0].text);
    try std.testing.expect(result[0].style.bold);
    try std.testing.expectEqualStrings(" ", result[1].text);
    try std.testing.expectEqualStrings("TEST", result[2].text);
    try std.testing.expect(result[2].style.bold);
    try std.testing.expectEqualStrings(" ", result[3].text);
    try std.testing.expectEqualStrings("test", result[4].text);
    try std.testing.expect(result[4].style.bold);
}

test "search highlighting - across syntax segments" {
    const allocator = std.testing.allocator;

    var app = searchTestApp(allocator);

    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    const query = "function";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 400 to matches
    try app.state.search_state.matches.append(400);

    // Simulate syntax-highlighted segments
    const chunk_text = "function test() {}";
    var input_segments = [_]vaxis.Cell.Segment{
        .{ // keyword
            .text = "function",
            .style = .{ .fg = .{ .rgb = [3]u8{ 255, 0, 0 } }, .bold = true },
        },
        .{ // space
            .text = " ",
            .style = .{},
        },
        .{ // function name
            .text = "test",
            .style = .{ .fg = .{ .rgb = [3]u8{ 255, 0, 255 } } },
        },
        .{ // rest
            .text = "() {}",
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    const result = try applySearchHighlighting(
        &app,
        input_copy,
        chunk_text,
        chunk_text,
        0,
        400,
    );
    defer allocator.free(result);

    // First segment should be highlighted with search colors (not syntax colors)
    try std.testing.expect(result.len > 0);
    try std.testing.expectEqualStrings("function", result[0].text);
    try std.testing.expect(result[0].style.bold);
    // Search highlight should override syntax highlighting
}
