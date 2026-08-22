const std = @import("std");
const types = @import("types");
const deploy = @import("deploy");
const fs = @import("fs");

test "deploy.run commits a generated artifact and reports true" {
    // Regression: a verified build must be checkpointed and reported as a
    // deploy. The first run commits the new artifact; a subsequent run with an
    // identical artifact is "nothing to commit" and must still report true
    // (already checkpointed, idempotent) so re-runs in the same workdir stay
    // green and engine.run's `ctx.deploys >= 1` holds.
    const alloc = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const wd = "/tmp/yuxi_deploy_test";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, wd) catch |e| if (e != error.FileNotFound) return e;
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, wd) catch {};
    try fs.ensureDir(alloc, wd);
    const file = try std.fmt.allocPrint(alloc, "{s}/gen_final.zig", .{wd});
    defer alloc.free(file);
    try fs.writeFileAlloc(alloc, file, "pub fn main() void {}");
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", wd);
    try std.testing.expect(try deploy.run(&ctx, file));
    try std.testing.expect(try deploy.run(&ctx, file));
}

test "deploy.run reports false when the artifact cannot be staged" {
    // A path that doesn't exist can't be `git add`ed, so no checkpoint exists.
    // The run must report false (not a swallowed "skipped") so the caller's
    // `ctx.deploys` only increments on a real, persisted checkpoint (§30).
    const alloc = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const wd = "/tmp/yuxi_deploy_bad_test";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, wd) catch |e| if (e != error.FileNotFound) return e;
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, wd) catch {};
    try fs.ensureDir(alloc, wd);
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", wd);
    try std.testing.expect(!(try deploy.run(&ctx, "/no/such/file.zig")));
}
