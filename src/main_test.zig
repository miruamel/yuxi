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
}

test "main exits non-zero on a CLI parse error, zero on --help" {
    // Regression guard for the §30 exit-code contract (#18/#19/#21): a malformed
    // invocation must NOT exit 0 — otherwise CI/cron gating treats a failed
    // parse as a healthy run. The binary is assumed built (CI runs `zig build`
    // before `zig build test`, same as evaluator.run's real-subprocess tests).
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    defer threaded.deinit();
    const bin = "zig-out/bin/yuxi";

    // Missing --task → MissingTask → exit 1.
    const missing = try std.process.run(a, threaded.io(), .{ .argv = &[_][]const u8{ bin, "--no-hitl", "--mock" } });
    defer a.free(missing.stdout);
    defer a.free(missing.stderr);
    try std.testing.expect(missing.term == .exited and missing.term.exited == 1);

    // --help → HelpRequested → exit 0 (a successful info request, not an error).
    const help = try std.process.run(a, threaded.io(), .{ .argv = &[_][]const u8{ bin, "--help" } });
    defer a.free(help.stdout);
    defer a.free(help.stderr);
    try std.testing.expect(help.term == .exited and help.term.exited == 0);
}

test "main --version prints the build stamp and exits zero" {
    // The version comes from git describe at build time; a gate or operator
    // can read `yuxi vX.Y.Z-...` from stdout. Assert the exact prefix so the
    // contract (not just a non-empty line) is locked.
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    const bin = "zig-out/bin/yuxi";
    const ver = try std.process.run(a, threaded.io(), .{ .argv = &[_][]const u8{ bin, "--version" } });
    defer a.free(ver.stdout);
    defer a.free(ver.stderr);
    try std.testing.expect(ver.term == .exited and ver.term.exited == 0);
    // stdout has a trailing newline from logLine; trim it before matching.
    const out = std.mem.trim(u8, ver.stdout, "\r\n");
    try std.testing.expect(std.mem.startsWith(u8, out, "yuxi v"));
}
