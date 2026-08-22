const std = @import("std");
const types = @import("types");
const critic = @import("critic");

/// Monotonic clock helper.
fn clockNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

// Benchmark critic.run fast-path (denylist check) with mock backend.
test "critic.run fast-path denylist latency (mock backend)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");

    // Benign code that passes fast-path and reaches LLM critic (mock returns APPROVE)
    const benign_code = "pub fn step() void { const x = 1 + 2; _ = x; }";
    // Code that triggers denylist (blocked before LLM call)
    const dangerous_code = "pub fn step() void { const c = std.process.Child.init(&.{\"sh\"}, .{}); }";

    const iterations = 1000;
    var total_benign_ns: u64 = 0;
    var total_dangerous_ns: u64 = 0;
    var min_benign_ns: u64 = std.math.maxInt(u64);
    var max_benign_ns: u64 = 0;
    var min_dangerous_ns: u64 = std.math.maxInt(u64);
    var max_dangerous_ns: u64 = 0;

    for (0..iterations) |_| {
        // Benign
        var start = clockNs();
        _ = try critic.run(&ctx, benign_code);
        var elapsed = clockNs() - start;
        total_benign_ns += elapsed;
        if (elapsed < min_benign_ns) min_benign_ns = elapsed;
        if (elapsed > max_benign_ns) max_benign_ns = elapsed;

        // Dangerous (denylist)
        start = clockNs();
        _ = try critic.run(&ctx, dangerous_code);
        elapsed = clockNs() - start;
        total_dangerous_ns += elapsed;
        if (elapsed < min_dangerous_ns) min_dangerous_ns = elapsed;
        if (elapsed > max_dangerous_ns) max_dangerous_ns = elapsed;
    }

    const avg_benign_ns = total_benign_ns / iterations;
    const avg_dangerous_ns = total_dangerous_ns / iterations;
    std.debug.print("critic.run fast-path (mock):\n", .{});
    std.debug.print("  benign (reaches LLM):\n", .{});
    std.debug.print("    iterations: {d}\n", .{iterations});
    std.debug.print("    avg: {d} µs ({d} ns)\n", .{ avg_benign_ns / 1000, avg_benign_ns });
    std.debug.print("    min: {d} µs ({d} ns)\n", .{ min_benign_ns / 1000, min_benign_ns });
    std.debug.print("    max: {d} µs ({d} ns)\n", .{ max_benign_ns / 1000, max_benign_ns });
    std.debug.print("  dangerous (denylist blocked):\n", .{});
    std.debug.print("    iterations: {d}\n", .{iterations});
    std.debug.print("    avg: {d} µs ({d} ns)\n", .{ avg_dangerous_ns / 1000, avg_dangerous_ns });
    std.debug.print("    min: {d} µs ({d} ns)\n", .{ min_dangerous_ns / 1000, min_dangerous_ns });
    std.debug.print("    max: {d} µs ({d} ns)\n", .{ max_dangerous_ns / 1000, max_dangerous_ns });
}

// Benchmark critic.reviewPlan with mock backend.
test "critic.reviewPlan latency (mock backend)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");

    const plans = [_][]const u8{
        "STEP: implement the body\nSTEP: add a unit test\n",
        "STEP: design the API\nSTEP: implement the core\nSTEP: add tests\nSTEP: write docs\n",
        "STEP: setup project\nSTEP: write main logic\nSTEP: handle errors\nSTEP: add tests\nSTEP: benchmark\n",
    };

    const iterations = 100;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |i| {
        const plan = plans[i % plans.len];
        const start = clockNs();
        _ = try critic.reviewPlan(&ctx, plan);
        const elapsed = clockNs() - start;
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    const avg_ns = total_ns / iterations;
    std.debug.print("critic.reviewPlan (mock):\n", .{});
    std.debug.print("  iterations: {d}\n", .{iterations});
    std.debug.print("  avg: {d} µs ({d} ns)\n", .{ avg_ns / 1000, avg_ns });
    std.debug.print("  min: {d} µs ({d} ns)\n", .{ min_ns / 1000, min_ns });
    std.debug.print("  max: {d} µs ({d} ns)\n", .{ max_ns / 1000, max_ns });
}
