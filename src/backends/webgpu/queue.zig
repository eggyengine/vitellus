//! The WebGPU queue.

const std = @import("std");
const c = @import("webgpu_c");
const queue_if = @import("../../interface/queue.zig");
const command = @import("../../interface/command.zig");
const sync = @import("../../interface/sync.zig");
const forever = @import("utils.zig").forever;
const ptrOf = @import("utils.zig").ptrOf;
const waitFuture = @import("utils.zig").waitFuture;
const WgpuDevice = @import("device.zig").WgpuDevice;
const WgpuFence = @import("sync.zig").WgpuFence;
const WgpuCommandBuffer = @import("command.zig").WgpuCommandBuffer;

pub const WgpuQueue = struct {
    instance: c.WGPUInstance,
    device: c.WGPUDevice,
    handle: c.WGPUQueue,

    const vtable: queue_if.Queue.VTable = .{ .deinitFn = deinit, .submitFn = submit, .waitIdleFn = waitIdle };

    pub fn create(ptr: *anyopaque, allocator: std.mem.Allocator, desc: queue_if.QueueDescriptor) anyerror!queue_if.Queue {
        _ = desc; // WebGPU has one queue that does everything.
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const self = try allocator.create(WgpuQueue);
        c.wgpuDeviceAddRef(device.handle);
        self.* = .{ .instance = device.instance, .device = device.handle, .handle = c.wgpuDeviceGetQueue(device.handle) };
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuQueue = @ptrCast(@alignCast(ptr));
        c.wgpuQueueRelease(self.handle);
        c.wgpuDeviceRelease(self.device);
        allocator.destroy(self);
    }

    fn submit(ptr: *anyopaque, desc: sync.SubmitDescriptor) anyerror!void {
        const self: *WgpuQueue = @ptrCast(@alignCast(ptr));
        var buffers: [16]c.WGPUCommandBuffer = undefined;
        if (desc.command_buffers.len > buffers.len) return error.TooManyCommandBuffers;
        for (desc.command_buffers, buffers[0..desc.command_buffers.len]) |cmd, *out| {
            const recorded: *WgpuCommandBuffer = @ptrCast(@alignCast(cmd.ptr));
            out.* = recorded.finished orelse return error.CommandBufferNotFinished;
        }
        c.wgpuQueueSubmit(self.handle, desc.command_buffers.len, &buffers);
        for (desc.command_buffers) |cmd| {
            const recorded: *WgpuCommandBuffer = @ptrCast(@alignCast(cmd.ptr));
            c.wgpuCommandBufferRelease(recorded.finished);
            recorded.finished = null;
        }
        for (desc.signal_fences) |point| try ptrOf(WgpuFence, point.fence.handle).signalAfter(self.handle, point.value);
    }

    fn waitIdle(ptr: *anyopaque) anyerror!void {
        const self: *WgpuQueue = @ptrCast(@alignCast(ptr));
        const future = c.wgpuQueueOnSubmittedWorkDone(self.handle, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_WaitAnyOnly,
            .callback = struct {
                fn done(_: c.WGPUQueueWorkDoneStatus, _: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
            }.done,
            .userdata1 = null,
            .userdata2 = null,
        });
        _ = try waitFuture(self.instance, future, forever);
    }
};
