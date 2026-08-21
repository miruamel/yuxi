const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Every source file is a public named module (issue #3). Zig 0.16 only
    // collects `test` blocks from the root module of a test build, and a
    // sub-directory test file's relative imports may not escape its own
    // directory, so all imports use module names. `addModule` registers the
    // module; each consumer must `addImport` it (no implicit global scope).
    const types = b.addModule("types", .{ .root_source_file = b.path("src/core/types.zig"), .target = target, .optimize = optimize });
    const compose = b.addModule("compose", .{ .root_source_file = b.path("src/core/compose.zig"), .target = target, .optimize = optimize });
    const config = b.addModule("config", .{ .root_source_file = b.path("src/core/config/config.zig"), .target = target, .optimize = optimize });
    const engine = b.addModule("engine", .{ .root_source_file = b.path("src/core/engine.zig"), .target = target, .optimize = optimize });
    const step = b.addModule("step", .{ .root_source_file = b.path("src/core/step.zig"), .target = target, .optimize = optimize });
    const runlife = b.addModule("runlife", .{ .root_source_file = b.path("src/core/runlife.zig"), .target = target, .optimize = optimize });
    const gateway = b.addModule("gateway", .{ .root_source_file = b.path("src/gateway/gateway.zig"), .target = target, .optimize = optimize });
    const orchestrator = b.addModule("orchestrator", .{ .root_source_file = b.path("src/orchestrator/orchestrator.zig"), .target = target, .optimize = optimize });
    const evaluator = b.addModule("evaluator", .{ .root_source_file = b.path("src/evaluator/evaluator.zig"), .target = target, .optimize = optimize });
    const deploy = b.addModule("deploy", .{ .root_source_file = b.path("src/deploy/deploy.zig"), .target = target, .optimize = optimize });
    const resilience = b.addModule("resilience", .{ .root_source_file = b.path("src/resilience/resilience.zig"), .target = target, .optimize = optimize });
    const knowledge = b.addModule("knowledge", .{ .root_source_file = b.path("src/knowledge/knowledge.zig"), .target = target, .optimize = optimize });
    const store = b.addModule("store", .{ .root_source_file = b.path("src/knowledge/store.zig"), .target = target, .optimize = optimize });
    const monitoring = b.addModule("monitoring", .{ .root_source_file = b.path("src/monitoring/monitoring.zig"), .target = target, .optimize = optimize });
    const report_kb_stats = b.addModule("report_kb_stats", .{ .root_source_file = b.path("src/monitoring/report_kb_stats.zig"), .target = target, .optimize = optimize });
    const fs = b.addModule("fs", .{ .root_source_file = b.path("src/util/fs.zig"), .target = target, .optimize = optimize });
    const cache = b.addModule("cache", .{ .root_source_file = b.path("src/util/cache.zig"), .target = target, .optimize = optimize });
    const builder = b.addModule("builder", .{ .root_source_file = b.path("src/builder/builder.zig"), .target = target, .optimize = optimize });
    const critic = b.addModule("critic", .{ .root_source_file = b.path("src/critic/critic.zig"), .target = target, .optimize = optimize });
    const transport = b.addModule("transport", .{ .root_source_file = b.path("src/llm/transport.zig"), .target = target, .optimize = optimize });
    const http = b.addModule("http", .{ .root_source_file = b.path("src/llm/http.zig"), .target = target, .optimize = optimize });
    const replay = b.addModule("replay", .{ .root_source_file = b.path("src/llm/replay.zig"), .target = target, .optimize = optimize });
    const loop = b.addModule("loop", .{ .root_source_file = b.path("src/loop.zig"), .target = target, .optimize = optimize });
    // Build-time version stamp (§28). Detected via `git describe` so a release
    // tag flows into the binary automatically; fall back to "" when git history
    // is unavailable (e.g. a shallow/code-only tarball build) rather than
    // failing the whole build. `b.run` (runAllowFail) only fatal on spawn
    // error, not a non-zero git exit, so a missing tag/shallow clone yields "".
    const raw_version = b.run(&[_][]const u8{ "git", "describe", "--tags", "--always", "--dirty" });
    // git describe prints a trailing newline; trim it so the version stamp is
    // a clean token with no embedded control char in the report/--version.
    const version_stamp = std.mem.trim(u8, raw_version, "\r\n");
    const version_opt = b.addOptions();
    version_opt.addOption([]const u8, "version", version_stamp);
    const bopt = b.createModule(.{ .root_source_file = version_opt.getOutput(), .target = target, .optimize = optimize });

    const mainmod = b.addModule("mainmod", .{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });

    const all = [_]*std.Build.Module{
        types,      config,    compose, engine,     step,            gateway, orchestrator, evaluator, deploy,
        resilience, knowledge, store,   monitoring, report_kb_stats, fs,      cache,        builder,   critic,
        transport,  replay,    http,    runlife,    loop,            mainmod, bopt,
    };
    const all_names = [_][]const u8{
        "types",      "config",    "compose", "engine",     "step",            "gateway", "orchestrator",  "evaluator", "deploy",
        "resilience", "knowledge", "store",   "monitoring", "report_kb_stats", "fs",      "cache",         "builder",   "critic",
        "transport",  "replay",    "http",    "runlife",    "loop",            "mainmod", "build_options",
    };

    // The dependency graph is a DAG, so wiring every module to every other
    // (except itself) introduces no cycle. This keeps build.zig honest and
    // removes the need to maintain a per-file import list by hand.
    for (all) |m| {
        for (all, all_names) |other, name| {
            if (m != other) m.addImport(name, other);
        }
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (all, all_names) |other, name| exe_mod.addImport(name, other);
    const exe = b.addExecutable(.{ .name = "yuxi", .root_module = exe_mod });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/builder/builder.zig",
        "src/builder/builder_test.zig",
        "src/config_test.zig",
        "src/core/compose.zig",
        "src/core/selfcorr/gate_test.zig",
        "src/core/selfcorr/recovery_test.zig",
        "src/core/selfcorr/plan_gate_test.zig",
        "src/critic/critic.zig",
        "src/evaluator/evaluator.zig",
        "src/deploy/deploy_test.zig",
        "src/knowledge/recorders_test.zig",
        "src/knowledge/store_test.zig",
        "src/knowledge/summarize_test.zig",
        "src/llm/http.zig",
        "src/llm/transport_test.zig",
        "src/monitoring/health_test.zig",
        "src/monitoring/report_test.zig",
        "src/util/fs.zig",
        "src/main_test.zig",
        "src/orchestrator/orchestrator_test.zig",
    };
    for (test_files) |tf| {
        const tmod = b.createModule(.{ .root_source_file = b.path(tf), .target = target, .optimize = optimize });
        for (all, all_names) |other, name| tmod.addImport(name, other);
        const tt = b.addTest(.{ .root_module = tmod });
        // Run the test binary directly in self-managed mode rather than through
        // the `zig_test` IPC server protocol. On aarch64 the default LLVM
        // backend selects server mode, and its protocol pipe deadlocks when this
        // engine test spawns child processes (the composed program's compile and
        // run) that inherit the pipe fds. Running the binary directly (no
        // `--listen`) is correct and avoids the deadlock.
        const run_tt = std.Build.Step.Run.create(b, b.fmt("run {s}", .{tf}));
        run_tt.addArtifactArg(tt);
        // Capture output to a real file instead of inheriting the build's pipe:
        // `global_single_threaded` stdout is mangled through the build's
        // run-step pipe, hiding the evaluator's `[evaluator] ...` diagnostics.
        run_tt.stdio = .inherit;
        test_step.dependOn(&run_tt.step);
    }
}
