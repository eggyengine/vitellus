const std = @import("std");
const vk = @import("vulkan");

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
const adapter_backend = @import("adapter.zig");
const shad = @import("shader.zig");
const vkShaderModule = shad.vkShaderModule;
const command_backend = @import("command.zig");
const pipeline_backend = @import("pipeline.zig");
const resource_backend = @import("resource.zig");

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

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.device_handle != .null_handle) {
            std.log.debug("destroying vulkan logical device: handle=0x{x}", .{@intFromEnum(typed.device_handle)});
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
            std.log.err("failed to track configured vulkan surface: {s}", .{@errorName(err)});
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
            std.log.err("failed to track vulkan device child: {s}", .{@errorName(err)});
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
            std.log.err("failed to track vulkan render pipeline handle: {s}", .{@errorName(err)});
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
            std.log.debug("destroying tracked vulkan render pipeline during device teardown: handle=0x{x}", .{@intFromEnum(handle)});
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

    fn createDescriptorSetLayout(ptr: *anyopaque, descriptor: descriptor_set.DescriptorSetLayout.Descriptor) anyerror!hal.DescriptorSetLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkDescriptorSetLayout.init(typed, descriptor);
    }

    fn createPipelineLayout(ptr: *anyopaque, descriptor: pipeline.PipelineLayout.Descriptor) anyerror!hal.PipelineLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        std.log.debug("creating vulkan pipeline layout: descriptor_set_layouts={}", .{descriptor.descriptorSetLayouts.len});
        return try pipeline_backend.vkPipelineLayout.init(typed, descriptor);
    }

    fn createDescriptorSet(ptr: *anyopaque, descriptor: descriptor_set.DescriptorSet.Descriptor) anyerror!hal.DescriptorSet {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        return try resource_backend.vkDescriptorSet.init(typed, descriptor);
    }

    fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        std.log.debug("creating vulkan shader module", .{});
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
        std.log.debug("creating vulkan render pipeline: vertex_buffers={} has_fragment={} has_depth_stencil={}", .{
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
        .onSubmittedWorkDone = onSubmittedWorkDone,
    };

    fn submit(ptr: *anyopaque, command_buffers: []const hal.CommandBuffer) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        std.log.debug("submitting vulkan queue work: command_buffers={}", .{command_buffers.len});
        typed.cleanupCompleted(false);
        for (command_buffers) |command_buffer| {
            const vk_command_buffer: *command_backend.vkCommandBuffer = @ptrCast(@alignCast(command_buffer.ptr));
            if (vk_command_buffer.fence != .null_handle) {
                typed.device.device.resetFences(@as([*]const vk.Fence, @ptrCast(&vk_command_buffer.fence))[0..1]) catch |err| {
                    std.log.err("failed to reset vulkan fence: {s}", .{@errorName(err)});
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
                std.log.err("failed to submit vulkan queue work: {s}", .{@errorName(err)});
                vk_command_buffer.deinit();
                continue;
            };
            typed.pending_command_buffers.append(typed.device.adapter.gpu.allocator, vk_command_buffer) catch |err| {
                std.log.err("failed to track pending vulkan command buffer: {s}", .{@errorName(err)});
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

    fn copyBufferToImage(
        self: *@This(),
        source: vk.Buffer,
        destination_texture: *resource_backend.vkTexture,
        destination: texture.TexelCopyTextureInfo,
        size: texture.Texture.Extent3D,
        data_layout: texture.TexelCopyBufferLayout,
        bytes_per_texel: u32,
    ) !void {
        if (destination.origin.x + size.width > destination_texture.extent.width or
            destination.origin.y + size.height > destination_texture.extent.height)
        {
            return error.TextureCopyOutOfBounds;
        }

        const is_3d = destination.texture.dimension == .@"3d";
        if (is_3d) {
            if (destination.origin.z + size.depthOrArrayLayers > destination_texture.extent.depth) return error.TextureCopyOutOfBounds;
        } else {
            if (destination.origin.z + size.depthOrArrayLayers > destination_texture.extent.depth) return error.TextureCopyOutOfBounds;
        }

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

        transitionImageLayout(
            self.device,
            command_buffers[0],
            destination_texture.handle,
            destination_texture.layout,
            .transfer_dst_optimal,
            accessMaskForLayout(destination_texture.layout),
            .{ .transfer_write_bit = true },
            stageMaskForLayout(destination_texture.layout),
            .{ .all_transfer_bit = true },
            imageSubresourceRange(destination, size, is_3d),
        );

        const row_length = rowLengthTexels(data_layout, size, bytes_per_texel);
        const image_height = data_layout.rowsPerImage orelse 0;
        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = row_length,
            .buffer_image_height = image_height,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = destination.mipLevel,
                .base_array_layer = if (is_3d) 0 else destination.origin.z,
                .layer_count = if (is_3d) 1 else size.depthOrArrayLayers,
            },
            .image_offset = .{
                .x = @intCast(destination.origin.x),
                .y = @intCast(destination.origin.y),
                .z = if (is_3d) @intCast(destination.origin.z) else 0,
            },
            .image_extent = .{
                .width = size.width,
                .height = size.height,
                .depth = if (is_3d) size.depthOrArrayLayers else 1,
            },
        };
        self.device.device.cmdCopyBufferToImage(command_buffers[0], source, destination_texture.handle, .transfer_dst_optimal, &.{region});

        transitionImageLayout(
            self.device,
            command_buffers[0],
            destination_texture.handle,
            .transfer_dst_optimal,
            .shader_read_only_optimal,
            .{ .transfer_write_bit = true },
            .{ .shader_sampled_read_bit = true },
            .{ .all_transfer_bit = true },
            .{ .fragment_shader_bit = true },
            imageSubresourceRange(destination, size, is_3d),
        );

        try self.device.device.endCommandBuffer(command_buffers[0]);

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffers),
        };
        try self.device.device.queueSubmit(self.handle, @as([*]const vk.SubmitInfo, @ptrCast(&submit_info))[0..1], .null_handle);
        try self.device.device.queueWaitIdle(self.handle);
        destination_texture.layout = .shader_read_only_optimal;
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
            std.log.err("failed to create vulkan staging buffer: {s}", .{@errorName(err)});
            return;
        };

        defer staging.destroy();

        const staging_buffer: *resource_backend.vkBuffer = @ptrCast(@alignCast(staging.ptr));
        staging_buffer.is_staging = true;
        const mapped = typed.device.device.mapMemory(staging_buffer.memory, 0, write_size, .{}) catch |err| {
            std.log.err("failed to map vulkan staging buffer: {s}", .{@errorName(err)});
            return;
        };

        const dst: [*]u8 = @ptrCast(mapped);
        const src = data[@intCast(data_offset)..][0..@intCast(write_size)];
        @memcpy(dst[0..@intCast(write_size)], src);
        typed.device.device.unmapMemory(staging_buffer.memory);

        typed.copyBuffer(staging_buffer.handle, dst_buffer.handle, 0, buffer_offset, write_size) catch |err| {
            std.log.err("failed to copy vulkan staging buffer: {s}", .{@errorName(err)});
        };
    }

    fn writeTexture(
        ptr: *anyopaque,
        destination: texture.TexelCopyTextureInfo,
        data: def.AllowSharedBufferSource,
        data_layout: texture.TexelCopyBufferLayout,
        size: texture.Texture.Extent3D,
    ) anyerror!void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const dst_texture: *resource_backend.vkTexture = @ptrCast(@alignCast((destination.texture.backend orelse return error.InvalidTexture).ptr));

        if (destination.aspect != .all) return error.UnsupportedTextureAspect;
        if (destination.mipLevel != 0) return error.NotImplemented;
        if (size.width == 0 or size.height == 0 or size.depthOrArrayLayers == 0) return;

        const bytes_per_texel = try bytesPerTexel(destination.texture.format);
        const upload_range = try textureUploadRange(data.len, data_layout, size, bytes_per_texel);
        if (upload_range.size == 0) return;

        const staging = try resource_backend.vkBuffer.init(typed.device, .{
            .label = "vitellus texture staging buffer",
            .size = upload_range.size,
            .usage = buffer.Buffer.Usage.COPY_SRC | buffer.Buffer.Usage.MAP_WRITE,
            .mappedAtCreation = false,
        });
        defer staging.destroy();

        const staging_buffer: *resource_backend.vkBuffer = @ptrCast(@alignCast(staging.ptr));
        staging_buffer.is_staging = true;
        const mapped = try typed.device.device.mapMemory(staging_buffer.memory, 0, upload_range.size, .{});
        const dst: [*]u8 = @ptrCast(mapped);
        const src = data[upload_range.offset..][0..@intCast(upload_range.size)];
        @memcpy(dst[0..@intCast(upload_range.size)], src);
        typed.device.device.unmapMemory(staging_buffer.memory);

        try typed.copyBufferToImage(staging_buffer.handle, dst_texture, destination, size, data_layout, bytes_per_texel);
    }

    fn onSubmittedWorkDone(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!void) {
        return io.async(onSubmittedWorkDoneInternal, .{ptr});
    }

    fn onSubmittedWorkDoneInternal(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        return error.NotImplemented;
    }
};

