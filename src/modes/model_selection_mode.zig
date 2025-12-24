const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Model alias information for display
pub const ModelInfo = struct {
    alias: []const u8,
    name: []const u8,
    description: []const u8,
};

/// Available model aliases (Claude Code compatible)
pub const model_aliases = [_]ModelInfo{
    .{ .alias = "opus", .name = "Opus", .description = "Complex reasoning and analysis" },
    .{ .alias = "sonnet", .name = "Sonnet", .description = "Daily coding tasks" },
    .{ .alias = "haiku", .name = "Haiku", .description = "Fast, simple tasks" },
    .{ .alias = "opusplan", .name = "Opus Plan", .description = "Opus for planning, Sonnet for execution" },
};

/// Handle keyboard input when in model selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const model_count = model_aliases.len;

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.model_selection = (app.state.model_selection + 1) % model_count;
                return;
            },
            'p' => {
                app.state.model_selection = if (app.state.model_selection == 0) model_count - 1 else app.state.model_selection - 1;
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        app.state.model_selection = (app.state.model_selection + 1) % model_count;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.model_selection = if (app.state.model_selection == 0) model_count - 1 else app.state.model_selection - 1;
        return;
    }

    switch (key.codepoint) {
        'j' => {
            app.state.model_selection = (app.state.model_selection + 1) % model_count;
        },
        'k' => {
            app.state.model_selection = if (app.state.model_selection == 0) model_count - 1 else app.state.model_selection - 1;
        },
        27, 'q' => { // ESC or q - cancel
            app.mode = .agent;
            app.needs_render = true;
        },
        '\r' => { // Enter - select model
            const selected_alias = model_aliases[app.state.model_selection].alias;

            // Send /model command to agent
            if (app.acp_manager) |mgr| {
                var buf: [64]u8 = undefined;
                const prompt = std.fmt.bufPrint(&buf, "/model {s}", .{selected_alias}) catch {
                    app.mode = .agent;
                    app.needs_render = true;
                    return;
                };
                mgr.sendPrompt(prompt) catch {};
            }

            app.mode = .agent;
            app.needs_render = true;
        },
        else => {},
    }
}
