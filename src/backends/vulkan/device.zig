const std = @import("std");
const vk = @import("vulkan");

const bind_group = @import("../../types/bind_group.zig");
const buffer = @import("../../types/buffer.zig");
const command = @import("../../types/command.zig");
const def = @import("../../types/def.zig");
const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const pipeline = @import("../../types/pipeline.zig");
const sampler = @import("../../types/sampler.zig");
const shader = @import("../../types/shader.zig");
const texture = @import("../../types/texture.zig");
const adapter_backend = @import("adapter.zig");
const shad = @import("shader.zig");
const vkShaderModule = shad.vkShaderModule;
const command_backend = @import("command.zig");
const pipeline_backend = @import("pipeline.zig");
const resource_backend = @import("resource.zig");

const log = std.log.scoped(.vitellus_vulkan);

pub const vkDevice = struct {
    adapter: *adapter_backend.vkAdapter,
    vkd: vk.DeviceWrapper,
    device: vk.DeviceProxy,
    device_handle: vk.Device,
    graphics_queue_family: u32,
    present_queue_family: u32,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    queue: vkQueue,

    pub const vtable = hal.Device.VTable{
        .destroy = destroy,
        .createBuffer = createBuffer,
        .createTexture = createTexture,
        .createSampler = createSampler,
        .importExternalTexture = importExternalTexture,
        .createBindGroupLayout = createBindGroupLayout,
        .createPipelineLayout = createPipelineLayout,
        .createBindGroup = createBindGroup,
        .createShaderModule = createShaderModule,
        .createComputePipeline = createComputePipeline,
        .createRenderPipeline = createRenderPipeline,
        .createComputePipelineAsync = createComputePipelineAsync,
        .createRenderPipelineAsync = createRenderPipelineAsync,
        .createCommandEncoder = createCommandEncoder,
        .createRenderBundleEncoder = createRenderBundleEncoder,
        .createQuerySet = createQuerySet,
        .lost = lost,
        .popErrorScope = popErrorScope,
        .pushErrorScope = pushErrorScope,
        .getQueue = getQueue,
    };

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.device_handle != .null_handle) {
            log.debug("destroying vulkan logical device: handle=0x{x}", .{@intFromEnum(typed.device_handle)});
            typed.device.destroyDevice(null);
            typed.device_handle = .null_handle;
        }
        typed.adapter.gpu.allocator.destroy(typed);
    }

    fn createBuffer(ptr: *anyopaque, descriptor: buffer.Buffer.Descriptor) anyerror!hal.Buffer {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkBuffer.init(typed, descriptor);
    }

    fn createTexture(ptr: *anyopaque, descriptor: texture.Texture.Descriptor) anyerror!hal.Texture {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkTexture.init(typed, descriptor);
    }

    fn createSampler(ptr: *anyopaque, descriptor: sampler.Sampler.Descriptor) anyerror!hal.Sampler {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkSampler.init(typed, descriptor);
    }

    fn importExternalTexture(ptr: *anyopaque, descriptor: texture.ExternalTexture.Descriptor) anyerror!hal.ExternalTexture {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkExternalTexture.init(typed, descriptor);
    }

    fn createBindGroupLayout(ptr: *anyopaque, descriptor: bind_group.BindGroupLayout.Descriptor) anyerror!hal.BindGroupLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkBindGroupLayout.init(typed, descriptor);
    }

    fn createPipelineLayout(ptr: *anyopaque, descriptor: pipeline.PipelineLayout.Descriptor) anyerror!hal.PipelineLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        log.debug("creating vulkan pipeline layout: bind_group_layouts={}", .{descriptor.bindGroupLayouts.len});
        return try pipeline_backend.vkPipelineLayout.init(typed, descriptor);
    }

    fn createBindGroup(ptr: *anyopaque, descriptor: bind_group.BindGroup.Descriptor) anyerror!hal.BindGroup {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkBindGroup.init(typed, descriptor);
    }

    fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        log.debug("creating vulkan shader module: bytes={}", .{descriptor.code.len});
        return try vkShaderModule.init(typed, descriptor);
    }

    fn createComputePipeline(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try pipeline_backend.vkComputePipeline.init(typed, descriptor);
    }

    fn createRenderPipeline(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        log.debug("creating vulkan render pipeline: vertex_buffers={} has_fragment={} has_depth_stencil={}", .{
            descriptor.vertex.buffers.len,
            descriptor.fragment != null,
            descriptor.depthStencil != null,
        });
        return try pipeline_backend.vkRenderPipeline.init(typed, descriptor);
    }

    fn createComputePipelineAsync(
        ptr: *anyopaque,
        io: std.Io,
        descriptor: pipeline.ComputePipeline.Descriptor,
    ) std.Io.Future(anyerror!hal.ComputePipeline) {
        return io.async(createComputePipelineAsyncInternal, .{ ptr, descriptor });
    }

    fn createComputePipelineAsyncInternal(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createRenderPipelineAsync(
        ptr: *anyopaque,
        io: std.Io,
        descriptor: pipeline.RenderPipeline.Descriptor,
    ) std.Io.Future(anyerror!hal.RenderPipeline) {
        return io.async(createRenderPipelineAsyncInternal, .{ ptr, descriptor });
    }

    fn createRenderPipelineAsyncInternal(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
        return createRenderPipeline(ptr, descriptor);
    }

    fn createCommandEncoder(ptr: *anyopaque, descriptor: ?command.CommandEncoder.Descriptor) anyerror!hal.CommandEncoder {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try command_backend.vkCommandEncoder.init(typed, descriptor);
    }

    fn createRenderBundleEncoder(ptr: *anyopaque, descriptor: command.RenderBundleEncoder.Descriptor) anyerror!hal.RenderBundleEncoder {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try command_backend.vkRenderBundleEncoder.init(typed, descriptor);
    }

    fn createQuerySet(ptr: *anyopaque, descriptor: gpu.QuerySet.Descriptor) anyerror!hal.QuerySet {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkQuerySet.init(typed, descriptor);
    }

    fn lost(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!gpu.Device.LostInfo) {
        return io.async(lostInternal, .{ptr});
    }

    fn lostInternal(ptr: *anyopaque) anyerror!gpu.Device.LostInfo {
        _ = ptr;
        return error.NotImplemented;
    }

    fn popErrorScope(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!?gpu.Device.Error) {
        return io.async(popErrorScopeInternal, .{ptr});
    }

    fn popErrorScopeInternal(ptr: *anyopaque) anyerror!?gpu.Device.Error {
        _ = ptr;
        return null;
    }

    fn pushErrorScope(ptr: *anyopaque, filter: gpu.Device.ErrorFilter) void {
        _ = ptr;
        _ = filter;
    }

    fn getQueue(ptr: *anyopaque) hal.Queue {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return .{
            .ptr = &typed.queue,
            .vtable = &vkQueue.vtable,
        };
    }
};

