const std = @import("std");
const types = @import("types");
const knowledge = @import("knowledge");

fn countNewlines(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

test "knowledge save then load returns accumulated lessons" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.save(alloc, path, "lesson one");
    try knowledge.save(alloc, path, "lesson two");
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson one") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson two") != null);
    // Each save is newline-terminated; two lessons == two newlines.
    try std.testing.expectEqual(@as(usize, 2), countNewlines(got));
}

test "knowledge load returns null when file missing" {
    const alloc = std.testing.allocator;
    const got = try knowledge.load(alloc, "/tmp/yuxi_kb_missing_xyz/kb.md");
    try std.testing.expect(got == null);
}

test "knowledge injectPrompt prepends prior lessons from configured kb" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_inject_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.save(alloc, path, "prior lesson A");
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    const prompt = try knowledge.injectPrompt(&ctx, "do a thing");
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson A") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "do a thing") != null);
}

test "knowledge injectPrompt is plain when kb missing" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", "ae_out");
    const prompt = try knowledge.injectPrompt(&ctx, "do a thing");
    defer alloc.free(prompt);
    try std.testing.expectEqualStrings("Task: do a thing", prompt);
}

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
    ctx.mock_fallbacks = 1;
    ctx.token_budgets_exceeded = 0;
    try knowledge.recordLesson(&ctx, "add a feature", 3);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "add a feature: deployed") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "steps=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "critic_rej=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "mock_fb=1") != null);
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
