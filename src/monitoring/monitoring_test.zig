const std = @import("std");
const types = @import("types");
const monitoring = @import("monitoring");
const fs = @import("fs");

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

test "monitoring.writeReport emits verdict + escapes it" {
    // The report must carry the machine-readable verdict so a CI/gate consumer
    // can branch on *why* a run is unhealthy, not just the boolean. A verdict
    // containing a JSON-breaking char (double-quote) must be escaped.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "/tmp/yuxi_report_test.json";

    const single = monitoring.TaskResult{
        .task = "ship the thing",
        .deploys = 0,
        .retries = 0,
        .critic_rejections = 1,
        .mock_fallbacks = 0,
        .token_budgets_exceeded = 0,
        .run_time_exceeded = 0,
        .tokens = 0,
        .max_steps_exceeded = 0,
        .healthy = false,
        .verdict = "quote\" inside",
    };
    // Write through monitoring.writeReport (which uses the posix-backed fs
    // layer), then read back through the same layer so the read is
    // deterministic across runners and concurrent test binaries.
    try monitoring.writeReport(allocator, io, path, "v0.3.0-test", single, null);
    const got = try fs.readFileAlloc(allocator, path);
    defer allocator.free(got);
    // version travels with the report so a gate can compare engine versions
    // across deploys: it's a top-level envelope field, present for both
    // single and batch reports.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"version\":\"v0.3.0-test\"") != null);
    // verdict present; the JSON-breaking quote is escaped to \", the doc stays
    // valid JSON.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"verdict\":\"quote\\\" inside\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"healthy\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"deploys\":0") != null);

    const batch = [_]monitoring.TaskResult{
        single,
        .{ .task = "ok task", .deploys = 1, .retries = 0, .critic_rejections = 0, .mock_fallbacks = 0, .token_budgets_exceeded = 0, .run_time_exceeded = 0, .tokens = 0, .max_steps_exceeded = 0, .healthy = true, .verdict = "" },
    };
    try monitoring.writeReport(allocator, io, path, "v0.3.0-test", null, &batch);
    const got2 = try fs.readFileAlloc(allocator, path);
    defer allocator.free(got2);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"version\":\"v0.3.0-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"batch_healthy\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"tasks\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"verdict\":\"\"") != null);
}

test "monitoring.writeReport exposes tokens and max_steps_exceeded" {
    // Regression: the JSON report must carry real token spend and the
    // --max-steps abort counter so an external CI gate can see actual cost
    // and plan-cap violations, not just the boolean verdict. Previously the
    // report dropped both, leaving a gate blind to cost/plan-cap signals.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "/tmp/yuxi_report_fields_test.json";
    const r = monitoring.TaskResult{
        .task = "t",
        .deploys = 1,
        .retries = 0,
        .critic_rejections = 0,
        .mock_fallbacks = 0,
        .token_budgets_exceeded = 0,
        .run_time_exceeded = 0,
        .tokens = 42,
        .max_steps_exceeded = 2,
        .healthy = true,
        .verdict = "",
    };
    try monitoring.writeReport(allocator, io, path, "v0.4.0-test", r, null);
    const got = try fs.readFileAlloc(allocator, path);
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"tokens\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"max_steps_exceeded\":2") != null);
}
