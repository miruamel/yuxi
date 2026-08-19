const std = @import("std");
const config = @import("core/config.zig");
const loop = @import("loop.zig");

test "loop.runTasks iterates tasks, skips comments, reports health" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const tasks_path = "/tmp/yuxi_loop_tasks.txt";

    {
        const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, tasks_path, .{});
        defer file.close();
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.writeAll("add a function returning 42\n# a comment\nadd a function returning 7\n\n");
    }

    const cfg = config.Config{
        .mode = .no_hitl,
        .backend = .mock,
        .task = "",
        .workdir = "/tmp/yuxi_loop_test",
        .cache_path = null,
        .expect = null,
        .max_tokens = null,
        .tasks = tasks_path,
    };

    var results = try loop.runTasks(allocator, io, .empty, cfg, tasks_path);
    defer results.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    for (results.items) |r| {
        try std.testing.expect(r.deploys >= 1);
        try std.testing.expect(r.healthy);
    }
}
