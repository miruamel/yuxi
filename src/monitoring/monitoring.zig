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
/// never alters the pipeline.
///
/// Single source of truth for "is this cycle healthy". `healthy` is true iff
/// `verdict` is empty (no WARN fired); `loop.runTasks` and `engine.finishRun`
/// must both read health from here rather than re-deriving it, so a batch
/// report can never disagree with the per-cycle verdict persisted to the KB.
///
/// `verdict` is caller-owned and must be freed. `healthy` is just
/// `verdict.len == 0`, surfaced alongside for convenience.
pub const HealthVerdict = struct {
    verdict: []const u8,
    healthy: bool,
};
pub fn assessHealth(ctx: *types.Ctx) !HealthVerdict {
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
    const owned = verdict.toOwnedSlice(ctx.allocator) catch "";
    return .{ .verdict = owned, .healthy = owned.len == 0 };
}
