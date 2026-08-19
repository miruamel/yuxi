const std = @import("std");
const types = @import("../core/types.zig");
const transport = @import("../llm/transport.zig");
const knowledge = @import("../knowledge/knowledge.zig");

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
    ctx.record("orchestrator: decomposed");
    return true;
}
