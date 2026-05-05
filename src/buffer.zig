const std = @import("std");
const def = @import("def.zig");

const BufferUsage = packed struct(u32) {
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
    size: def.Size64Out,
    usage: def.FlagsConstant,

    map_state: MapState,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        size: def.Size64 = null,
        usage: Buffer.UsageFlags,
        mappedAtCreation: bool = false,
    };

    pub const UsageFlags = def.BufferUsageFlags;
    pub const Usage = BufferUsage;

    pub const MapAsyncError = error{NotImplemented};

    pub const MapState = enum { unmapped, pending, mapped };

    pub const MapMode = packed struct(u32) {
        read: bool = false,
        write: bool = false,

        _: u3 = 0,

        pub const READ: def.FlagsConstant = 0x0001;
        pub const WRITE: def.FlagsConstant = 0x0002;

        pub fn fromFlags(flags: def.FlagsConstant) MapMode {
            return .{
                .read = flags & READ != 0,
                .write = flags & WRITE != 0,
            };
        }

        pub fn toFlags(self: MapMode) def.FlagsConstant {
            return (if (self.read) READ else 0) | (if (self.write) WRITE else 0);
        }
    };

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn mapAsync(
        self: *@This(),
        io: std.Io,
        mode: MapMode,
        offset: ?u64, // default to 0
        size: u64,
    ) std.Io.Future(MapAsyncError!void) {
        return io.async(mapAsyncInternal, .{ self, mode, offset, size });
    }

    pub fn getMappedRange(
        self: *@This(),
        offset: ?def.Size64,
        size: ?def.Size64,
    ) ?def.ArrayBuffer {
        _ = self;
        const resolved_offset = offset orelse 0;
        _ = resolved_offset;
        _ = size;
        return null;
    }

    pub fn unmap(self: *@This()) void {
        _ = self;
    }

    // --- internal ---

    fn mapAsyncInternal(
        self: *@This(),
        mode: MapMode,
        offset: ?u64,
        size: u64,
    ) MapAsyncError!void {
        _ = self;
        _ = mode;
        _ = offset;
        _ = size;
        return error.NotImplemented;
    }
};
