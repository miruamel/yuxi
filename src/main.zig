const std = @import("std");
const config = @import("config");
const engine = @import("engine");
const loop = @import("loop");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    const cfg = config.parse(arena, io, &it) catch return;

    if (cfg.tasks) |tasks_path| {
        var results = try loop.runTasks(arena, io, init.minimal.environ, cfg, tasks_path);
        results.deinit(arena);
        return;
    }
    var ctx = try engine.newCtx(arena, io, init.minimal.environ, cfg, cfg.workdir);
    try engine.run(arena, io, &ctx, cfg.task);
}
