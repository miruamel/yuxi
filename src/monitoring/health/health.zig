const std = @import("std");
const types = @import("types");
const fs = @import("fs");
const report_kb_stats = @import("report_kb_stats");

/// Emit the run's autonomy metrics (counters + tokens) alongside the event
/// log, so the loop can read its own effectiveness at a glance. Purely
/// diagnostic — never alters the pipeline.
pub fn report(ctx: *types.Ctx) void {
    ctx.log("[monitoring] metrics deploys={d} retries={d} critic_rejections={d} mock_fallbacks={d} network_retries={d} token_budgets_exceeded={d} run_time_exceeded={d} tokens={d}", .{ ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.network_retries, ctx.token_budgets_exceeded, ctx.run_time_exceeded, ctx.tokens });
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
///
/// `verdict` is a caller-owned, NUL-safe slice (may be empty). The constructor
/// `taskResult` dups `HealthVerdict.verdict` into it; the caller frees it. A
/// report writer may dup it again safely — `verdict` holds no internal
/// allocator reference, so ownership is unambiguous.
pub const TaskResult = struct {
    task: []const u8,
    deploys: usize,
    retries: usize,
    critic_rejections: usize,
    mock_fallbacks: usize,
    token_budgets_exceeded: usize,
    run_time_exceeded: usize,
    /// Real LLM token spend this run (chars/4 + chars/8 + 16). Lets a gate see
    /// actual cost, not just the `token_budgets_exceeded` counter.
    tokens: usize,
    /// Times the plan hit --max-steps and decomposition was aborted. A distinct
    /// health signal (set in orchestrator), exposed so a gate can branch on *why*.
    max_steps_exceeded: usize,
    healthy: bool,
    /// Machine-readable reason the run is unhealthy (empty when healthy).
    /// Owned by the holder of the TaskResult (free alongside the other fields).
    verdict: []const u8,
};

/// Build a `TaskResult` from a finished `Ctx` and its `HealthVerdict`, owning a
/// dup of `hv.verdict`. Centralizes the borrow→own copy so the caller can free
/// `hv.verdict` immediately without stranding the report's copy. `task` is the
/// task label (from `cfg.task` / the batch line), since `Ctx` doesn't carry it.
/// On OOM during the dup, the result carries an empty verdict rather than
/// failing the whole run report.
pub fn taskResult(alloc: std.mem.Allocator, task: []const u8, ctx: *types.Ctx, hv: HealthVerdict) !TaskResult {
    // Both `task` and the verdict dup are owned by the returned struct: the
    // batch path borrows `task` from the tasks file (freed before `results`
    // is returned), so storing it directly would dangle.
    const tdup = if (task.len > 0) alloc.dupe(u8, task) catch "" else "";
    const vdup = if (hv.verdict.len > 0) alloc.dupe(u8, hv.verdict) catch "" else "";
    return .{
        .task = tdup,
        .deploys = ctx.deploys,
        .retries = ctx.retries,
        .critic_rejections = ctx.critic_rejections,
        .mock_fallbacks = ctx.mock_fallbacks,
        .token_budgets_exceeded = ctx.token_budgets_exceeded,
        .run_time_exceeded = ctx.run_time_exceeded,
        .tokens = ctx.tokens,
        .max_steps_exceeded = ctx.max_steps_exceeded,
        .healthy = hv.healthy,
        .verdict = vdup,
    };
}

/// Emit a machine-consumable run report (JSON) so CI / cron / the co-owner's
/// deploy-gating can read the engine's own autonomy-health verdict without
/// parsing the log (§30 runtime-feedback). Off by default — `report_path` is
/// null unless `--report[=FILE]` is passed.
///
/// `single` is the one `TaskResult` for a single `--task` run; `batch` is the
/// set of results from a `--tasks` run (null otherwise). Exactly one is
/// non-null. The report records `healthy` (all results healthy) so a consumer
/// can gate purely on the JSON, independent of the process exit code.
/// `version` is the build-time engine version (from `build_options`). It is
/// emitted as a top-level `"version"` field on every report so an external
/// gate comparing reports across deploys can tell which engine version
/// produced each one — a release stamp that travels with the artifact.
pub fn writeReport(allocator: std.mem.Allocator, io: std.Io, path: []const u8, version: []const u8, single: ?TaskResult, batch: ?[]const TaskResult, kb_path: ?[]const u8, kb_max_lines: ?usize) !void {
    _ = io;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buf.deinit(allocator);
    // One top-level object on every report: { "version":..., <results>, "kb_stats":... }.
    // Both the single ("task":) and batch ("batch_healthy" + "tasks":[]) shapes are
    // sibling fields of this object, so the document is always valid JSON — a gate can
    // parse it directly instead of matching substrings (the prior single shape emitted
    // two sibling objects, which is malformed; consumers must never receive that).
    try buf.appendSlice(allocator, "{\"version\":\"");
    // The version is a build constant; escape defensively in case a future
    // stamp ever contains a quote/backslash (current `git describe` output
    // cannot, but the writer must stay valid JSON either way).
    const esc_ver = report_kb_stats.escapeJson(allocator, version) catch "";
    if (esc_ver.len > 0) try buf.appendSlice(allocator, esc_ver);
    try buf.appendSlice(allocator, "\",");
    if (single) |s| {
        try buf.appendSlice(allocator, "\"task\":");
        try appendResultInner(allocator, &buf, s);
    } else if (batch) |results| {
        var all_healthy = true;
        for (results) |r| {
            if (!r.healthy) all_healthy = false;
        }
        try buf.appendSlice(allocator, "\"batch_healthy\":");
        try buf.appendSlice(allocator, if (all_healthy) "true" else "false");
        try buf.appendSlice(allocator, ",\"tasks\":[");
        for (results, 0..) |r, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try appendResultInner(allocator, &buf, r);
        }
        try buf.appendSlice(allocator, "]");
    }
    // Compose the read-only KB ledger summary into the same report (§12/§30):
    // a gate now sees both autonomy-health and what the loop has learned.
    try report_kb_stats.appendKbStats(allocator, &buf, kb_path, kb_max_lines);
    // Close the single top-level object.
    try buf.appendSlice(allocator, "}");
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try fs.ensureDir(allocator, dir);
    }
    try fs.writeFileAlloc(allocator, path, buf.items);
}

