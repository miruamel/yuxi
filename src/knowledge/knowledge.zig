const std = @import("std");
const types = @import("../core/types.zig");

/// Append a structured event to the engine knowledge log.
pub fn log(ctx: *types.Ctx, text: []const u8) void {
    ctx.log("[knowledge] {s}", .{text});
    ctx.record(text);
}
