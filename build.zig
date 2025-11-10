const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get vaxis dependency
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis = vaxis_dep.module("vaxis");

    // Get z-tree-sitter dependency with selected language grammars
    const zts_dep = b.dependency("zts", .{
        .target = target,
        .optimize = optimize,
        // Enable programming languages
        .javascript = true,
        .typescript = true,
        .python = true,
        .rust = true,
        .go = true,
        .zig = true,
        .c = true,
        .cpp = true,
        // Enable common file formats
        .json = true,
        .toml = true,
        .markdown = true,
        .css = true,
        .bash = true,
    });
    const zts = zts_dep.module("zts");

    // Build executable
    const exe = b.addExecutable(.{
        .name = "skim",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("vaxis", vaxis);
    exe.root_module.addImport("zts", zts);

    // Strip for smaller binary in release modes
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    // Debug test executable
    const debug_exe = b.addExecutable(.{
        .name = "test_syntax_debug",
        .root_source_file = b.path("test_syntax_debug.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_exe.root_module.addImport("zts", zts);
    const debug_run = b.addRunArtifact(debug_exe);
    const debug_step = b.step("debug-syntax", "Run syntax debugging");
    debug_step.dependOn(&debug_run.step);

    // Startup benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "bench_startup",
        .root_source_file = b.path("src/bench_startup.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_exe.root_module.addImport("zts", zts);
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run startup benchmark");
    bench_step.dependOn(&bench_run.step);

    // First render benchmark executable
    const first_render_exe = b.addExecutable(.{
        .name = "bench_first_render",
        .root_source_file = b.path("src/bench_first_render.zig"),
        .target = target,
        .optimize = optimize,
    });
    first_render_exe.root_module.addImport("zts", zts);
    const first_render_run = b.addRunArtifact(first_render_exe);
    const first_render_step = b.step("bench-render", "Run first render benchmark");
    first_render_step.dependOn(&first_render_run.step);

    // Async benchmark executable
    const async_exe = b.addExecutable(.{
        .name = "bench_async",
        .root_source_file = b.path("src/bench_async.zig"),
        .target = target,
        .optimize = optimize,
    });
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

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("vaxis", vaxis);
    unit_tests.root_module.addImport("zts", zts);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
