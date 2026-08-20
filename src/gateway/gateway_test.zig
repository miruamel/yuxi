const std = @import("std");
const types = @import("types");
const gateway = @import("gateway");

test "gateway.run rejects a short task" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");
    const r = try gateway.run(&ctx, "ab");
    try std.testing.expect(r == null);
}

test "gateway.run returns the sanitized task on admission" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");
    const r = (try gateway.run(&ctx, "email me at a@b.com about x")).?;
    defer allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "@") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "b.com") == null);
    try std.testing.expect(std.mem.eql(u8, r, "email me at <redacted> about x"));
}

test "gateway.run redacts the whole email token (domain must not leak)" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");
    const r = (try gateway.run(&ctx, "contact user@corp.com now")).?;
    defer allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "corp.com") == null);
    try std.testing.expect(std.mem.eql(u8, r, "contact <redacted> now"));
}

test "gateway.run leaves non-PII tasks untouched" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");
    const r = (try gateway.run(&ctx, "add a function returning 42")).?;
    defer allocator.free(r);
    try std.testing.expect(std.mem.eql(u8, r, "add a function returning 42"));
}
