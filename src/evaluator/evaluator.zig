const std = @import("std");
const types = @import("../core/types.zig");

pub fn run(ctx: *types.Ctx, path: []const u8) !bool {
    ctx.log("[evaluator] build-check: {s}", .{path});
    const argv = [_][]const u8{ "/opt/zig/zig", "ast-check", path };
    const res = std.process.run(ctx.allocator, ctx.io, .{ .argv = &argv }) catch |e| {
        ctx.log("[evaluator] spawn failed: {s}", .{@errorName(e)});
        return false;
    };
    defer ctx.allocator.free(res.stdout);
    defer ctx.allocator.free(res.stderr);

    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        ctx.log("[evaluator] build FAILED:\n{s}", .{res.stderr});
    } else {
        ctx.log("[evaluator] build OK", .{});
    }
    ctx.record("evaluator: done");
    return ok;
}
