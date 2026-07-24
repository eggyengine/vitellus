const std = @import("std");
const vk = @import("vulkan");
const command = @import("../../interface/command.zig");
const resource = @import("resource.zig");
const pipeline = @import("pipeline.zig");
const binding = @import("binding.zig");
const vkDevice = @import("device.zig").vkDevice;

pub const vkCommandPool = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.CommandPool,
    family: u32,
    live: usize = 0,
    fn fromHandle(value: command.CommandPool) !*vkCommandPool {
        if (value.handle == 0) return error.InvalidCommandPool;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};
pub const vkCommandBuffer = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.CommandBuffer,
    pool: *vkCommandPool,
    graphics_layout: vk.PipelineLayout = .null_handle,
    compute_layout: vk.PipelineLayout = .null_handle,
    rendering: bool = false,
    finished: bool = false,
    debug_utils: bool = false,
    pub fn fromInterface(value: command.CommandBuffer) *vkCommandBuffer {
        return @ptrCast(@alignCast(value.ptr));
    }
};
pub const vkQuerySet = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.QueryPool,
    kind: command.QueryType,
    count: u32,
    fn fromHandle(value: command.QuerySet) !*vkQuerySet {
        if (value.handle == 0) return error.InvalidQuerySet;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const pool_vtable: command.CommandPool.VTable = .{ .deinitFn = destroyPool, .resetFn = resetPool, .createCommandBufferFn = createBuffer };
const query_vtable: command.QuerySet.VTable = .{ .deinitFn = destroyQuerySet };
const buffer_vtable: command.CommandBuffer.VTable = .{
    .deinitFn = destroyBuffer,
    .beginRenderPassFn = beginRenderPass,
    .setGraphicsPipelineFn = setGraphicsPipeline,
    .beginComputePassFn = beginComputePass,
    .setComputePipelineFn = setComputePipeline,
    .setVertexBufferFn = setVertexBuffer,
    .setVertexBuffersFn = setVertexBuffers,
    .setIndexBufferFn = setIndexBuffer,
    .setBindGroupFn = setBindGroup,
    .setViewportFn = setViewport,
    .setViewportsFn = setViewports,
    .setScissorFn = setScissor,
    .setScissorsFn = setScissors,
    .setBlendConstantFn = setBlendConstant,
    .setStencilReferenceFn = setStencilReference,
    .drawFn = draw,
    .drawIndexedFn = drawIndexed,
    .drawIndirectFn = drawIndirect,
    .drawIndexedIndirectFn = drawIndexedIndirect,
    .drawIndirectMultiFn = drawIndirectMulti,
    .drawIndexedIndirectMultiFn = drawIndexedIndirectMulti,
    .drawIndirectCountFn = drawIndirectCount,
    .drawIndexedIndirectCountFn = drawIndexedIndirectCount,
    .dispatchFn = dispatch,
    .dispatchIndirectFn = dispatchIndirect,
    .endComputePassFn = endComputePass,
    .endRenderPassFn = endRenderPass,
    .barrierFn = barrier,
    .copyBufferFn = copyBuffer,
    .copyTextureFn = copyTexture,
    .copyBufferToTextureFn = copyBufferToTexture,
    .copyTextureToBufferFn = copyTextureToBuffer,
    .resolveTextureFn = resolveTexture,
    .resetQueriesFn = resetQueries,
    .beginQueryFn = beginQuery,
    .endQueryFn = endQuery,
    .writeTimestampFn = writeTimestamp,
    .resolveQueriesFn = resolveQueries,
    .beginDebugGroupFn = beginDebugGroup,
    .endDebugGroupFn = endDebugGroup,
    .insertDebugMarkerFn = insertDebugMarker,
    .finishFn = finish,
};

pub fn createPool(ptr: *anyopaque, desc: command.CommandPoolDescriptor) !command.CommandPool {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const family = switch (desc.kind) {
        .graphics => device.queues.graphics_family,
        .compute => device.queues.compute_family orelse return error.QueueKindUnsupported,
        .copy => device.queues.copy_family,
    };
    const handle = try device.proxy.createCommandPool(&.{ .flags = .{ .transient_bit = desc.transient, .reset_command_buffer_bit = desc.reset_individually }, .queue_family_index = family }, null);
    errdefer device.proxy.destroyCommandPool(handle, null);
    const self = try device.allocator.create(vkCommandPool);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = handle, .family = family };
    device.instance.nameObject(device.allocator, device.proxy, .command_pool, @intFromEnum(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &pool_vtable };
}
fn destroyPool(value: command.CommandPool) void {
    const self = vkCommandPool.fromHandle(value) catch return;
    const a = self.allocator;
    self.device.destroyCommandPool(self.handle, null);
    a.destroy(self);
}
fn resetPool(value: command.CommandPool) !void {
    const self = try vkCommandPool.fromHandle(value);
    if (self.live != 0) return error.CommandBuffersStillAlive;
    try self.device.resetCommandPool(self.handle, .{});
}
fn createBuffer(value: command.CommandPool, _: command.CommandBufferDescriptor) !command.CommandBuffer {
    const pool = try vkCommandPool.fromHandle(value);
    var handle: vk.CommandBuffer = undefined;
    try pool.device.allocateCommandBuffers(&.{ .command_pool = pool.handle, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&handle));
    errdefer pool.device.freeCommandBuffers(pool.handle, @as([]const vk.CommandBuffer, (&handle)[0..1]));
    try pool.device.beginCommandBuffer(handle, &.{ .flags = .{ .one_time_submit_bit = true } });
    const self = try pool.allocator.create(vkCommandBuffer);
    self.* = .{ .allocator = pool.allocator, .device = pool.device, .handle = handle, .pool = pool, .debug_utils = pool.device.wrapper.dispatch.vkCmdBeginDebugUtilsLabelEXT != null };
    pool.live += 1;
    return .{ .ptr = self, .vtable = &buffer_vtable };
}
fn destroyBuffer(ptr: *anyopaque) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    self.device.freeCommandBuffers(self.pool.handle, @as([]const vk.CommandBuffer, (&self.handle)[0..1]));
    self.pool.live -= 1;
    self.allocator.destroy(self);
}

