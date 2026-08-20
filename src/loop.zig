const std = @import("std");
const types = @import("types");
const config = @import("config");
const engine = @import("engine");
const knowledge = @import("knowledge");
const monitoring = @import("monitoring");

/// Per-task autonomy-health result. Defined in `monitoring` so a single run
/// (main) and a batch run (runTasks) share one shape.
pub const TaskResult = monitoring.TaskResult;

/// Run each non-comment, non-blank line of `tasks_path` as an isolated
/// engine.run cycle, then print one batch report aggregating the run metrics
/// and autonomy-health verdict. This is the "continuous" step of the engine:
/// it consumes the per-cycle metrics + health signals (§12/§30/§32) instead of
/// letting each cycle's verdict disappear into the log. Single-task behavior is
/// untouched; this is opt-in via `--tasks`.
pub fn runTasks(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, cfg: config.Config, tasks_path: []const u8) !std.ArrayList(TaskResult) {
    const content = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, tasks_path, allocator, std.Io.Limit.limited(1 << 20)) catch |e| {
        types.logLine(io, "[loop] cannot read tasks file {s}: {s}", .{ tasks_path, @errorName(e) });
        return std.ArrayList(TaskResult).initCapacity(allocator, 0);
    };
    defer allocator.free(content);

    var results = try std.ArrayList(TaskResult).initCapacity(allocator, 0);
    errdefer results.deinit(allocator);

    var it = std.mem.splitScalar(u8, content, '\n');
    var idx: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        idx += 1;
        const wd = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ cfg.workdir, idx });
        var ctx = engine.newCtx(allocator, io, environ, cfg, wd) catch |e| {
            types.logLine(io, "[loop] task {d} ctx build failed: {s}", .{ idx, @errorName(e) });
            continue;
        };
        engine.run(allocator, io, &ctx, line) catch |e| {
            types.logLine(io, "[loop] task {d} ({s}) failed: {s}", .{ idx, line, @errorName(e) });
        };
        // Health comes from the single source of truth (monitoring.assessHealth)
        // so the batch verdict can never contradict the per-cycle verdict the
        // engine persisted to the KB. The loop must not re-derive "healthy".
        const hv = try monitoring.assessHealth(&ctx);
        try results.append(allocator, .{
            .task = try allocator.dupe(u8, line),
            .deploys = ctx.deploys,
            .retries = ctx.retries,
            .critic_rejections = ctx.critic_rejections,
            .mock_fallbacks = ctx.mock_fallbacks,
            .token_budgets_exceeded = ctx.token_budgets_exceeded,
            .healthy = hv.healthy,
        });
        types.logLine(io, "[loop] {s} -> deploys={d} retries={d} critic_rej={d} mock_fb={d} budget_ex={d} health={s} verdict=\"{s}\"", .{
            line,                                  ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.token_budgets_exceeded,
            if (hv.healthy) "OK" else "UNHEALTHY", hv.verdict,
        });
        if (hv.verdict.len > 0) allocator.free(hv.verdict);
    }
    var total_unhealthy: usize = 0;
    for (results.items) |r| {
        if (!r.healthy) total_unhealthy += 1;
    }
    types.logLine(io, "[loop] === batch summary: {d} task(s), {d} unhealthy ===", .{ results.items.len, total_unhealthy });

    // Persist the aggregate batch autonomy-health summary to the KB so the
    // next cycle's injectPrompt learns batch shape, not only per-run verdicts.
    if (cfg.kb_path) |kb| {
        var total_deploys: usize = 0;
        for (results.items) |r| total_deploys += r.deploys;
        const summary = try std.fmt.allocPrint(allocator, "tasks={d} deploys={d} unhealthy={d}", .{ results.items.len, total_deploys, total_unhealthy });
        defer allocator.free(summary);
        knowledge.recordBatch(allocator, kb, summary) catch |e| types.logLine(io, "[loop] batch kb save failed: {s}", .{@errorName(e)});
    }

    return results;
}