const TextureUploadRange = struct {
    offset: usize,
    size: def.Size64,
};

fn textureUploadRange(
    data_len: usize,
    layout: texture.TexelCopyBufferLayout,
    size: texture.Texture.Extent3D,
    bytes_per_texel: u32,
) !TextureUploadRange {
    const offset: usize = @intCast(layout.offset);
    if (offset > data_len) return error.TextureCopyOutOfBounds;

    const width_bytes = try std.math.mul(def.Size64, size.width, bytes_per_texel);
    const row_pitch: def.Size64 = if (layout.bytesPerRow) |bytes_per_row| bytes_per_row else width_bytes;
    if (row_pitch < width_bytes or row_pitch % bytes_per_texel != 0) return error.InvalidTextureCopyLayout;

    const rows_per_image: def.Size64 = if (layout.rowsPerImage) |rows| rows else size.height;
    if (rows_per_image < size.height) return error.InvalidTextureCopyLayout;

    const image_count = size.depthOrArrayLayers;
    const layer_pitch = try std.math.mul(def.Size64, row_pitch, rows_per_image);
    const previous_layers = try std.math.mul(def.Size64, if (image_count == 0) 0 else image_count - 1, layer_pitch);
    const previous_rows = try std.math.mul(def.Size64, if (size.height == 0) 0 else size.height - 1, row_pitch);
    const upload_size = try std.math.add(def.Size64, try std.math.add(def.Size64, previous_layers, previous_rows), width_bytes);

    const end = try std.math.add(def.Size64, layout.offset, upload_size);
    if (end > data_len) return error.TextureCopyOutOfBounds;

    return .{
        .offset = offset,
        .size = upload_size,
    };
}

