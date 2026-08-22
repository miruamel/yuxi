const std = @import("std");
const monitoring = @import("monitoring");
const knowledge = @import("knowledge");
const fs = @import("fs");

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
