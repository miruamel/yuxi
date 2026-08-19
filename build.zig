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
    const config = b.addModule("config", .{ .root_source_file = b.path("src/core/config.zig"), .target = target, .optimize = optimize });
    const engine = b.addModule("engine", .{ .root_source_file = b.path("src/core/engine.zig"), .target = target, .optimize = optimize });
    const step = b.addModule("step", .{ .root_source_file = b.path("src/core/step.zig"), .target = target, .optimize = optimize });
    const gateway = b.addModule("gateway", .{ .root_source_file = b.path("src/gateway/gateway.zig"), .target = target, .optimize = optimize });
    const orchestrator = b.addModule("orchestrator", .{ .root_source_file = b.path("src/orchestrator/orchestrator.zig"), .target = target, .optimize = optimize });
    const evaluator = b.addModule("evaluator", .{ .root_source_file = b.path("src/evaluator/evaluator.zig"), .target = target, .optimize = optimize });
    const deploy = b.addModule("deploy", .{ .root_source_file = b.path("src/deploy/deploy.zig"), .target = target, .optimize = optimize });
    const resilience = b.addModule("resilience", .{ .root_source_file = b.path("src/resilience/resilience.zig"), .target = target, .optimize = optimize });
    const knowledge = b.addModule("knowledge", .{ .root_source_file = b.path("src/knowledge/knowledge.zig"), .target = target, .optimize = optimize });
    const monitoring = b.addModule("monitoring", .{ .root_source_file = b.path("src/monitoring/monitoring.zig"), .target = target, .optimize = optimize });
    const fs = b.addModule("fs", .{ .root_source_file = b.path("src/util/fs.zig"), .target = target, .optimize = optimize });
    const cache = b.addModule("cache", .{ .root_source_file = b.path("src/util/cache.zig"), .target = target, .optimize = optimize });
    const builder = b.addModule("builder", .{ .root_source_file = b.path("src/builder/builder.zig"), .target = target, .optimize = optimize });
    const critic = b.addModule("critic", .{ .root_source_file = b.path("src/critic/critic.zig"), .target = target, .optimize = optimize });
    const transport = b.addModule("transport", .{ .root_source_file = b.path("src/llm/transport.zig"), .target = target, .optimize = optimize });
    const replay = b.addModule("replay", .{ .root_source_file = b.path("src/llm/replay.zig"), .target = target, .optimize = optimize });
    const loop = b.addModule("loop", .{ .root_source_file = b.path("src/loop.zig"), .target = target, .optimize = optimize });

    const all = [_]*std.Build.Module{
        types, config, engine, step, gateway, orchestrator, evaluator, deploy,
        resilience, knowledge, monitoring, fs, cache, builder, critic, transport, replay, loop,
    };
    const all_names = [_][]const u8{
        "types", "config", "engine", "step", "gateway", "orchestrator", "evaluator", "deploy",
        "resilience", "knowledge", "monitoring", "fs", "cache", "builder", "critic", "transport", "replay", "loop",
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
        "src/loop_test.zig",
        "src/builder/builder.zig",
        "src/core/engine.zig",
        "src/core/selfcorr/gate_test.zig",
        "src/core/selfcorr/recovery_test.zig",
        "src/critic/critic.zig",
        "src/evaluator/evaluator.zig",
        "src/knowledge/knowledge_test.zig",
        "src/llm/transport.zig",
        "src/llm/transport_test.zig",
        "src/monitoring/monitoring_test.zig",
        "src/util/cache.zig",
        "src/util/fs.zig",
    };
    for (test_files) |tf| {
        const tmod = b.createModule(.{ .root_source_file = b.path(tf), .target = target, .optimize = optimize });
        for (all, all_names) |other, name| tmod.addImport(name, other);
        const tt = b.addTest(.{ .root_module = tmod });
        test_step.dependOn(&tt.step);
    }
}
