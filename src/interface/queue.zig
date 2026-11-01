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
    /// Optional name shown for the queue in graphics debuggers.
    label: ?[]const u8 = null,
    /// Required command capability.
    kind: QueueKind = .graphics,
    /// Backend scheduling hint; `0` is the normal/default priority.
    priority: i32 = 0,
    /// Multi-adapter node selector; `0` targets the default device node.
    node_mask: u32 = 0,
};

/// Owning handle to a device queue.
///
/// `submit` and `waitIdle` (like `Swapchain.present`) fail with `error.DeviceLost` on every
/// backend once the GPU is removed, reset or hung: nothing made on the device works after
/// that. Destroy everything made from it, then the device, and make new ones to go on.
pub const Queue = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        submitFn: ?*const fn (*anyopaque, sync.SubmitDescriptor) anyerror!void = null,
        waitIdleFn: ?*const fn (*anyopaque) anyerror!void = null,
    };

    /// Get a queue of `desc.kind` from `device`. Submit command buffers from pools of the same
    /// kind; destroy the queue after waiting for it and before the device.
    pub fn init(device: anytype, desc: QueueDescriptor) !Queue {
        return device.vtable.createQueueFn(device.ptr, device.allocator, desc);
    }

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

// Doc tests below: Zig's generated docs show each one as its type's example, and
// `zig build test` runs it, on the machine's GPU when it has one.
const vit = @import("../root.zig");
const ExampleGpu = @import("example_gpu.zig");

test Queue {
    const instance = vit.Instance.init(std.testing.allocator, .{ .validation = .none }) catch return error.SkipZigTest;
    defer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{}) catch return error.SkipZigTest;
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();

    // A graphics queue runs everything; `.compute` and `.copy` queues run work beside it.
    const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();
    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.finish();

    // Submissions run in order. `waitIdle` blocks until they're all done: right before
    // shutdown or a resize, too slow for every frame (use a `vit.Fence` there).
    try queue.submit(.{ .command_buffers = &.{cmd} });
    try queue.waitIdle();
}
