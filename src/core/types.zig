const std = @import("std");
const cache_mod = @import("../util/cache.zig");

pub const Mode = enum { hitl, no_hitl };
pub const LlmBackend = enum { mock, openai, local };

pub const Status = enum { pending, ok, rejected, failed };

pub const Step = struct {
    id: usize,
    name: []const u8,
    status: Status,
    notes: []const u8,
};

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    mode: Mode,
    backend: LlmBackend,
    llm_key: ?[]const u8,
    llm_base: []const u8,
    workdir: []const u8,
    tokens: usize,
    cache: ?*cache_mod.Cache,
    events: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, mode: Mode, backend: LlmBackend, key: ?[]const u8, base: []const u8, workdir: []const u8) !Ctx {
        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .mode = mode,
            .backend = backend,
            .llm_key = key,
            .llm_base = base,
            .workdir = workdir,
            .tokens = 0,
            .cache = null,
            .events = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn record(self: *Ctx, msg: []const u8) void {
        const owned = self.allocator.dupe(u8, msg) catch return;
        self.events.append(self.allocator, owned) catch {};
    }

    pub fn log(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        logLine(self.io, fmt, args);
    }
};

pub fn logLine(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.writeAll("\n") catch {};
    w.flush() catch {};
}
