const std = @import("std");
const types = @import("types");
const transport = @import("transport");
const fs = @import("fs");
const resilience = @import("resilience");

pub fn run(ctx: *types.Ctx, step: *types.Step, path: []const u8, feedback: ?[]const u8) !bool {
    ctx.log("[builder] planning step {d}: {s}", .{ step.id, step.name });
    const sys = "You are a code generator for ONE step of a larger program. Emit exactly one Zig function named `stepN` (N = the step number you are given) with signature `pub fn stepN() void`. Do NOT add `const std = @import(\"std\");` and do NOT write `main` -- the harness supplies the import and entry point. No markdown, no explanation.";
    const user = try promptFor(ctx.allocator, step, feedback);
    defer ctx.allocator.free(user);

    const code = transport.complete(ctx.allocator, ctx.io, ctx, sys, user) catch |e| {
        ctx.log("[builder] LLM failed: {s}; fallback to mock", .{@errorName(e)});
        resilience.fallback(ctx);
        ctx.mock_fallbacks += 1;
        const c = try transport.complete(ctx.allocator, ctx.io, ctx, sys, user);
        return writeAndMark(ctx, step, path, c);
    };
    return writeAndMark(ctx, step, path, code);
}

fn writeAndMark(ctx: *types.Ctx, step: *types.Step, path: []const u8, code: []const u8) !bool {
    defer ctx.allocator.free(code);
    if (ctx.mode == .hitl) {
        ctx.log("[builder] HITL gate: approve write to {s}? [y/N]", .{path});
        var buf: [16]u8 = undefined;
        const n = std.os.linux.read(0, &buf, buf.len);
        if (n == 0 or (buf[0] != 'y' and buf[0] != 'Y')) {
            ctx.log("[builder] HITL: rejected by operator", .{});
            step.status = .rejected;
            return false;
        }
    }
    try fs.writeFileAlloc(ctx.allocator, path, code);
    ctx.log("[builder] wrote {d} bytes -> {s}", .{ code.len, path });
    step.status = .ok;
    ctx.record("builder: wrote file");
    return true;
}
/// Build the builder's user prompt. When `feedback` (a prior evaluation
/// error) is present, it is embedded so the LLM can correct code that
/// failed to compile or run.
fn promptFor(alloc: std.mem.Allocator, step: *const types.Step, feedback: ?[]const u8) ![]u8 {
    if (feedback) |fb| {
        return std.fmt.allocPrint(alloc, "Implement step {d}: {s}\nThe previous attempt failed to compile or run. Error output:\n{s}\nFix the code so it compiles and runs cleanly. Keep the exact `step{d}()` signature and `pub fn step{d}() void` form.", .{ step.id, step.name, fb, step.id, step.id });
    }
    return std.fmt.allocPrint(alloc, "Implement step {d}: {s}", .{ step.id, step.name });
}

test "builder.promptFor embeds feedback when present" {
    const a = std.testing.allocator;
    const step = types.Step{ .id = 2, .name = "add two ints", .status = .pending, .notes = "" };
    const p0 = try promptFor(a, &step, null);
    defer a.free(p0);
    try std.testing.expectEqualStrings("Implement step 2: add two ints", p0);
    const fb = "error: expected ';' found '}'";
    const p1 = try promptFor(a, &step, fb);
    defer a.free(p1);
    try std.testing.expect(std.mem.indexOf(u8, p1, fb) != null);
    try std.testing.expect(std.mem.indexOf(u8, p1, "step2()") != null);
}
