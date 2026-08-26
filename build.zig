const std = @import("std");
const platform = @import("src/platform.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_profile = b.option(bool, "profile", "Enable render profiling") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_profile", enable_profile);
    const build_options_module = build_options.createModule();

    // `src/io.zig` as a named module: files reach the process-wide `std.Io`
    // handle as `@import("skim_io")` rather than by relative path, so a test
    // step rooted at `src/acp/` or `src/testing/` can still import it. One
    // instance per target -- two modules wrapping the same file in one compile
    // is an error, and would be two copies of the global besides.
    const skim_io_module = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // Build executable
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
    exe.root_module.addImport("skim_io", skim_io_module);

    // Note: tree-sitter core library is linked automatically via the module

    // Link all grammar libraries
    for (grammars) |grammar| {
        exe.root_module.linkLibrary(grammar);
    }

    // Link libc for C library support
    exe.root_module.link_libc = true;

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
    debug_exe.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        debug_exe.root_module.linkLibrary(grammar);
    }
    debug_exe.root_module.link_libc = true;
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
    bench_exe.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        bench_exe.root_module.linkLibrary(grammar);
    }
    bench_exe.root_module.link_libc = true;
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
    first_render_exe.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        first_render_exe.root_module.linkLibrary(grammar);
    }
    first_render_exe.root_module.link_libc = true;
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
    render_content_exe.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        render_content_exe.root_module.linkLibrary(grammar);
    }
    render_content_exe.root_module.link_libc = true;
    const render_content_run = b.addRunArtifact(render_content_exe);
    const render_content_step = b.step("bench-render-content", "Run render content benchmark");
    render_content_step.dependOn(&render_content_run.step);

    // Scroll session benchmark executable
    const scroll_exe = b.addExecutable(.{
        .name = "bench_scroll",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_scroll.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    scroll_exe.root_module.addImport("vaxis", vaxis);
    scroll_exe.root_module.addImport("tree-sitter", tree_sitter);
    scroll_exe.root_module.addImport("build_options", build_options_module);
    scroll_exe.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        scroll_exe.root_module.linkLibrary(grammar);
    }
    scroll_exe.root_module.link_libc = true;
    b.installArtifact(scroll_exe);
    const scroll_run = b.addRunArtifact(scroll_exe);
    const scroll_step = b.step("bench-scroll", "Run diff scroll session benchmark");
    scroll_step.dependOn(&scroll_run.step);

    // Agent render benchmark executable
    const agent_render_exe = b.addExecutable(.{
        .name = "bench_agent_render",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_agent_render.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    agent_render_exe.root_module.addImport("vaxis", vaxis);
    agent_render_exe.root_module.addImport("tree-sitter", tree_sitter);
    agent_render_exe.root_module.addImport("build_options", build_options_module);
    agent_render_exe.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        agent_render_exe.root_module.linkLibrary(grammar);
    }
    agent_render_exe.root_module.link_libc = true;
    const agent_render_run = b.addRunArtifact(agent_render_exe);
    const agent_render_step = b.step("bench-agent-render", "Run agent render benchmark");
    agent_render_step.dependOn(&agent_render_run.step);

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
    async_exe.root_module.addImport("skim_io", skim_io_module);
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

    // Web build: `zig build web` emits zig-out/web/skim.wasm, the engine behind
    // the browser demo. Always wasm32-wasi + ReleaseSmall — the host target and
    // optimize flags do not apply, and size is what matters over the wire. The
    // grammars and dependency modules are re-resolved for wasm rather than reused
    // from the native ones above.
    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const web_optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const web_vaxis = b.dependency("vaxis", .{
        .target = web_target,
        .optimize = web_optimize,
    }).module("vaxis");
    const web_tree_sitter = b.dependency("tree-sitter", .{
        .target = web_target,
        .optimize = web_optimize,
    }).module("tree_sitter");

    const web_exe = b.addExecutable(.{
        .name = "skim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/main.zig"),
            .target = web_target,
            .optimize = web_optimize,
        }),
    });
    const web_skim_io_module = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = web_target,
        .optimize = web_optimize,
    });
    web_exe.root_module.addImport("vaxis", web_vaxis);
    web_exe.root_module.addImport("skim_io", web_skim_io_module);
    web_exe.root_module.addImport("web_core", webCoreModule(b, .{
        .target = web_target,
        .optimize = web_optimize,
        .vaxis = web_vaxis,
        .tree_sitter = web_tree_sitter,
        .build_options = build_options_module,
        .skim_io = web_skim_io_module,
    }));
    for (buildWebGrammars(b, web_target, web_optimize)) |grammar| {
        web_exe.root_module.linkLibrary(grammar);
    }
    web_exe.root_module.link_libc = true;
    web_exe.root_module.strip = true;
    // Name the ABI exports rather than using rdynamic, which would also export
    // every tree-sitter symbol and keep the linker from dropping unused ones.
    web_exe.root_module.export_symbol_names = &.{
        "skimAlloc",
        "skimFree",
        "skimLoad",
        "skimUnload",
        "skimKey",
        "skimScroll",
        "skimResize",
        "skimRender",
        "skimAgentReplay",
        "skimAgentStep",
        "skimAgentInput",
        "skimAgentRender",
        "skimAgentOutPtr",
        "skimAgentOutLen",
        "skimAddComment",
        "skimListComments",
        "skimJsonPtr",
        "skimJsonLen",
        "skimOutPtr",
        "skimOutLen",
        "skimCursorRow",
        "skimCursorCol",
        "skimCursorVisible",
    };

    const web_install = b.addInstallArtifact(web_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    const web_step = b.step("web", "Build the WebAssembly module for the browser demo");
    web_step.dependOn(&web_install.step);
    // Put the loader and the demo page beside the module so zig-out/web/ can be
    // served as-is.
    for ([_][]const u8{ "web/skim.js", "web/index.html" }) |page| {
        const install_page = b.addInstallFileWithDir(b.path(page), .{ .custom = "web" }, std.fs.path.basename(page));
        web_step.dependOn(&install_page.step);
    }

    const lint_cmd = b.addSystemCommand(&.{b.pathFromRoot("scripts/ziglint.sh")});
    lint_cmd.setCwd(b.path("."));
    const lint_step = b.step("lint", "Run ziglint");
    lint_step.dependOn(&lint_cmd.step);

    // Tests
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
    unit_tests.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        unit_tests.root_module.linkLibrary(grammar);
    }
    unit_tests.root_module.link_libc = true;

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Mouse-wheel routing tests
    const mouse_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mouse.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mouse_tests.root_module.addImport("vaxis", vaxis);
    mouse_tests.root_module.addImport("skim_io", skim_io_module);
    const run_mouse_tests = b.addRunArtifact(mouse_tests);
    test_step.dependOn(&run_mouse_tests.step);

    // ACP module tests
    const acp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/acp/acp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    acp_tests.root_module.addImport("build_options", build_options_module);
    acp_tests.root_module.addImport("skim_io", skim_io_module);
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
    opencode_tests.root_module.addImport("skim_io", skim_io_module);
    opencode_tests.root_module.link_libc = true;
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
    codex_tests.root_module.addImport("skim_io", skim_io_module);
    const run_codex_tests = b.addRunArtifact(codex_tests);
    test_step.dependOn(&run_codex_tests.step);

    // PR module tests. Rooted at src/ (via pr_test_root) rather than src/pr/ so
    // pr files can import across directory boundaries (e.g.
    // review_render/review_controller -> ../rendering/width.zig).
    const pr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pr_test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pr_tests.root_module.addImport("vaxis", vaxis);
    pr_tests.root_module.addImport("build_options", build_options_module);
    pr_tests.root_module.addImport("skim_io", skim_io_module);
    pr_tests.root_module.link_libc = true;
    const run_pr_tests = b.addRunArtifact(pr_tests);
    test_step.dependOn(&run_pr_tests.step);

    // PR picker controller tests. The controller imports `../git/graphite.zig`,
    // which is outside the `src/pr/`-rooted pr_tests module, so it gets its own
    // src/-rooted aggregator step.
    const pr_controller_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pr_controller_test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pr_controller_tests.root_module.addImport("vaxis", vaxis);
    pr_controller_tests.root_module.addImport("build_options", build_options_module);
    pr_controller_tests.root_module.addImport("skim_io", skim_io_module);
    pr_controller_tests.root_module.link_libc = true;
    const run_pr_controller_tests = b.addRunArtifact(pr_controller_tests);
    test_step.dependOn(&run_pr_controller_tests.step);

    // Core diff-path tests: parser, line_map, comment store, streaming loader.
    // Same reason as width_tests below — these are only reachable from main.zig
    // through app.zig, so their test blocks need a direct root to be collected.
    const session_replay_root_module = b.createModule(.{
        .root_source_file = b.path("src/session_replay_test_root.zig"),
    });
    session_replay_root_module.addImport("vaxis", vaxis);
    session_replay_root_module.addImport("tree-sitter", tree_sitter);
    session_replay_root_module.addImport("build_options", build_options_module);
    session_replay_root_module.addImport("skim_io", skim_io_module);
    const session_replay_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/session_replay_scenarios.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    session_replay_tests.root_module.addImport("session_replay_root", session_replay_root_module);
    session_replay_tests.root_module.addImport("vaxis", vaxis);
    session_replay_tests.root_module.addImport("tree-sitter", tree_sitter);
    session_replay_tests.root_module.addImport("build_options", build_options_module);
    session_replay_tests.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        session_replay_tests.root_module.linkLibrary(grammar);
    }
    session_replay_tests.root_module.link_libc = true;
    const run_session_replay_tests = b.addRunArtifact(session_replay_tests);
    test_step.dependOn(&run_session_replay_tests.step);

    const diff_core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/diff_core_test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    diff_core_tests.root_module.addImport("vaxis", vaxis);
    diff_core_tests.root_module.addImport("tree-sitter", tree_sitter);
    diff_core_tests.root_module.addImport("build_options", build_options_module);
    diff_core_tests.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        diff_core_tests.root_module.linkLibrary(grammar);
    }
    diff_core_tests.root_module.link_libc = true;
    const run_diff_core_tests = b.addRunArtifact(diff_core_tests);
    test_step.dependOn(&run_diff_core_tests.step);

    // Web (wasm) session tests. Rooted at src/web/session.zig so its own tests are
    // collected, reaching production code through the src/-rooted `web_core` NAMED
    // module — a named import keeps app.zig's and its neighbours' test blocks out
    // of this binary (mirrors review_test_root). Runs on the host target: the
    // session engine is target-independent, only its ABI wrapper is wasm-only.
    const web_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/session.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    web_tests.root_module.addImport("vaxis", vaxis);
    web_tests.root_module.addImport("web_core", webCoreModule(b, .{
        .target = target,
        .optimize = optimize,
        .vaxis = vaxis,
        .tree_sitter = tree_sitter,
        .build_options = build_options_module,
        .skim_io = skim_io_module,
    }));
    for (grammars) |grammar| {
        web_tests.root_module.linkLibrary(grammar);
    }
    web_tests.root_module.link_libc = true;
    const run_web_tests = b.addRunArtifact(web_tests);
    test_step.dependOn(&run_web_tests.step);

    // Rendering width/wrap tests. width.zig is self-contained (std + vaxis only)
    // and holds colocated wrap tests, so it roots its own step — main.zig's tree
    // does not reliably pull test blocks from transitively-imported files.
    const width_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rendering/width.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    width_tests.root_module.addImport("vaxis", vaxis);
    width_tests.root_module.addImport("skim_io", skim_io_module);
    width_tests.root_module.link_libc = true;
    const run_width_tests = b.addRunArtifact(width_tests);
    test_step.dependOn(&run_width_tests.step);

    // Scroll-region redraw tests. scroll_region.zig is self-contained (std +
    // vaxis + rendering/common.zig) and its tests drive a real vaxis screen
    // through two frames, so it roots its own step like width.zig does.
    const scroll_region_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rendering/scroll_region.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    scroll_region_tests.root_module.addImport("vaxis", vaxis);
    scroll_region_tests.root_module.addImport("skim_io", skim_io_module);
    scroll_region_tests.root_module.link_libc = true;
    const run_scroll_region_tests = b.addRunArtifact(scroll_region_tests);
    test_step.dependOn(&run_scroll_region_tests.step);

    // Frame-pacing tests. frame_pacer.zig depends on nothing but std, so it
    // roots its own step like width.zig does.
    const frame_pacer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rendering/frame_pacer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_frame_pacer_tests = b.addRunArtifact(frame_pacer_tests);
    test_step.dependOn(&run_frame_pacer_tests.step);

    // Cell-writing fast-path tests. cells.zig is self-contained (std + vaxis
    // only) and its tests assert byte-for-byte equivalence with
    // vaxis.Window.print, so it roots its own step for the same reason
    // width.zig does.
    const cells_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rendering/cells.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cells_tests.root_module.addImport("vaxis", vaxis);
    cells_tests.root_module.addImport("skim_io", skim_io_module);
    cells_tests.root_module.link_libc = true;
    const run_cells_tests = b.addRunArtifact(cells_tests);
    test_step.dependOn(&run_cells_tests.step);

    // PR review-thread tests. The helper file lives in src/testing/ but reaches
    // production code (git/, rendering/, pr/) through the src/-rooted
    // review_test_root NAMED module — a named import keeps those modules' own
    // test blocks out of this binary (mirrors approval_test_root).
    const review_test_root_module = b.createModule(.{
        .root_source_file = b.path("src/review_test_root.zig"),
    });
    review_test_root_module.addImport("vaxis", vaxis);
    review_test_root_module.addImport("tree-sitter", tree_sitter);
    review_test_root_module.addImport("build_options", build_options_module);
    review_test_root_module.addImport("skim_io", skim_io_module);
    const review_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/review_test_helpers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    review_tests.root_module.addImport("vaxis", vaxis);
    review_tests.root_module.addImport("tree-sitter", tree_sitter);
    review_tests.root_module.addImport("build_options", build_options_module);
    review_tests.root_module.addImport("skim_io", skim_io_module);
    review_tests.root_module.addImport("review_test_root", review_test_root_module);
    for (grammars) |grammar| {
        review_tests.root_module.linkLibrary(grammar);
    }
    review_tests.root_module.link_libc = true;
    const run_review_tests = b.addRunArtifact(review_tests);
    test_step.dependOn(&run_review_tests.step);

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
    markdown_tests.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        markdown_tests.root_module.linkLibrary(grammar);
    }
    markdown_tests.root_module.link_libc = true;
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
    testing_harness_tests.root_module.addImport("skim_io", skim_io_module);
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
    testing_snapshot_tests.root_module.addImport("skim_io", skim_io_module);
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
    diff_helpers_tests.root_module.addImport("skim_io", skim_io_module);
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
    agent_helpers_tests.root_module.addImport("skim_io", skim_io_module);
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
    acp_replay_tests.root_module.addImport("skim_io", skim_io_module);
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
            .{ .name = "skim_io", .module = skim_io_module },
        },
    });

    // review_test_root reaches App (for the reply/edit input-box render snapshots),
    // which transitively needs the markdown module — wire it now that it exists.
    review_test_root_module.addImport("markdown", markdown_module);

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
    question_prompt_root_module.addImport("skim_io", skim_io_module);
    snapshot_scenarios_tests.root_module.addImport("vaxis", vaxis);
    snapshot_scenarios_tests.root_module.addImport("tree-sitter", tree_sitter);
    snapshot_scenarios_tests.root_module.addImport("markdown", markdown_module);
    snapshot_scenarios_tests.root_module.addImport("build_options", build_options_module);
    snapshot_scenarios_tests.root_module.addImport("skim_io", skim_io_module);
    for (grammars) |grammar| {
        snapshot_scenarios_tests.root_module.linkLibrary(grammar);
    }
    snapshot_scenarios_tests.root_module.link_libc = true;
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
    question_prompt_tests.root_module.addImport("skim_io", skim_io_module);
    question_prompt_tests.root_module.addImport("question_prompt_root", question_prompt_root_module);
    for (grammars) |grammar| {
        question_prompt_tests.root_module.linkLibrary(grammar);
    }
    question_prompt_tests.root_module.link_libc = true;
    const run_question_prompt_tests = b.addRunArtifact(question_prompt_tests);
    test_step.dependOn(&run_question_prompt_tests.step);

    const approval_root_module = b.createModule(.{
        .root_source_file = b.path("src/approval_test_root.zig"),
    });
    approval_root_module.addImport("vaxis", vaxis);
    approval_root_module.addImport("tree-sitter", tree_sitter);
    approval_root_module.addImport("markdown", markdown_module);
    approval_root_module.addImport("build_options", build_options_module);
    approval_root_module.addImport("skim_io", skim_io_module);
    const approval_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/approval_scenarios.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    approval_tests.root_module.addImport("vaxis", vaxis);
    approval_tests.root_module.addImport("tree-sitter", tree_sitter);
    approval_tests.root_module.addImport("build_options", build_options_module);
    approval_tests.root_module.addImport("skim_io", skim_io_module);
    approval_tests.root_module.addImport("approval_test_root", approval_root_module);
    for (grammars) |grammar| {
        approval_tests.root_module.linkLibrary(grammar);
    }
    approval_tests.root_module.link_libc = true;
    const run_approval_tests = b.addRunArtifact(approval_tests);
    test_step.dependOn(&run_approval_tests.step);
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

