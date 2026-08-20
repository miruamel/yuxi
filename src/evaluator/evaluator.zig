const std = @import("std");
const types = @import("types");
const fs = @import("fs");

pub fn run(ctx: *types.Ctx, path: []const u8) !bool {
    ctx.log("[evaluator] compile+run: {s}", .{path});

    const bin_path = try std.fmt.allocPrint(ctx.allocator, "{s}.eval-bin", .{path});
    defer ctx.allocator.free(bin_path);
    const out_path = try std.fmt.allocPrint(ctx.allocator, "{s}.eval-out", .{path});
    defer ctx.allocator.free(out_path);

    // Compile the generated artifact into a real executable. Output is captured
    // to a file (not piped) so behavioral verification and self-correction
    // feedback always observe the real compiler/run text.
    const emit_arg = try std.fmt.allocPrint(ctx.allocator, "-femit-bin={s}", .{bin_path});
    defer ctx.allocator.free(emit_arg);
    const compile_argv = [_][]const u8{ "/opt/zig/zig", "build-exe", path, emit_arg };
    const compiled = switch (try runTo(ctx, &compile_argv, out_path)) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!compiled) {
        const err = try readOut(ctx.allocator, out_path);
        defer ctx.allocator.free(err);
        ctx.log("[evaluator] compile FAILED:\n{s}", .{err});
        ctx.setEvalError(err);
        cleanup(ctx, bin_path, out_path);
        return false;
    }
    ctx.log("[evaluator] compile OK", .{});

    const run_argv = [_][]const u8{bin_path};
    const ran = switch (try runTo(ctx, &run_argv, out_path)) {
        .exited => |code| code == 0,
        else => false,
    };
    var accepted = false;
    if (!ran) {
        const err = try readOut(ctx.allocator, out_path);
        defer ctx.allocator.free(err);
        ctx.log("[evaluator] run FAILED:\n{s}", .{err});
        ctx.setEvalError(err);
    } else {
        const out = try readOut(ctx.allocator, out_path);
        defer ctx.allocator.free(out);
        ctx.log("[evaluator] run OK (output):\n{s}", .{out});
        // Behavioral verification: a supplied spec makes a clean run whose output
        // doesn't match still a failure, fed back via ctx.eval_error.
        if (ctx.expected) |exp| {
            const got = std.mem.trim(u8, out, &std.ascii.whitespace);
            const want = std.mem.trim(u8, exp, &std.ascii.whitespace);
            if (!std.mem.eql(u8, got, want)) {
                ctx.log("[evaluator] output mismatch: expected '{s}' got '{s}'", .{ exp, out });
                ctx.setEvalError(std.fmt.allocPrint(ctx.allocator, "expected output '{s}' but got '{s}'", .{ exp, out }) catch "output mismatch");
            } else {
                accepted = true;
            }
        } else {
            accepted = true;
        }
    }

    cleanup(ctx, bin_path, out_path);
    if (accepted) ctx.clearEvalError();
    ctx.record("evaluator: done");
    return accepted;
}

/// Read the captured-output file written by `runTo`.
fn readOut(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return fs.readFileAlloc(allocator, path);
}

/// Spawn a child, redirecting both stdout and stderr to `out_path`, and wait.
/// `ctx.io` is the global single-threaded Io whose `allocator` field is
/// `.failing` (see `std.Io.Threaded.init_single_threaded`), so passing it to
/// `std.process.spawn` OOMs on the argv/env arena. A per-call `Threaded`
/// backed by `ctx.allocator` (a real allocator) has a working allocator and is
/// safe for the spawn and the output-file redirect. The `environ` is taken from
/// `global_single_threaded` (the real OS environment): `spawnPosix` uses the
/// Threaded instance's own environ when `SpawnOptions.environ_map` is null, and
/// a default-initialized `Threaded` has an *empty* environ, which makes the
/// child `zig` fail with `AppDataDirUnavailable`.
fn runTo(ctx: *types.Ctx, argv: []const []const u8, out_path: []const u8) !std.process.Child.Term {
    var threaded = std.Io.Threaded.init(ctx.allocator, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    defer threaded.deinit();
    const io = threaded.io();
    const out_file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, out_path, .{ .truncate = true });
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = out_file },
    });
    const term = try child.wait(io);
    return term;
}

fn cleanup(ctx: *types.Ctx, bin_path: []const u8, out_path: []const u8) void {
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), ctx.io, bin_path) catch {};
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), ctx.io, out_path) catch {};
    const o_path = std.fmt.allocPrint(ctx.allocator, "{s}.o", .{bin_path}) catch "";
    defer if (o_path.len > 0) ctx.allocator.free(o_path);
    if (o_path.len > 0) std.Io.Dir.deleteFile(std.Io.Dir.cwd(), ctx.io, o_path) catch {};
}
test "evaluator.run gates deploy on compile+run" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const good = "/tmp/eval_test_good.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, good, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(
            \\pub fn main() void {
            \\    const x: i32 = 2 + 3;
            \\    if (x != 5) @panic("bad");
            \\}
        );
        try w.flush();
    }
    defer std.Io.Dir.deleteFile(cwd, io, good) catch {};

    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", ".");
    try std.testing.expect(try run(&ctx, good));
    try std.testing.expect(ctx.eval_error == null);

    const bad = "/tmp/eval_test_bad.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, bad, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll("this is not valid zig @@@");
        try w.flush();
    }
    defer std.Io.Dir.deleteFile(cwd, io, bad) catch {};

    try std.testing.expect(!(try run(&ctx, bad)));
    ctx.clearEvalError();
    // Behavioral verification: a matching expected output passes; a mismatch fails.
    const spec = "/tmp/eval_test_spec.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, spec, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(
            \\const std = @import("std");
            \\pub fn main() void {
            \\    std.debug.print("hello", .{});
            \\}
        );
        try w.flush();
    }
    defer std.Io.Dir.deleteFile(cwd, io, spec) catch {};
    ctx.expected = "hello";
    try std.testing.expect(try run(&ctx, spec));
    try std.testing.expect(ctx.eval_error == null);
    ctx.expected = "world";
    try std.testing.expect(!(try run(&ctx, spec)));
    if (ctx.eval_error) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e, "expected") != null);
        ctx.clearEvalError();
    }
    ctx.expected = null;
}
