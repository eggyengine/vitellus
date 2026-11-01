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
const d3d12ma = @import("d3d12ma.zig");
const DescriptorHeap = @import("descriptor_heap.zig").DescriptorHeap;
const ShaderDiskCache = @import("../../shader_disk_cache.zig").ShaderDiskCache;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

const log = std.log.scoped(.dx12_device);

const dx = @import("dx12_c");

pub const Dx12Device = struct {
    allocator: std.mem.Allocator,
    device: ComPtr(dx.ID3D12Device) = .{},
    /// Bind groups' buffer, texture and storage views.
    resources: DescriptorHeap = undefined,
    samplers: DescriptorHeap = undefined,
    rtvs: DescriptorHeap = undefined,
    dsvs: DescriptorHeap = undefined,
    debug_device: debug.Dx12DebugDevice = .{},
    /// Where every buffer's and texture's memory comes from; set right after the device is made.
    memory: d3d12ma.Allocator = undefined,
    /// Where compiled pipelines are kept between runs (`pipeline_cache.zig`), keyed partly by GPU.
    disk: ?*const ShaderDiskCache = null,
    vendor_id: u32 = 0,
    device_id: u32 = 0,

    // Where each heap starts; they double when full, up to D3D12's limits for shader-visible
    // heaps and an arbitrary bound for the CPU-only render-target and depth-stencil ones.
    pub const resource_capacity = 4096;
    pub const sampler_capacity = 256;
    pub const rtv_capacity = 256;
    pub const dsv_capacity = 256;
    const max_resources = dx.D3D12_MAX_SHADER_VISIBLE_DESCRIPTOR_HEAP_SIZE_TIER_1;
    const max_samplers = dx.D3D12_MAX_SHADER_VISIBLE_SAMPLER_HEAP_SIZE;
    const max_attachment_views = 1 << 16;

    /// A range of descriptors. `cpu` (where they are written) is only valid until the next
    /// allocation from the same heap, which may grow it; keep `index`.
    pub const DescriptorAllocation = struct {
        cpu: dx.D3D12_CPU_DESCRIPTOR_HANDLE,
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
        self.memory = try d3d12ma.createAllocator(self.device.unwrap(), @ptrCast(adapter.adapter.unwrap()));
        errdefer d3d12ma.destroyAllocator(self.memory);
        self.disk = desc.pipeline_cache;
        var adapter_desc: dx.DXGI_ADAPTER_DESC1 = undefined;
        if (adapter.adapter.unwrap().lpVtbl.*.GetDesc1.?(adapter.adapter.unwrap(), &adapter_desc) >= 0) {
            self.vendor_id = adapter_desc.VendorId;
            self.device_id = adapter_desc.DeviceId;
        }

        const raw = self.device.unwrap();
        self.resources = try .init(allocator, raw, dx.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, .shader_visible, resource_capacity, max_resources, "resource descriptors");
        errdefer self.resources.deinit(allocator);
        self.samplers = try .init(allocator, raw, dx.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, .shader_visible, sampler_capacity, max_samplers, "sampler descriptors");
        errdefer self.samplers.deinit(allocator);
        self.rtvs = try .init(allocator, raw, dx.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, .cpu_only, rtv_capacity, max_attachment_views, "RTV descriptors");
        errdefer self.rtvs.deinit(allocator);
        self.dsvs = try .init(allocator, raw, dx.D3D12_DESCRIPTOR_HEAP_TYPE_DSV, .cpu_only, dsv_capacity, max_attachment_views, "DSV descriptors");
        errdefer self.dsvs.deinit(allocator);
        log.debug("created DX12 descriptor heaps resources={} samplers={} RTVs={} DSVs={}", .{ resource_capacity, sampler_capacity, rtv_capacity, dsv_capacity });

        if (adapter.instance.?.config.validation != .none) {
            self.debug_device = debug.Dx12DebugDevice.init(self.device);
        }

        return Device{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Device = @ptrCast(@alignCast(ptr));
        self.dsvs.deinit(allocator);
        self.rtvs.deinit(allocator);
        self.samplers.deinit(allocator);
        self.resources.deinit(allocator);
        d3d12ma.destroyAllocator(self.memory);
        self.debug_device.reportLiveObjects();
        self.debug_device.deinit();
        self.device.deinit();
        log.debug("destroyed DX12 device and descriptor heaps", .{});
        allocator.destroy(self);
    }

    fn createQueueImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) anyerror!Queue {
        return Dx12Queue.init(ptr, allocator, desc);
    }

    pub fn allocateResourceDescriptors(self: *Dx12Device, count: u32) !DescriptorAllocation {
        return allocateFrom(&self.resources, self, count);
    }

    pub fn allocateSamplerDescriptors(self: *Dx12Device, count: u32) !DescriptorAllocation {
        return allocateFrom(&self.samplers, self, count);
    }

    pub fn allocateRtv(self: *Dx12Device) !DescriptorAllocation {
        return allocateFrom(&self.rtvs, self, 1);
    }

    pub fn allocateDsv(self: *Dx12Device) !DescriptorAllocation {
        return allocateFrom(&self.dsvs, self, 1);
    }

    pub fn freeResourceDescriptors(self: *Dx12Device, index: u32, count: u32) void {
        self.resources.free(index, count);
    }
    pub fn freeSamplerDescriptors(self: *Dx12Device, index: u32, count: u32) void {
        self.samplers.free(index, count);
    }
    pub fn freeRtv(self: *Dx12Device, index: u32) void {
        self.rtvs.free(index, 1);
    }
    pub fn freeDsv(self: *Dx12Device, index: u32) void {
        self.dsvs.free(index, 1);
    }

    fn allocateFrom(heap: *DescriptorHeap, self: *Dx12Device, count: u32) !DescriptorAllocation {
        const index = try heap.allocate(self.allocator, self.device.unwrap(), count);
        return .{ .cpu = heap.cpu(index), .index = index, .count = count };
    }
};
