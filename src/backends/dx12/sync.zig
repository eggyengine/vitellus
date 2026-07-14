//! DirectX 12 queue submission and synchronization entry points.

const sync = @import("../../interface/sync.zig");
const command = @import("command.zig");
const queue_impl = @import("queue.zig");
const Dx12Queue = queue_impl.Dx12Queue;
const dx = @import("dx.zig").c;

pub fn submit(ptr: *anyopaque, desc: sync.SubmitDescriptor) anyerror!void {
    if (desc.wait_semaphores.len != 0 or desc.signal_semaphores.len != 0 or desc.signal_fence != null) return error.UnsupportedSynchronization;
    const self: *Dx12Queue = @ptrCast(@alignCast(ptr));
    const queue = self.queue.unwrap();
    for (desc.command_buffers) |value| {
        const buffer = command.Dx12CommandBuffer.fromCommandBuffer(value);
        if (!buffer.finished) return error.CommandBufferNotFinished;
        var list: ?*dx.ID3D12CommandList = @ptrCast(buffer.list.unwrap());
        queue.lpVtbl.*.ExecuteCommandLists.?(queue, 1, @ptrCast(&list));
    }
    try queue_impl.waitIdle(self);
}

pub fn waitIdle(ptr: *anyopaque) anyerror!void {
    const self: *Dx12Queue = @ptrCast(@alignCast(ptr));
    try queue_impl.waitIdle(self);
}
