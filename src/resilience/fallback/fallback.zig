const std = @import("std");
const types = @import("types");

/// Circuit-breaker fallback: switch to mock backend after an LLM failure.
pub fn fallback(ctx: *types.Ctx) void {
    if (ctx.backend != .mock) {
        ctx.log("[resilience] circuit fallback: switch to mock backend", .{});
        ctx.backend = .mock;
    }
    // Always count the failure, even if already on mock
    ctx.failures += 1;
}

pub fn summary(ctx: *types.Ctx) void {
    ctx.log("[resilience] failures={d}, backend now={s}", .{ ctx.failures, @tagName(ctx.backend) });
    ctx.record("resilience: summary");
}
