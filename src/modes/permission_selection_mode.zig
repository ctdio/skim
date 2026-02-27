const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

const Option = struct {
    label: []const u8,
    policy: @import("../codex/protocol.zig").ApprovalPolicy,
};

const options = [_]Option{
    .{ .label = "Default", .policy = .on_request },
    .{ .label = "Full Access", .policy = .never },
};

pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const option_count = options.len;

    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.permission_selection = (app.state.permission_selection + 1) % option_count;
                return;
            },
            'p' => {
                app.state.permission_selection = if (app.state.permission_selection == 0) option_count - 1 else app.state.permission_selection - 1;
                return;
            },
            'd' => {
                if (app.getActiveAgentState()) |agent_state| {
                    agent_state.follow_bottom = false;
                    agent_state.scrollDown(10);
                    app.needs_render = true;
                }
                return;
            },
            'u' => {
                if (app.getActiveAgentState()) |agent_state| {
                    agent_state.follow_bottom = false;
                    agent_state.scrollUp(10);
                    app.needs_render = true;
                }
                return;
            },
            else => {},
        }
    }

    if (key.codepoint == vaxis.Key.down) {
        app.state.permission_selection = (app.state.permission_selection + 1) % option_count;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.permission_selection = if (app.state.permission_selection == 0) option_count - 1 else app.state.permission_selection - 1;
        return;
    }

    switch (key.codepoint) {
        27 => {
            app.mode = .agent;
            app.needs_render = true;
        },
        '\r' => {
            const selected = options[@min(app.state.permission_selection, option_count - 1)];

            if (app.getActiveManager()) |mgr| {
                switch (mgr) {
                    .codex => |cm| {
                        cm.setApprovalPolicy(selected.policy) catch |err| {
                            if (app.getActiveAgentState()) |agent_state| {
                                if (err == error.ApprovalSwitchDuringTurn) {
                                    agent_state.addMessage(.system, "Cannot switch permission mode while Codex is responding") catch {};
                                } else {
                                    var msg_buf: [128]u8 = undefined;
                                    const msg = std.fmt.bufPrint(&msg_buf, "Failed to set permission mode: {s}", .{@errorName(err)}) catch "Failed to set permission mode";
                                    agent_state.addMessage(.system, msg) catch {};
                                }
                            }
                            app.mode = .agent;
                            app.needs_render = true;
                            return;
                        };

                        if (app.getActiveAgentState()) |agent_state| {
                            if (selected.policy == .never) {
                                agent_state.addMessage(.system, "Permission mode set to Full Access") catch {};
                            } else {
                                agent_state.addMessage(.system, "Permission mode set to Default") catch {};
                            }
                        }
                    },
                    .acp, .opencode => {
                        if (app.getActiveAgentState()) |agent_state| {
                            agent_state.addMessage(.system, "Permission mode switching is only available for Codex") catch {};
                        }
                    },
                }
            }

            app.mode = .agent;
            app.needs_render = true;
        },
        else => {},
    }
}
