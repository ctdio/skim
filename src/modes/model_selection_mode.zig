const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const ManagerHandle = @import("../agent/manager_handle.zig").ManagerHandle;
const containsIgnoreCase = @import("../pr/filter.zig").containsIgnoreCase;

/// Model selection sub-state: the picker selection index plus the fuzzy search
/// filter over the active manager's models. All fields default so it stays out
/// of the State init literal.
pub const ModelSelectState = struct {
    selection: usize = 0, // Selected index in model picker (within filtered list)
    filter_query: [256]u8 = [_]u8{0} ** 256, // Search query for filtering models
    filter_len: usize = 0, // Length of search query
    filtered_indices: std.ArrayList(usize) = .empty, // Indices of models matching filter

    pub fn deinit(self: *ModelSelectState, allocator: std.mem.Allocator) void {
        self.filtered_indices.deinit(allocator);
    }
};

const FilterDeps = struct {
    allocator: std.mem.Allocator,
    manager: ?ManagerHandle,
};

/// Update the filtered model indices based on the current filter query.
/// Works with both ACP and OpenCode managers.
pub fn updateFilter(self: *ModelSelectState, deps: FilterDeps) void {
    // Clear existing filtered indices
    self.filtered_indices.clearRetainingCapacity();

    const query = self.filter_query[0..self.filter_len];

    if (deps.manager) |mgr| {
        const count = mgr.getModelCount();
        if (query.len == 0) {
            for (0..count) |i| {
                self.filtered_indices.append(deps.allocator, i) catch {};
            }
        } else {
            for (0..count) |i| {
                const model = mgr.getModelInfo(i);
                if (containsIgnoreCase(model.name, query) or containsIgnoreCase(model.model_id, query)) {
                    self.filtered_indices.append(deps.allocator, i) catch {};
                }
            }
        }
    }

    // Reset selection to 0 if current selection is out of bounds
    if (self.selection >= self.filtered_indices.items.len) {
        self.selection = 0;
    }
}

/// Reset model filter state (called when entering model selection mode)
pub fn resetFilter(self: *ModelSelectState, deps: FilterDeps) void {
    self.filter_query = [_]u8{0} ** 256;
    self.filter_len = 0;
    self.selection = 0;
    updateFilter(self, deps);
}

/// Handle keyboard input when in model selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const model = &app.state.model_select;
    const filtered_count = model.filtered_indices.items.len;

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                if (filtered_count > 0) {
                    model.selection = (model.selection + 1) % filtered_count;
                }
                return;
            },
            'p' => {
                if (filtered_count > 0) {
                    model.selection = if (model.selection == 0) filtered_count - 1 else model.selection - 1;
                }
                return;
            },
            'd' => {
                // Allow scrolling conversation history during model selection
                if (app.getActiveAgentState()) |agent_state| {
                    agent_state.follow_bottom = false;
                    agent_state.scrollDown(10);
                    app.needs_render = true;
                }
                return;
            },
            'u' => {
                // Allow scrolling conversation history during model selection
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

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        if (filtered_count > 0) {
            model.selection = (model.selection + 1) % filtered_count;
        }
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        if (filtered_count > 0) {
            model.selection = if (model.selection == 0) filtered_count - 1 else model.selection - 1;
        }
        return;
    }

    switch (key.codepoint) {
        27 => { // ESC - clear search or cancel
            if (model.filter_len > 0) {
                // Clear search query
                model.filter_query = [_]u8{0} ** 256;
                model.filter_len = 0;
                model.selection = 0;
                updateFilter(model, .{ .allocator = app.allocator, .manager = app.getActiveManager() });
            } else {
                // Exit mode
                app.mode = .agent;
            }
            app.needs_render = true;
        },
        '\r' => { // Enter - select model
            if (app.getActiveManager()) |mgr| {
                if (model.selection < model.filtered_indices.items.len) {
                    const actual_idx = model.filtered_indices.items[model.selection];
                    if (actual_idx < mgr.getModelCount()) {
                        const selected_model = mgr.getModelInfo(actual_idx);
                        mgr.setModelById(selected_model.model_id) catch |err| {
                            if (app.getActiveAgentState()) |agent_state| {
                                const msg = std.fmt.allocPrint(app.allocator, "Failed to switch model: {s}", .{@errorName(err)}) catch "Failed to switch model";
                                defer if (!std.mem.eql(u8, msg, "Failed to switch model")) app.allocator.free(msg);
                                agent_state.addMessage(.system, msg) catch {};
                            }
                        };
                    }
                }
            }

            app.mode = .agent;
            app.needs_render = true;
        },
        vaxis.Key.backspace => { // Backspace - delete character from search
            if (model.filter_len > 0) {
                model.filter_len -= 1;
                model.filter_query[model.filter_len] = 0;
                updateFilter(model, .{ .allocator = app.allocator, .manager = app.getActiveManager() });
                app.needs_render = true;
            }
        },
        else => {
            // Handle printable characters for search
            if (key.codepoint >= 32 and key.codepoint < 127) {
                if (model.filter_len < 255) {
                    model.filter_query[model.filter_len] = @intCast(key.codepoint);
                    model.filter_len += 1;
                    updateFilter(model, .{ .allocator = app.allocator, .manager = app.getActiveManager() });
                    app.needs_render = true;
                }
            }
        },
    }
}
