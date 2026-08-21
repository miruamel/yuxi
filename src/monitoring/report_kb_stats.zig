const std = @import("std");
const knowledge = @import("knowledge");

/// Minimal JSON string escape: `"`, `\`, and control chars U+0000–U+001F
/// (RFC 8259). Shared by the report writer and the KB-stats emitter so a report
/// never carries malformed JSON from a task/ledger line containing raw control
/// or quote bytes. Centralized here so `monitoring` and the KB-stats field use
/// one implementation instead of two drifting copies.
pub fn escapeJson(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            else => {
                if (c < 0x20) {
                    var ebuf: [6]u8 = undefined;
                    const n = std.fmt.bufPrint(&ebuf, "\\u{X:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(alloc, ebuf[0..n.len]);
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Append the `"kb_stats"` field to a report buffer: a summary of the
/// configured knowledge ledger (composing the read-only `--kb-stats` inspector
/// into the machine report, §12/§30) so an external gate reads what the loop
/// has learned from the same JSON it already consumes for autonomy health.
/// Emits `null` when no ledger is configured (`--kb` unset); a real (zeroed)
/// object when the ledger is absent/empty, keeping the JSON shape stable for
/// consumers rather than toggling between object and null.
pub fn appendKbStats(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), kb_path: ?[]const u8, kb_max_lines: ?usize) !void {
    _ = kb_max_lines;
    try buf.appendSlice(alloc, ",\"kb_stats\":");
    if (kb_path) |kb| {
        const raw = knowledge.load(alloc, kb) catch null;
        defer if (raw) |r| alloc.free(r);
        const s = knowledge.summarize(raw orelse "");
        const esc_latest = try escapeJson(alloc, s.latest);
        defer alloc.free(esc_latest);
        const obj = try std.fmt.allocPrint(alloc, "{{\"total\":{d},\"deployed\":{d},\"failed\":{d},\"critic\":{d},\"health\":{d},\"batch\":{d},\"other\":{d},\"latest\":\"{s}\"}}", .{
            s.total, s.deployed, s.failed, s.critic, s.health, s.batch, s.other, esc_latest,
        });
        defer alloc.free(obj);
        try buf.appendSlice(alloc, obj);
    } else {
        try buf.appendSlice(alloc, "null");
    }
}
