//! GPU queue selection, submission, and completion.

const std = @import("std");
const sync = @import("sync.zig");

/// Commands a queue is capable of executing.
pub const QueueKind = enum {
    graphics,
    compute,
    copy,
};

/// Queue capability and backend scheduling hints.
pub const QueueDescriptor = struct {
    /// Required command capability.
    kind: QueueKind = .graphics,
    /// Backend scheduling hint; `0` is the normal/default priority.
    priority: i32 = 0,
    /// Multi-adapter node selector; `0` targets the default device node.
    node_mask: u32 = 0,
};

/// Owning handle to a device queue.
pub const Queue = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        submitFn: ?*const fn (*anyopaque, sync.SubmitDescriptor) anyerror!void = null,
        waitIdleFn: ?*const fn (*anyopaque) anyerror!void = null,
    };

    /// Releases the queue after any required completion wait.
    pub fn deinit(self: Queue) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
    /// Submits recorded command buffers and optional synchronisation objects.
    pub fn submit(self: Queue, desc: sync.SubmitDescriptor) !void {
        return if (self.vtable.submitFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    /// Waits until all work previously submitted to this queue has completed.
    pub fn waitIdle(self: Queue) !void {
        return if (self.vtable.waitIdleFn) |f| f(self.ptr) else error.Unsupported;
    }
};
