const std = @import("std");
const types = @import("types");
const transport = @import("transport");
const knowledge = @import("knowledge");

pub fn run(ctx: *types.Ctx, task: []const u8, steps: *std.ArrayList(types.Step)) !bool {
    ctx.log("[orchestrator] decomposing task", .{});
    const sys = "You are a task decomposer. Return numbered steps, one per line, prefixed 'STEP: '.";
    const user = try knowledge.injectPrompt(ctx, task);
    defer ctx.allocator.free(user);
    const resp = try transport.complete(ctx.allocator, ctx.io, ctx, sys, user);
    defer ctx.allocator.free(resp);

    var it = std.mem.tokenizeScalar(u8, resp, '\n');
    var id: usize = 0;
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r");
        if (std.mem.startsWith(u8, t, "STEP:")) {
            const name = std.mem.trim(u8, t["STEP:".len..], " ");
            try steps.append(ctx.allocator, .{
                .id = id,
                .name = try ctx.allocator.dupe(u8, name),
                .status = .pending,
                .notes = "",
            });
            id += 1;
        }
    }
    if (steps.items.len == 0) {
        try steps.append(ctx.allocator, .{
            .id = 0,
            .name = try ctx.allocator.dupe(u8, task),
            .status = .pending,
            .notes = "",
        });
    }
    ctx.log("[orchestrator] plan: {d} steps", .{steps.items.len});
    // Autonomous-safety bound: a caller-set --max-steps caps how many steps
    // the engine may autonomously decompose. An unbounded plan is a real
    // autonomy risk (runaway scope, unbounded LLM/hardware cost), so when the
    // bound is exceeded the run fails fast instead of building a sprawling
    // artifact. Off by default (max_steps == null) so existing pipelines are
    // unchanged; this is the decomposition analogue of --max-tokens.
    if (ctx.max_steps) |cap| {
        if (steps.items.len > cap) {
            ctx.record("orchestrator: plan exceeded max-steps");
            return false;
        }
    }
    ctx.record("orchestrator: decomposed");
    return true;
}
