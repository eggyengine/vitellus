const std = @import("std");
const sync = @import("sync.zig");

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
        submitFn: ?*const fn (*anyopaque, sync.SubmitDescriptor) anyerror!void = null,
        waitIdleFn: ?*const fn (*anyopaque) anyerror!void = null,
    };

    pub fn deinit(self: Queue) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
    pub fn submit(self: Queue, desc: sync.SubmitDescriptor) !void { return if (self.vtable.submitFn) |f| f(self.ptr, desc) else error.Unsupported; }
    pub fn waitIdle(self: Queue) !void { return if (self.vtable.waitIdleFn) |f| f(self.ptr) else error.Unsupported; }
};
