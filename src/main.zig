const std = @import("std");
const config = @import("config");
const engine = @import("engine");
const loop = @import("loop");
const monitoring = @import("monitoring");
const types = @import("types");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    const cfg = config.parse(arena, io, &it) catch return;

    if (cfg.tasks) |tasks_path| {
        var results = try loop.runTasks(arena, io, init.minimal.environ, cfg, tasks_path);
        const healthy = try emitReportAndExit(arena, io, cfg.report_path, null, results.items);
        results.deinit(arena);
        if (!healthy) std.process.exit(1);
        return;
    }
    var ctx = try engine.newCtx(arena, io, init.minimal.environ, cfg, cfg.workdir);
    try engine.run(arena, io, &ctx, cfg.task);
    // The run's health verdict is computed once, from the single source of
    // truth (monitoring.assessHealth). A healthy run exits 0; an unhealthy one
    // exits 1 so CI / cron can gate on process status (§30), and the optional
    // --report JSON carries the same verdict to machine consumers.
    const hv = try monitoring.assessHealth(&ctx);
    const single = monitoring.TaskResult{
        .task = cfg.task,
        .deploys = ctx.deploys,
        .retries = ctx.retries,
        .critic_rejections = ctx.critic_rejections,
        .mock_fallbacks = ctx.mock_fallbacks,
        .token_budgets_exceeded = ctx.token_budgets_exceeded,
        .healthy = hv.healthy,
    };
    const healthy = try emitReportAndExit(arena, io, cfg.report_path, single, null);
    ctx.allocator.free(hv.verdict);
    if (!healthy) std.process.exit(1);
}

/// Write the optional `--report` JSON and return whether all reported results
/// are healthy. Centralizes the health→exit mapping so both the single-run and
/// batch paths use the identical policy.
fn emitReportAndExit(alloc: std.mem.Allocator, io: std.Io, report_path: ?[]const u8, single: ?monitoring.TaskResult, batch: ?[]const monitoring.TaskResult) !bool {
    var all_healthy = true;
    if (single) |s| all_healthy = s.healthy;
    if (batch) |b| for (b) |r| {
        if (!r.healthy) all_healthy = false;
    };
    if (report_path) |p| {
        monitoring.writeReport(alloc, io, p, single, batch) catch |e| types.logLine(io, "[main] report write failed: {s}", .{@errorName(e)});
    }
    return all_healthy;
}
