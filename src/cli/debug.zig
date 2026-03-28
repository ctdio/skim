//! CLI command: skim debug
//!
//! Debugging utilities for replaying internal session data.

const std = @import("std");
const acp_replay = @import("../acp/session_replay.zig");
const agent_render = @import("../agent/render.zig");
const TabManager = @import("../agent/tab_manager.zig").TabManager;
const App = @import("../app.zig").App;
const codex_replay = @import("../codex/session_replay.zig");
const DiffSource = @import("../git/diff.zig").DiffSource;
const logging = @import("../logging.zig");
const opencode_replay = @import("../opencode/session_replay.zig");
const harness = @import("../testing/harness.zig");

const Allocator = std.mem.Allocator;

const FRAME_TEXT_CAPACITY: usize = 262144;

const ReplayCommand = enum {
    acp,
    codex,
    opencode,
};

pub const ReplayConfig = struct {
    command: ReplayCommand,
    session_path: []const u8,
    width: ?u16,
    height: ?u16,
    tui: bool,

    fn deinit(self: *const ReplayConfig, allocator: Allocator) void {
        allocator.free(self.session_path);
    }
};

const TerminalSize = struct {
    width: u16,
    height: u16,
};

const ReplayError = error{
    MissingSessionPath,
    DuplicateSessionPath,
    MissingWidthValue,
    MissingHeightValue,
    InvalidWidthValue,
    InvalidHeightValue,
    UnknownOption,
};

const DEFAULT_WIDTH: u16 = 120;
const DEFAULT_HEIGHT: u16 = 24;

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        try printHelp();
        return;
    }

    const subcmd = args[2];
    if (std.mem.eql(u8, subcmd, "replay-acp")) {
        try runReplayCommand(allocator, args, .acp);
        return;
    }

    if (std.mem.eql(u8, subcmd, "replay-codex")) {
        try runReplayCommand(allocator, args, .codex);
        return;
    }

    if (std.mem.eql(u8, subcmd, "replay-opencode")) {
        try runReplayCommand(allocator, args, .opencode);
        return;
    }

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printHelp();
        return;
    }

    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr_writer.interface.flush() catch {};
    try stderr_writer.interface.print("Unknown debug subcommand: {s}\n", .{subcmd});
    try stderr_writer.interface.writeAll("Use 'skim debug --help' for usage.\n");
    std.process.exit(1);
}

