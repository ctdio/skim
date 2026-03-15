const std = @import("std");

const agent = @import("agent/agent.zig");
const app_mod = @import("app.zig");
const parser = @import("git/parser.zig");
const harness = @import("testing/harness.zig");

const App = app_mod.App;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const BenchPhase = enum {
    cold_render,
    steady_state_render,
    streaming_append_render,
    all,
};

const BenchStats = struct {
    samples: []u64,
    min: u64,
    median: u64,
    p90: u64,
    p99: u64,
    avg: u64,
};

const TranscriptConfig = struct {
    turns: usize,
    width: u16,
    height: u16,
    warmup: usize,
    iterations: usize,
    phase: BenchPhase,
};

const STREAM_CHUNK =
    "\n\n### Streaming update\n" ++
    "- update line map incrementally\n" ++
    "- reuse parsed markdown\n" ++
    "- avoid paint-time AST work\n";

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const config = TranscriptConfig{
        .turns = readEnvUsize(allocator, "SKIM_AGENT_BENCH_TURNS", 24),
        .width = readEnvU16(allocator, "SKIM_AGENT_BENCH_WIDTH", 120),
        .height = readEnvU16(allocator, "SKIM_AGENT_BENCH_HEIGHT", 42),
        .warmup = readEnvUsize(allocator, "SKIM_AGENT_BENCH_WARMUP", 20),
        .iterations = readEnvUsize(allocator, "SKIM_AGENT_BENCH_ITERS", 200),
        .phase = readEnvPhase(allocator, "SKIM_AGENT_BENCH_PHASE", .all),
    };

    std.log.info("=== AGENT RENDER BENCH ===", .{});
    std.log.info("turns={d} size={d}x{d} warmup={d} iterations={d} phase={s}", .{
        config.turns,
        config.width,
        config.height,
        config.warmup,
        config.iterations,
        @tagName(config.phase),
    });

    const empty_files = try allocator.alloc(parser.FileDiff, 0);
    defer allocator.free(empty_files);

    var app = try App.initForRenderBench(allocator, empty_files);
    defer app.deinit();
    app.mode = .agent;
    app.tab_manager = agent.TabManager.init(allocator, .right);
    app.tab_manager.?.panel_visible = true;

    const tab = try app.tab_manager.?.ensureTab();
    var ctx = try harness.createTestContext(allocator, config.width, config.height);
    defer ctx.deinit();

    switch (config.phase) {
        .cold_render => {
            const stats = try runColdRenderBench(&app, &tab.agent_state, ctx.window(), allocator, config);
            defer allocator.free(stats.samples);
            reportStats("cold_render", stats);
        },
        .steady_state_render => {
            const stats = try runSteadyStateBench(&app, &tab.agent_state, ctx.window(), allocator, config);
            defer allocator.free(stats.samples);
            reportStats("steady_state_render", stats);
        },
        .streaming_append_render => {
            const stats = try runStreamingBench(&app, &tab.agent_state, ctx.window(), allocator, config);
            defer allocator.free(stats.samples);
            reportStats("streaming_append_render", stats);
        },
        .all => {
            const cold_stats = try runColdRenderBench(&app, &tab.agent_state, ctx.window(), allocator, config);
            defer allocator.free(cold_stats.samples);
            reportStats("cold_render", cold_stats);

            const steady_stats = try runSteadyStateBench(&app, &tab.agent_state, ctx.window(), allocator, config);
            defer allocator.free(steady_stats.samples);
            reportStats("steady_state_render", steady_stats);

            const streaming_stats = try runStreamingBench(&app, &tab.agent_state, ctx.window(), allocator, config);
            defer allocator.free(streaming_stats.samples);
            reportStats("streaming_append_render", streaming_stats);
        },
    }
}

fn runColdRenderBench(
    app: *App,
    agent_state: *agent.AgentState,
    win: anytype,
    allocator: std.mem.Allocator,
    config: TranscriptConfig,
) !BenchStats {
    var samples = try allocator.alloc(u64, config.iterations);

    var i: usize = 0;
    while (i < config.warmup + config.iterations) : (i += 1) {
        resetTranscript(agent_state, config.turns, false) catch return error.BenchSetupFailed;

        const start = std.time.nanoTimestamp();
        try agent.renderAgentPanel(app, win);
        const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));

        if (i >= config.warmup) {
            samples[i - config.warmup] = elapsed;
        }
    }

    return computeStats(allocator, samples);
}

fn runSteadyStateBench(
    app: *App,
    agent_state: *agent.AgentState,
    win: anytype,
    allocator: std.mem.Allocator,
    config: TranscriptConfig,
) !BenchStats {
    var samples = try allocator.alloc(u64, config.iterations);

    resetTranscript(agent_state, config.turns, false) catch return error.BenchSetupFailed;
    try agent.renderAgentPanel(app, win);

    var i: usize = 0;
    while (i < config.warmup + config.iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        try agent.renderAgentPanel(app, win);
        const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));

        if (i >= config.warmup) {
            samples[i - config.warmup] = elapsed;
        }
    }

    return computeStats(allocator, samples);
}

fn runStreamingBench(
    app: *App,
    agent_state: *agent.AgentState,
    win: anytype,
    allocator: std.mem.Allocator,
    config: TranscriptConfig,
) !BenchStats {
    var samples = try allocator.alloc(u64, config.iterations);

    var i: usize = 0;
    while (i < config.warmup + config.iterations) : (i += 1) {
        resetTranscript(agent_state, config.turns, true) catch return error.BenchSetupFailed;
        try agent.renderAgentPanel(app, win);

        const start = std.time.nanoTimestamp();
        try agent_state.appendToLastAgentMessage(STREAM_CHUNK);
        try agent.renderAgentPanel(app, win);
        const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));

        if (i >= config.warmup) {
            samples[i - config.warmup] = elapsed;
        }
    }

    return computeStats(allocator, samples);
}

