const std = @import("std");
const types = @import("../core/types.zig");

pub fn run(ctx: *types.Ctx, path: []const u8) !bool {
    ctx.log("[evaluator] compile+run: {s}", .{path});

    const bin_path = try std.fmt.allocPrint(ctx.allocator, "{s}.eval-bin", .{path});
    defer ctx.allocator.free(bin_path);

    // Compile the generated artifact into a real executable.
    const emit_arg = try std.fmt.allocPrint(ctx.allocator, "-femit-bin={s}", .{bin_path});
    defer ctx.allocator.free(emit_arg);
    const compile_argv = [_][]const u8{ "/opt/zig/zig", "build-exe", path, emit_arg };
    const cres = std.process.run(ctx.allocator, ctx.io, .{ .argv = &compile_argv }) catch |e| {
        ctx.log("[evaluator] spawn failed: {s}", .{@errorName(e)});
        return false;
    };
    defer {
        ctx.allocator.free(cres.stdout);
        ctx.allocator.free(cres.stderr);
    }
    const compiled = switch (cres.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!compiled) {
        ctx.log("[evaluator] compile FAILED:\n{s}", .{cres.stderr});
        return false;
    }
    ctx.log("[evaluator] compile OK", .{});

    // Run the compiled artifact; the step is accepted only if it runs cleanly.
    const run_argv = [_][]const u8{bin_path};
    const rres = std.process.run(ctx.allocator, ctx.io, .{ .argv = &run_argv }) catch |e| {
        ctx.log("[evaluator] run spawn failed: {s}", .{@errorName(e)});
        return false;
    };
    defer {
        ctx.allocator.free(rres.stdout);
        ctx.allocator.free(rres.stderr);
    }
    const ran = switch (rres.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ran) {
        ctx.log("[evaluator] run FAILED (term={any}):\n{s}", .{ rres.term, rres.stderr });
    } else {
        ctx.log("[evaluator] run OK (stdout):\n{s}", .{rres.stdout});
        if (rres.stderr.len > 0) ctx.log("[evaluator] run OK (stderr):\n{s}", .{rres.stderr});
    }

    // Best-effort cleanup of the temporary executable and any emitted object file.
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), ctx.io, bin_path) catch {};
    const o_path = std.fmt.allocPrint(ctx.allocator, "{s}.o", .{bin_path}) catch "";
    defer if (o_path.len > 0) ctx.allocator.free(o_path);
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), ctx.io, o_path) catch {};

    ctx.record("evaluator: done");
    return ran;
}
test "evaluator.run gates deploy on compile+run" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const good = "eval_test_good.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, good, .{});
        defer file.close();
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

    const bad = "eval_test_bad.zig";
    {
        const file = try std.Io.Dir.createFile(cwd, io, bad, .{});
        defer file.close();
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll("this is not valid zig @@@");
        try w.flush();
    }
    defer std.Io.Dir.deleteFile(cwd, io, bad) catch {};

    try std.testing.expect(!(try run(&ctx, bad)));
}