pub const vkQueue = struct {
    device: *vkDevice,
    handle: vk.Queue,

    pub const vtable = hal.Queue.VTable{
        .submit = submit,
        .writeBuffer = writeBuffer,
        .writeTexture = writeTexture,
        .copyExternalImageToTexture = copyExternalImageToTexture,
        .onSubmittedWorkDone = onSubmittedWorkDone,
    };

    fn submit(ptr: *anyopaque, command_buffers: []const hal.CommandBuffer) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = typed;
        log.debug("submitting vulkan queue work: command_buffers={}", .{command_buffers.len});
    }

    fn writeBuffer(
        ptr: *anyopaque,
        target: hal.Buffer,
        buffer_offset: def.Size64,
        data: def.AllowSharedBufferSource,
        data_offset: def.Size64,
        size: ?def.Size64,
    ) void {
        _ = ptr;
        _ = target;
        _ = buffer_offset;
        _ = data;
        _ = data_offset;
        _ = size;
    }

    fn writeTexture(
        ptr: *anyopaque,
        destination: texture.TexelCopyTextureInfo,
        data: def.AllowSharedBufferSource,
        data_layout: texture.TexelCopyBufferLayout,
        size: texture.Texture.Extent3D,
    ) void {
        _ = ptr;
        _ = destination;
        _ = data;
        _ = data_layout;
        _ = size;
    }

    fn copyExternalImageToTexture(
        ptr: *anyopaque,
        source: texture.CopyExternalImageSourceInfo,
        destination: texture.CopyExternalImageDestInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = copy_size;
    }

    fn onSubmittedWorkDone(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!void) {
        return io.async(onSubmittedWorkDoneInternal, .{ptr});
    }

    fn onSubmittedWorkDoneInternal(ptr: *anyopaque) anyerror!void {
        _ = ptr;
    }
};
