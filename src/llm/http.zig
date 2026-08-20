const std = @import("std");
const types = @import("types");

/// One network attempt against the LLM HTTP endpoint. Returns the extracted
/// `content` field, or `error.RequestFailed` when curl reports no body (a
/// connection failure, DNS error, timeout, or HTTP error with `-f`). The caller
/// is responsible for retrying; this never retries on its own.
fn curlOnce(allocator: std.mem.Allocator, io: std.Io, url: []const u8, auth: []const u8, body: []const u8) ![]u8 {
    // `-f` makes curl exit non-zero on HTTP errors (4xx/5xx) and print nothing
    // to stdout; `-m` / `--connect-timeout` bound total and connect wait so a
    // hung or unreachable endpoint can't stall the engine indefinitely.
    const argv = [_][]const u8{ "curl", "-s", "-N", "-f", "-m", "60", "--connect-timeout", "10", "-X", "POST", url, "-H", "Content-Type: application/json", "-H", auth, "-d", body };
    const res = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    // A failed request yields an empty body; treat that as a retryable error
    // rather than feeding garbage to extractContent.
    if (res.stdout.len == 0) return error.RequestFailed;
    return try extractContent(allocator, res.stdout);
}

/// Network-backed LLM completion with bounded retries. Transient failures
/// (connection reset, 5xx, timeout) are retried up to 3 times; only a
/// persistent failure propagates. Without this, a single blip aborts the whole
/// build and `resilience.fallback` silently switches to the mock backend —
/// degrading the run without a visible signal.
pub fn complete(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{ctx.llm_base});
    defer allocator.free(url);
    const key = ctx.llm_key orelse "";
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);
    const model = if (ctx.backend == .openai) "gpt-4o-mini" else "local";
    const sys_esc = try jsonEscape(allocator, system);

    const user_esc = try jsonEscape(allocator, user);
    defer allocator.free(user_esc);
    const body = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","temperature":0.2,"messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}]}}
    , .{ model, sys_esc, user_esc });
    defer allocator.free(body);

    const max_attempts: usize = 3;
    var attempt: usize = 0;
    // Set once a transient failure was retried (not on the final, fatal
    // attempt). Used only to surface retry churn in the autonomy metrics — a
    // retry that recovers is not a degradation, so it must NOT count toward
    // mock_fallbacks or trip the health check.
    var recovered = false;
    while (attempt < max_attempts) : (attempt += 1) {
        const got = curlOnce(allocator, io, url, auth, body) catch |e| {
            ctx.log("[transport] http attempt {d}/{d} failed: {s}", .{ attempt + 1, max_attempts, @errorName(e) });
            if (attempt + 1 < max_attempts) {
                recovered = true;
                continue;
            }
            return e;
        };
        if (recovered) ctx.network_retries += 1;
        return got;
    }
    return error.RequestFailed;
}

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c == 0x08) {
                    try out.appendSlice(allocator, "\\b");
                } else if (c == 0x0C) {
                    try out.appendSlice(allocator, "\\f");
                } else {
                    // RFC 8259 §7: every control character (U+0000–U+001F) MUST
                    // be escaped. The prompt path carries semi-trusted input (KB
                    // lessons, recorded evaluator errors, task text) that can
                    // contain raw control bytes (e.g. ESC, form-feed from
                    // terminal output). Leaving them unescaped produces a
                    // malformed request body, which the endpoint rejects →
                    // silent mock fallback.
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const n = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{c}) catch unreachable;
                        try out.appendSlice(allocator, buf[0..n.len]);
                    } else {
                        try out.append(allocator, c);
                    }
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn extractContent(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const marker = "\"content\":\"";
    const start = std.mem.indexOf(u8, body, marker) orelse return allocator.dupe(u8, "");
    var i = start + marker.len;
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
            if (i >= body.len) break;
            switch (body[i]) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'r' => try out.append(allocator, '\r'),
                'b' => try out.append(allocator, 0x08),
                'f' => try out.append(allocator, 0x0C),
                else => try out.append(allocator, body[i]),
            }
            continue;
        }
        if (body[i] == '"') break;
        try out.append(allocator, body[i]);
    }
    return out.toOwnedSlice(allocator);
}

test "extractContent decodes OpenAI JSON string escapes" {
    const a = std.testing.allocator;
    const body1 =
        \\{"choices":[{"message":{"content":"pub fn step0() void {}"}}]}
    ;
    const got1 = try extractContent(a, body1);
    defer a.free(got1);
    try std.testing.expectEqualStrings("pub fn step0() void {}", got1);

    const body2 =
        \\{"choices":[{"message":{"content":"a \"quote\" b"}}]}
    ;
    const got2 = try extractContent(a, body2);
    defer a.free(got2);
    try std.testing.expectEqualStrings("a \"quote\" b", got2);

    const body3 =
        \\{"choices":[{"message":{"content":"line1\nline2\tend"}}]}
    ;
    const got3 = try extractContent(a, body3);
    defer a.free(got3);
    try std.testing.expectEqualStrings("line1\nline2\tend", got3);

    const got4 = try extractContent(a, "no content field here");
    defer a.free(got4);
    try std.testing.expectEqualStrings("", got4);
}

test "jsonEscape escapes JSON string syntax" {
    const a = std.testing.allocator;
    const got = try jsonEscape(a, "a\"b\\c\nd");
    defer a.free(got);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", got);
}
test "jsonEscape escapes full control-char range per RFC 8259" {
    const a = std.testing.allocator;
    // A raw ESC (0x1B) and vertical tab (0x0B) — control chars that previously
    // leaked unescaped into the request body, producing malformed JSON.
    const got = try jsonEscape(a, "x\x1by\x0bz");
    defer a.free(got);
    try std.testing.expectEqualStrings("x\\u001By\\u000Bz", got);
}
