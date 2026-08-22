const std = @import("std");
const types = @import("types");
const builder = @import("builder");
const critic = @import("critic");
const knowledge = @import("knowledge");
const resilience = @import("resilience");
const fs = @import("fs");

/// Build one step (Builder -> Critic). A critic rejection regenerates THIS step
/// with the critic's reason as builder feedback (no global backend downgrade);
/// only a still-rejected retry falls back to mock. `feedback` seeds the first build.
pub fn build(allocator: std.mem.Allocator, ctx: *types.Ctx, step: *types.Step, i: usize, feedback: ?[]const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ ctx.workdir, i });
    defer allocator.free(path);
    if (!try builder.run(ctx, step, path, feedback)) {
        ctx.log("[engine] step {d} not built", .{step.id});
        return null;
    }
    var code = fs.readFileAlloc(allocator, path) catch |e| {
        ctx.log("[engine] read failed: {s}", .{@errorName(e)});
        return null;
    };
    const v = try critic.run(ctx, code);
    if (v.ok) {
        if (v.reason) |r| allocator.free(r);
        return code;
    }
    ctx.log("[engine] critic rejected step {d}: {s}", .{ step.id, v.reason orelse "no reason" });
    ctx.critic_rejections += 1;
    knowledge.recordCritic(ctx, step.name, v.reason orelse "no reason") catch |e| ctx.log("[knowledge] failed to record critic lesson: {s}", .{@errorName(e)});
    allocator.free(code);
    const fb = if (v.reason) |r| r else "critic rejected";
    _ = try builder.run(ctx, step, path, fb);
    if (v.reason) |r| allocator.free(r);
    code = fs.readFileAlloc(allocator, path) catch {
        ctx.log("[engine] read failed after rebuild", .{});
        return null;
    };
    const v2 = try critic.run(ctx, code);
    if (v2.ok) {
        if (v2.reason) |r| allocator.free(r);
        return code;
    }
    resilience.fallback(ctx);
    ctx.mock_fallbacks += 1;
    if (v2.reason) |r| allocator.free(r);
    allocator.free(code);
    ctx.log("[engine] step {d} rejected after retry; fallback to mock", .{step.id});
    return null;
}
