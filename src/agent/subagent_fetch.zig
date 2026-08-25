const std = @import("std");
const opencode = @import("../opencode/opencode.zig");
const App = @import("../app.zig").App;
const skim_io = @import("skim_io");

/// Context for subagent modal fetch thread
pub const SubagentFetchContext = struct {
    app: *App,
    base_url: []const u8, // Owned copy
    session_id: []const u8, // Owned copy

    pub fn deinit(self: *SubagentFetchContext, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.session_id);
    }
};

/// Thread-safe pending result from subagent fetch worker.
/// Worker writes under mutex, main loop polls via atomic flag.
pub const PendingSubagentFetch = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    messages: ?[]opencode.Client.ModalMessage = null,
    error_message: ?[]const u8 = null, // String literal, not owned
};

/// Start async fetch of subagent session messages for the drill-in modal.
/// Opens the modal in loading state and spawns a background thread.
pub fn startSubagentModalFetch(app: *App, session_id: []const u8, title: []const u8) void {
    const agent_state = app.getActiveAgentState() orelse return;

    // Get base_url from the active opencode manager
    const mgr = app.getActiveOpencodeManager() orelse return;
    const base_url = mgr.base_url orelse return;

    // Open modal in loading state
    agent_state.openSubagentModal(session_id, title) catch |err| {
        std.log.err("Failed to open subagent modal: {}", .{err});
        return;
    };

    // Create context for the fetch thread
    // Use c_allocator since the worker thread frees with c_allocator
    const ctx = std.heap.c_allocator.create(SubagentFetchContext) catch return;
    ctx.* = .{
        .app = app,
        .base_url = std.heap.c_allocator.dupe(u8, base_url) catch {
            std.heap.c_allocator.destroy(ctx);
            return;
        },
        .session_id = std.heap.c_allocator.dupe(u8, session_id) catch {
            std.heap.c_allocator.free(ctx.base_url);
            std.heap.c_allocator.destroy(ctx);
            return;
        },
    };

    const thread = std.Thread.spawn(.{}, subagentFetchWorker, .{ctx}) catch {
        // On thread spawn failure, show error in modal
        if (agent_state.getSubagentModal()) |modal| {
            modal.loading = false;
            modal.error_message = app.allocator.dupe(u8, "Failed to start fetch thread") catch null;
        }
        ctx.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(ctx);
        return;
    };
    thread.detach();

    app.needs_render = true;
}

/// Poll for completed subagent fetch and process on main thread.
/// This avoids the data race of modifying modal.messages from the worker thread.
pub fn pollSubagentFetch(app: *App) void {
    if (!app.pending_subagent_fetch.ready.load(.acquire)) return;

    // Take pending data under mutex
    app.pending_subagent_fetch.mutex.lockUncancelable(skim_io.get());
    const messages = app.pending_subagent_fetch.messages;
    const err_msg = app.pending_subagent_fetch.error_message;
    app.pending_subagent_fetch.messages = null;
    app.pending_subagent_fetch.error_message = null;
    app.pending_subagent_fetch.mutex.unlock(skim_io.get());
    app.pending_subagent_fetch.ready.store(false, .release);

    processSubagentFetchResult(app, messages, err_msg);
}

/// Worker thread that fetches subagent session messages.
/// Stores result in pending_subagent_fetch for main-thread processing (avoids data race).
fn subagentFetchWorker(ctx: *SubagentFetchContext) void {
    const app = ctx.app;
    const pending = &app.pending_subagent_fetch;

    // Create a temporary client for the fetch
    var client = opencode.Client.init(std.heap.c_allocator, ctx.base_url) catch {
        pending.mutex.lockUncancelable(skim_io.get());
        pending.error_message = "Failed to connect to server";
        pending.mutex.unlock(skim_io.get());
        pending.ready.store(true, .release);
        app.needs_render = true;
        ctx.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(ctx);
        return;
    };
    defer client.deinit();

    const modal_messages = client.fetchSessionMessages(ctx.session_id) catch |err| {
        const err_msg: []const u8 = switch (err) {
            error.SessionNotFound => "Session not found",
            error.ConnectionFailed => "Connection failed",
            error.ServerError => "Server error",
            error.InvalidResponse => "Invalid response from server",
            else => "Failed to fetch messages",
        };
        std.log.err("Subagent fetch failed: {s} ({})", .{ err_msg, err });
        pending.mutex.lockUncancelable(skim_io.get());
        pending.error_message = err_msg;
        pending.mutex.unlock(skim_io.get());
        pending.ready.store(true, .release);
        app.needs_render = true;
        ctx.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(ctx);
        return;
    };

    pending.mutex.lockUncancelable(skim_io.get());
    pending.messages = modal_messages;
    pending.mutex.unlock(skim_io.get());
    pending.ready.store(true, .release);
    app.needs_render = true;
    ctx.deinit(std.heap.c_allocator);
    std.heap.c_allocator.destroy(ctx);
}

/// Process fetched subagent messages on the main thread (safe to modify modal state).
fn processSubagentFetchResult(app: *App, modal_messages: ?[]opencode.Client.ModalMessage, err_msg: ?[]const u8) void {
    const agent_state = app.getActiveAgentState() orelse {
        // Modal was closed while fetch was in progress — free the messages
        if (modal_messages) |msgs| {
            for (msgs) |*m| m.deinit(std.heap.c_allocator);
            std.heap.c_allocator.free(msgs);
        }
        return;
    };

    const modal = agent_state.getSubagentModal() orelse {
        if (modal_messages) |msgs| {
            for (msgs) |*m| m.deinit(std.heap.c_allocator);
            std.heap.c_allocator.free(msgs);
        }
        return;
    };

    modal.loading = false;

    if (err_msg) |msg| {
        modal.error_message = agent_state.allocator.dupe(u8, msg) catch null;
    } else if (modal_messages) |msgs| {
        // Convert ModalMessages to Messages for ChatLineMap rendering
        for (msgs) |*m| {
            const alloc = agent_state.allocator;
            switch (m.role) {
                .user => {
                    const content = if (m.content) |c|
                        alloc.dupe(u8, c) catch continue
                    else
                        alloc.dupe(u8, "") catch continue;
                    modal.messages.append(alloc, .{
                        .role = .user,
                        .content = content,
                        .timestamp = 0,
                    }) catch {
                        alloc.free(content);
                    };
                },
                .assistant => {
                    const content = if (m.content) |c|
                        alloc.dupe(u8, c) catch continue
                    else
                        alloc.dupe(u8, "") catch continue;
                    modal.messages.append(alloc, .{
                        .role = .agent,
                        .content = content,
                        .timestamp = 0,
                    }) catch {
                        alloc.free(content);
                    };
                },
                .tool => {
                    const display = m.tool_title orelse m.tool_name orelse "Tool";
                    const content = alloc.dupe(u8, display) catch continue;
                    const duped_name = if (m.tool_name) |n| (alloc.dupe(u8, n) catch null) else null;
                    modal.messages.append(alloc, .{
                        .role = .tool,
                        .content = content,
                        .tool_name = duped_name,
                        .tool_status = .completed,
                        .timestamp = 0,
                    }) catch {
                        alloc.free(content);
                        if (duped_name) |name| alloc.free(name);
                    };
                },
            }

            // Free the originals (owned by c_allocator)
            m.deinit(std.heap.c_allocator);
        }
        std.heap.c_allocator.free(msgs);
        modal.line_map_dirty = true;
    }

    app.needs_render = true;
}
