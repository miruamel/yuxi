const std = @import("std");
const types = @import("types");
const fs = @import("fs");
const engine = @import("engine");
const knowledge = @import("knowledge");

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
    try std.testing.expect(!engine.fileExists(final_path));
    try std.testing.expect(ctx.deploys == 0);
    // The plan rejection is counted + persisted as a critic lesson.
    try std.testing.expect(ctx.critic_rejections >= 1);
    const kb = (try knowledge.load(allocator, ctx.kb_path.?)).?;
    defer allocator.free(kb);
    try std.testing.expect(std.mem.indexOf(u8, kb, "critic rejected") != null);
}
