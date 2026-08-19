const std = @import("std");
const types = @import("../core/types.zig");

pub fn report(ctx: *types.Ctx) void {
    ctx.log("[monitoring] events={d} tokens={d} backend={s} mode={s}", .{ ctx.events.items.len, ctx.tokens, @tagName(ctx.backend), @tagName(ctx.mode) });
    if (ctx.cache) |c| {
        ctx.log("[monitoring] cache hits={d} misses={d}", .{ c.hits, c.misses });
    }
    ctx.record("monitoring: report");
}
