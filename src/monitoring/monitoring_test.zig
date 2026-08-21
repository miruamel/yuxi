const std = @import("std");
const types = @import("types");
const monitoring = @import("monitoring");
const knowledge = @import("knowledge");
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
test "monitoring.assessHealth warns on a wall-clock cap hit" {
    // The --max-time abort is a distinct health signal (not a generic "no
    // deploy"): a run that was killed by the wall-clock cap must surface
    // "wall-time exceeded" so the KB steer and an external gate can see it.
    // Regression: this clause had no direct test — the unhealthy-cycle test
    // below sets every other counter but never run_time_exceeded, so the
    // verdict branch was unexercised.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_walltime_test";

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.deploys = 1;
    ctx.run_time_exceeded = 1;
    const hv = try monitoring.assessHealth(&ctx);
    defer if (hv.verdict.len > 0) allocator.free(hv.verdict);

    try std.testing.expect(!hv.healthy);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "wall-time exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "no deploy") == null);
}
test "monitoring.assessHealth warns on a max-steps plan-cap abort" {
    // The --max-steps abort is a distinct health signal (not a generic "no
    // deploy"): a run whose decomposition was too large must surface
    // "max-steps exceeded" so the KB steer and an external gate can see it.
    // Regression: this clause had no direct test — the unhealthy-cycle test
    // sets critic_rejections/mock_fallbacks/retries/token_budgets but never
    // max_steps_exceeded, so the verdict branch was unexercised (same gap as
    // run_time_exceeded, closed separately).
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_maxsteps_test";

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.deploys = 1;
    ctx.max_steps_exceeded = 1;
    const hv = try monitoring.assessHealth(&ctx);
    defer if (hv.verdict.len > 0) allocator.free(hv.verdict);

    try std.testing.expect(!hv.healthy);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "max-steps exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.verdict, "no deploy") == null);
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
    try monitoring.writeReport(allocator, io, path, "v0.3.0-test", single, null, null, null);
    const got = try fs.readFileAlloc(allocator, path);
    defer allocator.free(got);
    // version travels with the report so a gate can compare engine versions
    // across deploys: it's a top-level envelope field, present for both
    // single and batch reports.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"version\":\"v0.3.0-test\"") != null);
    // Regression: the single report is ONE valid top-level object — the result
    // is wrapped under "task":, not emitted as a second sibling object
    // (that produced malformed JSON: {"version":"..",{"task":..}}). A gate must
    // be able to parse the document directly.
    try std.testing.expect(got.len > 1 and got[0] == '{' and got[got.len - 1] == '}');
    try std.testing.expect(std.mem.indexOf(u8, got, "\"task\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"verdict\":\"quote\\\" inside\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"healthy\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"deploys\":0") != null);

    const batch = [_]monitoring.TaskResult{
        single,
        .{ .task = "ok task", .deploys = 1, .retries = 0, .critic_rejections = 0, .mock_fallbacks = 0, .token_budgets_exceeded = 0, .run_time_exceeded = 0, .tokens = 0, .max_steps_exceeded = 0, .healthy = true, .verdict = "" },
    };
    try monitoring.writeReport(allocator, io, path, "v0.3.0-test", null, &batch, null, null);
    const got2 = try fs.readFileAlloc(allocator, path);
    defer allocator.free(got2);
    try std.testing.expect(std.mem.indexOf(u8, got2, "\"version\":\"v0.3.0-test\"") != null);
    // Batch report is one object: "tasks":[ ... ] closes before kb_stats.
    try std.testing.expect(got2.len > 1 and got2[0] == '{' and got2[got2.len - 1] == '}');
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
    try monitoring.writeReport(allocator, io, path, "v0.4.0-test", r, null, null, null);
    const got = try fs.readFileAlloc(allocator, path);
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"tokens\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"max_steps_exceeded\":2") != null);
}

test "monitoring.writeReport composes kb_stats into the report" {
    // The read-only KB ledger summary (the --kb-stats inspector) must travel in
    // the same machine-report a gate already consumes (§12/§30). With no ledger
    // configured ("--kb" unset) the field is `null`; with a present ledger it
    // is a real object carrying the category counts, so a consumer sees what
    // the loop has learned alongside autonomy-health without a second surface.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const kb = "/tmp/yuxi_kb_stats_report.md";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, kb) catch {};

    // No --kb: kb_stats must be null, and the rest of the report is unchanged.
    const r = monitoring.TaskResult{
        .task = "t",
        .deploys = 1,
        .retries = 0,
        .critic_rejections = 0,
        .mock_fallbacks = 0,
        .token_budgets_exceeded = 0,
        .run_time_exceeded = 0,
        .tokens = 0,
        .max_steps_exceeded = 0,
        .healthy = true,
        .verdict = "",
    };
    try monitoring.writeReport(allocator, io, "/tmp/yuxi_kb_stats_null.json", "v0.6.0-test", r, null, null, null);
    const none = try fs.readFileAlloc(allocator, "/tmp/yuxi_kb_stats_null.json");
    defer allocator.free(none);
    try std.testing.expect(none.len > 1 and none[0] == '{' and none[none.len - 1] == '}');

    // With a populated ledger: kb_stats is a real object with category counts
    // matching knowledge.summarize, so the gate reads the learned lesson shape.
    const kb_content =
        \\- a task: deployed (steps=1 deploys=1 retries=0 critic_rej=0 mock_fb=0 budget_ex=0 max_steps_ex=0)
        \\- other task: failed (steps=1 deploys=0 retries=2 critic_rej=0 mock_fb=1 budget_ex=0 max_steps_ex=0)
        \\- critic rejected "panic": unsafe
        \\- health: no deploy; self-correction exhausted;
        \\- batch: tasks=2 deploys=1 unhealthy=1
    ;
    try fs.writeFileAlloc(allocator, kb, kb_content);
    defer fs.deleteFile(io, kb) catch {};
    try monitoring.writeReport(allocator, io, "/tmp/yuxi_kb_stats_obj.json", "v0.6.0-test", r, null, kb, null);
    const got = try fs.readFileAlloc(allocator, "/tmp/yuxi_kb_stats_obj.json");
    defer allocator.free(got);
    const sum = knowledge.summarize(kb_content);
    try std.testing.expect(got.len > 1 and got[0] == '{' and got[got.len - 1] == '}');
    const counts = try std.fmt.allocPrint(allocator, "\"total\":{d},\"deployed\":{d},\"failed\":{d},\"critic\":{d},\"health\":{d},\"batch\":{d},\"other\":{d}", .{ sum.total, sum.deployed, sum.failed, sum.critic, sum.health, sum.batch, sum.other });
    defer allocator.free(counts);
    try std.testing.expect(std.mem.indexOf(u8, got, counts) != null);
    // The composed object is the LAST field before the document's closing brace,
    // so the whole report stays one valid object.
    try std.testing.expect(std.mem.indexOf(u8, got, ",\"kb_stats\":{") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "}}"));
}
