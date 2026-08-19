const std = @import("std");
const types = @import("../core/types.zig");
const monitoring = @import("monitoring.zig");

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
    monitoring.assessHealth(&ctx);

    var no_deploy = false;
    var budget = false;
    var exhausted = false;
    var mock_dom = false;
    for (ctx.events.items) |e| {
        if (std.mem.indexOf(u8, e, "monitoring: health WARN no deploy") != null) no_deploy = true;
        if (std.mem.indexOf(u8, e, "monitoring: health WARN token budget exceeded") != null) budget = true;
        if (std.mem.indexOf(u8, e, "monitoring: health WARN self-correction exhausted") != null) exhausted = true;
        if (std.mem.indexOf(u8, e, "monitoring: health WARN mock fallback dominated") != null) mock_dom = true;
    }
    try std.testing.expect(no_deploy);
    try std.testing.expect(budget);
    try std.testing.expect(exhausted);
    try std.testing.expect(mock_dom);
}

test "monitoring.assessHealth is silent on a healthy cycle" {
    // A cycle that deployed real work (deploys >= 1, no fallbacks, no budget
    // breach) must emit no WARN — the signal only fires when something is off.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_health_test_ok";

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.deploys = 1;
    monitoring.assessHealth(&ctx);

    for (ctx.events.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e, "monitoring: health WARN") == null);
    }
}
