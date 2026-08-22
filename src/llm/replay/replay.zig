const std = @import("std");
const types = @import("types");
const fs = @import("fs");

/// Serve the next recorded LLM response from `path`, in call order, so the
/// real `.openai`/`.local` backend path runs offline (CI, tests) without an
/// API key. Entries are delimited by a line that is exactly `---`, allowing a
/// recorded response to span multiple lines (e.g. a decomposer plan). Running
/// past the last entry is an error (misconfigured replay).
pub fn replayComplete(allocator: std.mem.Allocator, ctx: *types.Ctx, path: []const u8) ![]u8 {
    const raw = fs.readFileAlloc(allocator, path) catch |e| {
        ctx.log("[transport] replay read failed: {s}", .{@errorName(e)});
        return e;
    };
    defer allocator.free(raw);

    var entries = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer entries.deinit(allocator);
    var cur = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer cur.deinit(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, "\r"), "---")) {
            try entries.append(allocator, try cur.toOwnedSlice(allocator));
        } else {
            if (cur.items.len > 0) try cur.append(allocator, '\n');
            try cur.appendSlice(allocator, line);
        }
    }
    if (cur.items.len > 0) try entries.append(allocator, try cur.toOwnedSlice(allocator));

    if (ctx.replay_idx >= entries.items.len) {
        ctx.log("[transport] replay exhausted at entry {d}/{d}", .{ ctx.replay_idx, entries.items.len });
        for (entries.items) |e| allocator.free(e);
        return error.ReplayExhausted;
    }
    const out = try allocator.dupe(u8, entries.items[ctx.replay_idx]);
    ctx.replay_idx += 1;
    for (entries.items) |e| allocator.free(e);
    return out;
}
