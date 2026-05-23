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
    configured_surfaces: std.ArrayList(ConfiguredSurface) = .empty,
    device_children: std.ArrayList(DeviceChild) = .empty,
    render_pipeline_handles: std.ArrayList(vk.Pipeline) = .empty,

    pub const ConfiguredSurface = struct {
        ptr: *anyopaque,
        unconfigure: *const fn (*anyopaque) void,
    };

    pub const DeviceChild = struct {
        ptr: *anyopaque,
        destroy: *const fn (*anyopaque) void,
    };

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
            typed.unconfigureSurfaces();
            typed.queue.cleanupCompleted(true);
            typed.destroyDeviceChildren();
            typed.destroyRemainingRenderPipelines();
            typed.device.destroyDevice(null);
            typed.device_handle = .null_handle;
        }
        typed.configured_surfaces.deinit(typed.adapter.gpu.allocator);
        typed.device_children.deinit(typed.adapter.gpu.allocator);
        typed.render_pipeline_handles.deinit(typed.adapter.gpu.allocator);
        typed.adapter.gpu.allocator.destroy(typed);
    }

    pub fn registerConfiguredSurface(self: *@This(), ptr: *anyopaque, unconfigure: *const fn (*anyopaque) void) void {
        for (self.configured_surfaces.items) |surface| {
            if (surface.ptr == ptr) return;
        }
        self.configured_surfaces.append(self.adapter.gpu.allocator, .{
            .ptr = ptr,
            .unconfigure = unconfigure,
        }) catch |err| {
            logz.err().fmt("msg", "failed to track configured vulkan surface: {s}", .{@errorName(err)}).log();
        };
    }

    pub fn unregisterConfiguredSurface(self: *@This(), ptr: *anyopaque) void {
        var index: usize = 0;
        while (index < self.configured_surfaces.items.len) : (index += 1) {
            if (self.configured_surfaces.items[index].ptr == ptr) {
                _ = self.configured_surfaces.swapRemove(index);
                return;
            }
        }
    }

    fn unconfigureSurfaces(self: *@This()) void {
        while (self.configured_surfaces.items.len > 0) {
            const surface = self.configured_surfaces.pop().?;
            surface.unconfigure(surface.ptr);
        }
    }

    pub fn registerDeviceChild(self: *@This(), ptr: *anyopaque, destroy_child: *const fn (*anyopaque) void) void {
        for (self.device_children.items) |child| {
            if (child.ptr == ptr) return;
        }
        self.device_children.append(self.adapter.gpu.allocator, .{
            .ptr = ptr,
            .destroy = destroy_child,
        }) catch |err| {
            logz.err().fmt("msg", "failed to track vulkan device child: {s}", .{@errorName(err)}).log();
        };
    }

    pub fn unregisterDeviceChild(self: *@This(), ptr: *anyopaque) void {
        var index: usize = 0;
        while (index < self.device_children.items.len) : (index += 1) {
            if (self.device_children.items[index].ptr == ptr) {
                _ = self.device_children.swapRemove(index);
                return;
            }
        }
    }

    fn destroyDeviceChildren(self: *@This()) void {
        while (self.device_children.items.len > 0) {
            const child = self.device_children.pop().?;
            child.destroy(child.ptr);
        }
    }

    pub fn registerRenderPipelineHandle(self: *@This(), handle: vk.Pipeline) void {
        if (handle == .null_handle) return;
        for (self.render_pipeline_handles.items) |existing| {
            if (existing == handle) return;
        }
        self.render_pipeline_handles.append(self.adapter.gpu.allocator, handle) catch |err| {
            logz.err().fmt("msg", "failed to track vulkan render pipeline handle: {s}", .{@errorName(err)}).log();
        };
    }

    pub fn unregisterRenderPipelineHandle(self: *@This(), handle: vk.Pipeline) void {
        if (handle == .null_handle) return;
        var index: usize = 0;
        while (index < self.render_pipeline_handles.items.len) : (index += 1) {
            if (self.render_pipeline_handles.items[index] == handle) {
                _ = self.render_pipeline_handles.swapRemove(index);
                return;
            }
        }
    }

    fn destroyRemainingRenderPipelines(self: *@This()) void {
        while (self.render_pipeline_handles.items.len > 0) {
            const handle = self.render_pipeline_handles.pop().?;
            if (handle == .null_handle) continue;
            logz.info().fmt("msg", "destroying tracked vulkan render pipeline during device teardown: handle=0x{x}", .{@intFromEnum(handle)}).log();
            self.device.destroyPipeline(handle, null);
        }
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
        return error.NotImplemented;
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

    fn copyBuffer(
        self: *@This(),
        source: vk.Buffer,
        destination: vk.Buffer,
        source_offset: def.Size64,
        destination_offset: def.Size64,
        size: def.Size64,
    ) !void {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .transient_bit = true },
            .queue_family_index = self.device.graphics_queue_family,
        };
        const command_pool = try self.device.device.createCommandPool(&pool_info, null);
        defer self.device.device.destroyCommandPool(command_pool, null);

        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        var command_buffers: [1]vk.CommandBuffer = undefined;
        try self.device.device.allocateCommandBuffers(&alloc_info, &command_buffers);

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };
        try self.device.device.beginCommandBuffer(command_buffers[0], &begin_info);

        const copy_region = vk.BufferCopy{
            .src_offset = source_offset,
            .dst_offset = destination_offset,
            .size = size,
        };
        self.device.device.cmdCopyBuffer(command_buffers[0], source, destination, @as([*]const vk.BufferCopy, @ptrCast(&copy_region))[0..1]);
        try self.device.device.endCommandBuffer(command_buffers[0]);

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffers),
        };
        try self.device.device.queueSubmit(self.handle, @as([*]const vk.SubmitInfo, @ptrCast(&submit_info))[0..1], .null_handle);
        try self.device.device.queueWaitIdle(self.handle);
    }

    fn writeBuffer(
        ptr: *anyopaque,
        target: hal.Buffer,
        buffer_offset: def.Size64,
        data: def.AllowSharedBufferSource,
        data_offset: def.Size64,
        size: ?def.Size64,
    ) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const dst_buffer: *resource_backend.vkBuffer = @ptrCast(@alignCast(target.ptr));
        if (data_offset > data.len) return;
        const available = data.len - @as(usize, @intCast(data_offset));
        const write_size = size orelse available;
        if (write_size > available) return;
        if (buffer_offset > dst_buffer.size or write_size > dst_buffer.size - buffer_offset) return;

        const staging = resource_backend.vkBuffer.init(typed.device, .{
            .label = "vitellus staging buffer",
            .size = write_size,
            .usage = buffer.Buffer.Usage.COPY_SRC | buffer.Buffer.Usage.MAP_WRITE,
            .mappedAtCreation = false,
        }) catch |err| {
            logz.err().fmt("msg", "failed to create vulkan staging buffer: {s}", .{@errorName(err)}).log();
            return;
        };
        defer staging.destroy();

        const staging_buffer: *resource_backend.vkBuffer = @ptrCast(@alignCast(staging.ptr));
        const mapped = typed.device.device.mapMemory(staging_buffer.memory, 0, write_size, .{}) catch |err| {
            logz.err().fmt("msg", "failed to map vulkan staging buffer: {s}", .{@errorName(err)}).log();
            return;
        };

        const dst: [*]u8 = @ptrCast(mapped);
        const src = data[@intCast(data_offset)..][0..@intCast(write_size)];
        @memcpy(dst[0..@intCast(write_size)], src);
        typed.device.device.unmapMemory(staging_buffer.memory);

        typed.copyBuffer(staging_buffer.handle, dst_buffer.handle, 0, buffer_offset, write_size) catch |err| {
            logz.err().fmt("msg", "failed to copy vulkan staging buffer: {s}", .{@errorName(err)}).log();
        };
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
        return error.NotImplemented;
    }
};
