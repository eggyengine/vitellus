const std = @import("std");

pub const QueueKind = enum {
    graphics,
    compute,
    copy,
};

pub const QueueDescriptor = struct {
    kind: QueueKind = .graphics,
    /// Backend scheduling hint; `0` is the normal/default priority.
    priority: i32 = 0,
    /// Multi-adapter node selector; `0` targets the default device node.
    node_mask: u32 = 0,
};

pub const Queue = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn deinit(self: Queue) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};
