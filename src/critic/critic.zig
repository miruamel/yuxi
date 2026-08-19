const std = @import("std");
const types = @import("../core/types.zig");
const transport = @import("../llm/transport.zig");

pub fn run(ctx: *types.Ctx, code: []const u8) !bool {
    // Fast-path rules engine.
    if (std.mem.indexOf(u8, code, "panic(") != null) {
        ctx.log("[critic] fast-path: rejected (contains panic)", .{});
        return false;
    }
    // LLM critic.
    const sys = "You are a code critic. Reply only APPROVE or REJECT.";
    const user = try std.fmt.allocPrint(ctx.allocator, "Review:\n{s}", .{code});
    defer ctx.allocator.free(user);
    const verdict = try transport.complete(ctx.allocator, ctx.io, ctx, sys, user);
    defer ctx.allocator.free(verdict);

    const ok = blk: {
        var it = std.mem.tokenizeAny(u8, verdict, " \n\r.");
        while (it.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, "approve")) break :blk true;
            if (std.ascii.eqlIgnoreCase(w, "reject")) break :blk false;
        }
        break :blk true;
    };
    ctx.log("[critic] verdict: {s}", .{if (ok) "APPROVE" else "REJECT"});
    ctx.record("critic: done");
    return ok;
}
