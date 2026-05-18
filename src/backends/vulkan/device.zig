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

const logz = @import("logz");

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
            logz.info().fmt("msg", "destroying vulkan logical device: handle=0x{x}", .{@intFromEnum(typed.device_handle)}).log();
            _ = typed.device.deviceWaitIdle() catch {};
            typed.queue.cleanupCompleted(true);
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
        logz.info().fmt("msg", "creating vulkan pipeline layout: bind_group_layouts={}", .{descriptor.bindGroupLayouts.len}).log();
        return try pipeline_backend.vkPipelineLayout.init(typed, descriptor);
    }

    fn createBindGroup(ptr: *anyopaque, descriptor: bind_group.BindGroup.Descriptor) anyerror!hal.BindGroup {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkBindGroup.init(typed, descriptor);
    }

    fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "creating vulkan shader module", .{}).log();
        return try vkShaderModule.init(typed, .{
            .source = descriptor.source,
            .label = descriptor.label,
        });
    }

    fn createComputePipeline(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try pipeline_backend.vkComputePipeline.init(typed, descriptor);
    }

    fn createRenderPipeline(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "creating vulkan render pipeline: vertex_buffers={} has_fragment={} has_depth_stencil={}", .{
            descriptor.vertex.buffers.len,
            descriptor.fragment != null,
            descriptor.depthStencil != null,
        }).log();
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
    pending_command_buffers: std.ArrayList(*command_backend.vkCommandBuffer) = .empty,

    pub const vtable = hal.Queue.VTable{
        .submit = submit,
        .writeBuffer = writeBuffer,
        .writeTexture = writeTexture,
        .copyExternalImageToTexture = copyExternalImageToTexture,
        .onSubmittedWorkDone = onSubmittedWorkDone,
    };

    fn submit(ptr: *anyopaque, command_buffers: []const hal.CommandBuffer) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        logz.debug().fmt("msg", "submitting vulkan queue work: command_buffers={}", .{command_buffers.len}).log();
        typed.cleanupCompleted(false);
        for (command_buffers) |command_buffer| {
            const vk_command_buffer: *command_backend.vkCommandBuffer = @ptrCast(@alignCast(command_buffer.ptr));
            if (vk_command_buffer.fence != .null_handle) {
                typed.device.device.resetFences(@as([*]const vk.Fence, @ptrCast(&vk_command_buffer.fence))[0..1]) catch |err| {
                    logz.err().fmt("msg", "failed to reset vulkan fence: {s}", .{@errorName(err)}).log();
                    continue;
                };
            }
            var wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
            const submit_info = vk.SubmitInfo{
                .wait_semaphore_count = if (vk_command_buffer.wait_semaphore != .null_handle) 1 else 0,
                .p_wait_semaphores = if (vk_command_buffer.wait_semaphore != .null_handle) @ptrCast(&vk_command_buffer.wait_semaphore) else null,
                .p_wait_dst_stage_mask = if (vk_command_buffer.wait_semaphore != .null_handle) @ptrCast(&wait_stage) else null,
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&vk_command_buffer.command_buffer),
                .signal_semaphore_count = if (vk_command_buffer.signal_semaphore != .null_handle) 1 else 0,
                .p_signal_semaphores = if (vk_command_buffer.signal_semaphore != .null_handle) @ptrCast(&vk_command_buffer.signal_semaphore) else null,
            };
            typed.device.device.queueSubmit(typed.handle, @as([*]const vk.SubmitInfo, @ptrCast(&submit_info))[0..1], vk_command_buffer.fence) catch |err| {
                logz.err().fmt("msg", "failed to submit vulkan queue work: {s}", .{@errorName(err)}).log();
                vk_command_buffer.deinit();
                continue;
            };
            typed.pending_command_buffers.append(typed.device.adapter.gpu.allocator, vk_command_buffer) catch |err| {
                logz.err().fmt("msg", "failed to track pending vulkan command buffer: {s}", .{@errorName(err)}).log();
                _ = typed.device.device.queueWaitIdle(typed.handle) catch {};
                vk_command_buffer.deinit();
            };
        }
    }

    pub fn cleanupCompleted(self: *@This(), force: bool) void {
        var index: usize = 0;
        while (index < self.pending_command_buffers.items.len) {
            const command_buffer = self.pending_command_buffers.items[index];
            const completed = force or command_buffer.fence == .null_handle or
                ((self.device.device.getFenceStatus(command_buffer.fence) catch .not_ready) == .success);
            if (!completed) {
                index += 1;
                continue;
            }
            _ = self.pending_command_buffers.swapRemove(index);
            command_buffer.deinit();
        }
        if (force) {
            self.pending_command_buffers.deinit(self.device.adapter.gpu.allocator);
            self.pending_command_buffers = .empty;
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
