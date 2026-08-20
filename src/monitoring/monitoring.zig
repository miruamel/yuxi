const std = @import("std");
const types = @import("types");
const fs = @import("fs");

/// Emit the run's autonomy metrics (counters + tokens) alongside the event
/// log, so the loop can read its own effectiveness at a glance. Purely
/// diagnostic — never alters the pipeline.
pub fn report(ctx: *types.Ctx) void {
    ctx.log("[monitoring] metrics deploys={d} retries={d} critic_rejections={d} mock_fallbacks={d} network_retries={d} token_budgets_exceeded={d} tokens={d}", .{ ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.network_retries, ctx.token_budgets_exceeded, ctx.tokens });
    ctx.record("monitoring: metrics logged");
}

/// End-of-run autonomy-health verdict (§30/§32). Purely diagnostic: inspects
/// the loop's own counters and warns when they indicate an unhealthy cycle, so
/// the autonomous loop can read its effectiveness. No behavior change — it
/// never alters the pipeline.
///
/// Single source of truth for "is this cycle healthy". `healthy` is true iff
/// `verdict` is empty (no WARN fired); `loop.runTasks` and `engine.finishRun`
/// must both read health from here rather than re-deriving it, so a batch
/// report can never disagree with the per-cycle verdict persisted to the KB.
///
/// `verdict` is caller-owned and must be freed. `healthy` is just
/// `verdict.len == 0`, surfaced alongside for convenience.
/// One engine.run cycle's autonomy-health result. Public + owned by
/// `monitoring` so both `loop.runTasks` (batch) and `main` (single run) share a
/// single result shape instead of each defining their own copy.
pub const TaskResult = struct {
    task: []const u8,
    deploys: usize,
    retries: usize,
    critic_rejections: usize,
    mock_fallbacks: usize,
    token_budgets_exceeded: usize,
    healthy: bool,
};

/// Emit a machine-consumable run report (JSON) so CI / cron / the co-owner's
/// deploy-gating can read the engine's own autonomy-health verdict without
/// parsing the log (§30 runtime-feedback). Off by default — `report_path` is
/// null unless `--report[=FILE]` is passed.
///
/// `single` is the one `TaskResult` for a single `--task` run; `batch` is the
/// set of results from a `--tasks` run (null otherwise). Exactly one is
/// non-null. The report records `healthy` (all results healthy) so a consumer
/// can gate purely on the JSON, independent of the process exit code.
pub fn writeReport(allocator: std.mem.Allocator, io: std.Io, path: []const u8, single: ?TaskResult, batch: ?[]const TaskResult) !void {
    _ = io;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buf.deinit(allocator);
    if (single) |s| {
        try appendResult(allocator, &buf, s);
    } else if (batch) |results| {
        var all_healthy = true;
        for (results) |r| {
            if (!r.healthy) all_healthy = false;
        }
        try buf.appendSlice(allocator, "{\"batch_healthy\":");
        try buf.appendSlice(allocator, if (all_healthy) "true" else "false");
        try buf.appendSlice(allocator, ",\"tasks\":[");
        for (results, 0..) |r, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try appendResult(allocator, &buf, r);
        }
        try buf.appendSlice(allocator, "]}");
    }
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try fs.ensureDir(allocator, dir);
    }
    try fs.writeFileAlloc(allocator, path, buf.items);
}

/// Append one `TaskResult` as a JSON object to `buf`. String fields are escaped
/// (control chars + `"`/`\`) so semi-trusted task text can never break the
/// document — same discipline as `http.jsonEscape`.
fn appendResult(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), r: TaskResult) !void {
    const esc = try escapeJson(alloc, r.task);
    defer alloc.free(esc);
    const obj = try std.fmt.allocPrint(alloc, "{{\"task\":\"{s}\",\"deploys\":{d},\"retries\":{d},\"critic_rejections\":{d},\"mock_fallbacks\":{d},\"token_budgets_exceeded\":{d},\"healthy\":{s}}}", .{
        esc, r.deploys, r.retries, r.critic_rejections, r.mock_fallbacks, r.token_budgets_exceeded, if (r.healthy) "true" else "false",
    });
    defer alloc.free(obj);
    try buf.appendSlice(alloc, obj);
}

/// Minimal JSON string escape: `"`, `\`, and control chars U+0000–U+001F
/// (RFC 8259). Reused so a report never carries malformed JSON from a task
/// containing raw control bytes.
fn escapeJson(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            else => {
                if (c < 0x20) {
                    var ebuf: [6]u8 = undefined;
                    const n = std.fmt.bufPrint(&ebuf, "\\u{X:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(alloc, ebuf[0..n.len]);
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    return out.toOwnedSlice(alloc);
}
pub const HealthVerdict = struct {
    verdict: []const u8,
    healthy: bool,
};
pub fn assessHealth(ctx: *types.Ctx) !HealthVerdict {
    var verdict = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
    if (ctx.deploys == 0) {
        ctx.log("[monitoring][health] WARN no deploy this cycle: critic_rejections={d} mock_fallbacks={d} retries={d}", .{ ctx.critic_rejections, ctx.mock_fallbacks, ctx.retries });
        ctx.record("monitoring: health WARN no deploy");
        verdict.appendSlice(ctx.allocator, "no deploy; ") catch {};
    }
    if (ctx.token_budgets_exceeded > 0) {
        ctx.log("[monitoring][health] WARN token budget exceeded {d} time(s)", .{ctx.token_budgets_exceeded});
        ctx.record("monitoring: health WARN token budget exceeded");
        verdict.appendSlice(ctx.allocator, "token budget exceeded; ") catch {};
    }
    if (ctx.retries > 0 and ctx.deploys == 0) {
        ctx.log("[monitoring][health] WARN self-correction exhausted without a deploy", .{});
        ctx.record("monitoring: health WARN self-correction exhausted");
        verdict.appendSlice(ctx.allocator, "self-correction exhausted; ") catch {};
    }
    if (ctx.mock_fallbacks > ctx.deploys) {
        ctx.log("[monitoring][health] WARN mock fallback dominated this cycle (mock_fallbacks={d} > deploys={d})", .{ ctx.mock_fallbacks, ctx.deploys });
        ctx.record("monitoring: health WARN mock fallback dominated");
        verdict.appendSlice(ctx.allocator, "mock fallback dominated; ") catch {};
    }
    const owned = verdict.toOwnedSlice(ctx.allocator) catch "";
    return .{ .verdict = owned, .healthy = owned.len == 0 };
}