fn runReplayCommand(allocator: Allocator, args: []const []const u8, command: ReplayCommand) !void {
    const config = parseReplayArgs(allocator, args, command) catch |err| {
        try printReplayError(command, err);
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    const width = resolveWidth(config.width);
    const height = resolveHeight(config.height);

    if (config.tui) {
        try runReplayTui(allocator, command, config.session_path);
        return;
    }

    try runReplayHeadless(allocator, command, config.session_path, width, height);
}

fn runReplayHeadless(allocator: Allocator, command: ReplayCommand, session_path: []const u8, width: u16, height: u16) !void {
    var app = try initReplayApp(allocator);
    defer deinitReplayApp(&app);

    const tab = try app.tab_manager.?.createTab("Replay");
    switch (command) {
        .acp => {
            const mgr = try tab.createAcpManager();
            const summary = try acp_replay.replaySessionFile(allocator, &tab.agent_state, session_path);
            mgr.status = summary.manager_status;
        },
        .codex => {
            const mgr = try tab.createCodexManager();
            const summary = try codex_replay.replaySessionFile(allocator, &tab.agent_state, session_path);
            mgr.status = summary.manager_status;
        },
        .opencode => {
            const mgr = try tab.createOpencodeManager();
            mgr.status = .session_active;
            try opencode_replay.configureReplayManager(allocator, mgr, session_path);

            const lines = try opencode_replay.loadReplayLines(allocator, session_path);
            defer opencode_replay.freeReplayLines(allocator, lines);

            for (lines) |line| {
                try opencode_replay.replaySessionLine(mgr, line);
                _ = tab.manager.?.pollEvents(allocator, &tab.agent_state);
            }
        },
    }

    var ctx = try harness.createTestContext(allocator, width, height);
    defer ctx.deinit();

    try agent_render.renderAgentPanel(&app, ctx.window());

    const ansi_output = try ctx.captureToAnsi();
    defer allocator.free(ansi_output);

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    try stdout_writer.interface.writeAll(ansi_output);
    try stdout_writer.interface.writeByte('\n');
}

fn runReplayTui(allocator: Allocator, command: ReplayCommand, session_path: []const u8) !void {
    logging.init(.tui);
    defer logging.deinit();

    const config = .{
        .allocator = allocator,
        .diff_source = DiffSource{ .working_dir = .{ .staged = false } },
        .stdin_content = null,
        .mcp_port = null,
        .serve_port = null,
        .agent_only = true,
    };

    var app = try App.init(allocator, config);
    defer app.deinit();
    app.agent_only = false;

    const tm = try app.ensureTabManager();
    const tab = try tm.ensureTab();

    switch (command) {
        .acp => {
            const mgr = try tab.createAcpManager();
            mgr.status = .session_active;

            const lines = try acp_replay.loadReplayLines(allocator, session_path);
            tab.agent_state.startDebugReplay(.acp, lines, .{ .acp = .session_active }, true, true);
        },
        .codex => {
            const mgr = try tab.createCodexManager();
            mgr.status = .thread_active;

            const lines = try codex_replay.loadReplayLines(allocator, session_path);
            tab.agent_state.startDebugReplay(.codex, lines, .{ .codex = .thread_active }, true, true);
        },
        .opencode => {
            const mgr = try tab.createOpencodeManager();
            mgr.status = .session_active;
            try opencode_replay.configureReplayManager(allocator, mgr, session_path);

            const lines = try opencode_replay.loadReplayLines(allocator, session_path);
            tab.agent_state.startDebugReplay(.opencode, lines, .{ .opencode = .session_active }, true, true);
        },
    }

    tab.agent_state.visible = true;

    tm.panel_visible = true;
    tm.full_screen = true;
    app.mode = .agent;
    app.showStatusMessage("Replay controls: space play/pause, n step, r restart, q exit");

    try app.run();
}

fn parseReplayArgs(allocator: Allocator, args: []const []const u8, command: ReplayCommand) !ReplayConfig {
    var session_path: ?[]const u8 = null;
    errdefer if (session_path) |path| allocator.free(path);

    var width: ?u16 = null;
    var height: ?u16 = null;
    var tui = false;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printReplayHelp(command);
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--tui")) {
            tui = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--width=") or std.mem.startsWith(u8, arg, "-w=")) {
            const prefix_len = if (std.mem.startsWith(u8, arg, "--width=")) "--width=".len else "-w=".len;
            width = std.fmt.parseInt(u16, arg[prefix_len..], 10) catch return ReplayError.InvalidWidthValue;
            continue;
        }

        if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i >= args.len) return ReplayError.MissingWidthValue;
            width = std.fmt.parseInt(u16, args[i], 10) catch return ReplayError.InvalidWidthValue;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--height=")) {
            height = std.fmt.parseInt(u16, arg["--height=".len..], 10) catch return ReplayError.InvalidHeightValue;
            continue;
        }

        if (std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= args.len) return ReplayError.MissingHeightValue;
            height = std.fmt.parseInt(u16, args[i], 10) catch return ReplayError.InvalidHeightValue;
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') return ReplayError.UnknownOption;

        if (session_path != null) return ReplayError.DuplicateSessionPath;
        session_path = try allocator.dupe(u8, arg);
    }

    return .{
        .command = command,
        .session_path = session_path orelse return ReplayError.MissingSessionPath,
        .width = width,
        .height = height,
        .tui = tui,
    };
}

fn printHelp() !void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    try stdout_writer.interface.writeAll(
        \\skim debug - Debugging utilities
        \\
        \\USAGE:
        \\    skim debug <command> [options]
        \\
        \\COMMANDS:
        \\    replay-acp <session.jsonl>      Render a saved ACP/Claude session transcript
        \\    replay-codex <session.jsonl>    Render a saved Codex JSONL session
        \\    replay-opencode <session.log>   Render a saved Opencode SSE event log
        \\
        \\EXAMPLES:
        \\    skim debug replay-acp ~/.claude/projects/.../session.jsonl --tui
        \\    skim debug replay-codex ~/.codex/sessions/...jsonl
        \\    skim debug replay-opencode ~/.skim/opencode/events/ses_...log --tui
        \\
    );
}

fn printReplayHelp(command: ReplayCommand) !void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    try stdout_writer.interface.print(
        \\skim debug {s} - Render a saved {s}
        \\
        \\USAGE:
        \\    skim debug {s} <session-path> [--tui] [--width <N>] [--height <N>]
        \\
        \\OPTIONS:
        \\    --tui              Open the full TUI and incrementally replay events
        \\    -w, --width <N>    Output width (default: auto-detect, fallback: 120)
        \\    --height <N>       Output height (default: auto-detect, fallback: 24)
        \\    -h, --help         Print this help message
        \\
    , .{
        commandName(command),
        commandLabel(command),
        commandName(command),
    });
}

fn printReplayError(command: ReplayCommand, err: anyerror) !void {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr_writer.interface.flush() catch {};

    switch (err) {
        ReplayError.MissingSessionPath => try stderr_writer.interface.print("{s} requires a session path.\n", .{commandName(command)}),
        ReplayError.DuplicateSessionPath => try stderr_writer.interface.print("{s} accepts exactly one session path.\n", .{commandName(command)}),
        ReplayError.MissingWidthValue => try stderr_writer.interface.writeAll("--width requires a value.\n"),
        ReplayError.MissingHeightValue => try stderr_writer.interface.writeAll("--height requires a value.\n"),
        ReplayError.InvalidWidthValue => try stderr_writer.interface.writeAll("Invalid --width value.\n"),
        ReplayError.InvalidHeightValue => try stderr_writer.interface.writeAll("Invalid --height value.\n"),
        ReplayError.UnknownOption => try stderr_writer.interface.print("Unknown option for {s}.\n", .{commandName(command)}),
        else => return err,
    }

    try printReplayHelp(command);
}

