const std = @import("std");
const types = @import("types");

pub fn run(ctx: *types.Ctx, task: []const u8) !?[]const u8 {
    // Auth: optional token gate. Two modes, both opt-in / fail-closed:
    //  - If AE_TOKEN_EXPECTED is set, the presented AE_TOKEN must match it
    //    (constant-time compare). This closes CWE-306/CWE-287 — a bare
    //    "token is present" check accepts ANY non-empty token, which is no
    //    authentication at all. Operators that care set the expected value;
    //    the run refuses to proceed on mismatch or on a missing/empty token.
    //  - If AE_TOKEN_EXPECTED is unset, the legacy behavior holds: any
    //    non-empty AE_TOKEN is accepted and a missing one is accepted too
    //    (auth effectively disabled). This keeps dev/offline runs and every
    //    existing test untouched while letting real deployments enforce a
    //    real secret. The engine still does NOT gate its own deploys (issue
    //    #2 fork is untouched) — this only fixes the auth check it already claims.
    if (std.process.Environ.getPosix(ctx.environ, "AE_TOKEN_EXPECTED")) |expected| {
        const presented = std.process.Environ.getPosix(ctx.environ, "AE_TOKEN");
        if (presented == null or presented.?.len == 0 or !ctEq(presented.?, expected)) {
            ctx.log("[gateway] auth: token mismatch -> reject", .{});
            return null;
        }
        ctx.log("[gateway] auth: ok (token matched AE_TOKEN_EXPECTED)", .{});
    } else {
        // Legacy presence-only check (unchanged behavior).
        const tok = std.process.Environ.getPosix(ctx.environ, "AE_TOKEN");
        if (tok) |t| {
            if (t.len == 0) {
                ctx.log("[gateway] auth: empty token -> reject", .{});
                return null;
            }
        }
        ctx.log("[gateway] auth: ok (token={s})", .{if (tok) |_| "set" else "none"});
    }

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

/// Constant-time string equality: returns false on length mismatch without
/// short-circuiting the compare, so a wrong token isn't distinguishable by
/// how-far-it-matched timing. Used for the AE_TOKEN_EXPECTED gate above.
fn ctEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}
