const std = @import("std");
const mainmod = @import("mainmod");
const monitoring = @import("monitoring");
const fs = @import("fs");
test "emitReportAndExit fires the health hook only on an unhealthy run" {
    // page_allocator: std.process.run captures child stdout/stderr and can
    // exhaust std.testing.allocator's small budget (OutOfMemory), which would
    // mask a real hook-firing assertion. Page allocator matches real usage.
    const a = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // A fixture script the hook command points at; it writes a sentinel so we
    // can prove the hook actually spawned (argv[1] is the report path).
    const fixture = "/tmp/yuxi_hook_fixture.sh";
    const sentinel = "/tmp/yuxi_hook_fired";
    const report = "/tmp/yuxi_hook_report.json";

    try fs.writeFileAlloc(a, fixture, "#!/bin/sh\necho fired > " ++ sentinel ++ "\n");
    // chmod needs a real-allocator Io (the global single-threaded one has a
    // failing allocator and OOMs on spawn — same trap as evaluator.runTo).
    var threaded = std.Io.Threaded.init(a, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    defer threaded.deinit();
    _ = std.process.run(a, threaded.io(), .{ .argv = &[_][]const u8{ "chmod", "+x", fixture } }) catch {};
    _ = fs.deleteFile(io, sentinel) catch {};

    const unhealthy = monitoring.TaskResult{
        .task = "t",
        .deploys = 0,
        .retries = 0,
        .critic_rejections = 1,
        .mock_fallbacks = 0,
        .token_budgets_exceeded = 0,
        .run_time_exceeded = 0,
        .tokens = 0,
        .max_steps_exceeded = 0,
        .healthy = false,
        .verdict = "x",
    };
    const healthy = monitoring.TaskResult{
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

    // Unhealthy + hook set → hook must fire.
    const h1 = try mainmod.emitReportAndExit(a, io, report, fixture, false, null, null, unhealthy, null);
    try std.testing.expect(!h1);
    try std.testing.expect(fs.fileExists(sentinel));

    // Healthy + hook set, no --always-hook → hook must NOT fire again.
    _ = fs.deleteFile(io, sentinel) catch {};
    const h2 = try mainmod.emitReportAndExit(a, io, report, fixture, false, null, null, healthy, null);
    try std.testing.expect(h2);
    try std.testing.expect(!fs.fileExists(sentinel));

    // Healthy + --always-hook → hook fires regardless.
    const h3 = try mainmod.emitReportAndExit(a, io, report, fixture, true, null, null, healthy, null);
    try std.testing.expect(h3);
    try std.testing.expect(fs.fileExists(sentinel));

    _ = fs.deleteFile(io, sentinel) catch {};
    _ = fs.deleteFile(io, fixture) catch {};
}
test "emitReportAndExit writes a temp report when only --health-hook is set" {
    // Regression: the hook needs machine-readable input, but the user may set
    // --health-hook WITHOUT --report. emitReportAndExit must still write a
    // report (to a temp path) and pass it as argv[1], then clean it up. This
    // branch was unexercised: the existing hook test always passed a --report
    // path, so the temp-report path was dead in tests.
    const a = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const fixture = "/tmp/yuxi_hook_fixture2.sh";
    const sentinel = "/tmp/yuxi_hook_fired2";
    try fs.writeFileAlloc(a, fixture, "#!/bin/sh\necho fired > " ++ sentinel ++ "\n");
    var threaded = std.Io.Threaded.init(a, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    defer threaded.deinit();
    _ = std.process.run(a, threaded.io(), .{ .argv = &[_][]const u8{ "chmod", "+x", fixture } }) catch {};
    _ = fs.deleteFile(io, sentinel) catch {};

    const unhealthy = monitoring.TaskResult{
        .task = "t",
        .deploys = 0,
        .retries = 0,
        .critic_rejections = 1,
        .mock_fallbacks = 0,
        .token_budgets_exceeded = 0,
        .run_time_exceeded = 0,
        .tokens = 0,
        .max_steps_exceeded = 0,
        .healthy = false,
        .verdict = "x",
    };
    // No report_path: the hook must fire against a temp report, and the temp
    // file must be removed afterwards (no leftover in /tmp).
    const h = try mainmod.emitReportAndExit(a, io, null, fixture, false, null, null, unhealthy, null);
    try std.testing.expect(!h);
    try std.testing.expect(fs.fileExists(sentinel));

    _ = fs.deleteFile(io, sentinel) catch {};
    _ = fs.deleteFile(io, fixture) catch {};
}
