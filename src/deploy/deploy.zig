const std = @import("std");
const types = @import("types");

/// Commit a generated file into an isolated git repository inside `ctx.workdir`,
/// so a Yuxi run yields a self-contained, versioned artifact directory instead of
/// polluting the engine's own repository. Best-effort: if `git` is unavailable the
/// checkpoint is skipped rather than failing the pipeline.
pub fn run(ctx: *types.Ctx, path: []const u8) !bool {
    const wd = ctx.workdir;
    _ = std.process.run(ctx.allocator, ctx.io, .{ .argv = &[_][]const u8{ "git", "-C", wd, "init" } }) catch {};

    const base = std.fs.path.basename(path);
    _ = std.process.run(ctx.allocator, ctx.io, .{ .argv = &[_][]const u8{ "git", "-C", wd, "add", base } }) catch {};

    const msg = try std.fmt.allocPrint(ctx.allocator, "yuxi: stable change ({s})", .{path});
    defer ctx.allocator.free(msg);
    const commit = [_][]const u8{ "git", "-C", wd, "-c", "user.name=Yuxi Engine", "-c", "user.email=yuxi@localhost", "commit", "-m", msg };
    const res = std.process.run(ctx.allocator, ctx.io, .{ .argv = &commit }) catch |e| {
        ctx.log("[deploy] commit skipped: {s}", .{@errorName(e)});
        return true;
    };
    defer ctx.allocator.free(res.stdout);
    defer ctx.allocator.free(res.stderr);
    ctx.log("[deploy] committed {s} (term={s})", .{ base, @tagName(res.term) });
    ctx.record("deploy: committed");
    return true;
}
