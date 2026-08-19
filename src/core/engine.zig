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
    // LAYER 3-6: per step (Builder -> Critic), then compose + Evaluator -> Deploy
    var fragments = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var composed = true;
    for (steps.items, 0..) |*step, i| {
        const path = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ ctx.workdir, i });
        defer allocator.free(path);
        if (!try builder.run(ctx, step, path)) {
            ctx.log("[engine] step {d} not built", .{step.id});
            composed = false;
            break;
        }
        var code = fs.readFileAlloc(allocator, path) catch |e| {
            ctx.log("[engine] read failed: {s}", .{@errorName(e)});
            composed = false;
            break;
        };
        var approved = try critic.run(ctx, code);
        if (!approved) {
            resilience.fallback(ctx);
            ctx.log("[engine] critic rejected; retry build (fallback={s})", .{@tagName(ctx.backend)});
            _ = try builder.run(ctx, step, path);
            allocator.free(code);
            code = fs.readFileAlloc(allocator, path) catch |e| {
                ctx.log("[engine] read failed: {s}", .{@errorName(e)});
                composed = false;
                break;
            };
            approved = try critic.run(ctx, code);
        }
        if (!approved) {
            ctx.log("[engine] step {d} rejected by critic", .{step.id});
            allocator.free(code);
            composed = false;
            break;
        }
        try fragments.append(allocator, code);
    }

    if (composed) {
        const merged = try compose(allocator, fragments.items);
        defer allocator.free(merged);
        const merged_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{ctx.workdir});
        defer allocator.free(merged_path);
        try fs.writeFileAlloc(allocator, merged_path, merged);
        ctx.log("[engine] composed {d} steps -> {s}", .{ fragments.items.len, merged_path });
        const verified = try evaluator.run(ctx, merged_path);
        if (verified) {
            _ = try deploy.run(ctx, merged_path);
        } else {
            ctx.log("[engine] composition not deployed (evaluation failed)", .{});
        }
    } else {
        ctx.log("[engine] composition aborted; nothing deployed", .{});
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
