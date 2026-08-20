const std = @import("std");
const config = @import("config");
const loop = @import("loop");
const knowledge = @import("knowledge");
test "loop.runTasks iterates tasks, skips comments, reports health" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const tasks_path = "/tmp/yuxi_loop_tasks.txt";

    {
        const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, tasks_path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll("add a function returning 42\n# a comment\nadd a function returning 7\n\n");
        try w.flush();
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
        .kb_path = null,
        .replay_path = null,
        .record_path = null,
    };

    var results = try loop.runTasks(allocator, io, .empty, cfg, tasks_path);
    defer results.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    for (results.items) |r| {
        try std.testing.expect(r.deploys >= 1);
        try std.testing.expect(r.healthy);
    }
}

test "loop.runTasks persists a batch summary to the KB when configured" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const tasks_path = "/tmp/yuxi_loop_kb_tasks.txt";
    const kb_base = "/tmp/yuxi_loop_kb_test";
    const kb_path = try std.fmt.allocPrint(allocator, "{s}/kb.md", .{kb_base});
    defer allocator.free(kb_path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, kb_base) catch {};

    {
        const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, tasks_path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll("add a function returning 42\nadd a function returning 7\n");
        try w.flush();
    }
    const cfg = config.Config{
        .mode = .no_hitl,
        .backend = .mock,
        .task = "",
        .workdir = "/tmp/yuxi_loop_test2",
        .cache_path = null,
        .expect = null,
        .max_tokens = null,
        .tasks = tasks_path,
        .kb_path = kb_path,
        .replay_path = null,
        .record_path = null,
    };

    var results = try loop.runTasks(allocator, io, .empty, cfg, tasks_path);
    defer results.deinit(allocator);

    const got = (try knowledge.load(allocator, kb_path)).?;
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "- batch: tasks=2 deploys=2 unhealthy=0") != null);
}
