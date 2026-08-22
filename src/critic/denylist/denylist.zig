const std = @import("std");
const types = @import("types");
const transport = @import("transport");

pub const Verdict = struct {
    ok: bool,
    reason: ?[]const u8,
};

const deny_list = [_][]const u8{
    // Exact-prefix matches for native-exec / C-interop surface. Substrings
    // (not exact tokens) so indirection like `@field(std.process, "Child")`
    // or `std.process.spawn` — which contains "std.process" but not the
    // exact token "std.process.Child" — is still blocked. None of these
    // appear in the mock backend's benign step output, so the green deploy
    // path is unaffected; they only ever show up in generated code that is
    // trying to escape the sandbox.
    "std.process",
    "@cImport",
    "@import(\"c\")",
    "asm",
    "@export",
};

/// Return an owned reason if `code` contains a construct that must never run
/// (arbitrary process spawn or native C interop). Null otherwise.
fn dangerous(alloc: std.mem.Allocator, code: []const u8) !?[]const u8 {
    for (deny_list) |pat| {
        if (std.mem.indexOf(u8, code, pat) != null) {
            return try std.fmt.allocPrint(alloc, "blocked dangerous construct: {s}", .{pat});
        }
    }
    return null;
}

pub fn run(ctx: *types.Ctx, code: []const u8) !Verdict {
    // Fast-path rules engine.
    if (std.mem.indexOf(u8, code, "panic(") != null) {
        ctx.log("[critic] fast-path: rejected (contains panic)", .{});
        ctx.record("critic: rejected (panic)");
        return Verdict{ .ok = false, .reason = null };
    }
    // Dangerous-construct denylist: block native exec / C interop before the
    // LLM critic call, so generated code cannot spawn processes or link native.
    if (try dangerous(ctx.allocator, code)) |reason| {
        ctx.log("[critic] fast-path: rejected ({s})", .{reason});
        ctx.record("critic: rejected (denylist)");
        return Verdict{ .ok = false, .reason = reason };
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

/// Review the orchestrator's decomposition BEFORE codegen. Reuses the LLM
/// critic path (and its verdict parser) with a plan-specific prompt so a
/// nonsense, duplicated, or off-task plan is rejected and the run fails fast
/// instead of burning the self-correction budget. This is the plan-level
/// analogue of the per-step gate in step.zig. The system prompt deliberately
/// omits the word "critic" so test seams that distinguish the per-step code
/// review by the "critic" system string don't intercept the plan review.
pub fn reviewPlan(ctx: *types.Ctx, plan: []const u8) !Verdict {
    const sys = "You are a plan reviewer. Given the task decomposition below, reply APPROVE or REJECT followed by a short reason. Reject empty, duplicated, or off-task plans.";
    const user = try std.fmt.allocPrint(ctx.allocator, "Plan:\n{s}", .{plan});
    defer ctx.allocator.free(user);
    const resp = try transport.complete(ctx.allocator, ctx.io, ctx, sys, user);
    defer ctx.allocator.free(resp);
    const v = try parseVerdict(ctx.allocator, resp);
    ctx.log("[critic] plan verdict: {s}", .{if (v.ok) "APPROVE" else "REJECT"});
    if (v.reason) |r| ctx.log("[critic] plan reason: {s}", .{r});
    ctx.record("critic: plan reviewed");
    return v;
}

/// Parse a critic response into a verdict. The first token decides; any
/// following tokens form the (owned) reason. Ambiguous text defaults to APPROVE.
pub fn parseVerdict(alloc: std.mem.Allocator, text: []const u8) !Verdict {
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
