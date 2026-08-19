const std = @import("std");
const types = @import("core/types.zig");
const config = @import("core/config.zig");
const engine = @import("core/engine.zig");
const cache_mod = @import("util/cache.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    const cfg = config.parse(gpa, io, &it) catch return;
    const base = switch (cfg.backend) {
        .mock => try arena.dupe(u8, ""),
        .openai => try arena.dupe(u8, std.process.Environ.getPosix(init.minimal.environ, "OPENAI_BASE") orelse "https://api.openai.com/v1"),
        .local => try arena.dupe(u8, std.process.Environ.getPosix(init.minimal.environ, "LOCAL_BASE") orelse "http://localhost:11434/v1"),
    };
    const raw_key = if (cfg.backend == .openai)
        std.process.Environ.getPosix(init.minimal.environ, "OPENAI_API_KEY")
    else
        null;
    const key: ?[]const u8 = if (raw_key) |k| arena.dupe(u8, k) catch null else null;

    var ctx = try types.Ctx.init(arena, io, init.minimal.environ, cfg.mode, cfg.backend, key, base, cfg.workdir);
    ctx.expected = cfg.expect;
    ctx.max_tokens = cfg.max_tokens;
    ctx.cache = blk: {
        const cp = cfg.cache_path orelse break :blk null;
        const c = arena.create(cache_mod.Cache) catch break :blk null;
        c.* = cache_mod.Cache.init(arena, cp) catch break :blk null;
        break :blk c;
    };
    try engine.run(arena, io, &ctx, cfg.task);
}
