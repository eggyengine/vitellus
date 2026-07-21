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

    pub fn init(adapter: anytype, desc: DeviceDescriptor) !Device {
        const required: u32 = @bitCast(desc.required_features);
        const available: u32 = @bitCast(adapter.capabilities().features);
        if ((required & ~available) != 0) return error.RequiredFeatureUnsupported;
        return adapter.vtable.createDeviceFn(adapter.ptr, adapter.allocator, desc);
    }

    /// Releases the logical device. All child objects must already be gone.
    pub fn deinit(self: Device) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};
