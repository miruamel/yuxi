const std = @import("std");

/// Merge step fragments into one runnable program: a std import, each step
/// function, and a `main` that calls them in order. Invalid composition
/// (e.g. a step whose function fails to compile) surfaces at the evaluator.
pub fn merge(alloc: std.mem.Allocator, frags: [][]const u8) ![]u8 {
    var body = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "const std = @import(\"std\");\n\n");
    for (frags) |f| {
        try body.appendSlice(alloc, f);
        try body.appendSlice(alloc, "\n");
    }
    var calls = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer calls.deinit(alloc);
    var i: usize = 0;
    while (i < frags.len) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "    _ = step{d}();\n", .{i});
        try calls.appendSlice(alloc, line);
        alloc.free(line);
    }
    return try std.fmt.allocPrint(alloc, "{s}\npub fn main() void {{\n{s}}}\n", .{ body.items, calls.items });
}

test "compose.merge merges step fragments with a main harness" {
    const allocator = std.testing.allocator;
    var frags = [_][]const u8{
        "pub fn step0() void { std.debug.print(\"a\", .{}); }",
        "pub fn step1() void { std.debug.print(\"b\", .{}); }",
    };
    const prog = try merge(allocator, &frags);
    defer allocator.free(prog);
    try std.testing.expect(std.mem.indexOf(u8, prog, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "pub fn step0() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "pub fn step1() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "pub fn main() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "    _ = step0();") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog, "    _ = step1();") != null);
}
