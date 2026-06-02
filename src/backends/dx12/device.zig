const std = @import("std");

const descriptor_set = @import("../../types/descriptor_set.zig");
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

pub const DX_Device = struct {
    allocator: std.mem.Allocator,
    queue: DX_Queue = .{},

    pub const vtable = hal.Device.VTable{
        .destroy = destroy,
        .createBuffer = createBuffer,
        .createTexture = createTexture,
        .createSampler = createSampler,
        .createDescriptorSetLayout = createDescriptorSetLayout,
        .createPipelineLayout = createPipelineLayout,
        .createDescriptorSet = createDescriptorSet,
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
        const device = try allocator.create(DX_Device);
        device.* = .{ .allocator = allocator };
        const device_handle = hal.Device{
            .ptr = device,
            .vtable = &vtable,
        };
        const queue_handle = hal.Queue{
            .ptr = &device.queue,
            .vtable = &DX_Queue.vtable,
        };
        return .{ device_handle, queue_handle };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 device", .{});
        typed.allocator.destroy(typed);
    }

    fn createBuffer(ptr: *anyopaque, descriptor: buffer.Buffer.Descriptor) anyerror!hal.Buffer {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.DX_Buffer.init(typed.allocator);
    }

    fn createTexture(ptr: *anyopaque, descriptor: texture.Texture.Descriptor) anyerror!hal.Texture {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.DX_Texture.init(typed.allocator);
    }

    fn createSampler(ptr: *anyopaque, descriptor: sampler.Sampler.Descriptor) anyerror!hal.Sampler {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.DX_Sampler.init(typed.allocator);
    }

    fn createDescriptorSetLayout(ptr: *anyopaque, descriptor: descriptor_set.DescriptorSetLayout.Descriptor) anyerror!hal.DescriptorSetLayout {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.DX_DescriptorSetLayout.init(typed.allocator);
    }

    fn createPipelineLayout(ptr: *anyopaque, descriptor: pipeline.PipelineLayout.Descriptor) anyerror!hal.PipelineLayout {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return pipeline_backend.DX_PipelineLayout.init(typed.allocator);
    }

    fn createDescriptorSet(ptr: *anyopaque, descriptor: descriptor_set.DescriptorSet.Descriptor) anyerror!hal.DescriptorSet {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.DX_DescriptorSet.init(typed.allocator);
    }

    fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return shader_backend.DX_ShaderModule.init(typed.allocator);
    }

    fn createComputePipeline(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return pipeline_backend.DX_ComputePipeline.init(typed.allocator);
    }

    fn createRenderPipeline(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return pipeline_backend.DX_RenderPipeline.init(typed.allocator);
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
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return command_backend.DX_CommandEncoder.init(typed.allocator);
    }

    fn createRenderBundleEncoder(ptr: *anyopaque, descriptor: command.RenderBundleEncoder.Descriptor) anyerror!hal.RenderBundleEncoder {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return command_backend.DX_RenderBundleEncoder.init(typed.allocator);
    }

    fn createQuerySet(ptr: *anyopaque, descriptor: gpu.QuerySet.Descriptor) anyerror!hal.QuerySet {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return resource.DX_QuerySet.init(typed.allocator);
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
        return error.NotImplemented;
    }

    fn pushErrorScope(ptr: *anyopaque, filter: gpu.Device.ErrorFilter) void {
        _ = ptr;
        _ = filter;
    }

    fn getQueue(ptr: *anyopaque) hal.Queue {
        const typed: *DX_Device = @ptrCast(@alignCast(ptr));
        return .{
            .ptr = &typed.queue,
            .vtable = &DX_Queue.vtable,
        };
    }
};

pub const DX_Queue = struct {
    pub const vtable = hal.Queue.VTable{
        .submit = submit,
        .writeBuffer = writeBuffer,
        .writeTexture = writeTexture,
        .onSubmittedWorkDone = onSubmittedWorkDone,
    };

    fn submit(ptr: *anyopaque, command_buffers: []const hal.CommandBuffer) void {
        _ = ptr;
        for (command_buffers) |command_buffer| {
            command_buffer.destroy();
        }
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
    ) anyerror!void {
        _ = ptr;
        _ = destination;
        _ = data;
        _ = data_layout;
        _ = size;
    }

    fn onSubmittedWorkDone(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!void) {
        return io.async(onSubmittedWorkDoneInternal, .{ptr});
    }

    fn onSubmittedWorkDoneInternal(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        return error.NotImplemented;
    }
};
