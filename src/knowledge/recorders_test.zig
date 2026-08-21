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

test "knowledge save bounds the on-disk ledger to kb_max_lines" {
    // Regression: a continuously running autonomous engine must not grow the
    // ledger without limit. save() must enforce the bound on write, not only
    // tailLessons() at inject time — otherwise the file grows forever while
    // only the tail is ever read.
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_bounded_save_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    // 5 lessons, bounded to 2 on disk.
    try knowledge.save(alloc, path, "lesson 1", 2);
    try knowledge.save(alloc, path, "lesson 2", 2);
    try knowledge.save(alloc, path, "lesson 3", 2);
    try knowledge.save(alloc, path, "lesson 4", 2);
    try knowledge.save(alloc, path, "lesson 5", 2);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    // Oldest lessons are trimmed from disk; only the last two survive.
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson 5") != null);
    // Exactly two lines remain on disk.
    var lines: usize = 0;
    for (got) |c| {
        if (c == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), lines);
}

test "knowledge save is unbounded when kb_max_lines is null" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_unbounded_save_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.save(alloc, path, "lesson A", null);
    try knowledge.save(alloc, path, "lesson B", null);
    try knowledge.save(alloc, path, "lesson C", null);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson A") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson C") != null);
    var lines: usize = 0;
    for (got) |c| {
        if (c == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
}

test "knowledge recordBatch persists the batch summary to the KB" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_batch_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.recordBatch(alloc, path, "tasks=2 deploys=2 unhealthy=0", null);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "- batch: tasks=2 deploys=2 unhealthy=0") != null);
}

test "knowledge recordBatch honors kb_max_lines bound" {
    // Regression: the batch summary path must respect --kb-max-lines, exactly
    // like recordLesson/recordHealth, or a long-running --tasks engine grows
    // the ledger without limit despite the operator setting a cap (reopens the
    // unbounded-growth hole PR #29 closed for the per-run paths).
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_batch_bounded_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.recordBatch(alloc, path, "tasks=1 deploys=1 unhealthy=0", 2);
    try knowledge.recordBatch(alloc, path, "tasks=2 deploys=2 unhealthy=0", 2);
    try knowledge.recordBatch(alloc, path, "tasks=3 deploys=3 unhealthy=0", 2);
    try knowledge.recordBatch(alloc, path, "tasks=4 deploys=4 unhealthy=0", 2);
    try knowledge.recordBatch(alloc, path, "tasks=5 deploys=5 unhealthy=0", 2);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    // Only the last two batch lines survive the bound.
    try std.testing.expect(std.mem.indexOf(u8, got, "tasks=1 ") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "tasks=2 ") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "tasks=4 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "tasks=5 ") != null);
    var lines: usize = 0;
    for (got) |c| {
        if (c == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), lines);
}
