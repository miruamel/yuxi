const std = @import("std");
const types = @import("../core/types.zig");

/// Single LLM entry point. Dispatches on Ctx.backend.
pub fn complete(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) ![]u8 {
    if (ctx.cache) |c| {
        if (c.get(allocator, @tagName(ctx.backend), system, user) catch null) |hit| {
            return hit;
        }
    }
    ctx.tokens += user.len / 4 + system.len / 8 + 16;
    const resp = switch (ctx.backend) {
        .mock => try mockComplete(allocator, system, user),
        .openai, .local => try httpComplete(allocator, io, ctx, system, user),
    };
    if (ctx.cache) |c| {
        c.put(allocator, @tagName(ctx.backend), system, user, resp) catch {};
    }
    return resp;
}

fn mockComplete(allocator: std.mem.Allocator, system: []const u8, user: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, system, "decomposer") != null) {
        return allocator.dupe(u8,
            \\STEP: design the function signature
            \\STEP: implement the body
            \\STEP: add a unit test
        );
    }
    if (std.mem.indexOf(u8, system, "code generator") != null) {
        // The builder passes "Implement step N: ...", so name the function
        // uniquely per step; the engine composes all steps into one binary.
        var n: usize = 0;
        if (std.mem.indexOf(u8, user, "Implement step ")) |p| {
            const rest = user[p + "Implement step ".len ..];
            if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
                n = std.fmt.parseUnsigned(usize, rest[0..c], 10) catch 0;
            }
        }
        return std.fmt.allocPrint(allocator,
            \\pub fn step{d}() void {{
            \\    const a: i32 = 2;
            \\    const b: i32 = 3;
            \\    const sum = a + b;
            \\    std.debug.print("step result: 2+3={{d}}\n", .{{sum}});
            \\}}
        , .{n});
    }
    if (std.mem.indexOf(u8, system, "critic") != null) {
        return allocator.dupe(u8, "APPROVE");
    }
    return allocator.dupe(u8, user);
}

fn httpComplete(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{ctx.llm_base});
    defer allocator.free(url);
    const key = ctx.llm_key orelse "";
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);
    const model = if (ctx.backend == .openai) "gpt-4o-mini" else "local";
    const sys_esc = try jsonEscape(allocator, system);
    defer allocator.free(sys_esc);
    const user_esc = try jsonEscape(allocator, user);
    defer allocator.free(user_esc);
    const body = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","temperature":0.2,"messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}]}}
    , .{ model, sys_esc, user_esc });
    defer allocator.free(body);

    const argv = [_][]const u8{ "curl", "-s", "-N", "-X", "POST", url, "-H", "Content-Type: application/json", "-H", auth, "-d", body };
    const res = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    return try extractContent(allocator, res.stdout);
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
            else => try out.append(allocator, c),
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
            if (i < body.len) try out.append(allocator, body[i]);
            continue;
        }
        if (body[i] == '"') break;
        try out.append(allocator, body[i]);
    }
    return out.toOwnedSlice(allocator);
}
