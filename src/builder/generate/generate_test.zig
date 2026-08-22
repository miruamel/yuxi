const std = @import("std");
const types = @import("types");
const builder = @import("builder");
const fs = @import("fs");

test "builder.run falls back to mock on LLM failure and counts it" {
    // Regression: builder.run used resilience.fallback() on a transport error
    // but never incremented ctx.mock_fallbacks, so the autonomy-health signal
    // ("mock fallback dominated") under-counted builder-level fallbacks while
    // step-level critic fallbacks (step.zig) did count them. The mock count
    // must rise on a builder LLM failure so assessHealth can detect a
    // mock-dominated cycle regardless of where the fallback originated.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_builder_fallback_test";
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
    fs.ensureDir(allocator, workdir) catch {};

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .openai, null, "", workdir);
    ctx.llm_fn = struct {
        fn f(alloc: std.mem.Allocator, _: std.Io, c: *types.Ctx, sys: []const u8, _: []const u8) anyerror![]u8 {
            // Fail the builder's first generate call only; the fallback call
            // re-enters with the same sys, so gate on failures (bumped by the
            // first resilience.fallback) to succeed on the second attempt.
            if (c.failures == 0 and std.mem.indexOf(u8, sys, "code generator") != null) {
                return error.ConnectionRefused;
            }
            return alloc.dupe(u8,
                \\pub fn step0() void {
                \\    const a: i32 = 2;
                \\    const b: i32 = 3;
                \\    _ = a + b;
                \\}
            );
        }
    }.f;

    var step = types.Step{ .id = 0, .name = "add two ints", .status = .pending, .notes = "" };
    const path = try std.fmt.allocPrint(allocator, "{s}/gen_0.zig", .{workdir});
    defer allocator.free(path);

    const ok = try builder.run(&ctx, &step, path, null);
    try std.testing.expect(ok);
    try std.testing.expect(step.status == .ok);
    try std.testing.expect(ctx.mock_fallbacks == 1);
    try std.testing.expect(ctx.failures == 1);
    try std.testing.expect(fs.fileExists(path));
}
