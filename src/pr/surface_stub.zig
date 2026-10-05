//! Web stand-in for `surface.zig`: the same public API with no store, no
//! sync worker and no subprocesses, so the wasm build never analyzes SQLite
//! (D4). `:pr` is not offered on web, so `open` is unreachable in practice.

const std = @import("std");
const sidebar_state = @import("sidebar/state.zig");

const Allocator = std.mem.Allocator;
const SidebarState = sidebar_state.SidebarState;

pub const Surface = struct {};

pub const OpenParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
    gh_bin: []const u8 = "gh",
};

pub const ReloadParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
};

pub fn open(surface: *Surface, params: OpenParams) void {
    _ = surface;
    params.sidebar.unavailable = .not_github;
}

pub fn reload(surface: *Surface, params: ReloadParams) !void {
    _ = surface;
    _ = params;
}

pub fn pushVisible(surface: *Surface, params: ReloadParams) void {
    _ = surface;
    _ = params;
}

pub fn poll(surface: *Surface, params: ReloadParams) bool {
    _ = surface;
    _ = params;
    return false;
}

pub fn wantsTick(surface: *const Surface) bool {
    _ = surface;
    return false;
}

pub fn requestSync(surface: *Surface) void {
    _ = surface;
}

pub fn openInBrowser(sidebar: *const SidebarState) void {
    _ = sidebar;
}

pub fn close(surface: *Surface) void {
    _ = surface;
}
