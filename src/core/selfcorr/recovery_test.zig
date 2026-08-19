const std = @import("std");
const types = @import("types");
const fs = @import("fs");
const engine = @import("engine");
const knowledge = @import("knowledge");

// Call counter for the injected backend so the test can assert the engine
// actually retried a failed first build.
var cg_calls: usize = 0;

// Injected LLM backend: behaves like the mock except the very first code-
// generator call emits a compile error, forcing the engine's self-correction
// loop to rebuild with feedback and recover.
fn llmFailFirst(alloc: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) anyerror![]u8 {
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
        cg_calls += 1;
        if (cg_calls == 1) {
            // First code-gen call (step0, attempt 0): a compile error so the
            // composed program fails and the engine retries with feedback.
            return std.fmt.allocPrint(alloc,
                \\pub fn step{d}() void {{ undefined_symbol_xyz(); }}
            , .{n});
        }
        return std.fmt.allocPrint(alloc,
            \\pub fn step{d}() void {{
            \\    const a: i32 = 2;
            \\    const b: i32 = 3;
            \\    const sum = a + b;
            \\    std.debug.print("step result: 2+3={{d}}\n", .{{sum}});
            \\}}
        , .{n});
    }
    if (std.mem.indexOf(u8, system, "critic") != null) {
        return alloc.dupe(u8, "APPROVE");
    }
    return alloc.dupe(u8, user);
}

test "engine.run self-corrects a broken first build via retry" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_selfcorr_test";
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.llm_fn = llmFailFirst;
    cg_calls = 0;
    try engine.run(allocator, io, &ctx, "design a calculator");

    // A retry must have happened (more than one attempt's worth of code-gen).
    try std.testing.expect(cg_calls > 3);
    // Recovery: the verified build was deployed (gen_final.zig present).
    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(engine.fileExists(final_path));
    // Intermediate step files cleaned up.
    for (0..3) |i| {
        const p = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ workdir, i });
        defer allocator.free(p);
        try std.testing.expect(!engine.fileExists(p));
    }
}

// Injected backend that rejects the FIRST critic call (non-denylist) then
// approves, so the engine must regenerate the rejected step with the critic's
// reason as builder feedback and recover — exercising step.zig 23-41 (the
// recovery branch), complementary to the denylist test which asserts the
// fallback branch (reject -> still reject -> mock fallback, no deploy).
var cg_reject_calls: usize = 0;

fn llmRejectThenApprove(alloc: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) anyerror![]u8 {
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
            \\    const sum = a + b;
            \\    std.debug.print("step result: 2+3={{d}}\n", .{{sum}});
            \\}}
        , .{n});
    }
    if (std.mem.indexOf(u8, system, "critic") != null) {
        cg_reject_calls += 1;
        if (cg_reject_calls == 1) return alloc.dupe(u8, "REJECT missing error handling");
        return alloc.dupe(u8, "APPROVE");
    }
    return alloc.dupe(u8, user);
}

test "engine.run recovers from an LLM-critic REJECT via regenerate" {
    // Complements the denylist test: that one asserts the fallback branch
    // (reject -> still reject -> mock fallback, no deploy). This one asserts the
    // recovery branch (reject -> regenerate with feedback -> approve -> deploy),
    // so both branches of step.zig (23-47) are now covered end-to-end.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_reject_recover_test";
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.kb_path = "/tmp/yuxi_reject_recover_test/kb.md";
    ctx.llm_fn = llmRejectThenApprove;
    cg_reject_calls = 0;
    try engine.run(allocator, io, &ctx, "design a calculator");

    // A non-denylist rejection occurred...
    try std.testing.expect(ctx.critic_rejections >= 1);
    // ...but it recovered via regenerate (no mock fallback) and deployed.
    try std.testing.expect(ctx.mock_fallbacks == 0);
    try std.testing.expect(ctx.deploys >= 1);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(engine.fileExists(final_path));
    for (0..3) |i| {
        const p = try std.fmt.allocPrint(allocator, "{s}/gen_{d}.zig", .{ workdir, i });
        defer allocator.free(p);
        try std.testing.expect(!engine.fileExists(p));
    }

    // The critic rejection reason must be persisted as a durable lesson so a
    // future run's decompose prompt can avoid the rejected shape.
    const kb = (try knowledge.load(allocator, ctx.kb_path.?)).?;
    defer allocator.free(kb);
    try std.testing.expect(std.mem.indexOf(u8, kb, "critic rejected") != null);
}
