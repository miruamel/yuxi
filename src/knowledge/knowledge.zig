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
/// rejections, mock fallbacks, token-budget breaches) so a later run that
/// replays prior lessons via `injectPrompt` sees *how* a prior cycle went, not
/// just whether it deployed. On a failed run with a captured evaluator error,
/// the trimmed error is appended (see `errSnippet`) so the next run also learns
/// *why* it failed — closing the learning loop for non-critic failures too,
/// not only for critic rejections (`recordCritic`).
pub fn recordLesson(ctx: *types.Ctx, task: []const u8, steps: usize) !void {
    if (ctx.kb_path) |kb| {
        const outcome = if (ctx.deploys > 0) "deployed" else "failed";
        const err = if (ctx.deploys == 0) errSnippet(ctx) else null;
        defer if (err) |e| ctx.allocator.free(e);
        const lesson = if (err) |e|
            try std.fmt.allocPrint(
                ctx.allocator,
                "- {s}: {s} (steps={d} deploys={d} retries={d} critic_rej={d} mock_fb={d} budget_ex={d}) error=\"{s}\"",
                .{ task, outcome, steps, ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.token_budgets_exceeded, e },
            )
        else
            try std.fmt.allocPrint(
                ctx.allocator,
                "- {s}: {s} (steps={d} deploys={d} retries={d} critic_rej={d} mock_fb={d} budget_ex={d})",
                .{ task, outcome, steps, ctx.deploys, ctx.retries, ctx.critic_rejections, ctx.mock_fallbacks, ctx.token_budgets_exceeded },
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

/// Build the decomposition user-prompt, prepending prior lessons from the
/// configured knowledge base when present. Caller owns the returned string.
pub fn injectPrompt(ctx: *types.Ctx, task: []const u8) ![]const u8 {
    if (ctx.kb_path) |kb| {
        if (try load(ctx.allocator, kb)) |prior| {
            defer ctx.allocator.free(prior);
            if (prior.len > 0) {
                return try std.fmt.allocPrint(ctx.allocator, "Prior lessons (avoid repeating failures):\n{s}\n\nTask: {s}", .{ prior, task });
            }
        }
    }
    return try std.fmt.allocPrint(ctx.allocator, "Task: {s}", .{task});
}
