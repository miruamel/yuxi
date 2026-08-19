const std = @import("std");
const types = @import("types.zig");
const buildstep = @import("step.zig");
const gateway = @import("../gateway/gateway.zig");
const orchestrator = @import("../orchestrator/orchestrator.zig");
const evaluator = @import("../evaluator/evaluator.zig");
const deploy = @import("../deploy/deploy.zig");
const resilience = @import("../resilience/resilience.zig");
const knowledge = @import("../knowledge/knowledge.zig");
const monitoring = @import("../monitoring/monitoring.zig");
const fs = @import("../util/fs.zig");
const config = @import("config.zig");
const cache_mod = @import("../util/cache.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, task: []const u8) !void {
    types.logLine(io, "=== Yuxi (玉溪): autonomous software evolution engine ===", .{});
    types.logLine(io, "[engine] mode={s} backend={s}", .{ @tagName(ctx.mode), @tagName(ctx.backend) });
    defer flushRecord(allocator, ctx);
    try fs.ensureDir(allocator, ctx.workdir);

    // LAYER 1: Gateway
    if (!try gateway.run(ctx, task)) {
        ctx.log("[engine] ABORT at gateway", .{});
        return;
    }
    // LAYER 2: Orchestrator
    var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
    if (!try orchestrator.run(ctx, task, &steps)) {
        ctx.log("[engine] ABORT at orchestrator", .{});
        return;
    }
    // LAYER 3-6: per step (Builder -> Critic), then compose + Evaluator -> Deploy.
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
        const merged = try compose(allocator, fragments.items);
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

    // LAYER 7: Resilience summary
    resilience.summary(ctx);
    // LAYER 8: Knowledge
    knowledge.log(ctx, "task pipeline complete");
    if (ctx.kb_path) |_| {
        knowledge.recordLesson(ctx, task, steps.items.len) catch |e| ctx.log("[knowledge] save failed: {s}", .{@errorName(e)});
    }
    // LAYER 9: Monitoring
    monitoring.report(ctx);
    monitoring.assessHealth(ctx);
    types.logLine(io, "[engine] done. events={d}", .{ctx.events.items.len});
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
/// Merge step fragments into one runnable program: a std import, each step
/// function, and a `main` that calls them in order. Invalid composition
/// (e.g. a step whose function fails to compile) surfaces at the evaluator.
fn compose(alloc: std.mem.Allocator, frags: [][]const u8) ![]u8 {
    var body = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "const std = @import(\"std\");\n\n");
    for (frags) |f| {
        try body.appendSlice(alloc, f);
        try body.appendSlice(alloc, "\n");
    }
    var calls = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer calls.deinit(alloc);
    var i: usize = 0;
    while (i < frags.len) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "    _ = step{d}();\n", .{i});
        try calls.appendSlice(alloc, line);
        alloc.free(line);
    }
    return try std.fmt.allocPrint(alloc, "{s}\npub fn main() void {{\n{s}}}\n", .{ body.items, calls.items });
}
test "compose merges step fragments with a main harness" {
    const allocator = std.testing.allocator;
    const frags = [_][]const u8{
        "pub fn step0() void { std.debug.print(\"a\", .{}); }",
        "pub fn step1() void { std.debug.print(\"b\", .{}); }",
    };
    const prog = try compose(allocator, &frags);
    defer allocator.free(prog);
    try std.testing.expect(std.mem.indexOf(u8, prog, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "pub fn step0() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "pub fn step1() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "pub fn main() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "    _ = step0();") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "    _ = step1();") != null);
}

test "engine.run removes intermediate step files, keeps gen_final" {
    // Integration test: the mock backend yields a full, self-contained
    // pipeline (orchestrator -> 3 steps, builder -> stepN fns, critic -> APPROVE).
    // Uses page_allocator because engine.run intentionally leaves exit-time
    // allocations (ctx.events, steps) for the CLI, which the test allocator
    // would otherwise report as leaks.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_clean_test";
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    try run(allocator, io, &ctx, "design a calculator");
    try std.testing.expect(ctx.deploys >= 1);
    try std.testing.expect(ctx.retries == 0);

    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(fileExists(final_path));
    for (0..3) |i| {
        const p = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ workdir, i });
        defer allocator.free(p);
        try std.testing.expect(!fileExists(p));
    }
}

pub fn fileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch |e| {
        if (e == error.FileNotFound) return false;
        return true;
    };
    std.os.linux.close(fd);
    return true;
}
