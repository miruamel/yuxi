const std = @import("std");
const types = @import("core/types.zig");
const config = @import("core/config.zig");
const engine = @import("core/engine.zig");

pub const TaskResult = struct {
    task: []const u8,
    deploys: usize,
    retries: usize,
    critic_rejections: usize,
    mock_fallbacks: usize,
    token_budgets_exceeded: usize,
    healthy: bool,
};

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
        defer allocator.free(wd);
        var ctx = engine.newCtx(allocator, io, environ, cfg, wd) catch |e| {
            types.logLine(io, "[loop] task {d} ctx build failed: {s}", .{ idx, @errorName(e) });
            continue;
        };
        engine.run(allocator, io, &ctx, line) catch |e| {
            types.logLine(io, "[loop] task {d} ({s}) failed: {s}", .{ idx, line, @errorName(e) });
        };
        const healthy = ctx.deploys > 0 and ctx.token_budgets_exceeded == 0;
        try results.append(allocator, .{
            .task = try allocator.dupe(u8, line),
            .deploys = ctx.deploys,
            .retries = ctx.retries,
            .critic_rejections = ctx.critic_rejections,
            .mock_fallbacks = ctx.mock_fallbacks,
            .token_budgets_exceeded = ctx.token_budgets_exceeded,
            .healthy = healthy,
        });
    }

    types.logLine(io, "[loop] === batch report: {d} task(s) ===", .{results.items.len});
    for (results.items) |r| {
        types.logLine(io, "[loop] {s} -> deploys={d} retries={d} critic_rej={d} mock_fb={d} budget_ex={d} health={s}", .{
            r.task,                               r.deploys, r.retries, r.critic_rejections, r.mock_fallbacks, r.token_budgets_exceeded,
            if (r.healthy) "OK" else "UNHEALTHY",
        });
    }
    return results;
}
