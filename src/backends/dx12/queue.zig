const std = @import("std");
const Queue = @import("../../interface/queue.zig").Queue;
const QueueDescriptor = @import("../../interface/queue.zig").QueueDescriptor;
const QueueKind = @import("../../interface/queue.zig").QueueKind;
const device_mod = @import("device.zig");
const Dx12Device = device_mod.Dx12Device;
const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

const log = std.log.scoped(.dx12_queue);

pub const Dx12Queue = struct {
    queue: ComPtr(dx.ID3D12CommandQueue) = .{},
    kind: QueueKind = .graphics,

    const vtable: Queue.VTable = .{
        .deinitFn = deinitImpl,
    };

    pub fn init(device_ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) !Queue {
        const self = try allocator.create(Dx12Queue);
        self.* = .{ .kind = desc.kind };
        errdefer {
            self.queue.deinit();
            allocator.destroy(self);
        }

        const device: *Dx12Device = @ptrCast(@alignCast(device_ptr));
        const dx_desc = dx.D3D12_COMMAND_QUEUE_DESC{
            .Type = toDxQueueKind(desc.kind),
            .Priority = desc.priority,
            .Flags = dx.D3D12_COMMAND_QUEUE_FLAG_NONE,
            .NodeMask = desc.node_mask,
        };

        log.debug("initialising ID3D12CommandQueue", .{});
        const raw_device = device.device.unwrap();
        try checkHr(raw_device.lpVtbl.*.CreateCommandQueue.?(
            raw_device,
            &dx_desc,
            &dx.IID_ID3D12CommandQueue,
            @ptrCast(self.queue.put()),
        ));
        log.debug("successfully initialised ID3D12CommandQueue", .{});

        return Queue{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Queue = @ptrCast(@alignCast(ptr));
        self.queue.deinit();
        allocator.destroy(self);
    }
};

fn toDxQueueKind(kind: QueueKind) dx.D3D12_COMMAND_LIST_TYPE {
    return switch (kind) {
        .graphics => dx.D3D12_COMMAND_LIST_TYPE_DIRECT,
        .compute => dx.D3D12_COMMAND_LIST_TYPE_COMPUTE,
        .copy => dx.D3D12_COMMAND_LIST_TYPE_COPY,
    };
}
