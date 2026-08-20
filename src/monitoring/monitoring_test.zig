const std = @import("std");
const types = @import("types");
const monitoring = @import("monitoring");

test "monitoring.assessHealth warns on an unhealthy cycle" {
    // A cycle that tried, fell back to mock, exhausted retries, and shipped
    // nothing must surface every applicable WARN so the loop can self-assess.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_health_test";

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.critic_rejections = 2;
    ctx.mock_fallbacks = 1;
    ctx.retries = 1;
    ctx.deploys = 0;
    ctx.token_budgets_exceeded = 1;
    const hv = try monitoring.assessHealth(&ctx);
    defer if (hv.verdict.len > 0) allocator.free(hv.verdict);

    try std.testing.expect(!hv.healthy);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "no deploy") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "token budget exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "self-correction exhausted") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "mock fallback dominated") != null);
}

test "monitoring.assessHealth is silent on a healthy cycle" {
    // A cycle that deployed real work (deploys >= 1, no fallbacks, no budget
    // breach) must emit no WARN — the signal only fires when something is off.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_health_test_ok";

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.deploys = 1;
    const hv = try monitoring.assessHealth(&ctx);
    defer if (hv.verdict.len > 0) allocator.free(hv.verdict);
    try std.testing.expect(hv.healthy);
    try std.testing.expectEqualStrings("", hv.verdict);
    for (ctx.events.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e, "monitoring: health WARN") == null);
    }
}
