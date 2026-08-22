const std = @import("std");
const critic = @import("critic");
const types = @import("types");

test "critic.parseVerdict parses approve/reject with reason" {
    const a = std.testing.allocator;
    const va = try critic.parseVerdict(a, "APPROVE");
    try std.testing.expect(va.ok);
    try std.testing.expect(va.reason == null);
    const vr = try critic.parseVerdict(a, "REJECT missing error handling");
    try std.testing.expect(!vr.ok);
    try std.testing.expectEqualStrings("missing error handling", vr.reason.?);
    a.free(vr.reason.?);
    const vr2 = try critic.parseVerdict(a, "reject\nbad naming");
    try std.testing.expect(!vr2.ok);
    try std.testing.expectEqualStrings("bad naming", vr2.reason.?);
    a.free(vr2.reason.?);
    const vd = try critic.parseVerdict(a, "ambiguous text");
    try std.testing.expect(vd.ok);
}

test "critic fast-path blocks dangerous constructs" {
    // page_allocator: run() records events; the testing allocator would flag
    // those as leaks, so mirror the engine integration test's choice.
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");
    // Exact form still blocked (now via the broader "std.process" substring).
    const v = try critic.run(&ctx, "pub fn step0() void { const c = std.process.Child.init(&.{\"sh\"}, .{}); }");
    try std.testing.expect(!v.ok);
    try std.testing.expect(v.reason != null);
    try std.testing.expect(std.mem.indexOf(u8, v.reason.?, "std.process") != null);
    allocator.free(v.reason.?);
    // C-interop via @cImport still blocked.
    const v2 = try critic.run(&ctx, "pub fn step1() void { const x = @cImport({ @cInclude(\"x.h\"); }); }");
    try std.testing.expect(!v2.ok);
    try std.testing.expect(std.mem.indexOf(u8, v2.reason.?, "@cImport") != null);
    allocator.free(v2.reason.?);
    // Indirection MUST also be blocked: "@field(std.process, \"Child\")"
    // contains "std.process" but NOT the exact token "std.process.Child".
    // This is the bypass the broader denylist closes (the prior exact-token
    // match let it through to the evaluator/deploy).
    const v3 = try critic.run(&ctx, "pub fn step2() void { const P = @field(std.process, \"Child\"); _ = P; }");
    try std.testing.expect(!v3.ok);
    try std.testing.expect(std.mem.indexOf(u8, v3.reason.?, "std.process") != null);
    allocator.free(v3.reason.?);
    // spawn() is on the same namespace; must be blocked even without ".Child".
    const v4 = try critic.run(&ctx, "pub fn step3() void { _ = std.process.spawn; }");
    try std.testing.expect(!v4.ok);
    try std.testing.expect(std.mem.indexOf(u8, v4.reason.?, "std.process") != null);
    allocator.free(v4.reason.?);
    // Inline assembly and symbol export are out of scope for a generated step; blocked.
    const v5 = try critic.run(&ctx, "pub fn step4() void { asm volatile (\"nop\"); }");
    try std.testing.expect(!v5.ok);
    try std.testing.expect(std.mem.indexOf(u8, v5.reason.?, "asm") != null);
    allocator.free(v5.reason.?);
    const v6 = try critic.run(&ctx, "pub fn step5() void { @export(std.process, .{ .name = \"x\" }); }");
    try std.testing.expect(!v6.ok);
    allocator.free(v6.reason.?);
}

