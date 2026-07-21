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
const sync = @import("sync.zig");
const binding = @import("binding.zig");
const debug = @import("debug.zig");
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

const log = std.log.scoped(.dx12_device);

const dx = @import("dx.zig").c;

pub const Dx12Device = struct {
    allocator: std.mem.Allocator,
    device: ComPtr(dx.ID3D12Device) = .{},
    resource_heap: ComPtr(dx.ID3D12DescriptorHeap) = .{},
    sampler_heap: ComPtr(dx.ID3D12DescriptorHeap) = .{},
    rtv_heap: ComPtr(dx.ID3D12DescriptorHeap) = .{},
    dsv_heap: ComPtr(dx.ID3D12DescriptorHeap) = .{},
    resource_used: [4096]bool = [_]bool{false} ** 4096,
    sampler_used: [256]bool = [_]bool{false} ** 256,
    rtv_used: [256]bool = [_]bool{false} ** 256,
    dsv_used: [256]bool = [_]bool{false} ** 256,
    debug_device: debug.Dx12DebugDevice = .{},

    pub const resource_capacity = 4096;
    pub const sampler_capacity = 256;
    pub const rtv_capacity = 256;
    pub const dsv_capacity = 256;

    pub const DescriptorAllocation = struct {
        cpu: dx.D3D12_CPU_DESCRIPTOR_HANDLE,
        gpu: dx.D3D12_GPU_DESCRIPTOR_HANDLE,
        index: u32,
        count: u32,
    };

    const vtable: Device.VTable = .{
        .deinitFn = deinitImpl,
        .createQueueFn = createQueueImpl,
        .createShaderFn = shader.create,
        .createBufferFn = resource.createBuffer,
        .createTextureFn = resource.createTexture,
        .createTextureViewFn = resource.createTextureView,
        .createSamplerFn = binding.createSampler,
        .createBindGroupLayoutFn = binding.createLayout,
        .createBindGroupFn = binding.createGroup,
        .createPipelineLayoutFn = pipeline.createLayout,
        .createGraphicsPipelineFn = pipeline.createGraphics,
        .createComputePipelineFn = pipeline.createCompute,
        .createCommandPoolFn = command.createPool,
        .createQuerySetFn = command.createQuerySet,
        .createFenceFn = sync.createFence,
        .createSemaphoreFn = sync.createSemaphore,
    };

    pub fn init(adapter_ptr: *anyopaque, allocator: std.mem.Allocator, desc: DeviceDescriptor) !Device {
        const adapter: *Dx12Adapter = @ptrCast(@alignCast(adapter_ptr));

        const self = try allocator.create(Dx12Device);
        self.* = .{ .allocator = allocator };
        errdefer {
            self.rtv_heap.deinit();
            self.dsv_heap.deinit();
            self.sampler_heap.deinit();
            self.resource_heap.deinit();
            self.device.deinit();
            allocator.destroy(self);
        }

        if (adapter.instance.?.config.validation != .none) {
            if (adapter.instance) |instance| {
                instance.debug_ctrl.enable(adapter.instance.?.config.validation);
            } else {
                var debug_ctrl = debug.Dx12DebugController.init(adapter.instance.?.config.validation);
                defer debug_ctrl.deinit();
            }
        }
        log.debug("creating ID3D12Device", .{});
        try checkHr(dx.D3D12CreateDevice(
            @ptrCast(adapter.adapter.get()),
            dx.D3D_FEATURE_LEVEL_11_0,
            &dx.IID_ID3D12Device,
            @ptrCast(self.device.put()),
        ));
        utils.setD3D12Name(allocator, self.device.unwrap(), desc.label);
        log.debug("ID3D12Device successfully initialised", .{});

        try self.createDescriptorHeap(&self.resource_heap, dx.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, resource_capacity, true);
        try self.createDescriptorHeap(&self.sampler_heap, dx.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, sampler_capacity, true);
        try self.createDescriptorHeap(&self.rtv_heap, dx.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, rtv_capacity, false);
        try self.createDescriptorHeap(&self.dsv_heap, dx.D3D12_DESCRIPTOR_HEAP_TYPE_DSV, dsv_capacity, false);
        utils.setD3D12DerivedName(allocator, self.resource_heap.unwrap(), desc.label, "resource descriptors");
        utils.setD3D12DerivedName(allocator, self.sampler_heap.unwrap(), desc.label, "sampler descriptors");
        utils.setD3D12DerivedName(allocator, self.rtv_heap.unwrap(), desc.label, "RTV descriptors");
        utils.setD3D12DerivedName(allocator, self.dsv_heap.unwrap(), desc.label, "DSV descriptors");
        log.debug("created DX12 descriptor heaps resources={} samplers={} RTVs={} DSVs={}", .{ resource_capacity, sampler_capacity, rtv_capacity, dsv_capacity });

        if (adapter.instance.?.config.validation != .none) {
            self.debug_device = debug.Dx12DebugDevice.init(self.device);
        }

        return Device{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Device = @ptrCast(@alignCast(ptr));
        self.rtv_heap.deinit();
        self.dsv_heap.deinit();
        self.sampler_heap.deinit();
        self.resource_heap.deinit();
        self.debug_device.reportLiveObjects();
        self.debug_device.deinit();
        self.device.deinit();
        log.debug("destroyed DX12 device and descriptor heaps", .{});
        allocator.destroy(self);
    }

    fn createQueueImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) anyerror!Queue {
        return Dx12Queue.init(ptr, allocator, desc);
    }

    fn createDescriptorHeap(self: *Dx12Device, output: *ComPtr(dx.ID3D12DescriptorHeap), kind: dx.D3D12_DESCRIPTOR_HEAP_TYPE, count: u32, visible: bool) !void {
        const desc = dx.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = kind,
            .NumDescriptors = count,
            .Flags = if (visible) dx.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE else dx.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
            .NodeMask = 0,
        };
        try checkHr(self.device.unwrap().lpVtbl.*.CreateDescriptorHeap.?(
            self.device.unwrap(),
            &desc,
            &dx.IID_ID3D12DescriptorHeap,
            @ptrCast(output.put()),
        ));
    }

    pub fn allocateResourceDescriptors(self: *Dx12Device, count: u32) !DescriptorAllocation {
        return self.allocateDescriptors(self.resource_heap.unwrap(), dx.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, self.resource_used[0..], count, true);
    }

    pub fn allocateSamplerDescriptors(self: *Dx12Device, count: u32) !DescriptorAllocation {
        return self.allocateDescriptors(self.sampler_heap.unwrap(), dx.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, self.sampler_used[0..], count, true);
    }

    pub fn allocateRtv(self: *Dx12Device) !DescriptorAllocation {
        return self.allocateDescriptors(self.rtv_heap.unwrap(), dx.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, self.rtv_used[0..], 1, false);
    }

    pub fn allocateDsv(self: *Dx12Device) !DescriptorAllocation {
        return self.allocateDescriptors(self.dsv_heap.unwrap(), dx.D3D12_DESCRIPTOR_HEAP_TYPE_DSV, self.dsv_used[0..], 1, false);
    }

    pub fn freeResourceDescriptors(self: *Dx12Device, index: u32, count: u32) void {
        freeDescriptors(self.resource_used[0..], index, count);
    }
    pub fn freeSamplerDescriptors(self: *Dx12Device, index: u32, count: u32) void {
        freeDescriptors(self.sampler_used[0..], index, count);
    }
    pub fn freeRtv(self: *Dx12Device, index: u32) void {
        freeDescriptors(self.rtv_used[0..], index, 1);
    }
    pub fn freeDsv(self: *Dx12Device, index: u32) void {
        freeDescriptors(self.dsv_used[0..], index, 1);
    }

    fn allocateDescriptors(
        self: *Dx12Device,
        heap: *dx.ID3D12DescriptorHeap,
        kind: dx.D3D12_DESCRIPTOR_HEAP_TYPE,
        used: []bool,
        count: u32,
        visible: bool,
    ) !DescriptorAllocation {
        const count_usize: usize = @intCast(count);
        if (count == 0 or count_usize > used.len) return error.DescriptorHeapFull;
        var index: u32 = 0;
        while (@as(usize, index) + count_usize <= used.len) : (index += 1) {
            var available = true;
            const start: usize = @intCast(index);
            for (used[start .. start + count_usize]) |slot| if (slot) {
                available = false;
                break;
            };
            if (available) break;
        }
        const start: usize = @intCast(index);
        if (start + count_usize > used.len) return error.DescriptorHeapFull;
        @memset(used[start .. start + count_usize], true);
        const stride = self.device.unwrap().lpVtbl.*.GetDescriptorHandleIncrementSize.?(self.device.unwrap(), kind);
        var cpu: dx.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = heap.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(heap, &cpu);
        cpu.ptr += @as(usize, index) * stride;
        var gpu: dx.D3D12_GPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 };
        if (visible) {
            _ = heap.lpVtbl.*.GetGPUDescriptorHandleForHeapStart.?(heap, &gpu);
            gpu.ptr += @as(u64, index) * stride;
        }
        return .{ .cpu = cpu, .gpu = gpu, .index = index, .count = count };
    }
};

fn freeDescriptors(used: []bool, index: u32, count: u32) void {
    const start: usize = @intCast(index);
    const count_usize: usize = @intCast(count);
    if (start + count_usize <= used.len) @memset(used[start .. start + count_usize], false);
}
