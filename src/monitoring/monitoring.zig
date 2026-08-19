const std = @import("std");
const types = @import("types");

pub fn report(ctx: *types.Ctx) void {
    ctx.log("[monitoring] events={d} tokens={d} backend={s} mode={s}", .{ ctx.events.items.len, ctx.tokens, @tagName(ctx.backend), @tagName(ctx.mode) });
    ctx.log("[monitoring] critic_rejections={d} mock_fallbacks={d} retries={d} deploys={d} token_budgets_exceeded={d}", .{ ctx.critic_rejections, ctx.mock_fallbacks, ctx.retries, ctx.deploys, ctx.token_budgets_exceeded });
    if (ctx.cache) |c| {
        ctx.log("[monitoring] cache hits={d} misses={d}", .{ c.hits, c.misses });
    }
    ctx.record("monitoring: report");
}
/// End-of-run autonomy-health verdict (§30/§32). Purely diagnostic: warns
/// through the event log when the loop's own counters indicate an unhealthy
/// cycle, so the autonomous loop can read its effectiveness. No behavior
/// change — it never alters the pipeline, only reports.
pub fn assessHealth(ctx: *types.Ctx) void {
    if (ctx.deploys == 0) {
        ctx.log("[monitoring][health] WARN no deploy this cycle: critic_rejections={d} mock_fallbacks={d} retries={d}", .{ ctx.critic_rejections, ctx.mock_fallbacks, ctx.retries });
        ctx.record("monitoring: health WARN no deploy");
    }
    if (ctx.token_budgets_exceeded > 0) {
        ctx.log("[monitoring][health] WARN token budget exceeded {d} time(s)", .{ctx.token_budgets_exceeded});
        ctx.record("monitoring: health WARN token budget exceeded");
    }
    if (ctx.retries > 0 and ctx.deploys == 0) {
        ctx.log("[monitoring][health] WARN self-correction exhausted without a deploy", .{});
        ctx.record("monitoring: health WARN self-correction exhausted");
    }
    if (ctx.mock_fallbacks > ctx.deploys) {
        ctx.log("[monitoring][health] WARN mock fallback dominated this cycle (mock_fallbacks={d} > deploys={d})", .{ ctx.mock_fallbacks, ctx.deploys });
        ctx.record("monitoring: health WARN mock fallback dominated");
    }
}
