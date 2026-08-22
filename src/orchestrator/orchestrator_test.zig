const std = @import("std");
const types = @import("types");
const fs = @import("fs");
const engine = @import("engine");
const orchestrator = @import("orchestrator");

// End-to-end guard for `--max-steps`: with the cap set below the mock
// decomposer's fixed 3-step plan, the orchestrator must abort before any
// codegen/build/deploy. Mirrors the plan-gate test's abort assertions but
// exercises the decomposition-size bound specifically (not the critic).
test "engine.run aborts on a plan exceeding max-steps before codegen" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const workdir = "/tmp/yuxi_max_steps_test";
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
    try fs.ensureDir(allocator, workdir);

    // max_steps=2 but the mock decomposer always returns a 3-step plan, so the
    // orchestrator must abort before any codegen/build/deploy.
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
    ctx.max_steps = 2;

    try engine.run(allocator, io, &ctx, "design a calculator");

    // Plan exceeded the cap -> run aborts at the orchestrator: nothing built or
    // deployed, and the critic was never reached (critic_rejections stays 0).
    const final_path = try std.fmt.allocPrint(allocator, "{s}/gen_final.zig", .{workdir});
    defer allocator.free(final_path);
    try std.testing.expect(!fs.fileExists(final_path));
    try std.testing.expect(ctx.deploys == 0);
    try std.testing.expect(ctx.critic_rejections == 0);
    // The abort is a deliberate safety-cap hit, not a generic failure: the
    // distinct counter distinguishes it in the health verdict / next-cycle
    // KB steering, so it must be set.
    try std.testing.expect(ctx.max_steps_exceeded == 1);
}

// Property test: orchestrator decomposition idempotency with mock backend.
// Same task input must yield same step count and naming structure.
test "orchestrator.run idempotent decomposition (mock backend)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Run the same task 5 times and verify consistent decomposition
    const task = "build a simple calculator";
    var prev_steps: usize = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const workdir = try std.fmt.allocPrint(allocator, "/tmp/yuxi_idempotent_test_{d}", .{i});
        defer allocator.free(workdir);
        std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
        try fs.ensureDir(allocator, workdir);

        var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
        var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
        defer steps.deinit(allocator);

        const ok = try orchestrator.run(&ctx, task, &steps);
        try std.testing.expect(ok);

        // Mock decomposer always produces 3 steps for any task
        try std.testing.expect(steps.items.len == 3);
        if (prev_steps != 0) {
            try std.testing.expect(steps.items.len == prev_steps);
        }
        prev_steps = steps.items.len;

        // Verify step naming pattern: all steps have non-empty names
        for (steps.items) |step| {
            try std.testing.expect(step.name.len > 0);
            try std.testing.expect(step.id < 3);
        }
    }
}

test "orchestrator.run produces valid steps for varied tasks (mock backend)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tasks = [_][]const u8{
        "add two numbers",
        "design a REST API",
        "create a todo app",
        "implement quicksort",
        "write a markdown parser",
    };

    for (tasks) |task| {
        const workdir = try std.fmt.allocPrint(allocator, "/tmp/yuxi_varied_test_{s}", .{task});
        defer allocator.free(workdir);
        std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, workdir) catch {};
        try fs.ensureDir(allocator, workdir);

        var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", workdir);
        var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
        defer steps.deinit(allocator);

        const ok = try orchestrator.run(&ctx, task, &steps);
        try std.testing.expect(ok);
        try std.testing.expect(steps.items.len > 0);
        try std.testing.expect(steps.items.len <= 10); // reasonable bound

        for (steps.items) |step| {
            try std.testing.expect(step.name.len > 0);
        }
    }
}