// Property test: denylist detects all patterns across indirection forms
// Each pattern must be caught regardless of how it's embedded
test "critic.denylist comprehensive indirection coverage" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");

    // Test cases: {pattern, variations...}
    // Each pattern from deny_list tested with multiple embedding forms
    const TestCase = struct {
        pattern: []const u8,
        variations: []const []const u8,
    };
    const test_cases = [_]TestCase{
        .{
            .pattern = "std.process",
            .variations = &[_][]const u8{
                "std.process.Child.init",
                "std.process.spawn",
                "@field(std.process, \"Child\")",
                "const x = std.process;",
                "std.process.Command",
                "std.process.ExitCode",
            },
        },
        .{
            .pattern = "@cImport",
            .variations = &[_][]const u8{
                "@cImport({ @cInclude(\"x.h\"); })",
                "@cImport(@cInclude(\"y.h\"))",
                "const x = @cImport;",
                "@cImport({@cDefine(\"FOO\"); @cInclude(\"z.h\");})",
            },
        },
        .{
            .pattern = "@import(\"c\")",
            .variations = &[_][]const u8{
                "@import(\"c\")",
                "const libc = @import(\"c\");",
                "@import(\"c\").printf",
            },
        },
        .{
            .pattern = "asm",
            .variations = &[_][]const u8{
                "asm volatile (\"nop\");",
                "asm (\"mov rax, 1\");",
                "const x = asm;",
                "inline asm (\"nop\");",
            },
        },
        .{
            .pattern = "@export",
            .variations = &[_][]const u8{
                "@export(my_func, .{ .name = \"x\" });",
                "@export(other_func, .{ .name = \"foo\" });",
                "const x = @export;",
            },
        },
    };

    for (test_cases) |tc| {
        for (tc.variations) |code| {
            const full_code = try std.fmt.allocPrint(allocator, "pub fn step() void {{ {s} }}", .{code});
            defer allocator.free(full_code);
            const v = try critic.run(&ctx, full_code);
            if (v.ok) {
                std.debug.print("FAILED to block pattern: {s} in code: {s}\n", .{ tc.pattern, code });
                return error.TestFailed;
            }
            try std.testing.expect(v.reason != null);
            if (std.mem.indexOf(u8, v.reason.?, tc.pattern) == null) {
                std.debug.print("Reason missing pattern: {s}, got: {s}\n", .{ tc.pattern, v.reason.? });
                return error.TestFailed;
            }
            allocator.free(v.reason.?);
        }
    }
}

// Property test: benign code without dangerous constructs passes fast-path
test "critic.fast-path allows benign code" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");

    const benign_cases = [_][]const u8{
        "pub fn step() void { const x = 1 + 2; _ = x; }",
        "pub fn step() void { var sum: i32 = 0; for (0..10) |i| sum += i; _ = sum; }",
        "pub fn step() void { const arr = [_]i32{1,2,3}; _ = arr.len; }",
        "pub fn step() void { const s = \"hello\"; _ = s.len; }",
        "pub fn step() void { const opt: ?i32 = 42; _ = opt.?; }",
        "pub fn step() void { std.debug.print(\"hello\\n\", .{}); }",
        "pub fn step() void { const f = std.fmt.format; _ = f; }",
        "pub fn step() void { std.mem.copy(u8, &[0]u8, &[0]u8); }",
    };

    for (benign_cases) |code| {
        // These should NOT be rejected by fast-path (panic/denylist)
        // They will reach the LLM critic which with mock backend returns APPROVE
        const v = try critic.run(&ctx, code);
        try std.testing.expect(v.ok);
    }
}

// Property test: panic detection works for various forms
test "critic.fast-path blocks panic in various forms" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(allocator, io, .empty, .no_hitl, .mock, null, "", "ae_out");

    const panic_forms = [_][]const u8{
        "panic(\"oops\")",
        "panic(\"error: {}\", .{x})",
        "std.debug.panic(\"msg\")",
        "if (false) panic(\"unreachable\") else {}",
        "return panic(\"never\")",
    };

    for (panic_forms) |code| {
        const full_code = try std.fmt.allocPrint(allocator, "pub fn step() void {{ {s} }}", .{code});
        defer allocator.free(full_code);
        const v = try critic.run(&ctx, full_code);
        try std.testing.expect(!v.ok);
        try std.testing.expect(v.reason == null); // panic fast-path returns no reason
    }
}
