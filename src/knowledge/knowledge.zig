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
        try store.save(ctx.allocator, kb, lesson, ctx.kb_max_lines);
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
        try store.save(ctx.allocator, kb, lesson, ctx.kb_max_lines);
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
        try store.save(ctx.allocator, kb, lesson, ctx.kb_max_lines);
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
        try store.save(alloc, kb, lesson, kb_max_lines);
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
