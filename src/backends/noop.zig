//! No-operation/null backend.
//!
//! This is useful for tests and examples that need object plumbing without a real GPU backend.

const std = @import("std");

const bind_group = @import("../types/bind_group.zig");
const buffer = @import("../types/buffer.zig");
const command = @import("../types/command.zig");
const def = @import("../types/def.zig");
const gpu = @import("../types/gpu.zig");
const hal = @import("hal.zig");
const pipeline = @import("../types/pipeline.zig");
const sampler = @import("../types/sampler.zig");
const shader = @import("../types/shader.zig");
const texture = @import("../types/texture.zig");

var state: u8 = 0;

pub fn init() hal.GPU {
    return .{
        .ptr = &state,
        .vtable = &gpu_vtable,
    };
}

const gpu_vtable = hal.GPU.VTable{
    .requestAdapter = requestAdapter,
};

const adapter_vtable = hal.Adapter.VTable{
    .requestDevice = requestDevice,
};

const device_vtable = hal.Device.VTable{
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

const queue_vtable = hal.Queue.VTable{
    .submit = submit,
    .writeBuffer = writeBuffer,
    .writeTexture = writeTexture,
    .copyExternalImageToTexture = copyExternalImageToTexture,
    .onSubmittedWorkDone = onSubmittedWorkDone,
};

fn requestAdapter(
    ptr: *anyopaque,
    io: std.Io,
    options: gpu.Adapter.RequestOptions,
) std.Io.Future(anyerror!hal.Adapter) {
    return io.async(requestAdapterInternal, .{ ptr, options });
}

fn requestAdapterInternal(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror!hal.Adapter {
    _ = ptr;
    _ = options;
    return .{
        .ptr = &state,
        .vtable = &adapter_vtable,
    };
}

fn requestDevice(
    ptr: *anyopaque,
    io: std.Io,
    options: gpu.Device.Descriptor,
) std.Io.Future(anyerror!hal.Device) {
    return io.async(requestDeviceInternal, .{ ptr, options });
}

fn requestDeviceInternal(ptr: *anyopaque, options: gpu.Device.Descriptor) anyerror!hal.Device {
    _ = ptr;
    _ = options;
    return .{
        .ptr = &state,
        .vtable = &device_vtable,
    };
}

fn destroy(ptr: *anyopaque) void {
    _ = ptr;
}

fn createBuffer(ptr: *anyopaque, descriptor: buffer.Buffer.Descriptor) anyerror!hal.Buffer {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createTexture(ptr: *anyopaque, descriptor: texture.Texture.Descriptor) anyerror!hal.Texture {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createSampler(ptr: *anyopaque, descriptor: sampler.Sampler.Descriptor) anyerror!hal.Sampler {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn importExternalTexture(ptr: *anyopaque, descriptor: texture.ExternalTexture.Descriptor) anyerror!hal.ExternalTexture {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createBindGroupLayout(ptr: *anyopaque, descriptor: bind_group.BindGroupLayout.Descriptor) anyerror!hal.BindGroupLayout {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createPipelineLayout(ptr: *anyopaque, descriptor: pipeline.PipelineLayout.Descriptor) anyerror!hal.PipelineLayout {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createBindGroup(ptr: *anyopaque, descriptor: bind_group.BindGroup.Descriptor) anyerror!hal.BindGroup {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createComputePipeline(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createRenderPipeline(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
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
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createCommandEncoder(ptr: *anyopaque, descriptor: ?command.CommandEncoder.Descriptor) anyerror!hal.CommandEncoder {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createRenderBundleEncoder(ptr: *anyopaque, descriptor: command.RenderBundleEncoder.Descriptor) anyerror!hal.RenderBundleEncoder {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createQuerySet(ptr: *anyopaque, descriptor: gpu.QuerySet.Descriptor) anyerror!hal.QuerySet {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
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
    _ = ptr;
    return .{
        .ptr = &state,
        .vtable = &queue_vtable,
    };
}

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
