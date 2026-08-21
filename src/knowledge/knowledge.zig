const std = @import("std");
const types = @import("types");
const store = @import("store");

/// Append a structured event to the engine's in-memory knowledge log.
pub fn log(ctx: *types.Ctx, text: []const u8) void {
    ctx.log("[knowledge] {s}", .{text});
    ctx.record(text);
}

// Re-export the storage primitives so existing callers (tests, engine) keep
// using `knowledge.load`/`knowledge.save` after the extract to `store.zig`.
pub const load = store.load;
pub const save = store.save;
pub const appendUnique = store.appendUnique;

/// Persist a per-run lesson to the configured knowledge base; no-op when none
/// is set. The lesson captures outcome plus the degradation counters (critic
/// rejections, mock fallbacks, token-budget breaches, and max-steps cap hits)
/// so a later run that replays prior lessons via `injectPrompt` sees *how* a
/// prior cycle went, not just whether it deployed. On a failed run with a
/// captured evaluator error, the trimmed error is appended (see `errSnippet`)
/// so the next run also learns *why* it failed — closing the learning loop for
/// non-critic failures too, not only for critic rejections (`recordCritic`).
pub fn recordLesson(ctx: *types.Ctx, task: []const u8, steps: usize) !void {
    if (ctx.kb_path) |kb| {
        const outcome = if (ctx.deploys > 0) "deployed" else "failed";
        const err = if (ctx.deploys == 0) errSnippet(ctx) else null;
        defer if (err) |e| ctx.allocator.free(e);
        const lesson = if (err) |e|
            try std.fmt.allocPrint(
                ctx.allocator,
                "- {s}: {s} (steps={d} deploys={d} retries={d} critic_rej={d} mock_fb={d} budget_ex={d} max_steps_ex={d}) error=\"{s}\"",
                .{ task, outcome, steps, ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.token_budgets_exceeded, ctx.max_steps_exceeded, e },
            )
        else
            try std.fmt.allocPrint(
                ctx.allocator,
                "- {s}: {s} (steps={d} deploys={d} retries={d} critic_rej={d} mock_fb={d} budget_ex={d} max_steps_ex={d})",
                .{ task, outcome, steps, ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.token_budgets_exceeded, ctx.max_steps_exceeded },
            );
        defer ctx.allocator.free(lesson);
        try store.appendUnique(ctx.allocator, kb, lesson, ctx.kb_max_lines);
    }
}

/// Cap the captured evaluator error to a short, KB-readable snippet so failed
/// lessons stay consumable. Returns null for an absent or empty error.
fn errSnippet(ctx: *types.Ctx) ?[]const u8 {
    const raw = ctx.eval_error orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const cap: usize = 240;
    const slice = if (trimmed.len <= cap) trimmed else trimmed[0..cap];
    return ctx.allocator.dupe(u8, slice) catch null;
}

/// Persist a qualitative critic-rejection lesson when a KB is configured.
/// Unlike the numeric summary in `recordLesson`, this captures the *reason*
/// a step was rejected, so a future run's `injectPrompt` can steer the
/// decomposer away from the rejected shape — closing the critiqued-shape loop.
pub fn recordCritic(ctx: *types.Ctx, step_name: []const u8, reason: []const u8) !void {
    if (ctx.kb_path) |kb| {
        const lesson = try std.fmt.allocPrint(
            ctx.allocator,
            "- critic rejected \"{s}\": {s}",
            .{ step_name, reason },
        );
        defer ctx.allocator.free(lesson);
        try store.appendUnique(ctx.allocator, kb, lesson, ctx.kb_max_lines);
    }
}

/// Persist the end-of-run autonomy-health verdict to the configured knowledge
/// base when one is set. Unlike the per-run `recordLesson` (outcome + numeric
/// counters) and `recordCritic` (rejected shapes), this captures the
/// qualitative *health* signal the monitoring layer computed — so a future
/// run's `injectPrompt` can also steer away from an *unhealthy cycle shape*
/// (e.g. mock-dominated, budget-exhausted), not only from a specific failure
/// or a rejected step. No-op when no KB is configured, or when the verdict is
/// empty (a healthy cycle has nothing to learn).
pub fn recordHealth(ctx: *types.Ctx, verdict: []const u8) !void {
    if (ctx.kb_path) |kb| {
        if (verdict.len == 0) return;
        const lesson = try std.fmt.allocPrint(ctx.allocator, "- health: {s}", .{verdict});
        defer ctx.allocator.free(lesson);
        try store.appendUnique(ctx.allocator, kb, lesson, ctx.kb_max_lines);
    }
}