pub fn createQuerySet(ptr: *anyopaque, desc: command.QuerySetDescriptor) !command.QuerySet {
    if (desc.count == 0) return error.InvalidQueryCount;
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const handle = try device.proxy.createQueryPool(&.{ .query_type = if (desc.kind == .occlusion) .occlusion else .timestamp, .query_count = desc.count }, null);
    errdefer device.proxy.destroyQueryPool(handle, null);
    const self = try device.allocator.create(vkQuerySet);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = handle, .kind = desc.kind, .count = desc.count };
    device.instance.nameObject(device.allocator, device.proxy, .query_pool, @intFromEnum(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &query_vtable };
}
fn destroyQuerySet(value: command.QuerySet) void {
    const self = vkQuerySet.fromHandle(value) catch return;
    const a = self.allocator;
    self.device.destroyQueryPool(self.handle, null);
    a.destroy(self);
}

fn beginRenderPass(ptr: *anyopaque, desc: command.RenderPassDescriptor) !void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.rendering) return error.RenderPassAlreadyActive;
    const colors = try self.allocator.alloc(vk.RenderingAttachmentInfo, desc.color_attachments.len);
    defer self.allocator.free(colors);
    for (desc.color_attachments, colors) |attachment, *out| {
        const view = try resource.vkTextureView.fromHandle(attachment.view);
        out.* = .{ .image_view = view.view, .image_layout = .color_attachment_optimal, .resolve_mode = if (attachment.resolve_target != null) .{ .average_bit = true } else .{}, .resolve_image_view = if (attachment.resolve_target) |v| (try resource.vkTextureView.fromHandle(v)).view else .null_handle, .resolve_image_layout = .color_attachment_optimal, .load_op = loadOp(attachment.load_op), .store_op = storeOp(attachment.store_op), .clear_value = .{ .color = .{ .float_32 = .{ attachment.clear_value.r, attachment.clear_value.g, attachment.clear_value.b, attachment.clear_value.a } } } };
    }
    var depth: vk.RenderingAttachmentInfo = undefined;
    var stencil: vk.RenderingAttachmentInfo = undefined;
    const depth_ptr: ?*const vk.RenderingAttachmentInfo = if (desc.depth_stencil_attachment) |attachment| blk: {
        const view = try resource.vkTextureView.fromHandle(attachment.view);
        depth = .{ .image_view = view.view, .image_layout = if (attachment.depth_read_only) .depth_stencil_read_only_optimal else .depth_stencil_attachment_optimal, .resolve_mode = .{}, .resolve_image_view = .null_handle, .resolve_image_layout = .undefined, .load_op = loadOp(attachment.depth_load_op), .store_op = storeOp(attachment.depth_store_op), .clear_value = .{ .depth_stencil = .{ .depth = attachment.depth_clear, .stencil = attachment.stencil_clear } } };
        stencil = depth;
        break :blk &depth;
    } else null;
    const render_extent = if (colors.len > 0) (try resource.vkTextureView.fromHandle(desc.color_attachments[0].view)).extent else (try resource.vkTextureView.fromHandle(desc.depth_stencil_attachment.?.view)).extent;
    self.device.cmdBeginRendering(self.handle, &.{ .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = render_extent }, .layer_count = 1, .view_mask = 0, .color_attachment_count = @intCast(colors.len), .p_color_attachments = if (colors.len == 0) null else colors.ptr, .p_depth_attachment = depth_ptr, .p_stencil_attachment = if (depth_ptr != null) &stencil else null });
    self.rendering = true;
    self.device.cmdSetViewport(self.handle, 0, &.{vkViewport(.{ .width = @floatFromInt(render_extent.width), .height = @floatFromInt(render_extent.height) })});
    self.device.cmdSetScissor(self.handle, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = render_extent }});
}
fn setGraphicsPipeline(ptr: *anyopaque, value: @import("../../interface/pipeline.zig").GraphicsPipeline) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const p = pipeline.vkGraphicsPipeline.fromHandle(value) catch return;
    self.graphics_layout = p.layout;
    self.device.cmdBindPipeline(self.handle, .graphics, p.handle);
}
fn beginComputePass(_: *anyopaque, _: ?[]const u8) !void {}
fn setComputePipeline(ptr: *anyopaque, value: @import("../../interface/pipeline.zig").ComputePipeline) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const p = pipeline.vkComputePipeline.fromHandle(value) catch return;
    self.compute_layout = p.layout;
    self.device.cmdBindPipeline(self.handle, .compute, p.handle);
}
fn setVertexBuffer(ptr: *anyopaque, slot: u32, value: @import("../../interface/resource.zig").Buffer, offset: u64) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const b = resource.vkBuffer.fromHandle(value) catch return;
    self.device.cmdBindVertexBuffers(self.handle, slot, &.{b.buffer}, &.{offset});
}
fn setVertexBuffers(ptr: *anyopaque, first: u32, values: []const command.VertexBufferBinding) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    var buffers: [32]vk.Buffer = undefined;
    var offsets: [32]vk.DeviceSize = undefined;
    if (values.len > 32) return;
    for (values, 0..) |v, i| {
        buffers[i] = (resource.vkBuffer.fromHandle(v.buffer) catch return).buffer;
        offsets[i] = v.offset;
    }
    self.device.cmdBindVertexBuffers(self.handle, first, buffers[0..values.len], offsets[0..values.len]);
}
fn setIndexBuffer(ptr: *anyopaque, value: @import("../../interface/resource.zig").Buffer, format: command.IndexFormat, offset: u64) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const b = resource.vkBuffer.fromHandle(value) catch return;
    self.device.cmdBindIndexBuffer(self.handle, b.buffer, offset, if (format == .uint16) .uint16 else .uint32);
}
fn setBindGroup(ptr: *anyopaque, slot: u32, value: @import("../../interface/binding.zig").BindGroup, offsets: []const u32) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const group = binding.vkBindGroup.fromHandle(value) catch return;
    const bind_point: vk.PipelineBindPoint = if (self.rendering) .graphics else .compute;
    const pipeline_layout = if (self.rendering) self.graphics_layout else self.compute_layout;
    if (pipeline_layout == .null_handle) return;
    self.device.cmdBindDescriptorSets(self.handle, bind_point, pipeline_layout, slot, &.{group.set}, offsets);
}
fn setViewport(ptr: *anyopaque, v: command.Viewport) void {
    setViewports(ptr, &.{v});
}
fn setViewports(ptr: *anyopaque, values: []const command.Viewport) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    var out: [16]vk.Viewport = undefined;
    if (values.len > out.len) return;
    for (values, 0..) |v, i| out[i] = vkViewport(v);
    self.device.cmdSetViewport(self.handle, 0, out[0..values.len]);
}
fn setScissor(ptr: *anyopaque, v: command.ScissorRect) void {
    setScissors(ptr, &.{v});
}
fn setScissors(ptr: *anyopaque, values: []const command.ScissorRect) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    var out: [16]vk.Rect2D = undefined;
    if (values.len > out.len) return;
    for (values, 0..) |v, i| out[i] = .{ .offset = .{ .x = @intCast(v.x), .y = @intCast(v.y) }, .extent = .{ .width = v.width, .height = v.height } };
    self.device.cmdSetScissor(self.handle, 0, out[0..values.len]);
}
fn setBlendConstant(ptr: *anyopaque, c: command.Color) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    self.device.cmdSetBlendConstants(self.handle, &.{ c.r, c.g, c.b, c.a });
}
fn setStencilReference(ptr: *anyopaque, v: u32) void {
    const self: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    self.device.cmdSetStencilReference(self.handle, .{ .front_bit = true, .back_bit = true }, v);
}
fn draw(ptr: *anyopaque, a: u32, b: u32, c: u32, d: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    s.device.cmdDraw(s.handle, a, b, c, d);
}
fn drawIndexed(ptr: *anyopaque, a: u32, b: u32, c: u32, d: i32, e: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    s.device.cmdDrawIndexed(s.handle, a, b, c, d, e);
}
fn drawIndirect(ptr: *anyopaque, b: @import("../../interface/resource.zig").Buffer, o: u64) void {
    drawIndirectMulti(ptr, b, o, 1);
}
fn drawIndexedIndirect(ptr: *anyopaque, b: @import("../../interface/resource.zig").Buffer, o: u64) void {
    drawIndexedIndirectMulti(ptr, b, o, 1);
}
fn drawIndirectMulti(ptr: *anyopaque, b: @import("../../interface/resource.zig").Buffer, o: u64, n: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = resource.vkBuffer.fromHandle(b) catch return;
    s.device.cmdDrawIndirect(s.handle, x.buffer, o, n, @sizeOf(vk.DrawIndirectCommand));
}
fn drawIndexedIndirectMulti(ptr: *anyopaque, b: @import("../../interface/resource.zig").Buffer, o: u64, n: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = resource.vkBuffer.fromHandle(b) catch return;
    s.device.cmdDrawIndexedIndirect(s.handle, x.buffer, o, n, @sizeOf(vk.DrawIndexedIndirectCommand));
}
fn drawIndirectCount(ptr: *anyopaque, b: @import("../../interface/resource.zig").Buffer, o: u64, c: @import("../../interface/resource.zig").Buffer, co: u64, n: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = resource.vkBuffer.fromHandle(b) catch return;
    const y = resource.vkBuffer.fromHandle(c) catch return;
    s.device.cmdDrawIndirectCount(s.handle, x.buffer, o, y.buffer, co, n, @sizeOf(vk.DrawIndirectCommand));
}
fn drawIndexedIndirectCount(ptr: *anyopaque, b: @import("../../interface/resource.zig").Buffer, o: u64, c: @import("../../interface/resource.zig").Buffer, co: u64, n: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = resource.vkBuffer.fromHandle(b) catch return;
    const y = resource.vkBuffer.fromHandle(c) catch return;
    s.device.cmdDrawIndexedIndirectCount(s.handle, x.buffer, o, y.buffer, co, n, @sizeOf(vk.DrawIndexedIndirectCommand));
}
fn dispatch(ptr: *anyopaque, x: u32, y: u32, z: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    s.device.cmdDispatch(s.handle, x, y, z);
}
fn dispatchIndirect(ptr: *anyopaque, b: @import("../../interface/resource.zig").Buffer, o: u64) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = resource.vkBuffer.fromHandle(b) catch return;
    s.device.cmdDispatchIndirect(s.handle, x.buffer, o);
}
fn endComputePass(_: *anyopaque) void {}
fn endRenderPass(ptr: *anyopaque) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    if (!s.rendering) return;
    s.device.cmdEndRendering(s.handle);
    s.rendering = false;
}

