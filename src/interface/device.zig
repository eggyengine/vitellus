//! Logical-device factories and resource lifetime entry points.

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
    /// Validation requested from the selected backend.
    validation: ValidationLevel = .none,
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
        createCommandBufferFn: ?*const fn (*anyopaque, command.CommandPool) anyerror!command.CommandBuffer = null,
        createQuerySetFn: ?*const fn (*anyopaque, command.QuerySetDescriptor) anyerror!command.QuerySet = null,
        createFenceFn: ?*const fn (*anyopaque, u64) anyerror!sync.Fence = null,
        createSemaphoreFn: ?*const fn (*anyopaque) anyerror!sync.Semaphore = null,
        mapBufferFn: ?*const fn (*anyopaque, resource.Buffer, resource.MapMode, resource.BufferRange) anyerror![]u8 = null,
        unmapBufferFn: ?*const fn (*anyopaque, resource.Buffer, ?resource.BufferRange) void = null,
        destroyShaderFn: ?*const fn (*anyopaque, shader.Shader) void = null,
        destroyBufferFn: ?*const fn (*anyopaque, resource.Buffer) void = null,
        destroyTextureFn: ?*const fn (*anyopaque, resource.Texture) void = null,
        destroyTextureViewFn: ?*const fn (*anyopaque, resource.TextureView) void = null,
        destroySamplerFn: ?*const fn (*anyopaque, resource.Sampler) void = null,
        destroyBindGroupLayoutFn: ?*const fn (*anyopaque, binding.BindGroupLayout) void = null,
        destroyBindGroupFn: ?*const fn (*anyopaque, binding.BindGroup) void = null,
        destroyPipelineLayoutFn: ?*const fn (*anyopaque, pipeline.PipelineLayout) void = null,
        destroyGraphicsPipelineFn: ?*const fn (*anyopaque, pipeline.GraphicsPipeline) void = null,
        destroyComputePipelineFn: ?*const fn (*anyopaque, pipeline.ComputePipeline) void = null,
        destroyCommandPoolFn: ?*const fn (*anyopaque, command.CommandPool) void = null,
        resetCommandPoolFn: ?*const fn (*anyopaque, command.CommandPool) anyerror!void = null,
        destroyCommandBufferFn: ?*const fn (*anyopaque, command.CommandBuffer) void = null,
        destroyQuerySetFn: ?*const fn (*anyopaque, command.QuerySet) void = null,
        destroyFenceFn: ?*const fn (*anyopaque, sync.Fence) void = null,
        destroySemaphoreFn: ?*const fn (*anyopaque, sync.Semaphore) void = null,
        fenceValueFn: ?*const fn (*anyopaque, sync.Fence) u64 = null,
        waitFenceFn: ?*const fn (*anyopaque, sync.FencePoint, ?u64) anyerror!bool = null,
    };

    /// Creates a queue with the requested command capability.
    pub fn createQueue(self: Device, desc: QueueDescriptor) !Queue {
        return self.vtable.createQueueFn(self.ptr, self.allocator, desc);
    }

    /// Compiles or consumes a shader module and retains its backend binary.
    pub fn createShader(self: Device, desc: shader.ShaderDescriptor) !shader.Shader {
        return if (self.vtable.createShaderFn) |f| f(self.ptr, self.allocator, desc) else error.Unsupported;
    }
    /// Allocates a GPU buffer described by `desc`.
    pub fn createBuffer(self: Device, desc: resource.BufferDescriptor) !resource.Buffer {
        return if (self.vtable.createBufferFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    /// Allocates a texture and optionally uploads its first subresource.
    pub fn createTexture(self: Device, desc: resource.TextureDescriptor) !resource.Texture {
        return if (self.vtable.createTextureFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    /// Creates a view into a texture's mip range.
    pub fn createTextureView(self: Device, desc: resource.TextureViewDescriptor) !resource.TextureView {
        return if (self.vtable.createTextureViewFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    /// Creates immutable texture-sampling state.
    pub fn createSampler(self: Device, desc: resource.SamplerDescriptor) !resource.Sampler {
        return if (self.vtable.createSamplerFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    /// Creates a shader-resource binding layout.
    pub fn createBindGroupLayout(self: Device, desc: binding.BindGroupLayoutDescriptor) !binding.BindGroupLayout {
        return if (self.vtable.createBindGroupLayoutFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    /// Creates a bind group matching `desc.layout`.
    pub fn createBindGroup(self: Device, desc: binding.BindGroupDescriptor) !binding.BindGroup {
        return if (self.vtable.createBindGroupFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    pub fn createPipelineLayout(self: Device, desc: pipeline.PipelineLayoutDescriptor) !pipeline.PipelineLayout { return if (self.vtable.createPipelineLayoutFn) |f| f(self.ptr, desc) else error.Unsupported; }
    /// Creates immutable graphics-pipeline state.
    pub fn createGraphicsPipeline(self: Device, desc: pipeline.GraphicsPipelineDescriptor) !pipeline.GraphicsPipeline {
        return if (self.vtable.createGraphicsPipelineFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    pub fn createComputePipeline(self: Device, desc: pipeline.ComputePipelineDescriptor) !pipeline.ComputePipeline { return if (self.vtable.createComputePipelineFn) |f| f(self.ptr, desc) else error.Unsupported; }
    /// Creates storage used to allocate and reset command buffers.
    pub fn createCommandPool(self: Device, desc: command.CommandPoolDescriptor) !command.CommandPool {
        return if (self.vtable.createCommandPoolFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    /// Begins a command buffer owned by `pool`.
    pub fn createCommandBuffer(self: Device, pool: command.CommandPool) !command.CommandBuffer {
        return if (self.vtable.createCommandBufferFn) |f| f(self.ptr, pool) else error.Unsupported;
    }
    pub fn createQuerySet(self: Device, desc: command.QuerySetDescriptor) !command.QuerySet { return if (self.vtable.createQuerySetFn) |f| f(self.ptr, desc) else error.Unsupported; }
    pub fn createFence(self: Device, initial_value: u64) !sync.Fence { return if (self.vtable.createFenceFn) |f| f(self.ptr, initial_value) else error.Unsupported; }
    pub fn createSemaphore(self: Device) !sync.Semaphore { return if (self.vtable.createSemaphoreFn) |f| f(self.ptr) else error.Unsupported; }
    pub fn mapBuffer(self: Device, value: resource.Buffer, mode: resource.MapMode, range: resource.BufferRange) ![]u8 { return if (self.vtable.mapBufferFn) |f| f(self.ptr, value, mode, range) else error.Unsupported; }
    pub fn unmapBuffer(self: Device, value: resource.Buffer, written: ?resource.BufferRange) void { if (self.vtable.unmapBufferFn) |f| f(self.ptr, value, written); }
    /// Releases a shader created by this device.
    pub fn destroyShader(self: Device, value: shader.Shader) void {
        if (self.vtable.destroyShaderFn) |f| f(self.ptr, value);
    }
    /// Releases a buffer created by this device.
    pub fn destroyBuffer(self: Device, value: resource.Buffer) void {
        if (self.vtable.destroyBufferFn) |f| f(self.ptr, value);
    }
    /// Releases a texture created by this device.
    pub fn destroyTexture(self: Device, value: resource.Texture) void {
        if (self.vtable.destroyTextureFn) |f| f(self.ptr, value);
    }
    /// Releases a texture view created by this device.
    pub fn destroyTextureView(self: Device, value: resource.TextureView) void {
        if (self.vtable.destroyTextureViewFn) |f| f(self.ptr, value);
    }
    /// Releases a sampler created by this device.
    pub fn destroySampler(self: Device, value: resource.Sampler) void {
        if (self.vtable.destroySamplerFn) |f| f(self.ptr, value);
    }
    /// Releases a bind-group layout created by this device.
    pub fn destroyBindGroupLayout(self: Device, value: binding.BindGroupLayout) void {
        if (self.vtable.destroyBindGroupLayoutFn) |f| f(self.ptr, value);
    }
    /// Releases a bind group created by this device.
    pub fn destroyBindGroup(self: Device, value: binding.BindGroup) void {
        if (self.vtable.destroyBindGroupFn) |f| f(self.ptr, value);
    }
    pub fn destroyPipelineLayout(self: Device, value: pipeline.PipelineLayout) void { if (self.vtable.destroyPipelineLayoutFn) |f| f(self.ptr, value); }
    /// Releases a graphics pipeline created by this device.
    pub fn destroyGraphicsPipeline(self: Device, value: pipeline.GraphicsPipeline) void {
        if (self.vtable.destroyGraphicsPipelineFn) |f| f(self.ptr, value);
    }
    pub fn destroyComputePipeline(self: Device, value: pipeline.ComputePipeline) void { if (self.vtable.destroyComputePipelineFn) |f| f(self.ptr, value); }
    /// Releases a command pool and its command buffers.
    pub fn destroyCommandPool(self: Device, value: command.CommandPool) void {
        if (self.vtable.destroyCommandPoolFn) |f| f(self.ptr, value);
    }
    pub fn resetCommandPool(self: Device, value: command.CommandPool) !void { return if (self.vtable.resetCommandPoolFn) |f| f(self.ptr, value) else error.Unsupported; }
    pub fn destroyCommandBuffer(self: Device, value: command.CommandBuffer) void { if (self.vtable.destroyCommandBufferFn) |f| f(self.ptr, value); }
    pub fn destroyQuerySet(self: Device, value: command.QuerySet) void { if (self.vtable.destroyQuerySetFn) |f| f(self.ptr, value); }
    pub fn destroyFence(self: Device, value: sync.Fence) void { if (self.vtable.destroyFenceFn) |f| f(self.ptr, value); }
    pub fn destroySemaphore(self: Device, value: sync.Semaphore) void { if (self.vtable.destroySemaphoreFn) |f| f(self.ptr, value); }
    pub fn fenceValue(self: Device, value: sync.Fence) u64 { return if (self.vtable.fenceValueFn) |f| f(self.ptr, value) else 0; }
    pub fn waitFence(self: Device, point: sync.FencePoint, timeout_ns: ?u64) !bool { return if (self.vtable.waitFenceFn) |f| f(self.ptr, point, timeout_ns) else error.Unsupported; }

    /// Releases the logical device. All child objects must already be gone.
    pub fn deinit(self: Device) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};
