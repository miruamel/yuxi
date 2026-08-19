const std = @import("std");
const types = @import("../core/types.zig");
const transport = @import("../llm/transport.zig");
const fs = @import("../util/fs.zig");
const resilience = @import("../resilience/resilience.zig");

pub fn run(ctx: *types.Ctx, step: *types.Step, path: []const u8) !bool {
    ctx.log("[builder] planning step {d}: {s}", .{ step.id, step.name });
    const sys = "You are a code generator. Output ONLY Zig source code, no markdown.";
    const user = try std.fmt.allocPrint(ctx.allocator, "Implement: {s}", .{step.name});
    defer ctx.allocator.free(user);

    const code = transport.complete(ctx.allocator, ctx.io, ctx, sys, user) catch |e| {
        ctx.log("[builder] LLM failed: {s}; fallback to mock", .{@errorName(e)});
        resilience.fallback(ctx);
        const c = try transport.complete(ctx.allocator, ctx.io, ctx, sys, user);
        return writeAndMark(ctx, step, path, c);
    };
    return writeAndMark(ctx, step, path, code);
}

fn writeAndMark(ctx: *types.Ctx, step: *types.Step, path: []const u8, code: []const u8) !bool {
    defer ctx.allocator.free(code);
    if (ctx.mode == .hitl) {
        ctx.log("[builder] HITL gate: approve write to {s}? [y/N]", .{path});
        var buf: [16]u8 = undefined;
        const n = std.os.linux.read(0, &buf, buf.len);
        if (n == 0 or (buf[0] != 'y' and buf[0] != 'Y')) {
            ctx.log("[builder] HITL: rejected by operator", .{});
            step.status = .rejected;
            return false;
        }
    }
    try fs.writeFileAlloc(ctx.allocator, path, code);
    ctx.log("[builder] wrote {d} bytes -> {s}", .{ code.len, path });
    step.status = .ok;
    ctx.record("builder: wrote file");
    return true;
}
