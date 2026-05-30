const std = @import("std");
const vk = @import("vulkan");

const bind_group = @import("../../types/bind_group.zig");
const buffer = @import("../../types/buffer.zig");
const command = @import("../../types/command.zig");
const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const pipeline = @import("../../types/pipeline.zig");
const texture = @import("../../types/texture.zig");
const vkDevice = @import("device.zig").vkDevice;
const pipeline_backend = @import("pipeline.zig");
const resource = @import("resource.zig");
const surface_backend = @import("surface.zig");
const debug = @import("debug.zig");


fn indexFormatToVulkan(format: pipeline.IndexFormat) vk.IndexType {
    return switch (format) {
        .uint16 => .uint16,
        .uint32 => .uint32,
    };
}

pub const vkCommandBuffer = struct {
    device: *vkDevice,
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    wait_semaphore: vk.Semaphore = .null_handle,
    signal_semaphore: vk.Semaphore = .null_handle,
    fence: vk.Fence = .null_handle,
    owns_fence: bool = false,

    pub const vtable = hal.CommandBuffer.VTable{
        .destroy = destroy,
    };

    pub fn deinit(self: *@This()) void {
        std.log.debug("destroying vulkan command buffer", .{});
        if (self.command_pool != .null_handle) {
            self.device.device.destroyCommandPool(self.command_pool, null);
            self.command_pool = .null_handle;
        }
        if (self.owns_fence and self.fence != .null_handle) {
            self.device.device.destroyFence(self.fence, null);
            self.fence = .null_handle;
        }
        self.device.adapter.gpu.allocator.destroy(self);
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.deinit();
    }
};

