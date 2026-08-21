const std = @import("std");
const types = @import("types");
const fs = @import("fs");
const engine = @import("engine");
const knowledge = @import("knowledge");
const config = @import("config");

// Injected backend: rejects the PLAN review call (distinguished from the
// per-step code-critic call by the "Plan:" user-prompt prefix) so the engine
// must abort before any codegen — exercising the plan-quality gate end-to-end.
fn llmRejectPlan(alloc: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) anyerror![]u8 {
    _ = ctx;
    _ = io;
    if (std.mem.indexOf(u8, system, "decomposer") != null) {
        return alloc.dupe(u8,
            \\STEP: design the function signature
            \\STEP: implement the body
            \\STEP: add a unit test
        );
    }
    if (std.mem.indexOf(u8, system, "code generator") != null) {
        var n: usize = 0;
        if (std.mem.indexOf(u8, user, "Implement step ")) |p| {
            const rest = user[p + "Implement step ".len ..];
            if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
                n = std.fmt.parseUnsigned(usize, rest[0..c], 10) catch 0;
            }
        }
        return std.fmt.allocPrint(alloc,
            \\pub fn step{d}() void {{
            \\    const a: i32 = 2;
            \\    const b: i32 = 3;
            \\    _ = a + b;
            \\}}
        , .{n});
    }
    // Plan reviewer carries a "Plan:" user-prompt prefix; the per-step code
    // critic carries a "critic" system string. Reject only the plan so the
    // gate is exercised without desyncing the per-step review.
    if (std.mem.indexOf(u8, user, "Plan:") != null) return alloc.dupe(u8, "REJECT incoherent plan");
    if (std.mem.indexOf(u8, system, "critic") != null) return alloc.dupe(u8, "APPROVE");
    return alloc.dupe(u8, user);
}

test "engine.run aborts on a rejected plan before codegen" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_plan_gate_test";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.kb_path = "/tmp/yuxi_plan_gate_test/kb.md";
    ctx.llm_fn = llmRejectPlan;
    try engine.run(allocator, io, &ctx, "design a calculator");

    // Plan critic rejected -> run aborts before codegen: no deploy, no artifact.
    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(!fs.fileExists(final_path));
    try std.testing.expect(ctx.deploys == 0);
    // The plan rejection is counted + persisted as a critic lesson.
    try std.testing.expect(ctx.critic_rejections >= 1);
    const kb = (try knowledge.load(allocator, ctx.kb_path.?)).?;
    defer allocator.free(kb);
    try std.testing.expect(std.mem.indexOf(u8, kb, "critic rejected") != null);
}

test "engine.run aborts on a wall-clock cap (--max-time) before deploy" {
    // Regression for the --max-time autonomy-safety cap: a zero cap must abort
    // the run fail-closed (no deploy, no artifact) and count run_time_exceeded,
    // distinct from a generic failure. Mirrors the --max-steps gate test.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_maxtime_test";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.kb_path = "/tmp/yuxi_maxtime_test/kb.md";
    // Zero cap: the guard fires on the first attempt-loop check.
    ctx.max_time_ms = 0;
    try engine.run(allocator, io, &ctx, "design a calculator");

    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(!fs.fileExists(final_path));
    try std.testing.expect(ctx.deploys == 0);
    try std.testing.expect(ctx.run_time_exceeded == 1);
    // The cap hit is its own health-verdict clause, not a generic failure.
    const kb = (try knowledge.load(allocator, ctx.kb_path.?)).?;
    defer allocator.free(kb);
    try std.testing.expect(std.mem.indexOf(u8, kb, "wall-time exceeded") != null);
}

// Injected backend: produces valid code + APPROVEs the plan, but the build is
// rigged so evaluation always fails (gen_final.zig has a compile-time panic).
// Used to exhaust the self-correction retry budget and prove --max-attempts
// bounds the attempt loop rather than retrying forever.
fn llmFailEval(alloc: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) anyerror![]u8 {
    _ = ctx;
    _ = io;
    if (std.mem.indexOf(u8, system, "decomposer") != null) {
        return alloc.dupe(u8,
            \\STEP: write a panicking main
        );
    }
    if (std.mem.indexOf(u8, system, "code generator") != null) {
        return alloc.dupe(u8,
            \\pub fn main() void {
            \\    @panic("boom");
            \\}
        );
    }
    if (std.mem.indexOf(u8, user, "Plan:") != null) return alloc.dupe(u8, "APPROVE");
    if (std.mem.indexOf(u8, system, "critic") != null) return alloc.dupe(u8, "APPROVE");
    return alloc.dupe(u8, user);
}

test "engine.run bounds self-correction retries to --max-attempts" {
    // The attempt loop must stop after ctx.max_attempts attempts (not retry
    // forever) when evaluation keeps failing. max_attempts=1 -> exactly one
    // attempt, no deploy. This is the 4th autonomy-cap (after --max-steps,
    // --max-tokens, --max-time); null leaves the historical default of 3.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_maxattempts_test";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.kb_path = "/tmp/yuxi_maxattempts_test/kb.md";
    ctx.llm_fn = llmFailEval;
    ctx.max_attempts = 1;
    try engine.run(allocator, io, &ctx, "write a panicking main");

    // One attempt only: build loop ran once, no deploy, retries counts the
    // failed-evaluation follow-up (0 since attempt+1 < max_attempts is false).
    try std.testing.expect(ctx.deploys == 0);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});

    defer allocator.free(final_path);
    try std.testing.expect(!fs.fileExists(final_path));
}
