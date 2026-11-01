//! Keeps compiled shaders in a folder between runs, named by a hash of what they were compiled from.
const std = @import("std");

const log = std.log.scoped(.shader_disk_cache);

/// A folder of compiled shaders. Reading and writing are best-effort: a missing, damaged or
/// unwritable entry only means compiling again, so failures are logged, never returned.
///
/// ```zig
/// var cache: vit.ShaderDiskCache = .{ .io = io, .dir = try cwd.createDirPathOpen(io, "shader-cache", .{}) };
/// const key = vit.ShaderDiskCache.key(&.{ "my compiler 1.0", entry_point, source });
/// const bytes = cache.load(gpa, key) orelse compiled: {
///     const made = try compile(gpa, source);
///     cache.store(key, made);
///     break :compiled made;
/// };
/// ```
pub const ShaderDiskCache = struct {
    io: std.Io,
    dir: std.Io.Dir,

    /// Names an entry; hex, so it is its file's name.
    pub const Key = [std.crypto.hash.Blake3.digest_length * 2]u8;

    // Starts every entry, before the payload's length: a file cut short by a crash is ignored.
    const magic = "VSC1";
    const header_len = magic.len + @sizeOf(u64);
    const max_entry_bytes = 64 << 20;

    /// The key for output made from `parts`. Include everything that changes the output: the
    /// compiler and its version, the target, the stage, the entry point and the source.
    pub fn key(parts: []const []const u8) Key {
        var hasher = std.crypto.hash.Blake3.init(.{});
        for (parts) |part| {
            // Each part's length goes first, so ("ab", "c") and ("a", "bc") differ.
            hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, part.len)));
            hasher.update(part);
        }
        var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        hasher.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    /// The bytes stored under `entry`, owned by the caller; null when there are none.
    pub fn load(self: *const ShaderDiskCache, allocator: std.mem.Allocator, entry: Key) ?[]u8 {
        const file = self.dir.readFileAlloc(self.io, &entry, allocator, .limited(max_entry_bytes)) catch |err| {
            if (err != error.FileNotFound) log.warn("shader cache entry {s} can't be read: {t}", .{ entry, err });
            return null;
        };
        const payload = payloadOf(file) orelse {
            log.debug("shader cache entry {s} is damaged; compiling again", .{entry});
            allocator.free(file);
            return null;
        };
        // Move the payload to the start so the caller frees a whole allocation.
        std.mem.copyForwards(u8, file[0..payload.len], payload);
        return allocator.realloc(file, payload.len) catch file[0..payload.len];
    }

    /// Store `bytes` under `entry`, replacing what was there.
    pub fn store(self: *const ShaderDiskCache, entry: Key, bytes: []const u8) void {
        self.write(entry, bytes) catch |err| log.warn("shader cache entry {s} can't be written: {t}", .{ entry, err });
    }

    fn write(self: *const ShaderDiskCache, entry: Key, bytes: []const u8) !void {
        // Written whole beside the entry and renamed over it, so a reader never sees half of one.
        const partial = entry ++ ".part".*;
        var file = try self.dir.createFile(self.io, &partial, .{});
        {
            defer file.close(self.io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(self.io, &buffer);
            try writer.interface.writeAll(magic);
            try writer.interface.writeInt(u64, bytes.len, .little);
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
        }
        try self.dir.rename(&partial, self.dir, &entry, self.io);
    }

    fn payloadOf(file: []u8) ?[]u8 {
        if (file.len < header_len or !std.mem.eql(u8, file[0..magic.len], magic)) return null;
        const len = std.mem.readInt(u64, file[magic.len..header_len], .little);
        if (len != file.len - header_len) return null;
        return file[header_len..];
    }
};

test "a stored shader loads back under the same key only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache: ShaderDiskCache = .{ .io = std.testing.io, .dir = tmp.dir };
    const stored = ShaderDiskCache.key(&.{ "compiler 1", "main", "source" });
    cache.store(stored, "DXBC bytes");
    const loaded = cache.load(std.testing.allocator, stored).?;
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings("DXBC bytes", loaded);
    try std.testing.expect(cache.load(std.testing.allocator, ShaderDiskCache.key(&.{ "compiler 2", "main", "source" })) == null);
}

test "parts are hashed with their boundaries" {
    try std.testing.expect(!std.mem.eql(u8, &ShaderDiskCache.key(&.{ "ab", "c" }), &ShaderDiskCache.key(&.{ "a", "bc" })));
}

test "an entry cut short is ignored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache: ShaderDiskCache = .{ .io = std.testing.io, .dir = tmp.dir };
    const entry = ShaderDiskCache.key(&.{"cut"});
    cache.store(entry, "0123456789");
    const whole = try tmp.dir.readFileAlloc(std.testing.io, &entry, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(whole);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = &entry, .data = whole[0 .. whole.len - 3] });
    try std.testing.expect(cache.load(std.testing.allocator, entry) == null);
}
