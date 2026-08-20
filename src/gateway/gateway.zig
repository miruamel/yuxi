const std = @import("std");
const types = @import("types");

pub fn run(ctx: *types.Ctx, task: []const u8) !?[]const u8 {
    // Auth: optional token gate.
    const tok = std.process.Environ.getPosix(ctx.environ, "AE_TOKEN");
    if (tok) |t| {
        if (t.len == 0) {
            ctx.log("[gateway] auth: empty token -> reject", .{});
            return null;
        }
    }
    ctx.log("[gateway] auth: ok (token={s})", .{if (tok) |_| "set" else "none"});

    // Validation.
    if (task.len < 3) {
        ctx.log("[gateway] validation: task too short", .{});
        return null;
    }

    // Sanitizer / PII redaction. The earlier version only replaced the '@'
    // glyph and swallowed the rest of the @-run, so "user@corp.com" leaked as
    // "user<redacted>corp.com" — the domain stayed visible. Redact the WHOLE
    // token containing '@' instead (email/ handle disappears entirely).
    // Owning the redacted copy and returning it is the whole point: the
    // downstream orchestrator and the knowledge ledger must operate on the
    // *sanitized* task, or the PII filter is a no-op.
    const clean = try redact(ctx.allocator, task);
    ctx.log("[gateway] sanitizer: {d} -> {d} bytes", .{ task.len, clean.len });

    ctx.record("gateway: passed");
    return clean;
}

/// Redact PII from `s`. Any whitespace-delimited token containing '@' (an
/// email address or handle) is replaced wholesale with `<redacted>`; other
/// tokens pass through unchanged. Over-redaction is preferred to under-
/// redaction at a trust boundary — a benign token with '@' in it is hidden
/// rather than risk leaking an address. Whitespace runs collapse to single
/// spaces, which is acceptable for a sanitized task string.
fn redact(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var first = true;
    while (it.next()) |tok| {
        if (!first) try out.append(allocator, ' ');
        first = false;
        if (std.mem.indexOf(u8, tok, "@") != null) {
            try out.appendSlice(allocator, "<redacted>");
        } else {
            try out.appendSlice(allocator, tok);
        }
    }
    return out.toOwnedSlice(allocator);
}
