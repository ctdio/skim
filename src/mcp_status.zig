const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig").App;
const mcp_client = @import("mcp/client.zig");

pub fn renderMcpStatusPopup(app: *App, win: vaxis.Window) !void {
    // Calculate popup dimensions - smaller than help since less content
    const popup_width = @min(60, win.width - 4);
    const popup_height = @min(15, win.height - 4);
    const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
    const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

    const popup_win = win.child(.{
        .x_off = x_offset,
        .y_off = y_offset,
        .width = .{ .limit = popup_width },
        .height = .{ .limit = popup_height },
        .border = .{
            .where = .all,
            .style = .{
                .fg = .{ .index = 6 }, // cyan
            },
        },
    });

    popup_win.clear();

    // Fill with solid background
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{
            .bg = .{ .index = 0 }, // black background
        },
    };
    popup_win.fill(bg_cell);

    const title_style = vaxis.Style{ .fg = .{ .index = 6 }, .bold = true };
    const label_style = vaxis.Style{ .fg = .{ .index = 3 } }; // yellow
    const value_style = vaxis.Style{ .fg = .{ .index = 7 } }; // white
    const connected_style = vaxis.Style{ .fg = .{ .index = 2 } }; // green
    const disconnected_style = vaxis.Style{ .fg = .{ .index = 1 } }; // red

    var row: usize = 0;

    // Title
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = "MCP Server Status", .style = title_style },
    };
    _ = try popup_win.print(&title_seg, .{ .row_offset = row });
    row += 1;

    // Separator
    if (popup_width > 2) {
        const render_utils = @import("rendering/utils.zig");
        const RenderUtils = render_utils.RenderUtils;
        const sep_width = popup_width - 2;
        const sep_text = try RenderUtils.frameTextSlice(app, sep_width);
        @memset(sep_text, '-');
        var sep_seg = [_]vaxis.Cell.Segment{
            .{ .text = sep_text, .style = .{ .fg = .{ .index = 8 } } },
        };
        _ = try popup_win.print(&sep_seg, .{ .row_offset = row });
    }
    row += 2;

    // Connection status
    if (app.mcp) |mcp| {
        // Status line
        var status_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  Status:     ", .style = label_style },
            .{ .text = if (mcp.connected) "Connected" else "Disconnected", .style = if (mcp.connected) connected_style else disconnected_style },
        };
        _ = try popup_win.print(&status_seg, .{ .row_offset = row });
        row += 1;

        // Port
        var port_buf: [32]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{app.mcp_port orelse 9999}) catch "9999";
        var port_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  Port:       ", .style = label_style },
            .{ .text = port_str, .style = value_style },
        };
        _ = try popup_win.print(&port_seg, .{ .row_offset = row });
        row += 1;

        // Session ID
        if (mcp.session_id) |session_id| {
            var session_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  Session:    ", .style = label_style },
                .{ .text = session_id, .style = value_style },
            };
            _ = try popup_win.print(&session_seg, .{ .row_offset = row });
        } else {
            var session_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  Session:    ", .style = label_style },
                .{ .text = "(none)", .style = .{ .fg = .{ .index = 8 } } },
            };
            _ = try popup_win.print(&session_seg, .{ .row_offset = row });
        }
        row += 2;

        // Description
        var desc_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  MCP allows AI agents to add comments to your", .style = .{ .fg = .{ .index = 8 } } },
        };
        _ = try popup_win.print(&desc_seg, .{ .row_offset = row });
        row += 1;

        var desc2_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  code review session programmatically.", .style = .{ .fg = .{ .index = 8 } } },
        };
        _ = try popup_win.print(&desc2_seg, .{ .row_offset = row });
    } else {
        // No MCP client
        var status_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  Status:     ", .style = label_style },
            .{ .text = "Not Connected", .style = disconnected_style },
        };
        _ = try popup_win.print(&status_seg, .{ .row_offset = row });
        row += 2;

        var info_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  No MCP server running on port 9999.", .style = .{ .fg = .{ .index = 8 } } },
        };
        _ = try popup_win.print(&info_seg, .{ .row_offset = row });
        row += 2;

        var start_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  To start an MCP server:", .style = .{ .fg = .{ .index = 8 } } },
        };
        _ = try popup_win.print(&start_seg, .{ .row_offset = row });
        row += 1;

        var cmd_seg = [_]vaxis.Cell.Segment{
            .{ .text = "    skim --serve", .style = .{ .fg = .{ .index = 6 } } },
        };
        _ = try popup_win.print(&cmd_seg, .{ .row_offset = row });
    }

    // Footer
    row = popup_height - 3;
    var footer_seg = [_]vaxis.Cell.Segment{
        .{ .text = "  Press ESC or q to close", .style = .{ .fg = .{ .index = 8 } } },
    };
    _ = try popup_win.print(&footer_seg, .{ .row_offset = row });
}
