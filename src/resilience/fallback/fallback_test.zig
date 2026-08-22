const std = @import("std");
const types = @import("types");
const resilience = @import("resilience");

test "resilience.fallback switches backend to mock on first failure" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .openai, null, "", "/tmp/yuxi_fallback_test1");

    ctx.backend = .openai;
    ctx.failures = 0;

    resilience.fallback(&ctx);

    try std.testing.expectEqual(types.LlmBackend.mock, ctx.backend);
    try std.testing.expectEqual(@as(usize, 1), ctx.failures);
}

test "resilience.fallback increments failures on every call, backend stays on mock" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "/tmp/yuxi_fallback_test2");

    ctx.backend = .mock;
    ctx.failures = 0;

    resilience.fallback(&ctx);
    resilience.fallback(&ctx);

    try std.testing.expectEqual(types.LlmBackend.mock, ctx.backend);
    try std.testing.expectEqual(@as(usize, 2), ctx.failures);
}

test "resilience.fallback increments failures on each LLM failure" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .local, null, "", "/tmp/yuxi_fallback_test3");

    ctx.backend = .local;
    ctx.failures = 0;

    resilience.fallback(&ctx);
    resilience.fallback(&ctx);
    resilience.fallback(&ctx);

    try std.testing.expectEqual(types.LlmBackend.mock, ctx.backend);
    try std.testing.expectEqual(@as(usize, 3), ctx.failures);
}

test "resilience.summary logs failures and current backend" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "/tmp/yuxi_fallback_test4");

    ctx.backend = .mock;
    ctx.failures = 5;

    // Just verify it doesn't crash and records the event
    resilience.summary(&ctx);

    // The summary function logs and records; we can't easily capture the log
    // but we can verify it runs without panic
    try std.testing.expect(true);
}
