const std = @import("std");
const types = @import("types");
const evaluator = @import("evaluator");
const fs = @import("fs");

/// Monotonic clock helper.
fn clockNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

// Benchmark evaluator.run for compile+run of valid Zig.
test "evaluator.run compile+run latency (valid code)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const code = "pub fn main() void { const x: i32 = 2 + 3; if (x != 5) @panic(\"bad\"); }";
    const path = "/tmp/eval_bench_valid.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(code);
        try w.flush();
    }
    defer std.Io.Dir.deleteFile(cwd, io, path) catch {};

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", ".");

    // Single warmup + measurement (compile+run is slow; no 50-iter loop to avoid OOM)
    const start = clockNs();
    const ok = try evaluator.run(&ctx, path);
    const elapsed = clockNs() - start;

    std.debug.print("evaluator.run compile+run (valid):\n", .{});
    std.debug.print("  elapsed: {d} ms ({d} µs)\n", .{ elapsed / 1_000_000, elapsed / 1000 });
    std.debug.print("  compile_ok: {}\n", .{ok});
}

// Benchmark evaluator.run for compile failure (invalid code).
test "evaluator.run compile failure latency (invalid code)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const code = "this is not valid zig @@@";
    const path = "/tmp/eval_bench_invalid.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(code);
        try w.flush();
    }
    defer std.Io.Dir.deleteFile(cwd, io, path) catch {};

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", ".");

    const start = clockNs();
    const ok = try evaluator.run(&ctx, path);
    const elapsed = clockNs() - start;

    std.debug.print("evaluator.run compile failure (invalid):\n", .{});
    std.debug.print("  elapsed: {d} ms ({d} µs)\n", .{ elapsed / 1_000_000, elapsed / 1000 });
    std.debug.print("  compile_fail: {}\n", .{!ok});
}

// Benchmark evaluator.run with behavioral verification (--expect).
test "evaluator.run with --expect behavioral verification latency" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const code = "const std = @import(\"std\");\npub fn main() void { std.debug.print(\"hello\\n\", .{}); }";
    const path = "/tmp/eval_bench_expect.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(code);
        try w.flush();
    }
    defer std.Io.Dir.deleteFile(cwd, io, path) catch {};

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", ".");
    ctx.expected = "hello";

    const start = clockNs();
    const ok = try evaluator.run(&ctx, path);
    const elapsed = clockNs() - start;

    std.debug.print("evaluator.run with --expect (match):\n", .{});
    std.debug.print("  elapsed: {d} ms ({d} µs)\n", .{ elapsed / 1_000_000, elapsed / 1000 });
    std.debug.print("  accepted: {}\n", .{ok});
}
