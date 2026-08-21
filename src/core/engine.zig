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
const runlife = @import("runlife");

pub fn run(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, task: []const u8) !void {
    types.logLine(io, "=== Yuxi (玉溪): autonomous software evolution engine ===", .{});
    types.logLine(io, "[engine] mode={s} backend={s}", .{ @tagName(ctx.mode), @tagName(ctx.backend) });
    // Wall-clock autonomy cap (--max-time). A hung build/eval/deploy must not
    // run unattended forever; the timer starts here so the whole run is bounded.
    var start_ns: ?u64 = null;
    if (ctx.max_time_ms != null) {
        var ts: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
            start_ns = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        } else {
            start_ns = null;
        }
    }
    defer runlife.flushRecord(allocator, ctx);

    // LAYER 1: Gateway. On admission it returns the *sanitized* task (PII
    // redacted) owned by us; downstream codegen and the KB ledger use that, not
    // the raw input. Denied -> null, nothing runs.
    const safe_task = (try gateway.run(ctx, task)) orelse {
        ctx.log("[engine] ABORT at gateway", .{});
        return runlife.finishRun(ctx, false, 0, task);
    };
    defer allocator.free(safe_task);
    // LAYER 2: Orchestrator
    var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
    if (!try orchestrator.run(ctx, safe_task, &steps)) {
        ctx.log("[engine] ABORT at orchestrator", .{});
        return runlife.finishRun(ctx, false, 0, safe_task);
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
            return runlife.finishRun(ctx, false, steps.items.len, safe_task);
        }
        if (pv.reason) |r| allocator.free(r);
    }
    // On evaluation failure the compiler/run error is fed back to the builder
    // and the pipeline is rebuilt up to `max_attempts` times (self-correction).
    var fragments = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var verified = false;
    var feedback: ?[]const u8 = null;
    defer if (feedback) |f| allocator.free(f);
    const max_attempts: usize = ctx.max_attempts orelse 3;
    var attempt: usize = 0;
    // Wall-clock cap: abort fail-closed if the run has overrun --max-time.
    if (start_ns) |t0| {
        if (ctx.max_time_ms) |ms| {
            var ts: std.os.linux.timespec = undefined;
            var now_ns: u64 = 0;
            if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
                now_ns = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
            } else {
                now_ns = 0;
            }
            if (now_ns - t0 >= ms * std.time.ns_per_ms) {
                ctx.record("engine: wall-clock cap exceeded");
                ctx.run_time_exceeded += 1;
                ctx.log("[engine] wall-clock cap ({d} ms) exceeded; aborting run", .{ms});
                return runlife.finishRun(ctx, false, steps.items.len, safe_task);
            }
        }
    }
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

    return runlife.finishRun(ctx, verified, steps.items.len, safe_task);
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
    ctx.max_steps = cfg.max_steps;
    ctx.max_time_ms = cfg.max_time_ms;
    ctx.max_attempts = cfg.max_attempts;
    ctx.cache = blk: {
        const cp = cfg.cache_path orelse break :blk null;
        const c = allocator.create(cache_mod.Cache) catch break :blk null;
        c.* = cache_mod.Cache.init(allocator, cp) catch break :blk null;
        break :blk c;
    };
    ctx.kb_max_lines = cfg.kb_max_lines;
    ctx.replay_path = cfg.replay_path;
    ctx.record_path = cfg.record_path;
    return ctx;
}
