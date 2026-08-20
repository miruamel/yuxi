const std = @import("std");
const types = @import("types");
const buildstep = @import("step");
const compose = @import("compose");
const gateway = @import("gateway");
const orchestrator = @import("orchestrator");
const evaluator = @import("evaluator");
const critic = @import("critic");
const deploy = @import("deploy");
const resilience = @import("resilience");
const knowledge = @import("knowledge");
const monitoring = @import("monitoring");
const fs = @import("fs");
const config = @import("config");
const cache_mod = @import("cache");

pub fn run(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, task: []const u8) !void {
    types.logLine(io, "=== Yuxi (玉溪): autonomous software evolution engine ===", .{});
    types.logLine(io, "[engine] mode={s} backend={s}", .{ @tagName(ctx.mode), @tagName(ctx.backend) });
    defer flushRecord(allocator, ctx);
    try fs.ensureDir(allocator, ctx.workdir);

    // LAYER 1: Gateway. On admission it returns the *sanitized* task (PII
    // redacted) owned by us; downstream codegen and the KB ledger use that, not
    // the raw input. Denied -> null, nothing runs.
    const safe_task = (try gateway.run(ctx, task)) orelse {
        ctx.log("[engine] ABORT at gateway", .{});
        return finishRun(ctx, false, 0, task);
    };
    defer allocator.free(safe_task);
    // LAYER 2: Orchestrator
    var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
    if (!try orchestrator.run(ctx, safe_task, &steps)) {
        ctx.log("[engine] ABORT at orchestrator", .{});
        return finishRun(ctx, false, 0, safe_task);
    }
    // LAYER 2.5: Plan-quality gate. Review the decomposition before committing
    // to codegen; a bad plan fails fast instead of burning the self-correction
    // budget. Mirrors the per-step critic gate in step.zig.
    {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        for (steps.items) |s| {
            try buf.appendSlice(allocator, "STEP: ");
            try buf.appendSlice(allocator, s.name);
            try buf.append(allocator, '\n');
        }
        const pv = try critic.reviewPlan(ctx, try buf.toOwnedSlice(allocator));
        if (!pv.ok) {
            ctx.critic_rejections += 1;
            knowledge.recordCritic(ctx, "plan", pv.reason orelse "no reason") catch |e| ctx.log("[knowledge] plan lesson failed: {s}", .{@errorName(e)});
            if (pv.reason) |r| allocator.free(r);
            ctx.log("[engine] ABORT at plan critic", .{});
            return finishRun(ctx, false, steps.items.len, safe_task);
        }
        if (pv.reason) |r| allocator.free(r);
    }
    // On evaluation failure the compiler/run error is fed back to the builder
    // and the pipeline is rebuilt up to `max_attempts` times (self-correction).
    var fragments = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var verified = false;
    var feedback: ?[]const u8 = null;
    defer if (feedback) |f| allocator.free(f);
    const max_attempts: usize = 3;
    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (ctx.max_tokens) |mt| {
            if (ctx.tokens >= mt) {
                ctx.record("engine: token budget exceeded");
                ctx.token_budgets_exceeded += 1;
                ctx.log("[engine] token budget exceeded ({d} >= {d}); aborting build", .{ ctx.tokens, mt });
                break;
            }
        }
        for (fragments.items) |f| allocator.free(f);
        fragments.clearRetainingCapacity();
        var composed = true;
        for (steps.items, 0..) |*step, i| {
            const frag = try buildstep.build(allocator, ctx, step, i, if (attempt == 0) null else feedback);
            if (frag == null) {
                composed = false;
                break;
            }
            try fragments.append(allocator, frag.?);
        }
        if (!composed) break;
        const merged = try compose.merge(allocator, fragments.items);
        defer allocator.free(merged);
        const merged_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{ctx.workdir});
        defer allocator.free(merged_path);
        try fs.writeFileAlloc(allocator, merged_path, merged);
        ctx.log("[engine] attempt {d}/{d}: composed {d} steps -> {s}", .{ attempt + 1, max_attempts, fragments.items.len, merged_path });
        verified = try evaluator.run(ctx, merged_path);
        if (verified) break;
        ctx.log("[engine] attempt {d}/{d} failed evaluation", .{ attempt + 1, max_attempts });
        if (attempt + 1 < max_attempts) {
            ctx.retries += 1;
            if (ctx.eval_error) |e| {
                if (feedback) |f| allocator.free(f);
                feedback = try allocator.dupe(u8, e);
                ctx.log("[engine] retrying with eval error feedback", .{});
            }
        }
    }
    if (verified) {
        const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{ctx.workdir});
        defer allocator.free(final_path);
        _ = try deploy.run(ctx, final_path);
        ctx.deploys += 1;
        for (steps.items, 0..) |_, i| {
            const p = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ ctx.workdir, i });
            defer allocator.free(p);
            fs.deleteFile(io, p) catch |err| ctx.log("[engine] keep gen_{d}: {s}", .{ i, @errorName(err) });
        }
    } else {
        ctx.log("[engine] no verified build; nothing deployed", .{});
    }
    for (fragments.items) |f| allocator.free(f);
    fragments.deinit(allocator);

    return finishRun(ctx, verified, steps.items.len, safe_task);
}

/// LAYER 7-9 tail: resilience summary, knowledge ledger (outcome lesson +
/// persisted health verdict), and monitoring metrics. Runs on EVERY exit path
/// — including the early aborts at the gateway, orchestrator, and plan critic —
/// so a rejected plan still records its outcome (critic_rej=N), the health
/// verdict, and the metrics. This keeps the learning loop closed for that class
/// of failure: without it, a plan-level rejection skipped recordLesson (the
/// numeric critic_rej counter was lost from the ledger) and assessHealth
/// (no health verdict persisted), so the next cycle's injectPrompt never saw
/// a plan-shaped failure to steer away from.
fn finishRun(ctx: *types.Ctx, verified: bool, steps_len: usize, task_label: []const u8) !void {
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
fn flushRecord(allocator: std.mem.Allocator, ctx: *types.Ctx) void {
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
/// Build a run Ctx from parsed Config. `workdir` overrides cfg.workdir so the
/// multi-task loop can give each task an isolated directory. Backend base URL
/// and API key resolve from the environment (mirrors main.zig).
pub fn newCtx(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, cfg: config.Config, workdir: []const u8) !types.Ctx {
    const base = switch (cfg.backend) {
        .mock => try allocator.dupe(u8, ""),
        .openai => try allocator.dupe(u8, std.process.Environ.getPosix(environ, "OPENAI_BASE") orelse "https://api.openai.com/v1"),
        .local => try allocator.dupe(u8, std.process.Environ.getPosix(environ, "LOCAL_BASE") orelse "http://localhost:11434/v1"),
    };
    const raw_key = if (cfg.backend == .openai) std.process.Environ.getPosix(environ, "OPENAI_API_KEY") else null;
    const key: ?[]const u8 = if (raw_key) |k| allocator.dupe(u8, k) catch null else null;

    var ctx = try types.Ctx.init(allocator, io, environ, cfg.mode, cfg.backend, key, base, workdir);
    ctx.expected = cfg.expect;
    ctx.max_tokens = cfg.max_tokens;
    ctx.cache = blk: {
        const cp = cfg.cache_path orelse break :blk null;
        const c = allocator.create(cache_mod.Cache) catch break :blk null;
        c.* = cache_mod.Cache.init(allocator, cp) catch break :blk null;
        break :blk c;
    };
    ctx.kb_path = cfg.kb_path;
    ctx.replay_path = cfg.replay_path;
    ctx.record_path = cfg.record_path;
    return ctx;
}
