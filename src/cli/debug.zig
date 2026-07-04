//! CLI command: skim debug
//!
//! Debugging utilities for replaying internal session data.

const std = @import("std");
const acp_replay = @import("../acp/session_replay.zig");
const agent_render = @import("../agent/render.zig");
const TabManager = @import("../agent/tab_manager.zig").TabManager;
const App = @import("../app.zig").App;
const codex_replay = @import("../codex/session_replay.zig");
const diff = @import("../git/diff.zig");
const DiffSource = diff.DiffSource;
const logging = @import("../logging.zig");
const opencode_replay = @import("../opencode/session_replay.zig");
const harness = @import("../testing/harness.zig");
const github = @import("../pr/github.zig");
const review_parse = @import("../pr/review_parse.zig");
const parser = @import("../git/parser.zig");
const thread_anchor = @import("../pr/thread_anchor.zig");

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

    if (std.mem.eql(u8, subcmd, "pr-view")) {
        try runPrView(allocator, args);
        return;
    }

    if (std.mem.eql(u8, subcmd, "pr-anchor")) {
        try runPrAnchor(allocator, args);
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

/// `skim debug pr-view <number|url>`: fetch + parse a PR's full review payload
/// through the SAME `github.zig`/`review_parse.zig` functions the TUI uses
/// (AD-2), and print a human-readable summary. Exits non-zero on any failure.
fn runPrView(allocator: Allocator, args: []const []const u8) !void {
    const raw = try fetchReviewJson(allocator, args, "pr-view");
    defer allocator.free(raw);

    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    var data = review_parse.parsePrDetails(allocator, raw) catch {
        try stderr_writer.interface.writeAll("Failed to parse the review payload from gh.\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer data.deinit();

    try printPrView(data.details);
}

/// `skim debug pr-anchor <number|url>`: fetch a PR's review data + the PR diff
/// through the SAME `github.zig`/`git` paths the TUI uses, run the real
/// `thread_anchor.anchorThreads`, and print every thread's placement. Enforces
/// the totality invariant (every thread is inline, bucketed, or unplaced —
/// nothing silently dropped) and exits non-zero if it is ever violated.
fn runPrAnchor(allocator: Allocator, args: []const []const u8) !void {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    const raw = try fetchReviewJson(allocator, args, "pr-anchor");
    defer allocator.free(raw);

    var data = review_parse.parsePrDetails(allocator, raw) catch {
        try stderr_writer.interface.writeAll("Failed to parse the review payload from gh.\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer data.deinit();
    const details = data.details;

    const head_ref = github.fetchRef(allocator, .{ .number = details.number, .base_ref = details.base_ref }) catch {
        try stderr_writer.interface.writeAll("Failed to git-fetch the PR head ref (is git authenticated?).\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(head_ref);

    const ref1 = if (details.base_ref.len > 0)
        try std.fmt.allocPrint(allocator, "origin/{s}", .{details.base_ref})
    else
        try allocator.dupe(u8, "HEAD");
    defer allocator.free(ref1);

    const diff_text = diff.getDiff(allocator, .{ .two_refs = .{
        .ref1 = ref1,
        .ref2 = head_ref,
        .use_merge_base = true,
    } }) catch {
        try stderr_writer.interface.writeAll("Failed to run git diff for the PR range.\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(diff_text);

    const files = parser.parse(allocator, diff_text) catch {
        try stderr_writer.interface.writeAll("Failed to parse the PR diff.\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer {
        for (files) |*f| f.deinit(allocator);
        allocator.free(files);
    }

    const anchored = thread_anchor.anchorThreads(allocator, details.threads, files) catch {
        try stderr_writer.interface.writeAll("Failed to anchor review threads.\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(anchored);

    const ok = try printPrAnchor(details, files, anchored);
    if (!ok) std.process.exit(1);
}

/// Shared arg → gh review-data resolution for pr-view/pr-anchor. Returns the
/// raw JSON bytes (caller owns) or exits non-zero with a diagnostic.
fn fetchReviewJson(allocator: Allocator, args: []const []const u8, comptime cmd: []const u8) ![]u8 {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    if (args.len < 4) {
        try stderr_writer.interface.writeAll(cmd ++ " requires a PR number or github.com PR URL.\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    }

    const arg = args[3];
    const request = github.parsePrArg(arg) catch {
        try stderr_writer.interface.print("Invalid PR argument '{s}' — expected a number or a github.com PR URL.\n", .{arg});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };

    const origin = github.getOriginOwnerRepo(allocator) catch {
        try stderr_writer.interface.writeAll("Could not resolve the origin remote (run inside a GitHub repo clone).\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(origin.owner);
    defer allocator.free(origin.repo);

    const number = switch (request) {
        .number => |n| n,
        .url => |u| blk: {
            if (!std.mem.eql(u8, origin.owner, u.owner) or !std.mem.eql(u8, origin.repo, u.repo)) {
                try stderr_writer.interface.print(
                    "URL points at {s}/{s} but the origin remote is {s}/{s}.\n",
                    .{ u.owner, u.repo, origin.owner, origin.repo },
                );
                stderr_writer.interface.flush() catch {};
                std.process.exit(1);
            }
            break :blk u.number;
        },
    };

    const fetch = github.fetchReviewData(allocator, origin, number) catch {
        try stderr_writer.interface.writeAll("Failed to run gh api graphql.\n");
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };

    return switch (fetch) {
        .failed => |kind| {
            try stderr_writer.interface.print("{s}\n", .{github.kindMessage(kind)});
            stderr_writer.interface.flush() catch {};
            std.process.exit(1);
        },
        .ok => |bytes| bytes,
    };
}

/// Print each thread's placement + totals. Returns false if the totality
/// invariant is violated (inline + bucketed + unplaced != thread count), so the
/// caller can exit non-zero.
fn printPrAnchor(details: review_parse.PrDetails, files: []const parser.FileDiff, anchored: []const thread_anchor.AnchoredThread) !bool {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_writer.interface;
    defer w.flush() catch {};

    try w.print("PR #{d}: {s}\n", .{ details.number, details.title });
    try w.print("base: {s}  head: {s}  files: {d}  threads: {d}\n\n", .{
        details.base_ref,
        details.head_ref,
        files.len,
        details.threads.len,
    });

    var inline_count: usize = 0;
    var bucket_count: usize = 0;
    var unplaced_count: usize = 0;

    try w.writeAll("Placements:\n");
    for (anchored) |a| {
        const t = details.threads[a.thread_idx];
        const shown_line: ?u32 = t.line orelse t.original_line;
        switch (a.placement) {
            .inline_line => |loc| {
                inline_count += 1;
                try w.print("  [{d}] {s}:{?d} [{s}] {s} -> inline file={d} hunk={d} line={d}\n", .{
                    a.thread_idx,      t.path,       shown_line,   sideLabel(t.side),
                    threadStateLbl(t), loc.file_idx, loc.hunk_idx, loc.line_idx,
                });
            },
            .file_bucket => |b| {
                bucket_count += 1;
                try w.print("  [{d}] {s}:{?d} [{s}] {s} -> file_bucket file={d} reason={s}\n", .{
                    a.thread_idx,      t.path,     shown_line,                sideLabel(t.side),
                    threadStateLbl(t), b.file_idx, bucketReasonLbl(b.reason),
                });
            },
            .unplaced => {
                unplaced_count += 1;
                try w.print("  [{d}] {s}:{?d} [{s}] {s} -> UNPLACED (path not in diff)\n", .{
                    a.thread_idx, t.path, shown_line, sideLabel(t.side), threadStateLbl(t),
                });
            },
        }
    }

    const total = details.threads.len;
    const accounted = inline_count + bucket_count + unplaced_count;
    try w.print("\nTotals: inline={d}  bucketed={d}  unplaced={d}  accounted={d}/{d}\n", .{
        inline_count, bucket_count, unplaced_count, accounted, total,
    });

    const totality_ok = accounted == total and anchored.len == total;
    if (!totality_ok) {
        try w.print("INVARIANT VIOLATED: {d} threads accounted for, expected {d} (anchored slice len {d}).\n", .{
            accounted, total, anchored.len,
        });
    } else {
        try w.writeAll("Totality invariant holds: every thread accounted for.\n");
    }
    return totality_ok;
}

fn threadStateLbl(t: review_parse.ReviewThread) []const u8 {
    if (t.is_resolved) return "resolved";
    if (t.is_outdated) return "outdated";
    return "open";
}

fn bucketReasonLbl(reason: thread_anchor.BucketReason) []const u8 {
    return switch (reason) {
        .outdated => "outdated",
        .out_of_context => "out_of_context",
        .file_level => "file_level",
    };
}

fn printPrView(details: review_parse.PrDetails) !void {
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_writer.interface;
    defer w.flush() catch {};

    try w.print("PR #{d}: {s}\n", .{ details.number, details.title });
    try w.print("author: {s}  draft: {}  decision: {s}  rollup: {s}  viewer: {s}\n", .{
        details.author,
        details.is_draft,
        if (details.review_decision.len > 0) details.review_decision else "-",
        rollupLabel(details.rollup),
        details.viewer_login,
    });
    try w.print("base: {s}  head: {s}  node: {s}\n", .{ details.base_ref, details.head_ref, details.pr_node_id });
    if (details.truncated) try w.writeAll("WARNING: results truncated — showing first page only\n");
    if (details.pending_review_id) |id| try w.print("pending review: {s}\n", .{id});
    try w.print("checks: {d}  reviews: {d}  threads: {d}\n", .{ details.checks.len, details.reviews.len, details.threads.len });

    try w.writeAll("\nReviews:\n");
    for (details.reviews) |r| {
        try w.print("  - {s} [{s}] {s}\n", .{ r.author, reviewStateLabel(r.state), r.submitted_at });
    }

    try w.writeAll("\nThreads:\n");
    for (details.threads) |t| {
        const shown_line: ?u32 = t.line orelse t.original_line;
        try w.print("  - {s}:{?d} [{s}] {s}{s} ({d} comments)\n", .{
            t.path,
            shown_line,
            sideLabel(t.side),
            if (t.is_resolved) "resolved" else "open",
            if (t.is_outdated) " outdated" else "",
            t.comments.len,
        });
        if (t.comments.len > 0) {
            const c = t.comments[0];
            try w.print("      first by {s}: {s}\n", .{ c.author, previewLine(c.body) });
        }
    }
}

fn rollupLabel(state: review_parse.RollupState) []const u8 {
    return switch (state) {
        .success => "success",
        .failure => "failure",
        .pending => "pending",
        .err => "error",
        .none => "none",
    };
}

fn reviewStateLabel(state: review_parse.ReviewState) []const u8 {
    return switch (state) {
        .pending => "pending",
        .commented => "commented",
        .approved => "approved",
        .changes_requested => "changes_requested",
        .dismissed => "dismissed",
        .unknown => "unknown",
    };
}

fn sideLabel(side: review_parse.Side) []const u8 {
    return switch (side) {
        .left => "left",
        .right => "right",
    };
}

/// First line of a comment body, capped, for a one-line preview.
fn previewLine(body: []const u8) []const u8 {
    var end = body.len;
    if (std.mem.indexOfAny(u8, body, "\r\n")) |nl| end = @min(end, nl);
    if (end > 60) end = 60;
    return body[0..end];
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
        \\    pr-view <number|url>            Fetch + print a PR's GitHub review data
        \\    pr-anchor <number|url>          Fetch a PR + anchor its review threads to the diff
        \\
        \\EXAMPLES:
        \\    skim debug replay-acp ~/.claude/projects/.../session.jsonl --tui
        \\    skim debug replay-codex ~/.codex/sessions/...jsonl
        \\    skim debug replay-opencode ~/.skim/opencode/events/ses_...log --tui
        \\    skim debug pr-view 26015
        \\    skim debug pr-view https://github.com/owner/repo/pull/42
        \\    skim debug pr-anchor 26015
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
        .blame = undefined,
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
