const std = @import("std");
const types = @import("types");

pub fn run(ctx: *types.Ctx, task: []const u8) !bool {
    // Auth: optional token gate.
    const tok = std.process.Environ.getPosix(ctx.environ, "AE_TOKEN");
    if (tok) |t| {
        if (t.len == 0) {
            ctx.log("[gateway] auth: empty token -> reject", .{});
            return false;
        }
    }
    ctx.log("[gateway] auth: ok (token={s})", .{if (tok) |_| "set" else "none"});

    // Validation.
    if (task.len < 3) {
        ctx.log("[gateway] validation: task too short", .{});
        return false;
    }

    // Sanitizer / PII redaction (naive '@' redaction).
    const clean = try redact(ctx.allocator, task);
    defer ctx.allocator.free(clean);
    ctx.log("[gateway] sanitizer: {d} -> {d} bytes", .{ task.len, clean.len });

    ctx.record("gateway: passed");
    return true;
}

fn redact(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '@') {
            try out.appendSlice(allocator, "<redacted>");
            while (i < s.len and s[i] != ' ' and s[i] != '\n') : (i += 1) {}
            continue;
        }
        try out.append(allocator, s[i]);
    }
    return out.toOwnedSlice(allocator);
}
