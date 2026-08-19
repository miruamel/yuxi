const std = @import("std");

pub fn writeFileAlloc(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    _ = allocator;
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    defer _ = std.os.linux.close(fd);
    var off: usize = 0;
    while (off < content.len) {
        const n = std.os.linux.write(fd, content[off..].ptr, content.len - off);
        if (n == 0) break;
        off += n;
    }
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        std.posix.O{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    defer _ = std.os.linux.close(fd);
    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.os.linux.read(fd, &tmp, tmp.len);
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return buf.toOwnedSlice(allocator);
}
/// Create `dir` and any missing parents if absent; no-op if it already exists.
pub fn ensureDir(alloc: std.mem.Allocator, dir: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, dir, "/");
    if (trimmed.len == 0) return;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == '/') try mkdirOne(alloc, trimmed[0..i]);
    }
    try mkdirOne(alloc, trimmed);
}

/// Create one directory level, tolerating an already-present path.
fn mkdirOne(alloc: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0) return;
    var zbuf = try std.ArrayList(u8).initCapacity(alloc, path.len + 1);
    defer zbuf.deinit(alloc);
    try zbuf.appendSlice(alloc, path);
    try zbuf.append(alloc, 0);
    const z: [*:0]u8 = @ptrCast(zbuf.items.ptr);
    const rc = std.os.linux.mkdir(z, 0o755);
    if (rc != 0) {
        const e = std.posix.errno(rc);
        if (e != .SUCCESS and e != .EXIST) return error.DirCreateFailed;
    }
}
/// Remove a single file. Fails (does not panic) if the path is a directory
/// or the syscall is rejected; callers decide whether a missing file is fatal.
pub fn deleteFile(io: std.Io, path: []const u8) !void {
    return std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, path);
}

test "ensureDir creates nested parents and is idempotent" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base = "/tmp/yuxi_ensuredir_test";
    const full = try std.fmt.allocPrint(alloc, "{s}/a/b/c", .{base});
    defer alloc.free(full);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, base) catch {};
    // Regression: a nested workdir (parent absent) must not fail with
    // DirCreateFailed, which is what the single-mkdir version did.
    try ensureDir(alloc, full);
    // Prove the nested dir exists by writing into it (project's own writer).
    const marker = try std.fmt.allocPrint(alloc, "{s}/marker", .{full});
    defer alloc.free(marker);
    try writeFileAlloc(alloc, marker, "x");
    try ensureDir(alloc, full);
}
