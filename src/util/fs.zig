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
