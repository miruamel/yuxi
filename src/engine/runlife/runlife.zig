const std = @import("std");
const types = @import("types");
const resilience = @import("resilience");
const knowledge = @import("knowledge");
const monitoring = @import("monitoring");
const fs = @import("fs");

/// LAYER 7-9 tail: resilience summary, knowledge ledger (outcome lesson +
/// persisted health verdict), and monitoring metrics. Runs on EVERY exit path
/// — including the early aborts at the gateway, orchestrator, and plan critic —
/// so a rejected plan still records its outcome (critic_rej=N), the health
/// verdict, and the metrics. This keeps the learning loop closed for that class
/// of failure: without it, a plan-level rejection skipped recordLesson (the
/// numeric critic_rej counter was lost from the ledger) and assessHealth
/// (no health verdict persisted), so the next cycle's injectPrompt never saw
/// a plan-shaped failure to steer away from.
pub fn finishRun(ctx: *types.Ctx, verified: bool, steps_len: usize, task_label: []const u8) !void {
    // LAYER 7: Resilience summary
    resilience.summary(ctx);
    // LAYER 8: Knowledge
    if (verified) {
        knowledge.log(ctx, "task pipeline complete; artifact deployed");
    } else {
        knowledge.log(ctx, "task pipeline finished; nothing deployed");
    }
    if (ctx.kb_path) |_| {
        knowledge.recordLesson(ctx, task_label, steps_len) catch |e| ctx.log("[knowledge] save failed: {s}", .{@errorName(e)});
    }
    // LAYER 9: Monitoring — collect the autonomy-health verdict (single source
    // of truth), then persist it to the KB so the next cycle's injectPrompt can
    // steer away from the exact failure mode (closes the monitoring->knowledge
    // learning loop).
    monitoring.report(ctx);
    const hv = try monitoring.assessHealth(ctx);
    if (ctx.kb_path) |_| {
        knowledge.recordHealth(ctx, hv.verdict) catch |e| ctx.log("[knowledge] health save failed: {s}", .{@errorName(e)});
    }
    ctx.allocator.free(hv.verdict);
    types.logLine(ctx.io, "[engine] done. events={d}", .{ctx.events.items.len});
}

/// Flush captured LLM responses (Ctx.recorded) to Ctx.record_path as a
/// `--replay`-compatible transcript. No-op unless record_path is set and at
/// least one response was captured. Called via `defer` at the end of run so
/// every exit path (including early aborts) writes the transcript.
pub fn flushRecord(allocator: std.mem.Allocator, ctx: *types.Ctx) void {
    const rp = ctx.record_path orelse return;
    if (ctx.recorded.items.len == 0) return;
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return;
    defer buf.deinit(allocator);
    for (ctx.recorded.items, 0..) |e, i| {
        if (i > 0) buf.appendSlice(allocator, "\n---\n") catch {};
        buf.appendSlice(allocator, e) catch {};
    }
    const content = buf.toOwnedSlice(allocator) catch return;
    defer allocator.free(content);
    fs.writeFileAlloc(allocator, rp, content) catch |e| ctx.log("[transport] record write failed: {s}", .{@errorName(e)});
}

/// Resolve the current monotonic-clock value (ns). Prefers an injected
/// `Ctx.clock_ns` so the `--max-time` cap is testable deterministically;
/// falls back to the live `std.os.linux.clock_gettime` for production runs.
pub fn clockNs(ctx: *types.Ctx) u64 {
    if (ctx.clock_ns) |f| return f();
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

/// Wall-clock cap check shared by the pre-loop and per-attempt guards.
/// Returns the configured cap (ms) when the run has exceeded it, else null.
/// `start_ns` is null when no cap is set, so the check is a no-op off by default.
pub fn wallClockExceeded(ctx: *types.Ctx, start_ns: ?u64) ?usize {
    const t0 = start_ns orelse return null;
    const ms = ctx.max_time_ms orelse return null;
    if (clockNs(ctx) - t0 >= ms * std.time.ns_per_ms) return ms;
    return null;
}
