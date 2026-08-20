const std = @import("std");
const types = @import("types");

/// Emit the run's autonomy metrics (counters + tokens) alongside the event
/// log, so the loop can read its own effectiveness at a glance. Purely
/// diagnostic — never alters the pipeline.
pub fn report(ctx: *types.Ctx) void {
    ctx.log("[monitoring] metrics deploys={d} retries={d} critic_rejections={d} mock_fallbacks={d} token_budgets_exceeded={d} tokens={d}", .{ ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.token_budgets_exceeded, ctx.tokens });
    ctx.record("monitoring: metrics logged");
}

/// End-of-run autonomy-health verdict (§30/§32). Purely diagnostic: inspects
/// the loop's own counters and warns when they indicate an unhealthy cycle, so
/// the autonomous loop can read its effectiveness. No behavior change — it
/// never alters the pipeline. Returns the accumulated `WARN ...; ` verdict
/// (caller-owned, must be freed) so the engine can also persist it to the
/// knowledge base; an empty result means a healthy cycle.
pub fn assessHealth(ctx: *types.Ctx) ![]const u8 {
    var verdict = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
    if (ctx.deploys == 0) {
        ctx.log("[monitoring][health] WARN no deploy this cycle: critic_rejections={d} mock_fallbacks={d} retries={d}", .{ ctx.critic_rejections, ctx.mock_fallbacks, ctx.retries });
        ctx.record("monitoring: health WARN no deploy");
        verdict.appendSlice(ctx.allocator, "no deploy; ") catch {};
    }
    if (ctx.token_budgets_exceeded > 0) {
        ctx.log("[monitoring][health] WARN token budget exceeded {d} time(s)", .{ctx.token_budgets_exceeded});
        ctx.record("monitoring: health WARN token budget exceeded");
        verdict.appendSlice(ctx.allocator, "token budget exceeded; ") catch {};
    }
    if (ctx.retries > 0 and ctx.deploys == 0) {
        ctx.log("[monitoring][health] WARN self-correction exhausted without a deploy", .{});
        ctx.record("monitoring: health WARN self-correction exhausted");
        verdict.appendSlice(ctx.allocator, "self-correction exhausted; ") catch {};
    }
    if (ctx.mock_fallbacks > ctx.deploys) {
        ctx.log("[monitoring][health] WARN mock fallback dominated this cycle (mock_fallbacks={d} > deploys={d})", .{ ctx.mock_fallbacks, ctx.deploys });
        ctx.record("monitoring: health WARN mock fallback dominated");
        verdict.appendSlice(ctx.allocator, "mock fallback dominated; ") catch {};
    }
    return verdict.toOwnedSlice(ctx.allocator) catch "";
}