fn rowLengthTexels(layout: texture.TexelCopyBufferLayout, size: texture.Texture.Extent3D, bytes_per_texel: u32) u32 {
    const row_pitch = layout.bytesPerRow orelse return 0;
    const tight_pitch = size.width * bytes_per_texel;
    if (row_pitch == tight_pitch) return 0;
    return row_pitch / bytes_per_texel;
}

fn bytesPerTexel(format: texture.Texture.Format) !u32 {
    return switch (format) {
        .r8unorm, .r8snorm, .r8uint, .r8sint => 1,
        .r16unorm,
        .r16snorm,
        .r16uint,
        .r16sint,
        .r16float,
        .rg8unorm,
        .rg8snorm,
        .rg8uint,
        .rg8sint,
        .depth16unorm,
        => 2,
        .r32uint,
        .r32sint,
        .r32float,
        .rg16unorm,
        .rg16snorm,
        .rg16uint,
        .rg16sint,
        .rg16float,
        .rgba8unorm,
        .rgba8unorm_srgb,
        .rgba8snorm,
        .rgba8uint,
        .rgba8sint,
        .bgra8unorm,
        .bgra8unorm_srgb,
        .rgb9e5ufloat,
        .rgb10a2uint,
        .rgb10a2unorm,
        .rg11b10ufloat,
        .depth24plus,
        .depth32float,
        => 4,
        .rg32uint,
        .rg32sint,
        .rg32float,
        .rgba16unorm,
        .rgba16snorm,
        .rgba16uint,
        .rgba16sint,
        .rgba16float,
        .depth24plus_stencil8,
        .depth32float_stencil8,
        => 8,
        .rgba32uint, .rgba32sint, .rgba32float => 16,
        else => error.UnsupportedTextureFormat,
    };
}

fn accessMaskForLayout(layout: vk.ImageLayout) vk.AccessFlags2 {
    return switch (layout) {
        .undefined => .{},
        .transfer_dst_optimal => .{ .transfer_write_bit = true },
        .shader_read_only_optimal => .{ .shader_sampled_read_bit = true },
        else => .{ .memory_read_bit = true, .memory_write_bit = true },
    };
}

fn stageMaskForLayout(layout: vk.ImageLayout) vk.PipelineStageFlags2 {
    return switch (layout) {
        .undefined => .{ .top_of_pipe_bit = true },
        .transfer_dst_optimal => .{ .all_transfer_bit = true },
        .shader_read_only_optimal => .{ .fragment_shader_bit = true },
        else => .{ .all_commands_bit = true },
    };
}

fn imageSubresourceRange(destination: texture.TexelCopyTextureInfo, size: texture.Texture.Extent3D, is_3d: bool) vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = destination.mipLevel,
        .level_count = 1,
        .base_array_layer = if (is_3d) 0 else destination.origin.z,
        .layer_count = if (is_3d) 1 else size.depthOrArrayLayers,
    };
}

fn transitionImageLayout(
    device: *vkDevice,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_access_mask: vk.AccessFlags2,
    dst_access_mask: vk.AccessFlags2,
    src_stage_mask: vk.PipelineStageFlags2,
    dst_stage_mask: vk.PipelineStageFlags2,
    subresource_range: vk.ImageSubresourceRange,
) void {
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = src_stage_mask,
        .src_access_mask = src_access_mask,
        .dst_stage_mask = dst_stage_mask,
        .dst_access_mask = dst_access_mask,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = subresource_range,
    };
    const dependency = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    };
    device.device.cmdPipelineBarrier2(command_buffer, &dependency);
}
