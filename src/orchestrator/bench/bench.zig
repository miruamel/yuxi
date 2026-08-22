const std = @import("std");
const types = @import("types");
const orchestrator = @import("orchestrator");
const transport = @import("transport");
const fs = @import("fs");

/// Monotonic clock helper (same as runlife.zig).
fn clockNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}
// Benchmark orchestrator.run decomposition with mock backend.
// Measures the time to parse a mock LLM response into steps.
test "orchestrator.run decomposition latency (mock backend)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");

    const tasks = [_][]const u8{
        "add two numbers",
        "write a function that adds two ints",
        "create a fibonacci calculator",
        "implement a simple HTTP server",
        "build a todo list CLI",
        "write a JSON parser",
        "create a file watcher",
        "implement a rate limiter",
    };

    const iterations = 100;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |i| {
        const task = tasks[i % tasks.len];
        const start = clockNs();
        var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
        defer steps.deinit(allocator);
        _ = try orchestrator.run(&ctx, task, &steps);
        const elapsed = clockNs() - start;
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    const avg_ns = total_ns / iterations;
    std.debug.print("orchestrator.run (mock):\n", .{});
    std.debug.print("  iterations: {d}\n", .{iterations});
    std.debug.print("  avg: {d} µs ({d} ns)\n", .{ avg_ns / 1000, avg_ns });
    std.debug.print("  min: {d} µs ({d} ns)\n", .{ min_ns / 1000, min_ns });
    std.debug.print("  max: {d} µs ({d} ns)\n", .{ max_ns / 1000, max_ns });
}

// Benchmark orchestrator.run with knowledge injection (KB ledger loaded).
test "orchestrator.run with KB injection latency" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");

    // Simulate KB ledger with some lessons
    const kb_content = "lesson: task=add two numbers deployed=true critic_rej=0 mock_fb=0 token_bud=0 max_steps=0 wall_time=0 steps=3 deploys=1 retries=0\n" ++ "lesson: task=write fib deployed=true critic_rej=1 mock_fb=0 token_bud=0 max_steps=0 wall_time=0 steps=3 deploys=1 retries=1\n" ++ "lesson: task=HTTP server deployed=false critic_rej=0 mock_fb=2 token_bud=1 max_steps=0 wall_time=0 steps=5 deploys=0 retries=3\n";
    const kb_path = "/tmp/orch_bench_kb.md";
    try fs.writeFileAlloc(allocator, kb_path, kb_content);
    defer fs.deleteFile(io, kb_path) catch {};

    ctx.kb_path = try allocator.dupe(u8, kb_path);
    ctx.kb_max_lines = 200;

    const task = "add two numbers with KB";
    const iterations = 100;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |_| {
        const start = clockNs();
        var steps = try std.ArrayList(types.Step).initCapacity(allocator, 0);
        defer steps.deinit(allocator);
        _ = try orchestrator.run(&ctx, task, &steps);
        const elapsed = clockNs() - start;
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    const avg_ns = total_ns / iterations;
    std.debug.print("orchestrator.run (with KB injection):\n", .{});
    std.debug.print("  iterations: {d}\n", .{iterations});
    std.debug.print("  avg: {d} µs ({d} ns)\n", .{ avg_ns / 1000, avg_ns });
    std.debug.print("  min: {d} µs ({d} ns)\n", .{ min_ns / 1000, min_ns });
    std.debug.print("  max: {d} µs ({d} ns)\n", .{ max_ns / 1000, max_ns });
}
