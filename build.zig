const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_profile = b.option(bool, "profile", "Enable render profiling") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_profile", enable_profile);
    const build_options_module = build_options.createModule();

    // Get vaxis dependency
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis = vaxis_dep.module("vaxis");

    // Get official tree-sitter bindings
    const ts_dep = b.dependency("tree-sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter = ts_dep.module("tree_sitter");

    // Build grammar libraries
    const grammars = buildGrammars(b, target, optimize);

    // Build executable - Zig 0.15: use root_module instead of direct fields
    const exe = b.addExecutable(.{
        .name = "skim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("vaxis", vaxis);
    exe.root_module.addImport("tree-sitter", tree_sitter);
    exe.root_module.addImport("build_options", build_options_module);

    // Note: tree-sitter core library is linked automatically via the module

    // Link all grammar libraries
    for (grammars) |grammar| {
        exe.linkLibrary(grammar);
    }

    // Link libc for C library support
    exe.linkLibC();

    // Strip for smaller binary in release modes
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    // Debug test executable
    const debug_exe = b.addExecutable(.{
        .name = "test_syntax_debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_syntax_debug.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    debug_exe.root_module.addImport("tree-sitter", tree_sitter);
    debug_exe.root_module.addImport("build_options", build_options_module);
    for (grammars) |grammar| {
        debug_exe.linkLibrary(grammar);
    }
    debug_exe.linkLibC();
    const debug_run = b.addRunArtifact(debug_exe);
    const debug_step = b.step("debug-syntax", "Run syntax debugging");
    debug_step.dependOn(&debug_run.step);

    // Startup benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "bench_startup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_startup.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_exe.root_module.addImport("tree-sitter", tree_sitter);
    bench_exe.root_module.addImport("build_options", build_options_module);
    for (grammars) |grammar| {
        bench_exe.linkLibrary(grammar);
    }
    bench_exe.linkLibC();
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run startup benchmark");
    bench_step.dependOn(&bench_run.step);

    // First render benchmark executable
    const first_render_exe = b.addExecutable(.{
        .name = "bench_first_render",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_first_render.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    first_render_exe.root_module.addImport("tree-sitter", tree_sitter);
    first_render_exe.root_module.addImport("build_options", build_options_module);
    for (grammars) |grammar| {
        first_render_exe.linkLibrary(grammar);
    }
    first_render_exe.linkLibC();
    const first_render_run = b.addRunArtifact(first_render_exe);
    const first_render_step = b.step("bench-render", "Run first render benchmark");
    first_render_step.dependOn(&first_render_run.step);

    // Render content benchmark executable
    const render_content_exe = b.addExecutable(.{
        .name = "bench_render_content",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_render_content.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    render_content_exe.root_module.addImport("vaxis", vaxis);
    render_content_exe.root_module.addImport("tree-sitter", tree_sitter);
    render_content_exe.root_module.addImport("build_options", build_options_module);
    for (grammars) |grammar| {
        render_content_exe.linkLibrary(grammar);
    }
    render_content_exe.linkLibC();
    const render_content_run = b.addRunArtifact(render_content_exe);
    const render_content_step = b.step("bench-render-content", "Run render content benchmark");
    render_content_step.dependOn(&render_content_run.step);

    // Async benchmark executable
    const async_exe = b.addExecutable(.{
        .name = "bench_async",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_async.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    async_exe.root_module.addImport("build_options", build_options_module);
    const async_run = b.addRunArtifact(async_exe);
    const async_step = b.step("bench-async", "Run async startup benchmark");
    async_step.dependOn(&async_run.step);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests - Zig 0.15: use root_module instead of direct fields
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    unit_tests.root_module.addImport("vaxis", vaxis);
    unit_tests.root_module.addImport("tree-sitter", tree_sitter);
    unit_tests.root_module.addImport("build_options", build_options_module);
    for (grammars) |grammar| {
        unit_tests.linkLibrary(grammar);
    }
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ACP module tests
    const acp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/acp/acp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    acp_tests.root_module.addImport("build_options", build_options_module);
    const run_acp_tests = b.addRunArtifact(acp_tests);
    test_step.dependOn(&run_acp_tests.step);

    // Opencode module tests
    const opencode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/opencode/opencode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    opencode_tests.root_module.addImport("build_options", build_options_module);
    opencode_tests.linkLibC();
    const run_opencode_tests = b.addRunArtifact(opencode_tests);
    test_step.dependOn(&run_opencode_tests.step);

    // Codex module tests
    const codex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codex/codex.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    codex_tests.root_module.addImport("build_options", build_options_module);
    const run_codex_tests = b.addRunArtifact(codex_tests);
    test_step.dependOn(&run_codex_tests.step);

    // Markdown module tests
    const markdown_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent/markdown/markdown.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    markdown_tests.root_module.addImport("vaxis", vaxis);
    markdown_tests.root_module.addImport("tree-sitter", tree_sitter);
    markdown_tests.root_module.addImport("build_options", build_options_module);
    for (grammars) |grammar| {
        markdown_tests.linkLibrary(grammar);
    }
    markdown_tests.linkLibC();
    const run_markdown_tests = b.addRunArtifact(markdown_tests);
    test_step.dependOn(&run_markdown_tests.step);

    // Testing harness tests
    const testing_harness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    testing_harness_tests.root_module.addImport("vaxis", vaxis);
    testing_harness_tests.root_module.addImport("build_options", build_options_module);
    const run_testing_harness_tests = b.addRunArtifact(testing_harness_tests);
    test_step.dependOn(&run_testing_harness_tests.step);

    // Testing snapshot tests
    const testing_snapshot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/snapshot.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    testing_snapshot_tests.root_module.addImport("build_options", build_options_module);
    const run_testing_snapshot_tests = b.addRunArtifact(testing_snapshot_tests);
    test_step.dependOn(&run_testing_snapshot_tests.step);

    // Testing diff_test_helpers tests
    const diff_helpers_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/diff_test_helpers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    diff_helpers_tests.root_module.addImport("vaxis", vaxis);
    diff_helpers_tests.root_module.addImport("build_options", build_options_module);
    const run_diff_helpers_tests = b.addRunArtifact(diff_helpers_tests);
    test_step.dependOn(&run_diff_helpers_tests.step);

    // Testing agent_test_helpers tests
    const agent_helpers_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/agent_test_helpers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    agent_helpers_tests.root_module.addImport("vaxis", vaxis);
    agent_helpers_tests.root_module.addImport("build_options", build_options_module);
    const run_agent_helpers_tests = b.addRunArtifact(agent_helpers_tests);
    test_step.dependOn(&run_agent_helpers_tests.step);

    // Testing acp_replay tests
    const acp_replay_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/acp_replay.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    acp_replay_tests.root_module.addImport("vaxis", vaxis);
    acp_replay_tests.root_module.addImport("build_options", build_options_module);
    const run_acp_replay_tests = b.addRunArtifact(acp_replay_tests);
    test_step.dependOn(&run_acp_replay_tests.step);

    // Snapshot scenario tests (needs markdown rendering for full-pipeline tests)
    // Create markdown module for snapshot tests
    const markdown_module = b.createModule(.{
        .root_source_file = b.path("src/agent/markdown/markdown.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis },
            .{ .name = "tree-sitter", .module = tree_sitter },
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    const snapshot_scenarios_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/snapshot_scenarios.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const question_prompt_root_module = b.createModule(.{
        .root_source_file = b.path("src/question_prompt_test_root.zig"),
    });
    question_prompt_root_module.addImport("vaxis", vaxis);
    question_prompt_root_module.addImport("tree-sitter", tree_sitter);
    question_prompt_root_module.addImport("build_options", build_options_module);
    snapshot_scenarios_tests.root_module.addImport("vaxis", vaxis);
    snapshot_scenarios_tests.root_module.addImport("tree-sitter", tree_sitter);
    snapshot_scenarios_tests.root_module.addImport("markdown", markdown_module);
    snapshot_scenarios_tests.root_module.addImport("build_options", build_options_module);
    for (grammars) |grammar| {
        snapshot_scenarios_tests.linkLibrary(grammar);
    }
    snapshot_scenarios_tests.linkLibC();
    const run_snapshot_scenarios_tests = b.addRunArtifact(snapshot_scenarios_tests);
    test_step.dependOn(&run_snapshot_scenarios_tests.step);

    const question_prompt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/question_prompt_scenarios.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    question_prompt_tests.root_module.addImport("vaxis", vaxis);
    question_prompt_tests.root_module.addImport("tree-sitter", tree_sitter);
    question_prompt_tests.root_module.addImport("build_options", build_options_module);
    question_prompt_tests.root_module.addImport("question_prompt_root", question_prompt_root_module);
    for (grammars) |grammar| {
        question_prompt_tests.linkLibrary(grammar);
    }
    question_prompt_tests.linkLibC();
    const run_question_prompt_tests = b.addRunArtifact(question_prompt_tests);
    test_step.dependOn(&run_question_prompt_tests.step);
}

// Grammar metadata for building
const GrammarInfo = struct {
    name: []const u8,
    dep_name: []const u8,
    has_scanner: bool,
    scanner_is_cpp: bool,
    // For TypeScript which has subdirectories for tsx/typescript
    subdir: ?[]const u8,
};

const grammar_infos = [_]GrammarInfo{
    .{ .name = "javascript", .dep_name = "tree-sitter-javascript", .has_scanner = true, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "typescript", .dep_name = "tree-sitter-typescript", .has_scanner = true, .scanner_is_cpp = false, .subdir = "typescript" },
    .{ .name = "tsx", .dep_name = "tree-sitter-typescript", .has_scanner = true, .scanner_is_cpp = false, .subdir = "tsx" },
    .{ .name = "python", .dep_name = "tree-sitter-python", .has_scanner = true, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "rust", .dep_name = "tree-sitter-rust", .has_scanner = true, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "go", .dep_name = "tree-sitter-go", .has_scanner = false, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "zig", .dep_name = "tree-sitter-zig", .has_scanner = false, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "c", .dep_name = "tree-sitter-c", .has_scanner = false, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "cpp", .dep_name = "tree-sitter-cpp", .has_scanner = true, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "json", .dep_name = "tree-sitter-json", .has_scanner = false, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "toml", .dep_name = "tree-sitter-toml", .has_scanner = true, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "markdown", .dep_name = "tree-sitter-markdown", .has_scanner = true, .scanner_is_cpp = false, .subdir = "tree-sitter-markdown" },
    .{ .name = "markdown_inline", .dep_name = "tree-sitter-markdown", .has_scanner = true, .scanner_is_cpp = false, .subdir = "tree-sitter-markdown-inline" },
    .{ .name = "css", .dep_name = "tree-sitter-css", .has_scanner = true, .scanner_is_cpp = false, .subdir = null },
    .{ .name = "bash", .dep_name = "tree-sitter-bash", .has_scanner = true, .scanner_is_cpp = false, .subdir = null },
};

fn buildGrammars(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [grammar_infos.len]*std.Build.Step.Compile {
    var libs: [grammar_infos.len]*std.Build.Step.Compile = undefined;

    for (grammar_infos, 0..) |info, i| {
        libs[i] = buildGrammar(b, info, target, optimize);
    }

    return libs;
}

fn buildGrammar(
    b: *std.Build,
    info: GrammarInfo,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const dep = b.dependency(info.dep_name, .{});

    // Zig 0.15: Use addLibrary with .linkage = .static instead of addStaticLibrary
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = b.fmt("tree-sitter-{s}", .{info.name}),
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    // Determine source path
    const src_path = if (info.subdir) |subdir|
        b.fmt("{s}/src", .{subdir})
    else
        "src";

    // Add parser.c
    lib.addCSourceFile(.{
        .file = dep.path(b.fmt("{s}/parser.c", .{src_path})),
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });

    // Add scanner if present
    if (info.has_scanner) {
        if (info.scanner_is_cpp) {
            lib.addCSourceFile(.{
                .file = dep.path(b.fmt("{s}/scanner.cc", .{src_path})),
                .flags = &.{ "-std=c++14", "-fno-sanitize=undefined" },
            });
            lib.linkLibCpp();
        } else {
            lib.addCSourceFile(.{
                .file = dep.path(b.fmt("{s}/scanner.c", .{src_path})),
                .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
            });
        }
    }

    // Add include path for tree_sitter headers
    lib.addIncludePath(dep.path(src_path));

    lib.linkLibC();

    return lib;
}
