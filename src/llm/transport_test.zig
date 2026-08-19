const std = @import("std");
const types = @import("../core/types.zig");
const engine = @import("../core/engine.zig");
const transport = @import("transport.zig");
const fs = @import("../util/fs.zig");

test "transport.complete serves recorded responses in order (offline replay)" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "/tmp/yuxi_replay_unit.txt";
    const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, path, .{});
    defer file.close();
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.writeAll(
        \\REPLAY_MARKER_ALPHA
        \\---
        \\REPLAY_MARKER_BETA
        \\---
        \\REPLAY_MARKER_GAMMA
    );

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .openai, null, "", "/tmp");
    ctx.replay_path = path;

    const a1 = try transport.complete(allocator, io, &ctx, "sys1", "user1");
    defer allocator.free(a1);
    try std.testing.expectEqualStrings("REPLAY_MARKER_ALPHA", a1);

    const a2 = try transport.complete(allocator, io, &ctx, "sys2", "user2");
    defer allocator.free(a2);
    try std.testing.expectEqualStrings("REPLAY_MARKER_BETA", a2);

    const a3 = try transport.complete(allocator, io, &ctx, "sys3", "user3");
    defer allocator.free(a3);
    try std.testing.expectEqualStrings("REPLAY_MARKER_GAMMA", a3);
    try std.testing.expectEqual(ctx.replay_idx, 3);
}

test "engine.run drives the real openai backend offline via --replay" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_replay_e2e";
    const replay_path = "/tmp/yuxi_replay_e2e.md";
    try fs.ensureDir(allocator, workdir);

    // 7 recorded entries in the engine's exact call order: decomposer, then per
    // step (builder, critic) x3. Authoring matches the real call sequence
    // (orchestrator -> builder -> critic per step), so replay replaces the
    // network without changing engine behavior.
    const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, replay_path, .{});
    defer file.close();
    var buf: [8192]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.writeAll(
        \\STEP: design the function signature
        \\STEP: implement the body
        \\STEP: add a unit test
        \\---
        \\pub fn step0() void {
        \\    const a: i32 = 2;
        \\    const b: i32 = 3;
        \\    _ = a + b;
        \\}
        \\---
        \\APPROVE
        \\---
        \\pub fn step1() void {
        \\    const a: i32 = 2;
        \\    const b: i32 = 3;
        \\    _ = a + b;
        \\}
        \\---
        \\APPROVE
        \\---
        \\pub fn step2() void {
        \\    const a: i32 = 2;
        \\    const b: i32 = 3;
        \\    const sum = a + b;
        \\    std.debug.print("step result: 2+3={d}\n", .{sum});
        \\}
        \\---
        \\APPROVE
    );

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .openai, null, "", workdir);
    ctx.replay_path = replay_path;
    try engine.run(allocator, io, &ctx, "design a calculator");

    try std.testing.expect(ctx.deploys >= 1);
    try std.testing.expectEqual(ctx.critic_rejections, 0);
    try std.testing.expectEqual(ctx.mock_fallbacks, 0);
}
