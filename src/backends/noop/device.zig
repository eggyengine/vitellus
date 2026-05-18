const std = @import("std");

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
const command_backend = @import("command.zig");
const pipeline_backend = @import("pipeline.zig");
const resource = @import("resource.zig");
const shader_backend = @import("shader.zig");

const logz = @import("logz");

pub const NoopDevice = struct {
    allocator: std.mem.Allocator,
    queue: NoopQueue = .{},

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

    pub fn init(allocator: std.mem.Allocator) !struct { hal.Device, hal.Queue } {
        const device = try allocator.create(NoopDevice);
        device.* = .{ .allocator = allocator };
        const device_handle = hal.Device{
            .ptr = device,
            .vtable = &vtable,
        };
        const queue_handle = hal.Queue{
            .ptr = &device.queue,
            .vtable = &NoopQueue.vtable,
        };
        return .{ device_handle, queue_handle };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "destroying noop device", .{}).log();
        typed.allocator.destroy(typed);
    }

    fn createBuffer(ptr: *anyopaque, descriptor: buffer.Buffer.Descriptor) anyerror!hal.Buffer {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.NoopBuffer.init(typed.allocator);
    }

    fn createTexture(ptr: *anyopaque, descriptor: texture.Texture.Descriptor) anyerror!hal.Texture {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.NoopTexture.init(typed.allocator);
    }

    fn createSampler(ptr: *anyopaque, descriptor: sampler.Sampler.Descriptor) anyerror!hal.Sampler {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.NoopSampler.init(typed.allocator);
    }

    fn importExternalTexture(ptr: *anyopaque, descriptor: texture.ExternalTexture.Descriptor) anyerror!hal.ExternalTexture {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.NoopExternalTexture.init(typed.allocator);
    }

    fn createBindGroupLayout(ptr: *anyopaque, descriptor: bind_group.BindGroupLayout.Descriptor) anyerror!hal.BindGroupLayout {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.NoopBindGroupLayout.init(typed.allocator);
    }

    fn createPipelineLayout(ptr: *anyopaque, descriptor: pipeline.PipelineLayout.Descriptor) anyerror!hal.PipelineLayout {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return pipeline_backend.NoopPipelineLayout.init(typed.allocator);
    }

    fn createBindGroup(ptr: *anyopaque, descriptor: bind_group.BindGroup.Descriptor) anyerror!hal.BindGroup {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.NoopBindGroup.init(typed.allocator);
    }

    fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return shader_backend.NoopShaderModule.init(typed.allocator);
    }

    fn createComputePipeline(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return pipeline_backend.NoopComputePipeline.init(typed.allocator);
    }

    fn createRenderPipeline(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return pipeline_backend.NoopRenderPipeline.init(typed.allocator);
    }

    fn createComputePipelineAsync(
        ptr: *anyopaque,
        io: std.Io,
        descriptor: pipeline.ComputePipeline.Descriptor,
    ) std.Io.Future(anyerror!hal.ComputePipeline) {
        return io.async(createComputePipelineAsyncInternal, .{ ptr, descriptor });
    }

    fn createComputePipelineAsyncInternal(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        return createComputePipeline(ptr, descriptor);
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
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return command_backend.NoopCommandEncoder.init(typed.allocator);
    }

    fn createRenderBundleEncoder(ptr: *anyopaque, descriptor: command.RenderBundleEncoder.Descriptor) anyerror!hal.RenderBundleEncoder {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return command_backend.NoopRenderBundleEncoder.init(typed.allocator);
    }

    fn createQuerySet(ptr: *anyopaque, descriptor: gpu.QuerySet.Descriptor) anyerror!hal.QuerySet {
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.NoopQuerySet.init(typed.allocator);
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
        const typed: *NoopDevice = @ptrCast(@alignCast(ptr));
        return .{
            .ptr = &typed.queue,
            .vtable = &NoopQueue.vtable,
        };
    }
};

pub const NoopQueue = struct {
    pub const vtable = hal.Queue.VTable{
        .submit = submit,
        .writeBuffer = writeBuffer,
        .writeTexture = writeTexture,
        .copyExternalImageToTexture = copyExternalImageToTexture,
        .onSubmittedWorkDone = onSubmittedWorkDone,
    };

    fn submit(ptr: *anyopaque, command_buffers: []const hal.CommandBuffer) void {
        _ = ptr;
        _ = command_buffers;
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
