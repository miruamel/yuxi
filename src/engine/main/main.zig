const std = @import("std");
const config = @import("config");
const engine = @import("engine");
const loop = @import("loop");
const monitoring = @import("monitoring");
const types = @import("types");
const fs = @import("fs");
const knowledge = @import("knowledge");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    // `parse` prints help and returns `error.HelpRequested` for `--help`
    // (a successful info request → exit 0) or `error.MissingTask` for a
    // genuine usage error. A real parse failure must exit non-zero so CI/cron
    // gating (the §30 exit-code contract from #18/#19/#21) isn't fooled into
    // treating malformed invocation as a healthy run.
    // `parse` also returns `error.VersionRequested` for `--version`/`-V` (a
    // successful info request → exit 0, same as `--help`).
    const cfg = config.parse(arena, io, &it) catch |e| {
        if (e != error.HelpRequested and e != error.VersionRequested) std.process.exit(1);
        return;
    };

    // `--kb-stats` is a read-only inspector: summarize the configured ledger
    // and exit 0 without running the engine. This is the §30/§24 observability
    // surface for what the autonomous loop has learned — a co-owner or audit
    // can read it without triggering a run or parsing raw ledger lines.
    if (cfg.kb_stats) {
        try knowledge.printStats(arena, io, cfg.kb_path, cfg.kb_max_lines);
        return;
    }

    if (cfg.tasks) |tasks_path| {
        var results = try loop.runTasks(arena, io, init.minimal.environ, cfg, tasks_path);
        const healthy = try emitReportAndExit(arena, io, cfg.report_path, cfg.health_hook, cfg.always_hook, cfg.kb_path, cfg.kb_max_lines, null, results.items);
        // results owns task+verdict dups per element; deinit only frees the
        // array, so release the element slices explicitly before tearing down.
        for (results.items) |r| {
            arena.free(r.task);
            arena.free(r.verdict);
        }
        results.deinit(arena);
        if (!healthy) std.process.exit(1);
        return;
    }
    var ctx = try engine.newCtx(arena, io, init.minimal.environ, cfg, cfg.workdir);
    try engine.run(arena, io, &ctx, cfg.task);
    // The run's health verdict is computed once from the single source of truth
    // (monitoring.assessHealth). A healthy run exits 0; an unhealthy one exits 1
    // so CI/cron can gate on process status (§30); the optional --report JSON
    // carries the same verdict to machine consumers.
    const hv = try monitoring.assessHealth(&ctx);
    // taskResult dups hv.verdict into single.verdict; free both. The report
    // (inside emitReportAndExit) reads single by reference and does not own it.
    const single = try monitoring.taskResult(arena, cfg.task, &ctx, hv);
    defer arena.free(single.verdict);
    const healthy = try emitReportAndExit(arena, io, cfg.report_path, cfg.health_hook, cfg.always_hook, cfg.kb_path, cfg.kb_max_lines, single, null);
    ctx.allocator.free(hv.verdict);
    if (!healthy) std.process.exit(1);
}

/// Write the optional `--report` JSON and return whether all reported results
/// are healthy. Centralizes the health→exit mapping so both the single-run and
/// batch paths use the identical policy.
/// Write the optional `--report` JSON, then (if configured) spawn the health
/// hook command with the report path as its first argument. The hook fires
/// when the run is unhealthy, or always when `--always-hook` is set. This is
/// the engine's extension point for external gating (CI, a co-owner deploy
/// policy) — it makes the verdict observable to a consumer without the engine
/// implementing the gate itself (issue #2 fork is intentionally NOT built here).
/// A hook failure is logged but never changes the process exit status.
pub fn emitReportAndExit(alloc: std.mem.Allocator, io: std.Io, report_path: ?[]const u8, hook: ?[]const u8, always_hook: bool, kb_path: ?[]const u8, kb_max_lines: ?usize, single: ?monitoring.TaskResult, batch: ?[]const monitoring.TaskResult) !bool {
    const version = comptime @import("build_options").version;
    var all_healthy = true;
    if (single) |s| all_healthy = s.healthy;
    if (batch) |b| for (b) |r| {
        if (!r.healthy) all_healthy = false;
    };
    // Determine where the report lives for the hook. Prefer the user's
    // --report path; if a hook is set but no report was requested, write a
    // temp report so the hook still receives machine-readable input.
    var report_for_hook: ?[]const u8 = report_path;
    var tmp_report: ?[]const u8 = null;
    if (hook != null and report_for_hook == null) {
        tmp_report = try std.fmt.allocPrint(alloc, "/tmp/.yuxi_hook_report_{}.json", .{hook_seq});
        hook_seq += 1;
        report_for_hook = tmp_report;
    }
    if (report_for_hook) |p| {
        monitoring.writeReport(alloc, io, p, version, single, batch, kb_path, kb_max_lines) catch |e| types.logLine(io, "[main] report write failed: {s}", .{@errorName(e)});
    }
    if (hook) |cmd| {
        if (!all_healthy or always_hook) {
            // report_for_hook is always non-null here: either the user passed
            // --report, or we wrote a temp report above. Pass it as argv[1].
            const argv = [_][]const u8{ cmd, report_for_hook.? };
            types.logLine(io, "[main] firing health hook: {s}", .{cmd});
            // The caller's `io` (typically the global single-threaded one) has
            // a failing allocator, so spawning through it OOMs (see
            // evaluator.runTo). Build a per-call Threaded io backed by a real
            // allocator — the same workaround — so the hook actually fires.
            var threaded = std.Io.Threaded.init(alloc, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
            defer threaded.deinit();
            _ = std.process.run(alloc, threaded.io(), .{ .argv = &argv }) catch |e| types.logLine(io, "[main] health hook failed: {s}", .{@errorName(e)});
        }
    }
    if (tmp_report) |p| fs.deleteFile(io, p) catch {};
    return all_healthy;
}

var hook_seq: usize = 0;