/// Minimal JSON string escape: `"`, `\`, and control chars U+0000–U+001F
/// (RFC 8259). Defined in `report_kb_stats.escapeJson`; re-exported here so
/// existing call sites (`appendResultInner`) keep the name.
pub fn escapeJson(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return report_kb_stats.escapeJson(alloc, s);
}
/// Append one TaskResult as an inner JSON object `{...}` (no field key, no
/// surrounding comma). The caller supplies the field name ("task":) and any
/// preceding/leading commas so the enclosing report object stays valid.
fn appendResultInner(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), r: TaskResult) !void {
    const esc_task = try escapeJson(alloc, r.task);
    defer alloc.free(esc_task);
    const esc_verdict = try escapeJson(alloc, r.verdict);
    defer alloc.free(esc_verdict);
    const obj = try std.fmt.allocPrint(alloc, "{{\"task\":\"{s}\",\"deploys\":{d},\"retries\":{d},\"critic_rejections\":{d},\"mock_fallbacks\":{d},\"token_budgets_exceeded\":{d},\"run_time_exceeded\":{d},\"tokens\":{d},\"max_steps_exceeded\":{d},\"healthy\":{s},\"verdict\":\"{s}\"}}", .{
        esc_task, r.deploys, r.retries, r.critic_rejections, r.mock_fallbacks, r.token_budgets_exceeded, r.run_time_exceeded, r.tokens, r.max_steps_exceeded, if (r.healthy) "true" else "false", esc_verdict,
    });
    defer alloc.free(obj);
    try buf.appendSlice(alloc, obj);
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
    if (ctx.max_steps_exceeded > 0) {
        ctx.log("[monitoring][health] WARN plan exceeded --max-steps {d} time(s); decomposition aborted", .{ctx.max_steps_exceeded});
        ctx.record("monitoring: health WARN plan exceeded max-steps");
        verdict.appendSlice(ctx.allocator, "max-steps exceeded; ") catch {};
    }
    if (ctx.run_time_exceeded > 0) {
        ctx.log("[monitoring][health] WARN wall-clock cap --max-time exceeded {d} time(s); run aborted", .{ctx.run_time_exceeded});
        ctx.record("monitoring: health WARN wall-clock cap exceeded");
        verdict.appendSlice(ctx.allocator, "wall-time exceeded; ") catch {};
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
