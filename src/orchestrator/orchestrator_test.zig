const std = @import("std");
const types = @import("types");
const fs = @import("fs");
const engine = @import("engine");

// End-to-end guard for `--max-steps`: with the cap set below the mock
// decomposer's fixed 3-step plan, the orchestrator must abort before any
// codegen/build/deploy. Mirrors the plan-gate test's abort assertions but
// exercises the decomposition-size bound specifically (not the critic).
test "engine.run aborts on a plan exceeding max-steps before codegen" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_max_steps_test";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
    try fs.ensureDir(allocator, workdir);

    // max_steps=2 but the mock decomposer always returns a 3-step plan, so the
    // orchestrator must abort before any codegen/build/deploy.
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.max_steps = 2;

    try engine.run(allocator, io, &ctx, "design a calculator");

    // Plan exceeded the cap -> run aborts at the orchestrator: nothing built or
    // deployed, and the critic was never reached (critic_rejections stays 0).
    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(!fs.fileExists(final_path));
    try std.testing.expect(ctx.deploys == 0);
    try std.testing.expect(ctx.critic_rejections == 0);
}
