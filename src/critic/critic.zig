const std = @import("std");
const types = @import("../core/types.zig");
const transport = @import("../llm/transport.zig");

pub const Verdict = struct {
    ok: bool,
    reason: ?[]const u8,
};

pub fn run(ctx: *types.Ctx, code: []const u8) !Verdict {
    // Fast-path rules engine.
    if (std.mem.indexOf(u8, code, "panic(") != null) {
        ctx.log("[critic] fast-path: rejected (contains panic)", .{});
        ctx.record("critic: rejected (panic)");
        return Verdict{ .ok = false, .reason = null };
    }
    // LLM critic. The reason (when present) is owned by the caller.
    const sys = "You are a code critic. Reply APPROVE or REJECT followed by a short reason.";
    const user = try std.fmt.allocPrint(ctx.allocator, "Review:\n{s}", .{code});
    defer ctx.allocator.free(user);
    const resp = try transport.complete(ctx.allocator, ctx.io, ctx, sys, user);
    defer ctx.allocator.free(resp);
    const v = try parseVerdict(ctx.allocator, resp);
    ctx.log("[critic] verdict: {s}", .{if (v.ok) "APPROVE" else "REJECT"});
    if (v.reason) |r| ctx.log("[critic] reason: {s}", .{r});
    ctx.record("critic: done");
    return v;
}

/// Parse a critic response into a verdict. The first token decides; any
/// following tokens form the (owned) reason. Ambiguous text defaults to APPROVE.
fn parseVerdict(alloc: std.mem.Allocator, text: []const u8) !Verdict {
    var it = std.mem.tokenizeAny(u8, text, " \n\r\t.");
    const first = it.next() orelse return Verdict{ .ok = true, .reason = null };
    if (std.ascii.eqlIgnoreCase(first, "approve")) return Verdict{ .ok = true, .reason = null };
    if (std.ascii.eqlIgnoreCase(first, "reject")) {
        var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
        errdefer buf.deinit(alloc);
        var first_word = true;
        while (it.next()) |w| {
            if (!first_word) try buf.append(alloc, ' ');
            first_word = false;
            try buf.appendSlice(alloc, w);
        }
        const reason = if (buf.items.len > 0) try alloc.dupe(u8, buf.items) else null;
        buf.deinit(alloc);
        return Verdict{ .ok = false, .reason = reason };
    }
    return Verdict{ .ok = true, .reason = null };
}
test "critic.parseVerdict parses approve/reject with reason" {
    const a = std.testing.allocator;
    const va = try parseVerdict(a, "APPROVE");
    try std.testing.expect(va.ok);
    try std.testing.expect(va.reason == null);
    const vr = try parseVerdict(a, "REJECT missing error handling");
    try std.testing.expect(!vr.ok);
    try std.testing.expectEqualStrings("missing error handling", vr.reason.?);
    a.free(vr.reason.?);
    const vr2 = try parseVerdict(a, "reject\nbad naming");
    try std.testing.expect(!vr2.ok);
    try std.testing.expectEqualStrings("bad naming", vr2.reason.?);
    a.free(vr2.reason.?);
    const vd = try parseVerdict(a, "ambiguous text");
    try std.testing.expect(vd.ok);
}
