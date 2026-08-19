const std = @import("std");
const types = @import("types.zig");
const gateway = @import("../gateway/gateway.zig");
const orchestrator = @import("../orchestrator/orchestrator.zig");
const builder = @import("../builder/builder.zig");
const critic = @import("../critic/critic.zig");
const evaluator = @import("../evaluator/evaluator.zig");
const deploy = @import("../deploy/deploy.zig");
const resilience = @import("../resilience/resilience.zig");
const knowledge = @import("../knowledge/knowledge.zig");
const monitoring = @import("../monitoring/monitoring.zig");
const fs = @import("../util/fs.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, task: []const u8) !void {
    types.logLine(io, "=== Yuxi (玉溪): autonomous software evolution engine ===", .{});
    types.logLine(io, "[engine] mode={s} backend={s}", .{ @tagName(ctx.mode), @tagName(ctx.backend) });

    // LAYER 1: Gateway
    if (!try gateway.run(ctx, task)) {
        ctx.log("[engine] ABORT at gateway", .{});
        return;
    }
    // LAYER 2: Orchestrator
    var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
    if (!try orchestrator.run(ctx, task, &steps)) {
        ctx.log("[engine] ABORT at orchestrator", .{});
        return;
    }
    // LAYER 3-6: per step (Builder -> Critic -> Evaluator -> Deploy)
    for (steps.items, 0..) |*step, i| {
        const path = try std.fmt.allocPrint(allocator, "gen_{d}.zig", .{i});
        if (!try builder.run(ctx, step, path)) {
            ctx.log("[engine] step {d} not built", .{step.id});
            allocator.free(path);
            continue;
        }
        const code = fs.readFileAlloc(allocator, path) catch |e| {
            ctx.log("[engine] read failed: {s}", .{@errorName(e)});
            allocator.free(path);
            continue;
        };
        var approved = try critic.run(ctx, code);
        if (!approved) {
            resilience.fallback(ctx);
            ctx.log("[engine] critic rejected; retry build (fallback={s})", .{@tagName(ctx.backend)});
            _ = try builder.run(ctx, step, path);
            approved = try critic.run(ctx, code);
        }
        _ = try evaluator.run(ctx, path);
        _ = try deploy.run(ctx, path);
        allocator.free(code);
        allocator.free(path);
    }
    // LAYER 7: Resilience summary
    resilience.summary(ctx);
    // LAYER 8: Knowledge
    knowledge.log(ctx, "task pipeline complete");
    // LAYER 9: Monitoring
    monitoring.report(ctx);
    types.logLine(io, "[engine] done. events={d}", .{ctx.events.items.len});
}
