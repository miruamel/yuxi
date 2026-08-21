const std = @import("std");
const fs = @import("fs");

/// Load the persisted knowledge base at `path`. Returns null when the file is
/// absent, so a first run simply has no prior lessons to inject. Caller owns
/// the returned slice.
pub fn load(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    return fs.readFileAlloc(alloc, path) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
}

/// Append one `lesson` line to the knowledge base at `path`, creating the
/// parent directory if needed. Lines are newline-terminated so successive
/// runs accumulate a readable, replayable ledger the orchestrator can reuse.
/// When `max_lines` is set, the ledger is bounded *on write*: after appending,
/// if the file exceeds `max_lines` it is rewritten to its last `max_lines`
/// lines. Without a bound the file grows unbounded — correct only because
/// `--kb-max-lines` is off by default; a long-running autonomous engine must
/// configure it or the ledger grows forever (and every decomposition reloads
/// it in full).
pub fn save(alloc: std.mem.Allocator, path: []const u8, lesson: []const u8, max_lines: ?usize) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try fs.ensureDir(alloc, dir);
    }
    // Write the new lesson first (append), then trim from the head if bounded.
    {
        const fd = try std.posix.openat(
            std.posix.AT.FDCWD,
            path,
            std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
            0o644,
        );
        defer _ = std.os.linux.close(fd);
        var buf = try std.ArrayList(u8).initCapacity(alloc, lesson.len + 1);
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, lesson);
        if (lesson.len == 0 or lesson[lesson.len - 1] != '\n') try buf.append(alloc, '\n');
        var off: usize = 0;
        while (off < buf.items.len) {
            const n = std.os.linux.write(fd, buf.items[off..].ptr, buf.items.len - off);
            if (n == 0) break;
            off += n;
        }
    }
    // Bounded ledger: keep only the last `max_lines` lines on disk. This is the
    // durable counterpart to `tailLessons` (which bounds what gets injected) —
    // without it a long-running autonomous engine grows the file without limit.
    if (max_lines) |m| {
        if (m == 0) {
            try fs.writeFileAlloc(alloc, path, "");
            return;
        }
        const full = (load(alloc, path) catch null) orelse return;
        defer alloc.free(full);
        const trimmed = try tailLessons(alloc, full, m);
        defer alloc.free(trimmed);
        if (trimmed.len < full.len) try fs.writeFileAlloc(alloc, path, trimmed);
    }
}

/// Return the last `max` lines of `prior` (or all of it when `max` is null), so
/// a long-lived KB ledger doesn't get loaded into every decomposition prompt in
/// full. Lessons are newline-terminated, so the split boundary is line-based.
/// Caller owns the returned slice. If `prior` has `max` or fewer lines, the
/// whole thing is returned.
pub fn tailLessons(alloc: std.mem.Allocator, prior: []const u8, max: ?usize) ![]const u8 {
    const m = max orelse return alloc.dupe(u8, prior);
    if (m == 0) return alloc.dupe(u8, "");
    var total: usize = 0;
    for (prior) |c| {
        if (c == '\n') total += 1;
    }
    if (total <= m) return alloc.dupe(u8, prior);
    // (total - m), then keep everything after it.
    const skip = total - m;
    var seen: usize = 0;
    var i: usize = 0;
    while (i < prior.len) : (i += 1) {
        if (prior[i] == '\n') {
            seen += 1;
            if (seen == skip) return alloc.dupe(u8, prior[i + 1 ..]);
        }
    }
    return alloc.dupe(u8, prior);
}
