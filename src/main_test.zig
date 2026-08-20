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
        .healthy = true,
        .verdict = "",
    };

    // Unhealthy + hook set → hook must fire.
    const h1 = try mainmod.emitReportAndExit(a, io, report, fixture, false, unhealthy, null);
    try std.testing.expect(!h1);
    try std.testing.expect(fs.fileExists(sentinel));

    // Healthy + hook set, no --always-hook → hook must NOT fire again.
    _ = fs.deleteFile(io, sentinel) catch {};
    const h2 = try mainmod.emitReportAndExit(a, io, report, fixture, false, healthy, null);
    try std.testing.expect(h2);
    try std.testing.expect(!fs.fileExists(sentinel));

    // Healthy + --always-hook → hook fires regardless.
    const h3 = try mainmod.emitReportAndExit(a, io, report, fixture, true, healthy, null);
    try std.testing.expect(h3);
    try std.testing.expect(fs.fileExists(sentinel));

    _ = fs.deleteFile(io, sentinel) catch {};
    _ = fs.deleteFile(io, fixture) catch {};
    _ = fs.deleteFile(io, report) catch {};
}