fn commandName(command: ReplayCommand) []const u8 {
    return switch (command) {
        .acp => "replay-acp",
        .codex => "replay-codex",
        .opencode => "replay-opencode",
    };
}

fn commandLabel(command: ReplayCommand) []const u8 {
    return switch (command) {
        .acp => "ACP/Claude session transcript",
        .codex => "Codex session",
        .opencode => "Opencode session log",
    };
}

fn resolveWidth(config_width: ?u16) u16 {
    if (config_width) |w| return w;
    if (getTerminalSize()) |size| return size.width;
    return DEFAULT_WIDTH;
}

fn resolveHeight(config_height: ?u16) u16 {
    if (config_height) |h| return h;
    if (getTerminalSize()) |size| return size.height;
    return DEFAULT_HEIGHT;
}

fn initReplayApp(allocator: Allocator) !App {
    const frame_buffer = try allocator.alloc(u8, FRAME_TEXT_CAPACITY);

    return .{
        .allocator = allocator,
        .vx = null,
        .tty = null,
        .mode = .agent,
        .state = undefined,
        .should_quit = false,
        .should_suspend_for_editor = false,
        .editor_file_path = null,
        .editor_line_number = null,
        .editor_is_prompt_edit = false,
        .last_ctrl_c = 0,
        .header_line_buffers = undefined,
        .frame_text_buffer = frame_buffer,
        .frame_text_used = 0,
        .frame_segment_arena = undefined,
        .syntax_highlighter = undefined,
        .highlight_worker = null,
        .pending_highlight_jobs = undefined,
        .needs_render = false,
        .needs_async_highlight = false,
        .tui_server = null,
        .session_manager = null,
        .blame_cache = undefined,
        .pending_blame_results = .{},
        .pending_blame_mutex = .{},
        .pending_blame_ready = std.atomic.Value(bool).init(false),
        .blame_requests_in_flight = .{},
        .pending_connection = null,
        .pending_agent_connect_idx = null,
        .pending_subagent_fetch = .{},
        .in_bracketed_paste = false,
        .agent_only = false,
        .tab_manager = TabManager.init(allocator, .right),
        .profile_render = false,
        .profile_every_n = 0,
        .profile_frame_counter = 0,
        .profile_active_frame = false,
        .profile_counters = .{},
    };
}

fn deinitReplayApp(app: *App) void {
    if (app.tab_manager) |*tm| tm.deinit();
    app.allocator.free(app.frame_text_buffer);
}

fn getTerminalSize() ?TerminalSize {
    const stderr = std.fs.File.stderr();
    if (!std.posix.isatty(stderr.handle)) return null;

    var ws: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(stderr.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result != 0 or ws.col == 0 or ws.row == 0) return null;

    return .{
        .width = ws.col,
        .height = ws.row,
    };
}

test "parseReplayArgs parses size overrides" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{
        "skim",
        "debug",
        "replay-codex",
        "/tmp/session.jsonl",
        "--width",
        "100",
        "--height=40",
    };

    const config = try parseReplayArgs(allocator, args, .codex);
    defer config.deinit(allocator);

    try std.testing.expectEqual(ReplayCommand.codex, config.command);
    try std.testing.expectEqualStrings("/tmp/session.jsonl", config.session_path);
    try std.testing.expectEqual(@as(?u16, 100), config.width);
    try std.testing.expectEqual(@as(?u16, 40), config.height);
    try std.testing.expect(!config.tui);
}

test "parseReplayArgs enables tui mode" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{
        "skim",
        "debug",
        "replay-acp",
        "/tmp/session.jsonl",
        "--tui",
    };

    const config = try parseReplayArgs(allocator, args, .acp);
    defer config.deinit(allocator);

    try std.testing.expectEqual(ReplayCommand.acp, config.command);
    try std.testing.expectEqualStrings("/tmp/session.jsonl", config.session_path);
    try std.testing.expectEqual(@as(?u16, null), config.width);
    try std.testing.expectEqual(@as(?u16, null), config.height);
    try std.testing.expect(config.tui);
}

test "parseReplayArgs rejects missing path" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{
        "skim",
        "debug",
        "replay-opencode",
        "--width",
        "80",
    };

    const result = parseReplayArgs(allocator, args, .opencode);
    try std.testing.expectError(ReplayError.MissingSessionPath, result);
}

test "parseReplayArgs rejects extra path" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{
        "skim",
        "debug",
        "replay-opencode",
        "/tmp/one.jsonl",
        "/tmp/two.jsonl",
    };

    const result = parseReplayArgs(allocator, args, .opencode);
    try std.testing.expectError(ReplayError.DuplicateSessionPath, result);
}
