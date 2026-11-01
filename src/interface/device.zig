//! Logical GPU device and backend creation dispatch.

const std = @import("std");
const Queue = @import("queue.zig").Queue;
const QueueDescriptor = @import("queue.zig").QueueDescriptor;
const ValidationLevel = @import("settings.zig").ValidationLevel;
const shader = @import("shader.zig");
const resource = @import("resource.zig");
const pipeline = @import("pipeline.zig");
const command = @import("command.zig");
const binding = @import("binding.zig");
const sync = @import("sync.zig");

/// Backend options applied while creating a logical device.
pub const DeviceDescriptor = struct {
    /// Optional name shown for the logical device in graphics debuggers.
    label: ?[]const u8 = null,
    required_features: @import("settings.zig").FeatureSet = .{},
    /// Where compiled pipelines are kept between runs, so the driver needn't compile them
    /// again: Vulkan saves its pipeline cache when the device is destroyed, DirectX 12 each
    /// pipeline as it is made. Must outlive the device.
    pipeline_cache: ?*const @import("../shader_disk_cache.zig").ShaderDiskCache = null,
};

/// GPU memory this process uses and may use, from the driver where it reports it (VMA or
/// D3D12MA estimate otherwise). Budgets change as other programs use the GPU: keep usage
/// under budget, or the OS may page memory out and frames stall.
pub const MemoryBudget = struct {
    /// Memory on the GPU (VRAM; on integrated GPUs, what the driver sets aside for it).
    device_local: Heap = .{},
    /// System memory the GPU reads over the bus: upload and readback buffers.
    shared: Heap = .{},

    pub const Heap = struct { usage_bytes: u64 = 0, budget_bytes: u64 = 0 };
};

/// Owning handle to a logical GPU device.
///
/// Objects created by this device must be destroyed before `deinit`.
pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        memoryBudgetFn: ?*const fn (ptr: *anyopaque) MemoryBudget = null,
        createQueueFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) anyerror!Queue,
        createShaderFn: ?*const fn (*anyopaque, std.mem.Allocator, shader.ShaderDescriptor) anyerror!shader.Shader = null,
        createBufferFn: ?*const fn (*anyopaque, resource.BufferDescriptor) anyerror!resource.Buffer = null,
        createTextureFn: ?*const fn (*anyopaque, resource.TextureDescriptor) anyerror!resource.Texture = null,
        createTextureViewFn: ?*const fn (*anyopaque, resource.TextureViewDescriptor) anyerror!resource.TextureView = null,
        createSamplerFn: ?*const fn (*anyopaque, resource.SamplerDescriptor) anyerror!resource.Sampler = null,
        createBindGroupLayoutFn: ?*const fn (*anyopaque, binding.BindGroupLayoutDescriptor) anyerror!binding.BindGroupLayout = null,
        createBindGroupFn: ?*const fn (*anyopaque, binding.BindGroupDescriptor) anyerror!binding.BindGroup = null,
        createPipelineLayoutFn: ?*const fn (*anyopaque, pipeline.PipelineLayoutDescriptor) anyerror!pipeline.PipelineLayout = null,
        createGraphicsPipelineFn: ?*const fn (*anyopaque, pipeline.GraphicsPipelineDescriptor) anyerror!pipeline.GraphicsPipeline = null,
        createComputePipelineFn: ?*const fn (*anyopaque, pipeline.ComputePipelineDescriptor) anyerror!pipeline.ComputePipeline = null,
        createCommandPoolFn: ?*const fn (*anyopaque, command.CommandPoolDescriptor) anyerror!command.CommandPool = null,
        createQuerySetFn: ?*const fn (*anyopaque, command.QuerySetDescriptor) anyerror!command.QuerySet = null,
        createFenceFn: ?*const fn (*anyopaque, sync.FenceDescriptor) anyerror!sync.Fence = null,
        createSemaphoreFn: ?*const fn (*anyopaque, sync.SemaphoreDescriptor) anyerror!sync.Semaphore = null,
    };

    /// Open a logical device on `adapter`, with the features `desc` requires (failing with
    /// `RequiredFeatureUnsupported` when the adapter lacks one). Everything else is made from it.
    pub fn init(adapter: anytype, desc: DeviceDescriptor) !Device {
        const required: u32 = @bitCast(desc.required_features);
        const available: u32 = @bitCast(adapter.capabilities().features);
        if ((required & ~available) != 0) return error.RequiredFeatureUnsupported;
        return adapter.vtable.createDeviceFn(adapter.ptr, adapter.allocator, desc);
    }

    /// Memory in use and the budget for it now; null where the backend can't tell (WebGPU).
    /// Cheap enough to call once a frame.
    pub fn memoryBudget(self: Device) ?MemoryBudget {
        const query = self.vtable.memoryBudgetFn orelse return null;
        return query(self.ptr);
    }

    /// Releases the logical device. All child objects must already be gone.
    pub fn deinit(self: Device) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};

test "a device reports the memory its buffers take" {
    const vit = @import("../root.zig");
    const gpa = std.testing.allocator;
    const instance = vit.Instance.init(gpa, .{ .validation = .none }) catch return error.SkipZigTest;
    defer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{}) catch return error.SkipZigTest;
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();

    const before = device.memoryBudget() orelse return error.SkipZigTest;
    try std.testing.expect(before.device_local.budget_bytes > 0);
    // Big enough to need a block of its own, on any allocator's block sizes.
    const buffer = try vit.Buffer.init(device, .{ .size = 512 << 20, .usage = .{ .storage = true } });
    defer buffer.deinit();
    const after = device.memoryBudget().?;
    try std.testing.expect(after.device_local.usage_bytes + after.shared.usage_bytes >= before.device_local.usage_bytes + before.shared.usage_bytes + (512 << 20));
}