/// The subset of grammars the wasm module links, named by
/// `platform.web_grammars`. The parse tables are about 90% of the module, so
/// the browser build drops every language its demo does not need.
fn buildWebGrammars(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [platform.web_grammars.len]*std.Build.Step.Compile {
    var libs: [platform.web_grammars.len]*std.Build.Step.Compile = undefined;

    inline for (platform.web_grammars, 0..) |name, i| {
        libs[i] = buildGrammar(b, grammarInfo(name), target, optimize);
    }

    return libs;
}

fn grammarInfo(comptime name: []const u8) GrammarInfo {
    inline for (grammar_infos) |info| {
        if (comptime std.mem.eql(u8, info.name, name)) return info;
    }
    @compileError("no tree-sitter grammar named '" ++ name ++ "'");
}

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
    lib.root_module.addCSourceFile(.{
        .file = dep.path(b.fmt("{s}/parser.c", .{src_path})),
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });

    // Add scanner if present
    if (info.has_scanner) {
        if (info.scanner_is_cpp) {
            lib.root_module.addCSourceFile(.{
                .file = dep.path(b.fmt("{s}/scanner.cc", .{src_path})),
                .flags = &.{ "-std=c++14", "-fno-sanitize=undefined" },
            });
            lib.root_module.link_libcpp = true;
        } else {
            lib.root_module.addCSourceFile(.{
                .file = dep.path(b.fmt("{s}/scanner.c", .{src_path})),
                .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
            });
        }
    }

    // Add include path for tree_sitter headers
    lib.root_module.addIncludePath(dep.path(src_path));

    lib.root_module.link_libc = true;

    return lib;
}

/// Build the `web_core` named module: the src/-rooted re-export root that
/// `web/session.zig` reaches production code through. See src/web_core.zig.
fn webCoreModule(b: *std.Build, opts: WebCoreOptions) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/web_core.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    module.addImport("vaxis", opts.vaxis);
    module.addImport("tree-sitter", opts.tree_sitter);
    module.addImport("build_options", opts.build_options);
    module.addImport("skim_io", opts.skim_io);
    return module;
}

const WebCoreOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vaxis: *std.Build.Module,
    tree_sitter: *std.Build.Module,
    build_options: *std.Build.Module,
    skim_io: *std.Build.Module,
};
