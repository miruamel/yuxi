const std = @import("std");

/// On-disk, content-addressed cache for LLM responses.
///
/// Entries are keyed by sha256(backend \0 system \0 user) and stored one file
/// per entry under `dir`. A hit returns the previously computed response
/// without contacting the model, so repeated engine runs skip redundant
/// generation. The directory is created on init; entries are immutable once
/// written, so the cache is safe to share across runs.
pub const Cache = struct {
    dir: []const u8,
    hits: usize,
    misses: usize,

    /// Create (or open) the cache directory `dir`.
    pub fn init(alloc: std.mem.Allocator, dir: []const u8) !Cache {
        var zbuf = try std.ArrayList(u8).initCapacity(alloc, dir.len + 1);
        try zbuf.appendSlice(alloc, dir);
        try zbuf.append(alloc, 0);
        const z: [*:0]u8 = @ptrCast(zbuf.items.ptr);
        const rc = std.os.linux.mkdir(z, 0o755);
        alloc.free(zbuf.items);
        if (rc != 0) {
            const e = std.posix.errno(rc);
            if (e != .SUCCESS and e != .EXIST) return error.CacheInitFailed;
        }
        return .{ .dir = dir, .hits = 0, .misses = 0 };
    }

    fn key(alloc: std.mem.Allocator, backend: []const u8, system: []const u8, user: []const u8) ![]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(backend);
        h.update("\x00");
        h.update(system);
        h.update("\x00");
        h.update(user);
        var out: [32]u8 = undefined;
        h.final(&out);
        var hex = try std.ArrayList(u8).initCapacity(alloc, 64);
        const digits = "0123456789abcdef";
        for (out) |b| {
            try hex.append(alloc, digits[b >> 4]);
            try hex.append(alloc, digits[b & 0x0f]);
        }
        return try hex.toOwnedSlice(alloc);
    }

    fn path(self: *const Cache, alloc: std.mem.Allocator, k: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}.cache", .{ self.dir, k });
    }

    /// Return the cached response (caller-owned) or null on miss / read error.
    pub fn get(self: *Cache, alloc: std.mem.Allocator, backend: []const u8, system: []const u8, user: []const u8) !?[]u8 {
        const k = try key(alloc, backend, system, user);
        defer alloc.free(k);
        const p = try path(self, alloc, k);
        defer alloc.free(p);
        const fd = std.posix.openat(std.posix.AT.FDCWD, p, std.posix.O{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer _ = std.os.linux.close(fd);
        var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = std.os.linux.read(fd, &tmp, tmp.len);
            if (n == 0) break;
            try buf.appendSlice(alloc, tmp[0..n]);
        }
        self.hits += 1;
        return try buf.toOwnedSlice(alloc);
    }

    /// Store `response` for the given inputs.
    pub fn put(self: *Cache, alloc: std.mem.Allocator, backend: []const u8, system: []const u8, user: []const u8, response: []const u8) !void {
        const k = try key(alloc, backend, system, user);
        defer alloc.free(k);
        const p = try path(self, alloc, k);
        defer alloc.free(p);
        const fd = try std.posix.openat(std.posix.AT.FDCWD, p, std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        defer _ = std.os.linux.close(fd);
        var off: usize = 0;
        while (off < response.len) {
            const n = std.os.linux.write(fd, response[off..].ptr, response.len - off);
            if (n == 0) break;
            off += n;
        }
        self.misses += 1;
    }
};

test "cache put then get returns same content" {
    const alloc = std.testing.allocator;
    var marker: u8 = 0;
    const dir = try std.fmt.allocPrint(alloc, "zt_cache_{d}", .{@intFromPtr(&marker)});
    defer alloc.free(dir);
    var c = try Cache.init(alloc, dir);
    try std.testing.expect((try c.get(alloc, "mock", "sys", "user")) == null);
    try c.put(alloc, "mock", "sys", "user", "hello");
    const got = (try c.get(alloc, "mock", "sys", "user")).?;
    defer alloc.free(got);
    try std.testing.expectEqualSlices(u8, "hello", got);
    try std.testing.expectEqual(@as(usize, 1), c.hits);
    try std.testing.expectEqual(@as(usize, 1), c.misses);
    try std.testing.expect((try c.get(alloc, "mock", "sys", "other")) == null);
}
