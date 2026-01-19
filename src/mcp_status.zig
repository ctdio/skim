const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig").App;
const session_mgr = @import("mcp/session.zig");
const Color = @import("rendering/common.zig").Color;

pub fn renderMcpStatusPopup(app: *App, win: vaxis.Window) !void {
    // Calculate popup dimensions - smaller than help since less content
    const popup_width = @min(60, win.width - 4);
    const popup_height = @min(15, win.height - 4);
    const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
    const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

    const popup_win = win.child(.{
        .x_off = x_offset,
        .y_off = y_offset,
        .width = @intCast(popup_width),
        .height = @intCast(popup_height),
        .border = .{
            .where = .all,
            .style = .{
                .fg = Color.cyan,
            },
        },
    });

    popup_win.clear();

    // Fill with solid background
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{
            .bg = Color.black,
        },
    };
    popup_win.fill(bg_cell);

    const title_style = vaxis.Style{ .fg = Color.cyan, .bold = true };
    const label_style = vaxis.Style{ .fg = Color.yellow };
    const value_style = vaxis.Style{ .fg = Color.white };
    const connected_style = vaxis.Style{ .fg = Color.green };
    const disconnected_style = vaxis.Style{ .fg = Color.red };

    var row: usize = 0;

    // Title - changed from "Daemon Connection" to "Session Server"
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = "Session Server", .style = title_style },
    };
    _ = popup_win.print(&title_seg, .{ .row_offset = @intCast(row) });
    row += 1;

    // Separator
    if (popup_width > 2) {
        const render_utils = @import("rendering/utils.zig");
        const RenderUtils = render_utils.RenderUtils;
        const sep_width = popup_width - 2;
        const sep_text = try RenderUtils.frameTextSlice(app, sep_width);
        @memset(sep_text, '-');
        var sep_seg = [_]vaxis.Cell.Segment{
            .{ .text = sep_text, .style = .{ .fg = Color.dim_gray } },
        };
        _ = popup_win.print(&sep_seg, .{ .row_offset = @intCast(row) });
    }
    row += 2;

    // Server status - check if TUI server is running
    if (app.tui_server) |*server| {
        if (server.running) {
            // Status line
            var status_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  Status:     ", .style = label_style },
                .{ .text = "Running", .style = connected_style },
            };
            _ = popup_win.print(&status_seg, .{ .row_offset = @intCast(row) });
            row += 1;

            // Port
            var port_buf: [32]u8 = undefined;
            const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{server.port}) catch "?";
            var port_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  Port:       ", .style = label_style },
                .{ .text = port_str, .style = value_style },
            };
            _ = popup_win.print(&port_seg, .{ .row_offset = @intCast(row) });
            row += 1;

            // PID
            if (app.session_manager) |*mgr| {
                var pid_buf: [32]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{mgr.current_pid}) catch "?";
                var pid_seg = [_]vaxis.Cell.Segment{
                    .{ .text = "  PID:        ", .style = label_style },
                    .{ .text = pid_str, .style = value_style },
                };
                _ = popup_win.print(&pid_seg, .{ .row_offset = @intCast(row) });
                row += 1;
            }

            // Client count
            var clients_buf: [32]u8 = undefined;
            const clients_str = std.fmt.bufPrint(&clients_buf, "{d}", .{server.clients.items.len}) catch "0";
            var clients_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  Clients:    ", .style = label_style },
                .{ .text = clients_str, .style = value_style },
            };
            _ = popup_win.print(&clients_seg, .{ .row_offset = @intCast(row) });
            row += 2;

            // Description
            var desc_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  CLI commands and AI agents can connect", .style = .{ .fg = Color.dim_gray } },
            };
            _ = popup_win.print(&desc_seg, .{ .row_offset = @intCast(row) });
            row += 1;

            var desc2_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  to this session via TCP.", .style = .{ .fg = Color.dim_gray } },
            };
            _ = popup_win.print(&desc2_seg, .{ .row_offset = @intCast(row) });
        } else {
            // Server not running
            var status_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  Status:     ", .style = label_style },
                .{ .text = "Not Running", .style = disconnected_style },
            };
            _ = popup_win.print(&status_seg, .{ .row_offset = @intCast(row) });
            row += 2;

            var info_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  Server failed to start.", .style = .{ .fg = Color.dim_gray } },
            };
            _ = popup_win.print(&info_seg, .{ .row_offset = @intCast(row) });
        }
    } else {
        // No TUI server
        var status_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  Status:     ", .style = label_style },
            .{ .text = "Not Initialized", .style = disconnected_style },
        };
        _ = popup_win.print(&status_seg, .{ .row_offset = @intCast(row) });
        row += 2;

        var info_seg = [_]vaxis.Cell.Segment{
            .{ .text = "  Session server not available.", .style = .{ .fg = Color.dim_gray } },
        };
        _ = popup_win.print(&info_seg, .{ .row_offset = @intCast(row) });
    }

    // Footer
    row = popup_height - 3;
    var footer_seg = [_]vaxis.Cell.Segment{
        .{ .text = "  Press ESC or q to close", .style = .{ .fg = Color.dim_gray } },
    };
    _ = popup_win.print(&footer_seg, .{ .row_offset = @intCast(row) });
}
