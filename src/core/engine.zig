const std = @import("std");
const types = @import("types.zig");
const gateway = @import("../gateway/gateway.zig");
const orchestrator = @import("../orchestrator/orchestrator.zig");
const builder = @import("../builder/builder.zig");
const critic = @import("../critic/critic.zig");
const evaluator = @import("../evaluator/evaluator.zig");
const deploy = @import("../deploy/deploy.zig");
const resilience = @import("../resilience/resilience.zig");
const knowledge = @import("../knowledge/knowledge.zig");
const monitoring = @import("../monitoring/monitoring.zig");
const fs = @import("../util/fs.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, task: []const u8) !void {
    types.logLine(io, "=== Yuxi (玉溪): autonomous software evolution engine ===", .{});
    types.logLine(io, "[engine] mode={s} backend={s}", .{ @tagName(ctx.mode), @tagName(ctx.backend) });
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
        for (fragments.items) |f| allocator.free(f);
        fragments.clearRetainingCapacity();
        var composed = true;
        for (steps.items, 0..) |*step, i| {
            const frag = try buildStep(allocator, ctx, step, i, if (attempt == 0) null else feedback);
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
    // LAYER 9: Monitoring
    monitoring.report(ctx);
    types.logLine(io, "[engine] done. events={d}", .{ctx.events.items.len});
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

    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(fileExists(final_path));
    for (0..3) |i| {
        const p = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ workdir, i });
        defer allocator.free(p);
        try std.testing.expect(!fileExists(p));
    }
}

fn fileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch |e| {
        if (e == error.FileNotFound) return false;
        return true;
    };
    std.os.linux.close(fd);
    return true;
}
/// Build one step (Builder -> Critic). A critic rejection regenerates THIS step
/// with the critic's reason as builder feedback (no global backend downgrade);
/// only a still-rejected retry falls back to mock. `feedback` seeds the first build.
fn buildStep(allocator: std.mem.Allocator, ctx: *types.Ctx, step: *types.Step, i: usize, feedback: ?[]const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ ctx.workdir, i });
    defer allocator.free(path);
    if (!try builder.run(ctx, step, path, feedback)) {
        ctx.log("[engine] step {d} not built", .{step.id});
        return null;
    }
    var code = fs.readFileAlloc(allocator, path) catch |e| {
        ctx.log("[engine] read failed: {s}", .{@errorName(e)});
        return null;
    };
    const v = try critic.run(ctx, code);
    if (v.ok) {
        if (v.reason) |r| allocator.free(r);
        return code;
    }
    ctx.log("[engine] critic rejected step {d}: {s}", .{ step.id, v.reason orelse "no reason" });
    allocator.free(code);
    const fb = if (v.reason) |r| r else "critic rejected";
    _ = try builder.run(ctx, step, path, fb);
    if (v.reason) |r| allocator.free(r);
    code = fs.readFileAlloc(allocator, path) catch {
        ctx.log("[engine] read failed after rebuild", .{});
        return null;
    };
    const v2 = try critic.run(ctx, code);
    if (v2.ok) {
        if (v2.reason) |r| allocator.free(r);
        return code;
    }
    resilience.fallback(ctx);
    if (v2.reason) |r| allocator.free(r);
    allocator.free(code);
    ctx.log("[engine] step {d} rejected after retry; fallback to mock", .{step.id});
    return null;
}
