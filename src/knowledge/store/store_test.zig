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
    try knowledge.save(alloc, path, "lesson one", null);
    try knowledge.save(alloc, path, "lesson two", null);
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
    try knowledge.save(alloc, path, "prior lesson A", null);
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    const prompt = try knowledge.injectPrompt(&ctx, "do a thing");
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson A") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "do a thing") != null);
}

test "knowledge injectPrompt caps to kb_max_lines when set" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_cap_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    // Three lessons, three newlines (each save is newline-terminated).
    try knowledge.save(alloc, path, "prior lesson A", null);
    try knowledge.save(alloc, path, "prior lesson B", null);
    try knowledge.save(alloc, path, "prior lesson C", null);
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    ctx.kb_max_lines = 2;
    const prompt = try knowledge.injectPrompt(&ctx, "do a thing");
    defer alloc.free(prompt);
    // Only the last two lessons are injected.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson A") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson B") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson C") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "do a thing") != null);
}

test "knowledge injectPrompt is uncapped when kb_max_lines is null" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_nocap_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.save(alloc, path, "prior lesson A", null);
    try knowledge.save(alloc, path, "prior lesson B", null);
    try knowledge.save(alloc, path, "prior lesson C", null);
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", base);
    ctx.kb_path = path;
    ctx.kb_max_lines = null;
    const prompt = try knowledge.injectPrompt(&ctx, "do a thing");
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson A") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson B") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "prior lesson C") != null);
}

test "knowledge injectPrompt is plain when kb missing" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ctx = try types.Ctx.init(alloc, io, .empty, .no_hitl, .mock, null, "", "ae_out");
    const prompt = try knowledge.injectPrompt(&ctx, "do a thing");
    defer alloc.free(prompt);
    try std.testing.expectEqualStrings("Task: do a thing", prompt);
}

test "knowledge appendUnique skips an identical existing lesson" {
    // Regression: a recurring critic/health/run lesson must be recorded once,
    // not re-accumulated every run — otherwise a bounded ledger fills with
    // duplicates and evicts the distinct lessons it exists to preserve.
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_dedup_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.appendUnique(alloc, path, "critic rejected X: missing handling", null);
    try knowledge.appendUnique(alloc, path, "critic rejected X: missing handling", null);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "critic rejected X: missing handling") != null);
    try std.testing.expectEqual(@as(usize, 1), countNewlines(got));
}

test "knowledge appendUnique keeps distinct lessons" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_dedup_distinct_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.appendUnique(alloc, path, "lesson A", null);
    try knowledge.appendUnique(alloc, path, "lesson B", null);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson A") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "lesson B") != null);
    try std.testing.expectEqual(@as(usize, 2), countNewlines(got));
}

test "knowledge appendUnique honors kb_max_lines and dedups" {
    // Mix: distinct lessons accumulate and the bound applies; a re-recorded
    // identical one does not consume a bounded slot, so L2 survives instead of
    // being evicted by a duplicate of L1.
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_kb_dedup_bound_test";
    const path = try std.fmt.allocPrint(alloc, "{s}/kb.md", .{base});
    defer alloc.free(path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    try knowledge.appendUnique(alloc, path, "L1", 2);
    try knowledge.appendUnique(alloc, path, "L2", 2);
    try knowledge.appendUnique(alloc, path, "L1", 2); // duplicate -> skipped
    try knowledge.appendUnique(alloc, path, "L3", 2);
    const got = (try knowledge.load(alloc, path)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "L1") == null); // evicted by bound
    try std.testing.expect(std.mem.indexOf(u8, got, "L2") != null); // survived dedup slot-save
    try std.testing.expect(std.mem.indexOf(u8, got, "L3") != null);
    try std.testing.expectEqual(@as(usize, 2), countNewlines(got));
}