fn barrier(ptr: *anyopaque, values: []const command.ResourceBarrier) !void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const images = try s.allocator.alloc(vk.ImageMemoryBarrier, values.len);
    defer s.allocator.free(images);
    var count: usize = 0;
    for (values) |value| switch (value) {
        .buffer => {},
        .texture => |v| {
            const t = try resource.vkTexture.fromHandle(v.texture);
            images[count] = imageBarrier(t.image, t.format, t.layout, v.after, v.range.base_mip, v.range.mip_count orelse t.mip_levels - v.range.base_mip, v.range.base_layer, v.range.layer_count orelse t.layers - v.range.base_layer, v.range.aspect);
            t.layout = imageLayout(v.after);
            count += 1;
        },
        .texture_view => |v| {
            const x = try resource.vkTextureView.fromHandle(v.view);
            images[count] = imageBarrier(x.image, x.format, x.layout, v.after, 0, 1, 0, 1, .all);
            x.layout = imageLayout(v.after);
            count += 1;
        },
    };
    const memory = vk.MemoryBarrier{ .src_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true }, .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true } };
    s.device.cmdPipelineBarrier(s.handle, .{ .all_commands_bit = true }, .{ .all_commands_bit = true }, .{}, &.{memory}, null, images[0..count]);
}
fn copyBuffer(ptr: *anyopaque, v: command.BufferCopyRegion) !void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const a = try resource.vkBuffer.fromHandle(v.source);
    const b = try resource.vkBuffer.fromHandle(v.destination);
    s.device.cmdCopyBuffer(s.handle, a.buffer, b.buffer, &.{.{ .src_offset = v.source_offset, .dst_offset = v.destination_offset, .size = v.size }});
}
fn copyTexture(ptr: *anyopaque, v: command.TextureCopyRegion) !void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const a = try resource.vkTexture.fromHandle(v.source.texture);
    const b = try resource.vkTexture.fromHandle(v.destination.texture);
    s.device.cmdCopyImage(s.handle, a.image, .transfer_src_optimal, b.image, .transfer_dst_optimal, &.{.{ .src_subresource = subresource(a.format, v.source.mip_level, v.source.array_layer), .src_offset = vkOffset(v.source.origin), .dst_subresource = subresource(b.format, v.destination.mip_level, v.destination.array_layer), .dst_offset = vkOffset(v.destination.origin), .extent = vkExtent(v.extent) }});
}
fn copyBufferToTexture(ptr: *anyopaque, v: command.BufferTextureCopyRegion) !void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const b = try resource.vkBuffer.fromHandle(v.buffer);
    const t = try resource.vkTexture.fromHandle(v.texture.texture);
    s.device.cmdCopyBufferToImage(s.handle, b.buffer, t.image, .transfer_dst_optimal, &.{bufferImageCopy(v, t.format)});
}
fn copyTextureToBuffer(ptr: *anyopaque, v: command.BufferTextureCopyRegion) !void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const b = try resource.vkBuffer.fromHandle(v.buffer);
    const t = try resource.vkTexture.fromHandle(v.texture.texture);
    s.device.cmdCopyImageToBuffer(s.handle, t.image, .transfer_src_optimal, b.buffer, &.{bufferImageCopy(v, t.format)});
}
fn resolveTexture(ptr: *anyopaque, v: command.TextureResolveRegion) !void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const a = try resource.vkTexture.fromHandle(v.source.texture);
    const b = try resource.vkTexture.fromHandle(v.destination.texture);
    s.device.cmdResolveImage(s.handle, a.image, .transfer_src_optimal, b.image, .transfer_dst_optimal, &.{.{ .src_subresource = subresource(a.format, v.source.mip_level, v.source.array_layer), .src_offset = .{ .x = 0, .y = 0, .z = 0 }, .dst_subresource = subresource(b.format, v.destination.mip_level, v.destination.array_layer), .dst_offset = .{ .x = 0, .y = 0, .z = 0 }, .extent = a.extent }});
}
fn resetQueries(ptr: *anyopaque, q: command.QuerySet, first: u32, count: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = vkQuerySet.fromHandle(q) catch return;
    s.device.cmdResetQueryPool(s.handle, x.handle, first, count);
}
fn beginQuery(ptr: *anyopaque, q: command.QuerySet, i: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = vkQuerySet.fromHandle(q) catch return;
    s.device.cmdBeginQuery(s.handle, x.handle, i, .{});
}
fn endQuery(ptr: *anyopaque, q: command.QuerySet, i: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = vkQuerySet.fromHandle(q) catch return;
    s.device.cmdEndQuery(s.handle, x.handle, i);
}
fn writeTimestamp(ptr: *anyopaque, q: command.QuerySet, i: u32) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = vkQuerySet.fromHandle(q) catch return;
    s.device.cmdWriteTimestamp(s.handle, .{ .bottom_of_pipe_bit = true }, x.handle, i);
}
fn resolveQueries(ptr: *anyopaque, q: command.QuerySet, first: u32, count: u32, b: @import("../../interface/resource.zig").Buffer, o: u64) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    const x = vkQuerySet.fromHandle(q) catch return;
    const y = resource.vkBuffer.fromHandle(b) catch return;
    s.device.cmdCopyQueryPoolResults(s.handle, x.handle, first, count, y.buffer, o, 8, .{ .@"64_bit" = true, .wait_bit = true });
}
// ponytail: debug labels truncate at 255 bytes; store allocator-backed labels if long names become useful.
fn beginDebugGroup(ptr: *anyopaque, value: []const u8) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    if (!s.debug_utils) return;
    var text: [256:0]u8 = undefined;
    const n = @min(value.len, 255);
    @memcpy(text[0..n], value[0..n]);
    text[n] = 0;
    s.device.cmdBeginDebugUtilsLabelEXT(s.handle, &.{ .p_label_name = @ptrCast(&text), .color = .{ 0, 0, 0, 0 } });
}
fn endDebugGroup(ptr: *anyopaque) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    if (s.debug_utils) s.device.cmdEndDebugUtilsLabelEXT(s.handle);
}
fn insertDebugMarker(ptr: *anyopaque, value: []const u8) void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    if (!s.debug_utils) return;
    var text: [256:0]u8 = undefined;
    const n = @min(value.len, 255);
    @memcpy(text[0..n], value[0..n]);
    text[n] = 0;
    s.device.cmdInsertDebugUtilsLabelEXT(s.handle, &.{ .p_label_name = @ptrCast(&text), .color = .{ 0, 0, 0, 0 } });
}
fn finish(ptr: *anyopaque) !void {
    const s: *vkCommandBuffer = @ptrCast(@alignCast(ptr));
    if (s.finished) return error.CommandBufferAlreadyFinished;
    if (s.rendering) return error.PassStillActive;
    try s.device.endCommandBuffer(s.handle);
    s.finished = true;
}

