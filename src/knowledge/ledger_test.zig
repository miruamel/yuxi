const std = @import("std");
const types = @import("types");
const knowledge = @import("knowledge");

test "knowledge recordLesson writes an enriched per-run lesson" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_record_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    ctx.deploys = 1;
    ctx.critic_rejections = 2;
    ctx.token_budgets_exceeded = 0;
    ctx.mock_fallbacks = 1;
    ctx.max_steps_exceeded = 1;
    try knowledge.recordLesson(&ctx, "add a feature", 3);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "add a feature: deployed") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "steps=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "critic_rej=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "mock_fb=1") != null);
    // The max-steps cap hit is a distinct degradation counter (PR #27); it must
    // surface in the ledger so future runs learn from an aborted decomposition.
    try std.testing.expect(std.mem.indexOf(u8, got, "max_steps_ex=1") != null);
}

test "knowledge recordLesson appends the eval error on a failed run" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_failed_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    ctx.deploys = 0;
    ctx.setEvalError("error: cannot find 'foo' in this scope");
    defer ctx.clearEvalError();
    try knowledge.recordLesson(&ctx, "add a feature", 3);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "add a feature: failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "cannot find 'foo'") != null);
}

test "knowledge recordHealth persists the verdict on an unhealthy cycle" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_health_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    ctx.deploys = 0;
    ctx.retries = 1;
    try knowledge.recordHealth(&ctx, "no deploy; self-correction exhausted; ");
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "- health: no deploy; self-correction exhausted; ") != null);
}

test "knowledge recordHealth is a no-op on a healthy cycle" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_health_ok_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    try knowledge.recordHealth(&ctx, "");
    const got = try knowledge.load(alloc, path);
    try std.testing.expect(got == null);
}

test "knowledge recordCritic writes a qualitative lesson" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_critic_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    try knowledge.recordCritic(&ctx, "add error handling", "missing error handling");
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "- critic rejected \"add error handling\": missing error handling") != null);
}

test "knowledge recordBatch persists the batch summary to the KB" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_batch_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.recordBatch(alloc, path, "tasks=2 deploys=2 unhealthy=0");
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "- batch: tasks=2 deploys=2 unhealthy=0") != null);
}
