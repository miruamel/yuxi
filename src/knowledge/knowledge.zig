const std = @import("std");
const types = @import("types");
const fs = @import("fs");

/// Append a structured event to the engine's in-memory knowledge log.
pub fn log(ctx: *types.Ctx, text: []const u8) void {
    ctx.log("[knowledge] {s}", .{text});
    ctx.record(text);
}

/// Load the persisted knowledge base at `path`. Returns null when the file is
/// absent, so a first run simply has no prior lessons to inject. Caller owns
/// the returned slice.
pub fn load(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    return fs.readFileAlloc(alloc, path) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
}

/// Append one `lesson` line to the knowledge base at `path`, creating the
/// parent directory if needed. Lines are newline-terminated so successive
/// runs accumulate a readable, replayable ledger the orchestrator can reuse.
pub fn save(alloc: std.mem.Allocator, path: []const u8, lesson: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try fs.ensureDir(alloc, dir);
    }
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
        0o644,
    );
    defer _ = std.os.linux.close(fd);
    var buf = try std.ArrayList(u8).initCapacity(alloc, lesson.len + 1);
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, lesson);
    if (lesson.len == 0 or lesson[lesson.len - 1] != '\n') try buf.append(alloc, '\n');
    var off: usize = 0;
    while (off < buf.items.len) {
        const n = std.os.linux.write(fd, buf.items[off..].ptr, buf.items.len - off);
        if (n == 0) break;
        off += n;
    }
}

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
        try save(ctx.allocator, kb, lesson);
    }
}

/// Cap the captured evaluator error to a short, KB-readable snippet so failed
/// lessons stay consumable. Returns null for an absent or empty error.
/// ponytail: 240-byte prefix; upgrade to first-N-lines if multiline context
/// proves worth keeping in the ledger.
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
        try save(ctx.allocator, kb, lesson);
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
        try save(ctx.allocator, kb, lesson);
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
pub fn recordBatch(alloc: std.mem.Allocator, kb_path: ?[]const u8, summary: []const u8) !void {
    if (kb_path) |kb| {
        if (summary.len == 0) return;
        const lesson = try std.fmt.allocPrint(alloc, "- batch: {s}", .{summary});
        defer alloc.free(lesson);
        try save(alloc, kb, lesson);
    }
}

/// Return the last `max` lines of `prior` (or all of it when `max` is null), so
/// a long-lived KB ledger doesn't get loaded into every decomposition prompt in
/// full. Lessons are newline-terminated, so the split boundary is line-based.
/// Caller owns the returned slice. If `prior` has `max` or fewer lines, the
/// whole thing is returned.
fn tailLessons(alloc: std.mem.Allocator, prior: []const u8, max: ?usize) ![]const u8 {
    const m = max orelse return alloc.dupe(u8, prior);
    if (m == 0) return alloc.dupe(u8, "");
    var total: usize = 0;
    for (prior) |c| {
        if (c == '\n') total += 1;
    }
    if (total <= m) return alloc.dupe(u8, prior);
    // (total - m), then keep everything after it.
    const skip = total - m;
    var seen: usize = 0;
    var i: usize = 0;
    while (i < prior.len) : (i += 1) {
        if (prior[i] == '\n') {
            seen += 1;
            if (seen == skip) return alloc.dupe(u8, prior[i + 1 ..]);
        }
    }
    return alloc.dupe(u8, prior);
}

/// Build the decomposition user-prompt, prepending prior lessons from the
/// configured knowledge base when present. Caller owns the returned string.
pub fn injectPrompt(ctx: *types.Ctx, task: []const u8) ![]const u8 {
    if (ctx.kb_path) |kb| {
        if (try load(ctx.allocator, kb)) |prior| {
            defer ctx.allocator.free(prior);
            if (prior.len > 0) {
                const capped = try tailLessons(ctx.allocator, prior, ctx.kb_max_lines);
                defer ctx.allocator.free(capped);
                return try std.fmt.allocPrint(ctx.allocator, "Prior lessons (avoid repeating failures):\n{s}\n\nTask: {s}", .{ capped, task });
            }
        }
    }
    return try std.fmt.allocPrint(ctx.allocator, "Task: {s}", .{task});
}
