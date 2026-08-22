const std = @import("std");
const types = @import("types");
const fs = @import("fs");
const engine = @import("engine");

// Injected backend that always emits a process-spawning construct, so the
// critic's dangerous-construct denylist must reject it before any deploy.
var cg_danger_calls: usize = 0;

fn llmDanger(alloc: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) anyerror![]u8 {
    _ = ctx;
    _ = io;
    if (std.mem.indexOf(u8, system, "decomposer") != null) {
        return alloc.dupe(u8,
            \\STEP: step one
            \\STEP: step two
            \\STEP: step three
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
        cg_danger_calls += 1;
        // 'std.process.Child' is on the critic denylist: must never reach deploy.
        return std.fmt.allocPrint(alloc,
            \\pub fn step{d}() void {{ _ = std.process.Child.init(&.{{"sh"}}, .{{}}); }}
        , .{n});
    }
    if (std.mem.indexOf(u8, system, "critic") != null) {
        return alloc.dupe(u8, "APPROVE");
    }
    return alloc.dupe(u8, user);
}

test "engine.run blocks dangerous constructs via critic denylist" {
    // The injected backend emits code that spawns a process. The critic's
    // denylist must reject it before the LLM critic call (and before deploy),
    // so the pipeline ends without committing an artifact. This exercises the
    // security gate end-to-end through the real engine, not just the isolated
    // critic unit test.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_denylist_test";
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.llm_fn = llmDanger;
    cg_danger_calls = 0;
    try engine.run(allocator, io, &ctx, "design a calculator");

    try std.testing.expect(cg_danger_calls > 0);
    var rejected_denylist = false;
    var deployed = false;
    for (ctx.events.items) |e| {
        if (std.mem.indexOf(u8, e, "critic: rejected (denylist)") != null) rejected_denylist = true;
        if (std.mem.indexOf(u8, e, "deploy: committed") != null) deployed = true;
    }
    try std.testing.expect(rejected_denylist);
    try std.testing.expect(!deployed);
    // New observability counters must reflect the rejection + mock fallback.
    try std.testing.expect(ctx.critic_rejections >= 1);
    try std.testing.expect(ctx.mock_fallbacks >= 1);
}

test "engine.run respects token budget" {
    // `transport.complete` adds >=16 tokens per call (user.len/4 + system.len/8 + 16),
    // so a tiny budget is exceeded by the decomposer alone. With `--max-tokens 1`
    // the engine must abort the build loop before deploying, recording the
    // budget-exceeded event. Uses the real (mock) backend to exercise the
    // counting path in transport.complete, not the seam.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_budget_test";
    try fs.ensureDir(allocator, workdir);

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.max_tokens = 1;
    try engine.run(allocator, io, &ctx, "design a calculator");

    var over = false;
    var deployed = false;
    for (ctx.events.items) |e| {
        if (std.mem.indexOf(u8, e, "engine: token budget exceeded") != null) over = true;
        if (std.mem.indexOf(u8, e, "deploy: committed") != null) deployed = true;
    }
    try std.testing.expect(over);
    try std.testing.expect(!deployed);
    try std.testing.expect(ctx.tokens >= 16); // decomposer call spent tokens
    // New observability counter must reflect the budget abort.
    try std.testing.expect(ctx.token_budgets_exceeded >= 1);
}
