const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable Thread Sanitizer") orelse false;

    // Engine modules
    const engine_types = b.addModule("types", .{ .root_source_file = b.path("src/engine/types/types.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const engine_config = b.addModule("config", .{ .root_source_file = b.path("src/engine/config/config.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const engine_compose = b.addModule("compose", .{ .root_source_file = b.path("src/engine/compose/compose.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const engine_engine = b.addModule("engine", .{ .root_source_file = b.path("src/engine/engine.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const engine_step = b.addModule("step", .{ .root_source_file = b.path("src/engine/step/step.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const engine_runlife = b.addModule("runlife", .{ .root_source_file = b.path("src/engine/runlife/runlife.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const engine_loop = b.addModule("loop", .{ .root_source_file = b.path("src/engine/loop/loop.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const engine_main = b.addModule("mainmod", .{ .root_source_file = b.path("src/engine/main/main.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // LLM modules
    const llm_transport = b.addModule("transport", .{ .root_source_file = b.path("src/llm/transport/transport.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const llm_http = b.addModule("http", .{ .root_source_file = b.path("src/llm/transport/http/http.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const llm_replay = b.addModule("replay", .{ .root_source_file = b.path("src/llm/replay/replay.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Orchestrator modules
    const orchestrator_decompose = b.addModule("orchestrator", .{ .root_source_file = b.path("src/orchestrator/decompose/decompose.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Builder modules
    const builder_generate = b.addModule("builder", .{ .root_source_file = b.path("src/builder/generate/generate.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Critic modules
    const critic_denylist = b.addModule("critic", .{ .root_source_file = b.path("src/critic/denylist/denylist.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Evaluator modules
    const evaluator_compile = b.addModule("evaluator", .{ .root_source_file = b.path("src/evaluator/compile/compile.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Deploy modules
    const deploy_commit = b.addModule("deploy", .{ .root_source_file = b.path("src/deploy/commit/commit.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Gateway modules
    const gateway_auth = b.addModule("gateway", .{ .root_source_file = b.path("src/gateway/auth/auth.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Knowledge modules
    const knowledge_ledger = b.addModule("knowledge", .{ .root_source_file = b.path("src/knowledge/ledger/ledger.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const knowledge_store = b.addModule("store", .{ .root_source_file = b.path("src/knowledge/store/store.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Monitoring modules
    const monitoring_health = b.addModule("monitoring", .{ .root_source_file = b.path("src/monitoring/health/health.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const monitoring_report_kb_stats = b.addModule("report_kb_stats", .{ .root_source_file = b.path("src/monitoring/report/report_kb_stats.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Resilience modules
    const resilience_fallback = b.addModule("resilience", .{ .root_source_file = b.path("src/resilience/fallback/fallback.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Util modules
    const util_fs = b.addModule("fs", .{ .root_source_file = b.path("src/util/fs/fs.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const util_cache = b.addModule("cache", .{ .root_source_file = b.path("src/util/cache/cache.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    // Build-time version stamp
    const raw_version = b.run(&[_][]const u8{ "git", "describe", "--tags", "--always", "--dirty" });
    const version_stamp = std.mem.trim(u8, raw_version, "\r\n");
    const version_opt = b.addOptions();
    version_opt.addOption([]const u8, "version", version_stamp);
    const bopt = b.createModule(.{ .root_source_file = version_opt.getOutput(), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });

    const all = [_]*std.Build.Module{
        engine_types,      engine_config,    engine_compose, engine_engine,     engine_step,
        engine_runlife,    engine_loop,      engine_main,
        llm_transport,     llm_http,         llm_replay,
        orchestrator_decompose,
        builder_generate,
        critic_denylist,
        evaluator_compile,
        deploy_commit,
        gateway_auth,
        knowledge_ledger,  knowledge_store,
        monitoring_health, monitoring_report_kb_stats,
        resilience_fallback,
        util_fs,           util_cache,
        bopt,
    };
    const all_names = [_][]const u8{
        "types",           "config",         "compose",       "engine",          "step",
        "runlife",         "loop",           "mainmod",
        "transport",       "http",           "replay",
        "orchestrator",
        "builder",
        "critic",
        "evaluator",
        "deploy",
        "gateway",
        "knowledge",       "store",
        "monitoring",      "report_kb_stats",
        "resilience",
        "fs",              "cache",
        "build_options",
    };

    for (all) |m| {
        for (all, all_names) |other, name| {
            if (m != other) m.addImport(name, other);
        }
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/main/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    for (all, all_names) |other, name| exe_mod.addImport(name, other);
    const exe = b.addExecutable(.{ .name = "yuxi", .root_module = exe_mod });
    b.installArtifact(exe);

    // Benchmark step
    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_files = [_][]const u8{
        "src/orchestrator/bench/bench.zig",
        "src/critic/bench/bench.zig",
        "src/evaluator/bench/bench.zig",
    };
    for (bench_files) |bf| {
        const bmod = b.createModule(.{ .root_source_file = b.path(bf), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
        for (all, all_names) |other, name| bmod.addImport(name, other);
        const bt = b.addTest(.{ .root_module = bmod });
        const run_bt = std.Build.Step.Run.create(b, b.fmt("bench {s}", .{bf}));
        run_bt.addArtifactArg(bt);
        run_bt.stdio = .inherit;
        bench_step.dependOn(&run_bt.step);
    }

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/builder/generate/generate.zig",
        "src/builder/generate/generate_test.zig",
        "src/engine/config/config_test.zig",
        "src/engine/compose/compose.zig",
        "src/engine/loop/loop.zig",
        "src/engine/loop/loop_test.zig",
        "src/engine/selfcorr/recovery/recovery_test.zig",
        "src/engine/selfcorr/gate/gate_test.zig",
        "src/engine/selfcorr/plan_gate/plan_gate_test.zig",
        "src/critic/denylist/denylist_test.zig",
        "src/evaluator/compile/compile.zig",
        "src/deploy/commit/commit_test.zig",
        "src/knowledge/ledger/ledger_test.zig",
        "src/knowledge/store/store_test.zig",
        "src/knowledge/summarize/summarize_test.zig",
        "src/llm/transport/http/http.zig",
        "src/llm/transport/transport_test.zig",
        "src/monitoring/health/health_test.zig",
        "src/monitoring/report/report_test.zig",
        "src/util/fs/fs.zig",
        "src/engine/main/main_test.zig",
        "src/engine/main/main_cli_test.zig",
        "src/orchestrator/decompose/decompose_test.zig",
        "src/gateway/auth/auth_test.zig",
        "src/util/cache/cache.zig",
        "src/resilience/fallback/fallback_test.zig",
    };
    for (test_files) |tf| {
        const tmod = b.createModule(.{ .root_source_file = b.path(tf), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
        for (all, all_names) |other, name| tmod.addImport(name, other);
        const tt = b.addTest(.{ .root_module = tmod });
        const run_tt = std.Build.Step.Run.create(b, b.fmt("run {s}", .{tf}));
        run_tt.addArtifactArg(tt);
        run_tt.stdio = .inherit;
        test_step.dependOn(&run_tt.step);
    }
}