pub const vkCommandEncoder = struct {
    device: *vkDevice,
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    wait_semaphore: vk.Semaphore = .null_handle,
    signal_semaphore: vk.Semaphore = .null_handle,
    fence: vk.Fence = .null_handle,
    owns_fence: bool = false,
    finished: bool = false,

    pub const vtable = hal.CommandEncoder.VTable{
        .beginRenderPass = beginRenderPass,
        .beginComputePass = beginComputePass,
        .copyBufferToBuffer = copyBufferToBuffer,
        .copyBufferToBufferWithOffsets = copyBufferToBufferWithOffsets,
        .copyBufferToTexture = copyBufferToTexture,
        .copyTextureToBuffer = copyTextureToBuffer,
        .copyTextureToTexture = copyTextureToTexture,
        .clearBuffer = clearBuffer,
        .resolveQuerySet = resolveQuerySet,
        .finish = finish,
        .pushDebugGroup = pushDebugGroup,
        .popDebugGroup = popDebugGroup,
        .insertDebugMarker = insertDebugMarker,
    };

    pub fn init(device: *vkDevice, descriptor: ?command.CommandEncoder.Descriptor) !hal.CommandEncoder {
        const allocator = device.adapter.gpu.allocator;
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = device.graphics_queue_family,
        };
        const command_pool = try device.device.createCommandPool(&pool_info, null);
        errdefer device.device.destroyCommandPool(command_pool, null);

        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        var command_buffers: [1]vk.CommandBuffer = undefined;
        try device.device.allocateCommandBuffers(&alloc_info, &command_buffers);

        const begin_info = vk.CommandBufferBeginInfo{};
        try device.device.beginCommandBuffer(command_buffers[0], &begin_info);

        self.* = .{
            .device = device,
            .command_pool = command_pool,
            .command_buffer = command_buffers[0],
        };
        if (descriptor) |desc| debug.setObjectName(device, .command_pool, command_pool, desc.label);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn beginRenderPass(ptr: *anyopaque, descriptor: command.RenderPassEncoder.Descriptor) anyerror!hal.RenderPassEncoder {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (descriptor.colorAttachments.len == 0 or descriptor.colorAttachments[0] == null) return error.MissingColorAttachment;
        const attachment = descriptor.colorAttachments[0].?;
        const view_backend = switch (attachment.view) {
            .texture_view => |view| view.backend orelse return error.MissingBackendTextureView,
            .texture => |tex| blk: {
                const view = try tex.createView(.{});
                break :blk view.backend orelse return error.MissingBackendTextureView;
            },
        };
        const vk_view: *resource.vkTextureView = @ptrCast(@alignCast(view_backend.ptr));

        if (vk_view.present_surface) |surface_ptr| {
            const surface: *surface_backend.vkSurface = @ptrCast(@alignCast(surface_ptr));
            if (surface.image_available_semaphores) |semaphores| typed.wait_semaphore = semaphores[surface.frame_index];
            if (surface.render_finished_semaphores) |semaphores| typed.signal_semaphore = semaphores[vk_view.present_image_index];
            if (surface.in_flight_fences) |fences| typed.fence = fences[surface.frame_index];
        }

        transitionImageLayout(
            typed.device,
            typed.command_buffer,
            vk_view.image,
            .undefined,
            .color_attachment_optimal,
            .{},
            .{ .color_attachment_write_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_output_bit = true },
        );

        const clear: def.Color = attachment.clearValue orelse .{ .dict = .{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 } };
        const color = switch (clear) {
            .dict => |dict| vk.ClearValue{ .color = .{ .float_32 = .{ @floatCast(dict.r), @floatCast(dict.g), @floatCast(dict.b), @floatCast(dict.a) } } },
            .sequence => |array| vk.ClearValue{ .color = .{ .float_32 = .{ @floatCast(array[0]), @floatCast(array[1]), @floatCast(array[2]), @floatCast(array[3]) } } },
        };
        const rendering_attachment = vk.RenderingAttachmentInfo{
            .image_view = vk_view.handle,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = if (attachment.loadOp == .clear) .clear else .load,
            .store_op = if (attachment.storeOp == .store) .store else .dont_care,
            .clear_value = color,
        };
        const rendering_info = vk.RenderingInfo{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = vk_view.device.adapter.gpu.instance.getPhysicalDeviceProperties(vk_view.device.adapter.pdev).limits.max_framebuffer_width, .height = 1 } },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&rendering_attachment),
        };
        var adjusted = rendering_info;
        if (vk_view.present_surface) |surface_ptr| {
            const surface: *surface_backend.vkSurface = @ptrCast(@alignCast(surface_ptr));
            adjusted.render_area.extent = surface.swapchain_extent;
        }
        typed.device.device.cmdBeginRendering(typed.command_buffer, &adjusted);

        const pass = try typed.device.adapter.gpu.allocator.create(vkRenderPassEncoder);
        pass.* = .{
            .encoder = typed,
            .image = vk_view.image,
            .extent = adjusted.render_area.extent,
        };
        return .{ .ptr = pass, .vtable = &vkRenderPassEncoder.vtable };
    }

    fn beginComputePass(ptr: *anyopaque, descriptor: ?command.ComputePassEncoder.Descriptor) anyerror!hal.ComputePassEncoder {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn copyBufferToBuffer(ptr: *anyopaque, source: hal.Buffer, destination: hal.Buffer, size: ?def.Size64) void {
        copyBufferToBufferWithOffsets(ptr, source, 0, destination, 0, size);
    }

    fn copyBufferToBufferWithOffsets(ptr: *anyopaque, source: hal.Buffer, source_offset: def.Size64, destination: hal.Buffer, destination_offset: def.Size64, size: ?def.Size64) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const source_buffer: *resource.vkBuffer = @ptrCast(@alignCast(source.ptr));
        const destination_buffer: *resource.vkBuffer = @ptrCast(@alignCast(destination.ptr));

        if (source_offset > source_buffer.size or destination_offset > destination_buffer.size) {
            std.log.err("buffer copy offset out of bounds: source_offset={} destination_offset={}", .{ source_offset, destination_offset });
            return;
        }

        const source_available = source_buffer.size - source_offset;
        const destination_available = destination_buffer.size - destination_offset;
        const copy_size = size orelse @min(source_available, destination_available);
        if (copy_size == 0 or copy_size > source_available or copy_size > destination_available) {
            std.log.err("buffer copy size out of bounds: size={?} source_available={} destination_available={}", .{ size, source_available, destination_available });
            return;
        }

        const copy_region = vk.BufferCopy{
            .src_offset = source_offset,
            .dst_offset = destination_offset,
            .size = copy_size,
        };
        typed.device.device.cmdCopyBuffer(
            typed.command_buffer,
            source_buffer.handle,
            destination_buffer.handle,
            @as([*]const vk.BufferCopy, @ptrCast(&copy_region))[0..1],
        );
    }

    fn copyBufferToTexture(ptr: *anyopaque, source: texture.TexelCopyBufferInfo, destination: texture.TexelCopyTextureInfo, copy_size: texture.Texture.Extent3D) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = copy_size;
    }
    fn copyTextureToBuffer(ptr: *anyopaque, source: texture.TexelCopyTextureInfo, destination: texture.TexelCopyBufferInfo, copy_size: texture.Texture.Extent3D) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = copy_size;
    }
    fn copyTextureToTexture(ptr: *anyopaque, source: texture.TexelCopyTextureInfo, destination: texture.TexelCopyTextureInfo, copy_size: texture.Texture.Extent3D) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = copy_size;
    }
    fn clearBuffer(ptr: *anyopaque, target: hal.Buffer, offset: ?def.Size64, size: ?def.Size64) void {
        _ = ptr;
        _ = target;
        _ = offset;
        _ = size;
    }
    fn resolveQuerySet(ptr: *anyopaque, query_set: hal.QuerySet, first_query: def.Size32, query_count: def.Size32, destination: hal.Buffer, destination_offset: def.Size64) void {
        _ = ptr;
        _ = query_set;
        _ = first_query;
        _ = query_count;
        _ = destination;
        _ = destination_offset;
    }

    fn finish(ptr: *anyopaque, descriptor: ?command.CommandBuffer.Descriptor) anyerror!hal.CommandBuffer {
        _ = descriptor;
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (!typed.finished) {
            try typed.device.device.endCommandBuffer(typed.command_buffer);
            typed.finished = true;
        }
        const allocator = typed.device.adapter.gpu.allocator;
        const buffer_value = try allocator.create(vkCommandBuffer);
        errdefer allocator.destroy(buffer_value);

        var fence = typed.fence;
        var owns_fence = typed.owns_fence;
        if (fence == .null_handle) {
            const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
            fence = try typed.device.device.createFence(&fence_info, null);
            owns_fence = true;
            errdefer typed.device.device.destroyFence(fence, null);
        }

        buffer_value.* = .{
            .device = typed.device,
            .command_pool = typed.command_pool,
            .command_buffer = typed.command_buffer,
            .wait_semaphore = typed.wait_semaphore,
            .signal_semaphore = typed.signal_semaphore,
            .fence = fence,
            .owns_fence = owns_fence,
        };
        typed.command_pool = .null_handle;
        typed.device.adapter.gpu.allocator.destroy(typed);
        return .{ .ptr = buffer_value, .vtable = &vkCommandBuffer.vtable };
    }

    fn pushDebugGroup(ptr: *anyopaque, group_label: []const u8) void {
        _ = ptr;
        _ = group_label;
    }
    fn popDebugGroup(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn insertDebugMarker(ptr: *anyopaque, marker_label: []const u8) void {
        _ = ptr;
        _ = marker_label;
    }
};

