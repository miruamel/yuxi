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
/// Create `dir` if absent; no-op if it already exists.
pub fn ensureDir(alloc: std.mem.Allocator, dir: []const u8) !void {
    var zbuf = try std.ArrayList(u8).initCapacity(alloc, dir.len + 1);
    try zbuf.appendSlice(alloc, dir);
    try zbuf.append(alloc, 0);
    const z: [*:0]u8 = @ptrCast(zbuf.items.ptr);
    const rc = std.os.linux.mkdir(z, 0o755);
    alloc.free(zbuf.items);
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
