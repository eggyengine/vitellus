const std = @import("std");
const def = @import("def.zig");
const hal = @import("../backends/hal.zig");

pub const BufferUsage = packed struct(u32) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,

    _: u22 = 0,

    pub const MAP_READ: def.FlagsConstant = 0x0001;
    pub const MAP_WRITE: def.FlagsConstant = 0x0002;
    pub const COPY_SRC: def.FlagsConstant = 0x0004;
    pub const COPY_DST: def.FlagsConstant = 0x0008;
    pub const INDEX: def.FlagsConstant = 0x0010;
    pub const VERTEX: def.FlagsConstant = 0x0020;
    pub const UNIFORM: def.FlagsConstant = 0x0040;
    pub const STORAGE: def.FlagsConstant = 0x0080;
    pub const INDIRECT: def.FlagsConstant = 0x0100;
    pub const QUERY_RESOLVE: def.FlagsConstant = 0x0200;

    pub fn fromFlags(flags: def.BufferUsageFlags) BufferUsage {
        return @bitCast(flags);
    }

    pub fn toFlags(self: BufferUsage) def.BufferUsageFlags {
        return @bitCast(self);
    }
};

pub const Buffer = struct {
    backend: ?hal.Buffer = null,
    size: def.Size64Out,
    usage: def.FlagsConstant,

    map_state: MapState,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        size: def.Size64,
        usage: Buffer.UsageFlags,
        mappedAtCreation: bool = false,
    };

    pub const UsageFlags = def.BufferUsageFlags;
    pub const Usage = BufferUsage;
    pub const MapModeFlags = def.MapModeFlags;

    pub const MapAsyncError = error{NotImplemented};

    pub const MapState = enum { unmapped, pending, mapped };

    pub const MapMode = packed struct(u32) {
        read: bool = false,
        write: bool = false,

        _: u30 = 0,

        pub const READ: def.FlagsConstant = 0x0001;
        pub const WRITE: def.FlagsConstant = 0x0002;

        pub fn fromFlags(flags: MapModeFlags) MapMode {
            return .{
                .read = flags & READ != 0,
                .write = flags & WRITE != 0,
            };
        }

        pub fn toFlags(self: MapMode) MapModeFlags {
            return (if (self.read) READ else 0) | (if (self.write) WRITE else 0);
        }
    };

    pub fn destroy(self: *@This()) void {
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
        self.map_state = .unmapped;
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }

    pub fn mapAsync(
        self: *@This(),
        io: std.Io,
        mode: MapMode,
        offset: ?u64, // defaults to 0
        size: u64,
    ) std.Io.Future(MapAsyncError!void) {
        return io.async(mapAsyncInternal, .{ self, io, mode, offset, size });
    }

    pub fn getMappedRange(
        self: *@This(),
        offset: ?def.Size64,
        size: ?def.Size64,
    ) !?def.ArrayBuffer {
        if (self.backend) |b| return b.getMappedRange(offset, size) else @panic("unreachable: for struct to be initialised, backend must be passed and `self.backend` cannot be null. unless...");
    }

    pub fn unmap(self: *@This()) void {
        if (self.backend) |b| {
            b.unmap();
            self.map_state = .unmapped;
        } else @panic("unreachable: for struct to be initialised, backend must be passed and `self.backend` cannot be null. unless...");
    }

    fn mapAsyncInternal(
        self: *@This(),
        io: std.Io,
        mode: MapMode,
        offset: ?u64,
        size: u64,
    ) MapAsyncError!void {
        if (self.backend) |backend| {
            self.map_state = .pending;
            var future = backend.mapAsync(io, mode, offset, size);
            defer _ = future.cancel(io) catch {};
            future.await(io) catch |err| {
                self.map_state = .unmapped;
                _ = err;
                return error.NotImplemented;
            };
            self.map_state = .mapped;
            return;
        }
        return error.NotImplemented;
    }
};