fn transitionImageLayout(device: *vkDevice, command_buffer: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout, src_access_mask: vk.AccessFlags2, dst_access_mask: vk.AccessFlags2, src_stage_mask: vk.PipelineStageFlags2, dst_stage_mask: vk.PipelineStageFlags2) void {
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
        .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    };
    const dependency = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    };
    device.device.cmdPipelineBarrier2(command_buffer, &dependency);
}

pub const vkComputePassEncoder = struct {
    pub const vtable = hal.ComputePassEncoder.VTable{
        .setPipeline = setPipeline,
        .dispatchWorkgroups = dispatchWorkgroups,
        .dispatchWorkgroupsIndirect = dispatchWorkgroupsIndirect,
        .end = end,
        .setBindGroup = setBindGroup,
        .setBindGroupFromData = setBindGroupFromData,
        .pushDebugGroup = pushDebugGroup,
        .popDebugGroup = popDebugGroup,
        .insertDebugMarker = insertDebugMarker,
    };
    fn setPipeline(ptr: *anyopaque, target: hal.ComputePipeline) void {
        _ = ptr;
        _ = target;
    }
    fn dispatchWorkgroups(ptr: *anyopaque, x: def.Size32, y: def.Size32, z: def.Size32) void {
        _ = ptr;
        _ = x;
        _ = y;
        _ = z;
    }
    fn dispatchWorkgroupsIndirect(ptr: *anyopaque, indirect_buffer: hal.Buffer, indirect_offset: def.Size64) void {
        _ = ptr;
        _ = indirect_buffer;
        _ = indirect_offset;
    }
    fn end(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn setBindGroup(ptr: *anyopaque, index: def.Index32, group: ?hal.BindGroup, dynamic_offsets: []const def.BufferDynamicOffset) void {
        _ = ptr;
        _ = index;
        _ = group;
        _ = dynamic_offsets;
    }
    fn setBindGroupFromData(ptr: *anyopaque, index: def.Index32, group: ?hal.BindGroup, dynamic_offsets_data: []const u32, dynamic_offsets_data_start: def.Size64, dynamic_offsets_data_length: def.Size32) void {
        _ = ptr;
        _ = index;
        _ = group;
        _ = dynamic_offsets_data;
        _ = dynamic_offsets_data_start;
        _ = dynamic_offsets_data_length;
    }
    fn pushDebugGroup(ptr: *anyopaque, group_label: []const u8) void {
        _ = ptr;
        _ = group_label;
    }
    fn popDebugGroup(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn insertDebugMarker(ptr: *anyopaque, marker_label: []const u8) void {
        _ = ptr;
        _ = marker_label;
    }
};

pub const vkRenderPassEncoder = struct {
    encoder: *vkCommandEncoder,
    image: vk.Image,
    extent: vk.Extent2D,
    pipeline_layout: vk.PipelineLayout = .null_handle,

    pub const vtable = hal.RenderPassEncoder.VTable{
        .setViewport = setViewport,
        .setScissorRect = setScissorRect,
        .setBlendConstant = setBlendConstant,
        .setStencilReference = setStencilReference,
        .beginOcclusionQuery = beginOcclusionQuery,
        .endOcclusionQuery = endOcclusionQuery,
        .executeBundles = executeBundles,
        .end = end,
        .setPipeline = setPipeline,
        .setIndexBuffer = setIndexBuffer,
        .setVertexBuffer = setVertexBuffer,
        .draw = draw,
        .drawIndexed = drawIndexed,
        .drawIndirect = drawIndirect,
        .drawIndexedIndirect = drawIndexedIndirect,
        .setBindGroup = setBindGroup,
        .setBindGroupFromData = setBindGroupFromData,
        .pushDebugGroup = pushDebugGroup,
        .popDebugGroup = popDebugGroup,
        .insertDebugMarker = insertDebugMarker,
    };

    fn setViewport(ptr: *anyopaque, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const viewport = vk.Viewport{ .x = x, .y = y, .width = width, .height = height, .min_depth = min_depth, .max_depth = max_depth };
        typed.encoder.device.device.cmdSetViewport(typed.encoder.command_buffer, 0, @as([*]const vk.Viewport, @ptrCast(&viewport))[0..1]);
    }
    fn setScissorRect(ptr: *anyopaque, x: def.IntegerCoordinate, y: def.IntegerCoordinate, width: def.IntegerCoordinate, height: def.IntegerCoordinate) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const rect = vk.Rect2D{ .offset = .{ .x = @intCast(x), .y = @intCast(y) }, .extent = .{ .width = @intCast(width), .height = @intCast(height) } };
        typed.encoder.device.device.cmdSetScissor(typed.encoder.command_buffer, 0, @as([*]const vk.Rect2D, @ptrCast(&rect))[0..1]);
    }
    fn setBlendConstant(ptr: *anyopaque, color: def.Color) void {
        _ = ptr;
        _ = color;
    }
    fn setStencilReference(ptr: *anyopaque, reference: def.StencilValue) void {
        _ = ptr;
        _ = reference;
    }
    fn beginOcclusionQuery(ptr: *anyopaque, query_index: def.Size32) void {
        _ = ptr;
        _ = query_index;
    }
    fn endOcclusionQuery(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn executeBundles(ptr: *anyopaque, bundles: []const hal.RenderBundle) void {
        _ = ptr;
        _ = bundles;
    }
    fn end(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.encoder.device.device.cmdEndRendering(typed.encoder.command_buffer);
        transitionImageLayout(typed.encoder.device, typed.encoder.command_buffer, typed.image, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_write_bit = true }, .{}, .{ .color_attachment_output_bit = true }, .{ .bottom_of_pipe_bit = true });
        typed.encoder.device.adapter.gpu.allocator.destroy(typed);
    }
    fn setPipeline(ptr: *anyopaque, target: hal.RenderPipeline) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const vk_pipeline: *pipeline_backend.vkRenderPipeline = @ptrCast(@alignCast(target.ptr));
        typed.encoder.device.device.cmdBindPipeline(typed.encoder.command_buffer, .graphics, vk_pipeline.handle);
        typed.pipeline_layout = vk_pipeline.layout.handle;

        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(typed.extent.width),
            .height = @floatFromInt(typed.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        typed.encoder.device.device.cmdSetViewport(typed.encoder.command_buffer, 0, @as([*]const vk.Viewport, @ptrCast(&viewport))[0..1]);

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = typed.extent,
        };
        typed.encoder.device.device.cmdSetScissor(typed.encoder.command_buffer, 0, @as([*]const vk.Rect2D, @ptrCast(&scissor))[0..1]);
    }
    fn setIndexBuffer(ptr: *anyopaque, target: hal.Buffer, index_format: pipeline.IndexFormat, offset: def.Size64, size: ?def.Size64) void {
        _ = size;
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const vk_buffer: *resource.vkBuffer = @ptrCast(@alignCast(target.ptr));
        typed.encoder.device.device.cmdBindIndexBuffer(typed.encoder.command_buffer, vk_buffer.handle, offset, indexFormatToVulkan(index_format));
    }
    fn setVertexBuffer(ptr: *anyopaque, slot: def.Index32, target: ?hal.Buffer, offset: def.Size64, size: ?def.Size64) void {
        _ = size;
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const target_buffer = target orelse return;
        const vk_buffer: *resource.vkBuffer = @ptrCast(@alignCast(target_buffer.ptr));
        var handle = vk_buffer.handle;
        var resolved_offset = offset;
        typed.encoder.device.device.cmdBindVertexBuffers(typed.encoder.command_buffer, slot, @as([*]const vk.Buffer, @ptrCast(&handle))[0..1], @as([*]const vk.DeviceSize, @ptrCast(&resolved_offset))[0..1]);
    }
    fn draw(ptr: *anyopaque, vertex_count: def.Size32, instance_count: def.Size32, first_vertex: def.Size32, first_instance: def.Size32) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.encoder.device.device.cmdDraw(typed.encoder.command_buffer, vertex_count, instance_count, first_vertex, first_instance);
    }
    fn drawIndexed(ptr: *anyopaque, index_count: def.Size32, instance_count: def.Size32, first_index: def.Size32, base_vertex: def.SignedOffset32, first_instance: def.Size32) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.encoder.device.device.cmdDrawIndexed(typed.encoder.command_buffer, index_count, instance_count, first_index, base_vertex, first_instance);
    }
    fn drawIndirect(ptr: *anyopaque, indirect_buffer: hal.Buffer, indirect_offset: def.Size64) void {
        _ = ptr;
        _ = indirect_buffer;
        _ = indirect_offset;
    }
    fn drawIndexedIndirect(ptr: *anyopaque, indirect_buffer: hal.Buffer, indirect_offset: def.Size64) void {
        _ = ptr;
        _ = indirect_buffer;
        _ = indirect_offset;
    }
    fn setBindGroup(ptr: *anyopaque, index: def.Index32, group: ?hal.BindGroup, dynamic_offsets: []const def.BufferDynamicOffset) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const target = group orelse return;
        if (typed.pipeline_layout == .null_handle) {
            std.log.err("cannot bind vulkan bind group before a render pipeline is bound", .{});
            return;
        }
        const vk_group: *resource.vkBindGroup = @ptrCast(@alignCast(target.ptr));
        var descriptor_set = vk_group.descriptor_set;
        typed.encoder.device.device.cmdBindDescriptorSets(
            typed.encoder.command_buffer,
            .graphics,
            typed.pipeline_layout,
            index,
            @as([*]const vk.DescriptorSet, @ptrCast(&descriptor_set))[0..1],
            if (dynamic_offsets.len == 0) null else dynamic_offsets,
        );
    }
    fn setBindGroupFromData(ptr: *anyopaque, index: def.Index32, group: ?hal.BindGroup, dynamic_offsets_data: []const u32, dynamic_offsets_data_start: def.Size64, dynamic_offsets_data_length: def.Size32) void {
        const offsets_end = dynamic_offsets_data_start + dynamic_offsets_data_length;
        if (dynamic_offsets_data_start > dynamic_offsets_data.len or offsets_end > dynamic_offsets_data.len) {
            std.log.err("bind group dynamic offsets range is out of bounds: start={} length={} available={}", .{ dynamic_offsets_data_start, dynamic_offsets_data_length, dynamic_offsets_data.len });
            return;
        }
        setBindGroup(ptr, index, group, dynamic_offsets_data[dynamic_offsets_data_start..offsets_end]);
    }
    fn pushDebugGroup(ptr: *anyopaque, group_label: []const u8) void {
        _ = ptr;
        _ = group_label;
    }
    fn popDebugGroup(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn insertDebugMarker(ptr: *anyopaque, marker_label: []const u8) void {
        _ = ptr;
        _ = marker_label;
    }
};

