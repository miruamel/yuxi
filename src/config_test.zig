const std = @import("std");
const types = @import("types");
const config = @import("config");

fn parseArgs(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !config.Config {
    // config.parse borrows its string fields (task, workdir, kb_path, ...) from
    // the argument slices, so the null-terminated copies must outlive the
    // returned Config. Allocate them from page_allocator (not leak-checked) so
    // std.testing.allocator stays clean and the borrowed slices stay valid.
    const tmp = std.heap.page_allocator;
    var vec: [16][*:0]u8 = undefined;
    for (argv, 0..) |a, i| {
        const buf = try tmp.alloc(u8, a.len + 1);
        @memcpy(buf[0..a.len], a);
        buf[a.len] = 0;
        vec[i] = @ptrCast(buf.ptr);
    }
    const args = std.process.Args{ .vector = vec[0..argv.len] };
    var it = std.process.Args.Iterator.init(args);
    return config.parse(alloc, io, &it);
}

// A real Io keeps the tests honest about the parse contract without threading
// stdout through the help printer's formatting.
fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "config parses backend + knows feature flags are off by default" {
    const io = testIo();
    const argv = [_][]const u8{ "./yuxi", "--openai", "--task", "hello" };
    const cfg = try parseArgs(std.testing.allocator, io, &argv);
    try std.testing.expectEqual(types.LlmBackend.openai, cfg.backend);
    // Off-by-default features must stay off until the flag is passed.
    try std.testing.expect(cfg.kb_max_lines == null);
    try std.testing.expect(cfg.cache_path == null);
    try std.testing.expect(cfg.replay_path == null);
    try std.testing.expect(cfg.record_path == null);
    try std.testing.expectEqualStrings("hello", cfg.task);
}

test "config --kb-max-lines defaults to 200 (bare) and parses N" {
    const io = testIo();
    const bare = [_][]const u8{ "./yuxi", "--kb-max-lines", "--mock", "--task", "t" };
    const b = try parseArgs(std.testing.allocator, io, &bare);
    try std.testing.expectEqual(@as(usize, 200), b.kb_max_lines.?);
    const set = [_][]const u8{ "./yuxi", "--kb-max-lines=50", "--mock", "--task", "t" };
    const s = try parseArgs(std.testing.allocator, io, &set);
    try std.testing.expectEqual(@as(usize, 50), s.kb_max_lines.?);
}

test "config --help and missing task are reachable error paths" {
    const io = testIo();
    // --help must signal HelpRequested so the (now always-current) help path is
    // reachable from the CLI, not dead code.
    const help = [_][]const u8{ "./yuxi", "--help" };
    try std.testing.expectError(error.HelpRequested, parseArgs(std.testing.allocator, io, &help));
    // A bare invocation with no task must fail rather than silently defaulting.
    const mock = [_][]const u8{ "./yuxi", "--mock" };
    try std.testing.expectError(error.MissingTask, parseArgs(std.testing.allocator, io, &mock));
}

test "config --version and -V are reachable and exit-zero info paths" {
    const io = testIo();
    // `--version` must signal VersionRequested so the (now always-current)
    // version path is reachable from the CLI, not dead code. Same success
    // contract as `--help` (exit 0); the actual version string is asserted
    // against the built binary in the main test's smoke check.
    const v = [_][]const u8{ "./yuxi", "--version" };
    try std.testing.expectError(error.VersionRequested, parseArgs(std.testing.allocator, io, &v));
    const vshort = [_][]const u8{ "./yuxi", "-V" };
    try std.testing.expectError(error.VersionRequested, parseArgs(std.testing.allocator, io, &vshort));
}