fn loadOp(v: command.LoadOp) vk.AttachmentLoadOp {
    return switch (v) {
        .load => .load,
        .clear => .clear,
        .discard => .dont_care,
    };
}
fn storeOp(v: command.StoreOp) vk.AttachmentStoreOp {
    return if (v == .store) .store else .dont_care;
}
fn vkOffset(v: command.Origin3D) vk.Offset3D {
    return .{ .x = @intCast(v.x), .y = @intCast(v.y), .z = @intCast(v.z) };
}
fn vkExtent(v: command.Extent3D) vk.Extent3D {
    return .{ .width = v.width, .height = v.height, .depth = v.depth };
}
fn vkViewport(v: command.Viewport) vk.Viewport {
    return .{ .x = v.x, .y = v.y + v.height, .width = v.width, .height = -v.height, .min_depth = v.min_depth, .max_depth = v.max_depth };
}
fn subresource(format: vk.Format, mip: u32, layer: u32) vk.ImageSubresourceLayers {
    return .{ .aspect_mask = formatAspect(format), .mip_level = mip, .base_array_layer = layer, .layer_count = 1 };
}
fn bufferImageCopy(v: command.BufferTextureCopyRegion, format: vk.Format) vk.BufferImageCopy {
    return .{ .buffer_offset = v.buffer_offset, .buffer_row_length = 0, .buffer_image_height = v.rows_per_image, .image_subresource = subresource(format, v.texture.mip_level, v.texture.array_layer), .image_offset = vkOffset(v.texture.origin), .image_extent = vkExtent(v.extent) };
}
fn formatAspect(f: vk.Format) vk.ImageAspectFlags {
    return switch (f) {
        .s8_uint => .{ .stencil_bit = true },
        .d16_unorm, .d32_sfloat => .{ .depth_bit = true },
        .d24_unorm_s8_uint, .d32_sfloat_s8_uint => .{ .depth_bit = true, .stencil_bit = true },
        else => .{ .color_bit = true },
    };
}
fn imageBarrier(image: vk.Image, format: vk.Format, old_layout: vk.ImageLayout, after: command.TextureState, mip: u32, mips: u32, layer: u32, layers: u32, _: @import("../../interface/resource.zig").TextureAspect) vk.ImageMemoryBarrier {
    return .{ .src_access_mask = if (old_layout == .undefined) .{} else .{ .memory_read_bit = true, .memory_write_bit = true }, .dst_access_mask = access(after), .old_layout = old_layout, .new_layout = imageLayout(after), .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .image = image, .subresource_range = .{ .aspect_mask = formatAspect(format), .base_mip_level = mip, .level_count = mips, .base_array_layer = layer, .layer_count = layers } };
}
fn imageLayout(v: command.TextureState) vk.ImageLayout {
    return switch (v) {
        .common => .general,
        .copy_source, .resolve_source => .transfer_src_optimal,
        .copy_destination, .resolve_destination => .transfer_dst_optimal,
        .sampled => .shader_read_only_optimal,
        .storage_read, .storage_write => .general,
        .color_attachment => .color_attachment_optimal,
        .depth_stencil_read => .depth_stencil_read_only_optimal,
        .depth_stencil_write => .depth_stencil_attachment_optimal,
        .present => .present_src_khr,
    };
}
fn access(v: command.TextureState) vk.AccessFlags {
    return switch (v) {
        .common => .{ .memory_read_bit = true, .memory_write_bit = true },
        .copy_source, .resolve_source => .{ .transfer_read_bit = true },
        .copy_destination, .resolve_destination => .{ .transfer_write_bit = true },
        .sampled, .storage_read => .{ .shader_read_bit = true },
        .storage_write => .{ .shader_write_bit = true },
        .color_attachment => .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
        .depth_stencil_read => .{ .depth_stencil_attachment_read_bit = true },
        .depth_stencil_write => .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true },
        .present => .{},
    };
}

test "Vulkan viewports preserve the D3D and Metal coordinate convention" {
    const result = vkViewport(.{ .x = 10, .y = 20, .width = 640, .height = 480, .min_depth = 0, .max_depth = 1 });
    try std.testing.expectEqual(@as(f32, 10), result.x);
    try std.testing.expectEqual(@as(f32, 500), result.y);
    try std.testing.expectEqual(@as(f32, 640), result.width);
    try std.testing.expectEqual(@as(f32, -480), result.height);
    try std.testing.expectEqual(@as(f32, 0), result.min_depth);
    try std.testing.expectEqual(@as(f32, 1), result.max_depth);
}