fn reportStats(label: []const u8, stats: BenchStats) void {
    var min_buf: [32]u8 = undefined;
    var median_buf: [32]u8 = undefined;
    var p90_buf: [32]u8 = undefined;
    var p99_buf: [32]u8 = undefined;
    var avg_buf: [32]u8 = undefined;

    std.log.info(
        "{s}: min={s} median={s} p90={s} p99={s} avg={s}",
        .{
            label,
            formatDurationNs(&min_buf, stats.min),
            formatDurationNs(&median_buf, stats.median),
            formatDurationNs(&p90_buf, stats.p90),
            formatDurationNs(&p99_buf, stats.p99),
            formatDurationNs(&avg_buf, stats.avg),
        },
    );
}

fn computeStats(allocator: std.mem.Allocator, samples: []u64) !BenchStats {
    const sorted = try allocator.dupe(u64, samples);
    defer allocator.free(sorted);

    std.mem.sort(u64, sorted, {}, comptime std.sort.asc(u64));

    var total: u128 = 0;
    for (samples) |sample| total += sample;

    return .{
        .samples = samples,
        .min = sorted[0],
        .median = percentile(sorted, 50),
        .p90 = percentile(sorted, 90),
        .p99 = percentile(sorted, 99),
        .avg = @as(u64, @intCast(total / samples.len)),
    };
}

fn percentile(sorted: []const u64, pct: usize) u64 {
    if (sorted.len == 0) return 0;
    const idx = ((sorted.len - 1) * pct) / 100;
    return sorted[idx];
}

fn formatDurationNs(buf: []u8, value: u64) []const u8 {
    if (value >= std.time.ns_per_ms) {
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{
            @as(f64, @floatFromInt(value)) / @as(f64, std.time.ns_per_ms),
        }) catch "?";
    }

    return std.fmt.bufPrint(buf, "{d:.2}us", .{
        @as(f64, @floatFromInt(value)) / @as(f64, std.time.ns_per_us),
    }) catch "?";
}

fn resetTranscript(agent_state: *agent.AgentState, turns: usize, streaming_tail: bool) !void {
    agent_state.clearMessages();
    agent_state.follow_bottom = true;
    agent_state.history.exit();
    agent_state.expanded_user_messages.clearRetainingCapacity();
    agent_state.codex_token_usage = .{
        .total_tokens = 182_000,
        .input_tokens = 140_000,
        .output_tokens = 42_000,
        .cached_input_tokens = 18_000,
        .model_context_window = 256_000,
    };
    agent_state.codex_rate_limits = .{
        .primary_used_percent = 62.0,
        .secondary_used_percent = 18.0,
    };

    var turn_idx: usize = 0;
    while (turn_idx < turns) : (turn_idx += 1) {
        try addUserTurn(agent_state, turn_idx);
        try addAgentTurn(agent_state, turn_idx, streaming_tail and turn_idx + 1 == turns);
    }
}

fn addUserTurn(agent_state: *agent.AgentState, turn_idx: usize) !void {
    var user_buf: [512]u8 = undefined;
    const content = try std.fmt.bufPrint(
        &user_buf,
        "Review turn {d}: focus on scrolling, markdown rendering, and streaming updates.\nCheck `src/agent/render.zig` and `src/agent/chat_line_map.zig` for regressions.",
        .{turn_idx},
    );
    try agent_state.addMessage(.user, content);
}

fn addAgentTurn(agent_state: *agent.AgentState, turn_idx: usize, streaming_tail: bool) !void {
    var content: std.ArrayList(u8) = .{};
    defer content.deinit(agent_state.allocator);

    try content.writer(agent_state.allocator).print(
        "### Turn {d}\n\nThe rendering path is sensitive to repeated work. This message mixes paragraphs, inline code like `ensureLineMap()` and `renderAgentPanel()`, plus a table.\n\n| Phase | Goal |\n| --- | --- |\n| Cold | Build markdown and line map |\n| Steady | Paint cached rows |\n| Stream | Update the last message |\n\n```zig\nfn benchRender(frame: usize) void {{\n    if (frame % 2 == 0) std.log.debug(\"frame={{d}}\", .{{frame}});\n}}\n```\n\n1. Keep message formatting stable.\n2. Avoid parsing unchanged content.\n3. Measure the steady-state frame budget.\n",
        .{turn_idx},
    );

    if (!streaming_tail) {
        try content.appendSlice(agent_state.allocator, "\nFinal note: the UI should stay responsive while long messages stream in.");
    }

    const owned = try content.toOwnedSlice(agent_state.allocator);
    defer agent_state.allocator.free(owned);
    try agent_state.addMessage(.agent, owned);
}

fn readEnvUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize) usize {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env_value);
    if (env_value.len == 0) return default_value;
    return std.fmt.parseInt(usize, env_value, 10) catch default_value;
}

fn readEnvU16(allocator: std.mem.Allocator, name: []const u8, default_value: u16) u16 {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env_value);
    if (env_value.len == 0) return default_value;
    return std.fmt.parseInt(u16, env_value, 10) catch default_value;
}

fn readEnvPhase(allocator: std.mem.Allocator, name: []const u8, default_value: BenchPhase) BenchPhase {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env_value);
    if (env_value.len == 0) return default_value;

    if (std.ascii.eqlIgnoreCase(env_value, "cold")) return .cold_render;
    if (std.ascii.eqlIgnoreCase(env_value, "steady")) return .steady_state_render;
    if (std.ascii.eqlIgnoreCase(env_value, "stream")) return .streaming_append_render;
    if (std.ascii.eqlIgnoreCase(env_value, "all")) return .all;
    return default_value;
}
