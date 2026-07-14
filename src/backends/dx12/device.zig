const std = @import("std");

const Device = @import("../../interface/device.zig").Device;
const DeviceDescriptor = @import("../../interface/device.zig").DeviceDescriptor;
const Queue = @import("../../interface/queue.zig").Queue;
const QueueDescriptor = @import("../../interface/queue.zig").QueueDescriptor;
const Dx12Adapter = @import("adapter.zig").Dx12Adapter;
const Dx12Queue = @import("queue.zig").Dx12Queue;
const shader = @import("shader.zig");
const resource = @import("resource.zig");
const pipeline = @import("pipeline.zig");
const command = @import("command.zig");
const debug = @import("debug.zig");
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

const log = std.log.scoped(.dx12_device);

const dx = @import("dx.zig").c;

pub const Dx12Device = struct {
    allocator: std.mem.Allocator,
    device: ComPtr(dx.ID3D12Device) = .{},
    debug_device: debug.Dx12DebugDevice = .{},

    const vtable: Device.VTable = .{
        .deinitFn = deinitImpl,
        .createQueueFn = createQueueImpl,
        .createShaderFn = shader.create,
        .createBufferFn = resource.createBuffer,
        .createGraphicsPipelineFn = pipeline.createGraphics,
        .createCommandPoolFn = command.createPool,
        .createCommandBufferFn = command.createBuffer,
        .destroyShaderFn = shader.destroy,
        .destroyBufferFn = resource.destroyBuffer,
        .destroyGraphicsPipelineFn = pipeline.destroyGraphics,
        .destroyCommandPoolFn = command.destroyPool,
    };

    pub fn init(adapter_ptr: *anyopaque, allocator: std.mem.Allocator, desc: DeviceDescriptor) !Device {
        const adapter: *Dx12Adapter = @ptrCast(@alignCast(adapter_ptr));

        const self = try allocator.create(Dx12Device);
        self.* = .{ .allocator = allocator };
        errdefer {
            self.device.deinit();
            allocator.destroy(self);
        }

        log.debug("creating ID3D12Device", .{});
        try checkHr(dx.D3D12CreateDevice(
            @ptrCast(adapter.adapter.get()),
            dx.D3D_FEATURE_LEVEL_11_0,
            &dx.IID_ID3D12Device,
            @ptrCast(self.device.put()),
        ));
        log.debug("ID3D12Device successfully initialised", .{});

        if (desc.validation != .none) {
            self.debug_device = debug.Dx12DebugDevice.init(self.device);
        }

        return Device{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Device = @ptrCast(@alignCast(ptr));
        self.device.deinit();
        self.debug_device.reportLiveObjects();
        self.debug_device.deinit();
        allocator.destroy(self);
    }

    fn createQueueImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) anyerror!Queue {
        return Dx12Queue.init(ptr, allocator, desc);
    }
};
