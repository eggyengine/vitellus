//! DirectX 12 asynchronous queue and timeline synchronisation.

const std = @import("std");
const sync = @import("../../interface/sync.zig");
const command = @import("command.zig");
const queue_impl = @import("queue.zig");
const Dx12Queue = queue_impl.Dx12Queue;
const Dx12Device = @import("device.zig").Dx12Device;
const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;
const log = std.log.scoped(.dx12_sync);

pub const Dx12Fence = struct {
    allocator: std.mem.Allocator,
    fence: ComPtr(dx.ID3D12Fence) = .{},
    fn fromHandle(value: sync.Fence) !*Dx12Fence {
        if (value.handle == 0) return error.InvalidFence;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const Dx12Semaphore = struct {
    allocator: std.mem.Allocator,
    fence: ComPtr(dx.ID3D12Fence) = .{},
    value: u64 = 0,
    fn fromHandle(value: sync.Semaphore) !*Dx12Semaphore {
        if (value.handle == 0) return error.InvalidSemaphore;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const fence_vtable: sync.Fence.VTable = .{
    .deinitFn = destroyFence,
    .currentValueFn = fenceValue,
    .waitFn = waitFence,
};
const semaphore_vtable: sync.Semaphore.VTable = .{ .deinitFn = destroySemaphore };

pub fn createFence(ptr: *anyopaque, initial_value: u64) anyerror!sync.Fence {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12Fence);
    self.* = .{ .allocator = device.allocator };
    errdefer device.allocator.destroy(self);
    try checkHr(device.device.unwrap().lpVtbl.*.CreateFence.?(device.device.unwrap(), initial_value, dx.D3D12_FENCE_FLAG_NONE, &dx.IID_ID3D12Fence, @ptrCast(self.fence.put())));
    log.debug("created DX12 fence initial-value={}", .{initial_value});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &fence_vtable };
}

pub fn destroyFence(value: sync.Fence) void {
    const self = Dx12Fence.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.fence.deinit();
    log.debug("destroyed DX12 fence", .{});
    allocator.destroy(self);
}

pub fn createSemaphore(ptr: *anyopaque) anyerror!sync.Semaphore {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12Semaphore);
    self.* = .{ .allocator = device.allocator };
    errdefer device.allocator.destroy(self);
    try checkHr(device.device.unwrap().lpVtbl.*.CreateFence.?(device.device.unwrap(), 0, dx.D3D12_FENCE_FLAG_NONE, &dx.IID_ID3D12Fence, @ptrCast(self.fence.put())));
    log.debug("created DX12 semaphore", .{});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &semaphore_vtable };
}

pub fn destroySemaphore(value: sync.Semaphore) void {
    const self = Dx12Semaphore.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.fence.deinit();
    log.debug("destroyed DX12 semaphore", .{});
    allocator.destroy(self);
}

pub fn fenceValue(value: sync.Fence) u64 {
    const self = Dx12Fence.fromHandle(value) catch return 0;
    return self.fence.unwrap().lpVtbl.*.GetCompletedValue.?(self.fence.unwrap());
}

pub fn waitFence(point: sync.FencePoint, timeout_ns: ?u64) anyerror!bool {
    const self = try Dx12Fence.fromHandle(point.fence);
    const fence = self.fence.unwrap();
    if (fence.lpVtbl.*.GetCompletedValue.?(fence) >= point.value) return true;
    const event = dx.CreateEventW(null, 0, 0, null) orelse return error.CreateEventFailed;
    defer _ = dx.CloseHandle(event);
    try checkHr(fence.lpVtbl.*.SetEventOnCompletion.?(fence, point.value, event));
    const timeout_ms: u32 = if (timeout_ns) |ns| @intCast(@min(ns / std.time.ns_per_ms + @intFromBool(ns % std.time.ns_per_ms != 0), std.math.maxInt(u32) - 1)) else dx.INFINITE;
    return switch (dx.WaitForSingleObject(event, timeout_ms)) {
        dx.WAIT_OBJECT_0 => true,
        dx.WAIT_TIMEOUT => false,
        else => error.FenceWaitFailed,
    };
}

pub fn submit(ptr: *anyopaque, desc: sync.SubmitDescriptor) anyerror!void {
    const self: *Dx12Queue = @ptrCast(@alignCast(ptr));
    const queue = self.queue.unwrap();
    for (desc.wait_semaphores) |value| try waitSemaphore(queue, value);
    for (desc.wait_fences) |point| {
        const fence = try Dx12Fence.fromHandle(point.fence);
        try checkHr(queue.lpVtbl.*.Wait.?(queue, fence.fence.unwrap(), point.value));
    }
    for (desc.command_buffers) |value| {
        const buffer = command.Dx12CommandBuffer.fromCommandBuffer(value);
        if (!buffer.finished) return error.CommandBufferNotFinished;
        if (@intFromEnum(buffer.pool.kind) != @intFromEnum(self.kind)) return error.CommandBufferQueueKindMismatch;
        var list: ?*dx.ID3D12CommandList = @ptrCast(buffer.list.unwrap());
        queue.lpVtbl.*.ExecuteCommandLists.?(queue, 1, @ptrCast(&list));
    }
    for (desc.signal_semaphores) |value| try signalSemaphore(queue, value);
    for (desc.signal_fences) |point| {
        const fence = try Dx12Fence.fromHandle(point.fence);
        try checkHr(queue.lpVtbl.*.Signal.?(queue, fence.fence.unwrap(), point.value));
    }
}

pub fn waitSemaphore(queue: *dx.ID3D12CommandQueue, value: sync.Semaphore) !void {
    const semaphore = try Dx12Semaphore.fromHandle(value);
    try checkHr(queue.lpVtbl.*.Wait.?(queue, semaphore.fence.unwrap(), semaphore.value));
}

pub fn signalSemaphore(queue: *dx.ID3D12CommandQueue, value: sync.Semaphore) !void {
    const semaphore = try Dx12Semaphore.fromHandle(value);
    semaphore.value += 1;
    try checkHr(queue.lpVtbl.*.Signal.?(queue, semaphore.fence.unwrap(), semaphore.value));
}

pub fn signalSemaphoreCpu(value: sync.Semaphore) !void {
    const semaphore = try Dx12Semaphore.fromHandle(value);
    semaphore.value += 1;
    try checkHr(semaphore.fence.unwrap().lpVtbl.*.Signal.?(semaphore.fence.unwrap(), semaphore.value));
}

pub fn waitIdle(ptr: *anyopaque) anyerror!void {
    const self: *Dx12Queue = @ptrCast(@alignCast(ptr));
    try queue_impl.waitIdle(self);
}
