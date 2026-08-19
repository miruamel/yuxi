const std = @import("std");
const types = @import("../core/types.zig");

pub fn run(ctx: *types.Ctx, path: []const u8) !bool {
    ctx.log("[deploy] git checkpoint for {s}", .{path});
    const add = [_][]const u8{ "git", "add", path };
    _ = std.process.run(ctx.allocator, ctx.io, .{ .argv = &add }) catch {};

    const msg = try std.fmt.allocPrint(ctx.allocator, "yuxi: stable change ({s})", .{path});
    defer ctx.allocator.free(msg);
    const commit = [_][]const u8{ "git", "commit", "-m", msg };
    const res = std.process.run(ctx.allocator, ctx.io, .{ .argv = &commit }) catch |e| {
        ctx.log("[deploy] commit skipped: {s}", .{@errorName(e)});
        return true;
    };
    defer ctx.allocator.free(res.stdout);
    defer ctx.allocator.free(res.stderr);
    ctx.log("[deploy] committed (term={s})", .{@tagName(res.term)});
    ctx.record("deploy: committed");
    return true;
}
