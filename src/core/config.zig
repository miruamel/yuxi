const std = @import("std");
const types = @import("types");

pub const Config = struct {
    mode: types.Mode,
    backend: types.LlmBackend,
    task: []const u8,
    workdir: []const u8,
    cache_path: ?[]const u8,
    expect: ?[]const u8,
    max_tokens: ?usize,
    tasks: ?[]const u8,
    kb_path: ?[]const u8,
    kb_max_lines: ?usize,
    replay_path: ?[]const u8,
    record_path: ?[]const u8,
};

pub fn parse(gpa: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !Config {
    _ = gpa;
    var mode: types.Mode = .no_hitl;
    var backend: types.LlmBackend = .mock;
    var task: ?[]const u8 = null;
    var workdir: []const u8 = "ae_out";
    var cache_path: ?[]const u8 = null;
    var expect: ?[]const u8 = null;
    var max_tokens: ?usize = null;
    var tasks: ?[]const u8 = null;
    var kb_path: ?[]const u8 = null;
    var kb_max_lines: ?usize = null;
    var replay_path: ?[]const u8 = null;
    var record_path: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--tasks")) {
            if (args.next()) |p| tasks = p;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            if (args.next()) |m| max_tokens = std.fmt.parseUnsigned(usize, m, 10) catch null;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp(io);
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--kb")) {
            if (args.next()) |p| kb_path = p;
        } else if (std.mem.startsWith(u8, arg, "--kb=")) {
            kb_path = arg["--kb=".len..];
        } else if (std.mem.eql(u8, arg, "--replay")) {
            if (args.next()) |p| replay_path = p;
        } else if (std.mem.startsWith(u8, arg, "--replay=")) {
            replay_path = arg["--replay=".len..];
        } else if (std.mem.eql(u8, arg, "--kb-max-lines")) {
            kb_max_lines = 200;
        } else if (std.mem.startsWith(u8, arg, "--kb-max-lines=")) {
            kb_max_lines = std.fmt.parseUnsigned(usize, arg["--kb-max-lines=".len..], 10) catch 200;
        } else if (std.mem.eql(u8, arg, "--record")) {
            record_path = ".yuxi_record.txt";
        } else if (std.mem.startsWith(u8, arg, "--record=")) {
            record_path = arg["--record=".len..];
        } else if (task == null) task = arg;
    }

    const t = if (tasks) |_| "" else task orelse {
        printHelp(io);
        return error.MissingTask;
    };
    return .{ .mode = mode, .backend = backend, .task = t, .workdir = workdir, .cache_path = cache_path, .expect = expect, .max_tokens = max_tokens, .tasks = tasks, .kb_path = kb_path, .kb_max_lines = kb_max_lines, .replay_path = replay_path, .record_path = record_path };
}
fn printHelp(io: std.Io) void {
    types.logLine(io, "Yuxi (玉溪): autonomous software evolution engine", .{});
    types.logLine(io, "yuxi [--hitl|--no-hitl] [--mock|--openai|--local] [--max-tokens N] [--cache[=DIR]] [--kb[=DIR]] [--replay[=FILE]] [--record[=FILE]] [--out DIR] [--task TEXT] [--expect TEXT] [--tasks FILE] TASK", .{});
}
