const std = @import("std");
const types = @import("types.zig");

pub const Config = struct {
    mode: types.Mode,
    backend: types.LlmBackend,
    task: []const u8,
    workdir: []const u8,
    cache_path: ?[]const u8,
    expect: ?[]const u8,
};

pub fn parse(gpa: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !Config {
    _ = gpa;
    var mode: types.Mode = .no_hitl;
    var backend: types.LlmBackend = .mock;
    var task: ?[]const u8 = null;
    var workdir: []const u8 = "ae_out";
    var cache_path: ?[]const u8 = null;
    var expect: ?[]const u8 = null;

    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--hitl")) mode = .hitl else if (std.mem.eql(u8, arg, "--no-hitl")) mode = .no_hitl else if (std.mem.eql(u8, arg, "--mock")) backend = .mock else if (std.mem.eql(u8, arg, "--openai")) backend = .openai else if (std.mem.eql(u8, arg, "--local")) backend = .local else if (std.mem.eql(u8, arg, "--out")) {
            if (args.next()) |w| workdir = w;
        } else if (std.mem.eql(u8, arg, "--task")) {
            if (args.next()) |t| task = t;
        } else if (std.mem.eql(u8, arg, "--expect")) {
            if (args.next()) |e| expect = e;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            cache_path = ".yuxi_cache";
        } else if (std.mem.startsWith(u8, arg, "--cache=")) {
            cache_path = arg["--cache=".len..];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp(io);
            return error.HelpRequested;
        } else if (task == null) task = arg;
    }

    const t = task orelse {
        printHelp(io);
        return error.MissingTask;
    };
    return .{ .mode = mode, .backend = backend, .task = t, .workdir = workdir, .cache_path = cache_path, .expect = expect };
}
fn printHelp(io: std.Io) void {
    types.logLine(io, "Yuxi (玉溪): autonomous software evolution engine", .{});
    types.logLine(io, "yuxi [--hitl|--no-hitl] [--mock|--openai|--local] [--cache[=DIR]] [--out DIR] [--task TEXT] TASK", .{});
}