pub const vkRenderBundle = struct {
    pub const vtable = hal.RenderBundle.VTable{ .destroy = destroy };
    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        std.log.debug("destroying vulkan render bundle", .{});
    }
};

pub const vkRenderBundleEncoder = struct {
    pub const vtable = hal.RenderBundleEncoder.VTable{ .finish = finish, .setPipeline = setPipeline, .setIndexBuffer = setIndexBuffer, .setVertexBuffer = setVertexBuffer, .draw = draw, .drawIndexed = drawIndexed, .drawIndirect = drawIndirect, .drawIndexedIndirect = drawIndexedIndirect, .setBindGroup = setBindGroup, .setBindGroupFromData = setBindGroupFromData, .pushDebugGroup = pushDebugGroup, .popDebugGroup = popDebugGroup, .insertDebugMarker = insertDebugMarker };
    pub fn init(device: *vkDevice, descriptor: command.RenderBundleEncoder.Descriptor) !hal.RenderBundleEncoder {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }
    fn finish(ptr: *anyopaque, descriptor: ?command.RenderBundle.Descriptor) anyerror!hal.RenderBundle {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }
    fn setPipeline(ptr: *anyopaque, target: hal.RenderPipeline) void {
        _ = ptr;
        _ = target;
    }
    fn setIndexBuffer(ptr: *anyopaque, target: hal.Buffer, index_format: pipeline.IndexFormat, offset: def.Size64, size: ?def.Size64) void {
        _ = ptr;
        _ = target;
        _ = index_format;
        _ = offset;
        _ = size;
    }
    fn setVertexBuffer(ptr: *anyopaque, slot: def.Index32, target: ?hal.Buffer, offset: def.Size64, size: ?def.Size64) void {
        _ = ptr;
        _ = slot;
        _ = target;
        _ = offset;
        _ = size;
    }
    fn draw(ptr: *anyopaque, vertex_count: def.Size32, instance_count: def.Size32, first_vertex: def.Size32, first_instance: def.Size32) void {
        _ = ptr;
        _ = vertex_count;
        _ = instance_count;
        _ = first_vertex;
        _ = first_instance;
    }
    fn drawIndexed(ptr: *anyopaque, index_count: def.Size32, instance_count: def.Size32, first_index: def.Size32, base_vertex: def.SignedOffset32, first_instance: def.Size32) void {
        _ = ptr;
        _ = index_count;
        _ = instance_count;
        _ = first_index;
        _ = base_vertex;
        _ = first_instance;
    }
    fn drawIndirect(ptr: *anyopaque, indirect_buffer: hal.Buffer, indirect_offset: def.Size64) void {
        _ = ptr;
        _ = indirect_buffer;
        _ = indirect_offset;
    }
    fn drawIndexedIndirect(ptr: *anyopaque, indirect_buffer: hal.Buffer, indirect_offset: def.Size64) void {
        _ = ptr;
        _ = indirect_buffer;
        _ = indirect_offset;
    }
    fn setBindGroup(ptr: *anyopaque, index: def.Index32, group: ?hal.BindGroup, dynamic_offsets: []const def.BufferDynamicOffset) void {
        _ = ptr;
        _ = index;
        _ = group;
        _ = dynamic_offsets;
    }
    fn setBindGroupFromData(ptr: *anyopaque, index: def.Index32, group: ?hal.BindGroup, dynamic_offsets_data: []const u32, dynamic_offsets_data_start: def.Size64, dynamic_offsets_data_length: def.Size32) void {
        _ = ptr;
        _ = index;
        _ = group;
        _ = dynamic_offsets_data;
        _ = dynamic_offsets_data_start;
        _ = dynamic_offsets_data_length;
    }
    fn pushDebugGroup(ptr: *anyopaque, group_label: []const u8) void {
        _ = ptr;
        _ = group_label;
    }
    fn popDebugGroup(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn insertDebugMarker(ptr: *anyopaque, marker_label: []const u8) void {
        _ = ptr;
        _ = marker_label;
    }
};
