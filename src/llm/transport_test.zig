const std = @import("std");
const types = @import("types");
const engine = @import("engine");
const transport = @import("transport");
const fs = @import("fs");

test "transport.complete serves recorded responses in order (offline replay)" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "/tmp/yuxi_replay_unit.txt";
    const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(
        \\REPLAY_MARKER_ALPHA
        \\---
        \\REPLAY_MARKER_BETA
        \\---
        \\REPLAY_MARKER_GAMMA
    );
    try w.flush();

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

    // 8 recorded entries in the engine's exact call order: decomposer, plan
    // review, then per step (builder, critic) x3. Authoring matches the real
    // call sequence (orchestrator -> plan critic -> builder -> critic per
    // step), so replay replaces the network without changing engine behavior.
    const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, replay_path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(
        \\STEP: design the function signature
        \\STEP: implement the body
        \\STEP: add a unit test
        \\---
        \\APPROVE
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
    try w.flush();

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .openai, null, "", workdir);
    ctx.replay_path = replay_path;
    try engine.run(allocator, io, &ctx, "design a calculator");

    try std.testing.expect(ctx.deploys >= 1);
    try std.testing.expectEqual(ctx.critic_rejections, 0);
    try std.testing.expectEqual(ctx.mock_fallbacks, 0);
}

test "engine.run records a replay-compatible transcript (mock capture -> offline replay)" {
    // Capture a real run's completions (mock backend) into a file, then drive
    // the real .openai backend path OFFLINE through that transcript. Deploys
    // again with zero API key / network => --record produced --replay-compatible
    // output, closing the record/replay loop end-to-end.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const rec_path = "/tmp/yuxi_record_e2e.txt";
    const workdir = "/tmp/yuxi_record_run";
    fs.deleteFile(io, rec_path) catch {};
    try fs.ensureDir(allocator, workdir);

    var ctx1 = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx1.record_path = rec_path;
    try engine.run(allocator, io, &ctx1, "design a calculator");
    try std.testing.expect(ctx1.deploys >= 1);
    try std.testing.expect(fs.fileExists(rec_path));

    var ctx2 = try types.Ctx.init(allocator, io, .empty, .no_hitl, .openai, null, "", workdir);
    ctx2.replay_path = rec_path;
    try engine.run(allocator, io, &ctx2, "design a calculator");
    try std.testing.expect(ctx2.deploys >= 1);
    try std.testing.expectEqual(ctx2.critic_rejections, 0);
    try std.testing.expectEqual(ctx2.mock_fallbacks, 0);
}