/// Persist the `--tasks` batch autonomy-health summary to the configured KB
/// when one is set. Unlike the per-run `recordLesson`/`recordHealth` (one line
/// per engine.run cycle, written by each task's own ctx.kb_path inside
/// engine.run), this captures the *aggregate* shape of a multi-task run —
/// total deploys and how many of the batch's tasks ended unhealthy — so a
/// future run's `injectPrompt` can also steer away from an *unhealthy batch
/// shape* (e.g. every task mock-fell-back, or none deployed), not only from a
/// single cycle's verdict. No-op when no KB is configured, or when `summary`
/// is empty (an empty batch has nothing to learn).
pub fn recordBatch(alloc: std.mem.Allocator, kb_path: ?[]const u8, summary: []const u8, kb_max_lines: ?usize) !void {
    if (kb_path) |kb| {
        if (summary.len == 0) return;
        const lesson = try std.fmt.allocPrint(alloc, "- batch: {s}", .{summary});
        defer alloc.free(lesson);
        // Honor the operator's --kb-max-lines cap so the batch ledger stays
        // bounded on write, exactly like recordLesson/recordHealth (PR #29).
        try store.appendUnique(alloc, kb, lesson, kb_max_lines);
    }
}

/// Build the decomposition user-prompt, prepending prior lessons from the
/// configured knowledge base when present. Caller owns the returned string.
pub fn injectPrompt(ctx: *types.Ctx, task: []const u8) ![]const u8 {
    if (ctx.kb_path) |kb| {
        if (try store.load(ctx.allocator, kb)) |prior| {
            defer ctx.allocator.free(prior);
            if (prior.len > 0) {
                const capped = try store.tailLessons(ctx.allocator, prior, ctx.kb_max_lines);
                defer ctx.allocator.free(capped);
                return try std.fmt.allocPrint(ctx.allocator, "Prior lessons (avoid repeating failures):\n{s}\n\nTask: {s}", .{ capped, task });
            }
        }
    }
    return try std.fmt.allocPrint(ctx.allocator, "Task: {s}", .{task});
}

/// Category counts over a knowledge-ledger text. Returned by `summarize`
/// (pure, no IO) and rendered by `printStats`. Categories are prefix-based
/// (`- <marker>:`), matching the line shapes written by `recordLesson`
/// (`- <task>: deployed` / `- <task>: failed`), `recordCritic`
/// (`- critic rejected`), `recordHealth` (`- health:`), and `recordBatch`
/// (`- batch:`). `other` catches any non-matching lesson line.
pub const Stats = struct {
    total: usize,
    deployed: usize,
    failed: usize,
    critic: usize,
    health: usize,
    batch: usize,
    other: usize,
    latest: []const u8,
};

/// Pure categorization of a ledger's text into `Stats`. No IO, so it is
/// directly unit-testable. `latest` borrows the last non-empty line of
/// `content` (caller keeps `content` alive while reading it).
pub fn summarize(content: []const u8) Stats {
    var s: Stats = .{ .total = 0, .deployed = 0, .failed = 0, .critic = 0, .health = 0, .batch = 0, .other = 0, .latest = "" };
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, content, &std.ascii.whitespace), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        last = line;
        s.total += 1;
        if (std.mem.startsWith(u8, line, "- critic rejected")) s.critic += 1
        else if (std.mem.startsWith(u8, line, "- health:")) s.health += 1
        else if (std.mem.startsWith(u8, line, "- batch:")) s.batch += 1
        else if (std.mem.startsWith(u8, line, "- ") and std.mem.indexOf(u8, line, ": deployed") != null) s.deployed += 1
        else if (std.mem.startsWith(u8, line, "- ") and std.mem.indexOf(u8, line, ": failed") != null) s.failed += 1
        else s.other += 1;
    }
    s.latest = last;
    return s;
}

/// Print a read-only summary of the configured knowledge ledger and return.
/// Used by `--kb-stats`: an inspection surface for what the autonomous loop
/// has actually learned, so a co-owner (or audit) can see the accumulated
/// lessons without running the engine or reading raw ledger lines (§30/§24).
/// With no `--kb` path, or when the ledger is absent/empty, reports that and
/// exits cleanly — it is purely observational and never errors on a missing
/// ledger.
pub fn printStats(alloc: std.mem.Allocator, io: std.Io, kb_path: ?[]const u8, max_lines: ?usize) !void {
    const kb = kb_path orelse {
        types.logLine(io, "[kb-stats] no --kb ledger configured; nothing to summarize", .{});
        return;
    };
    const raw = store.load(alloc, kb) catch |e| {
        types.logLine(io, "[kb-stats] cannot read {s}: {s}", .{ kb, @errorName(e) });
        return;
    };
    const content = raw orelse {
        types.logLine(io, "[kb-stats] {s}: ledger empty (not yet written)", .{kb});
        return;
    };
    defer alloc.free(content);
    const s = summarize(content);
    types.logLine(io, "[kb-stats] {s}", .{kb});
    types.logLine(io, "  lessons:        {d}", .{s.total});
    types.logLine(io, "  deployed:       {d}", .{s.deployed});
    types.logLine(io, "  failed:         {d}", .{s.failed});
    types.logLine(io, "  critic-rejected:{d}", .{s.critic});
    types.logLine(io, "  health:         {d}", .{s.health});
    types.logLine(io, "  batch:          {d}", .{s.batch});
    types.logLine(io, "  other:          {d}", .{s.other});
    if (max_lines) |m| types.logLine(io, "  cap (--kb-max-lines): {d}", .{m});
    if (s.latest.len > 0) types.logLine(io, "  latest: {s}", .{s.latest});
}
