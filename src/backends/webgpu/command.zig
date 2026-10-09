//! Command recording.

const std = @import("std");
const c = @import("webgpu_c");
const resource = @import("../../interface/resource.zig");
const binding = @import("../../interface/binding.zig");
const pipeline = @import("../../interface/pipeline.zig");
const command = @import("../../interface/command.zig");
const str = @import("utils.zig").str;
const wgpuEnum = @import("utils.zig").wgpuEnum;
const zeroInit = @import("utils.zig").zeroInit;
const ptrOf = @import("utils.zig").ptrOf;
const hasStencil = @import("utils.zig").hasStencil;
const hasDepth = @import("utils.zig").hasDepth;
const texelSize = @import("utils.zig").texelSize;
const aspect = @import("utils.zig").aspect;
const loadOp = @import("utils.zig").loadOp;
const storeOp = @import("utils.zig").storeOp;
const WgpuDevice = @import("device.zig").WgpuDevice;
const WgpuView = @import("resource.zig").WgpuView;
const WgpuBuffer = @import("resource.zig").WgpuBuffer;

pub const WgpuCommandBuffer = struct {
    device: *WgpuDevice,
    encoder: c.WGPUCommandEncoder,
    pass: union(enum) { none, render: c.WGPURenderPassEncoder, compute: c.WGPUComputePassEncoder } = .none,
    finished: c.WGPUCommandBuffer = null,

    pub fn create(pool: command.CommandPool, desc: command.CommandBufferDescriptor) anyerror!command.CommandBuffer {
        const device = ptrOf(WgpuDevice, pool.handle);
        const encoder = c.wgpuDeviceCreateCommandEncoder(device.handle, &.{ .nextInChain = null, .label = str(desc.label) }) orelse return error.CommandBufferCreationFailed;
        errdefer c.wgpuCommandEncoderRelease(encoder);
        const self = try device.allocator.create(WgpuCommandBuffer);
        self.* = .{ .device = device, .encoder = encoder };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn from(ptr: *anyopaque) *WgpuCommandBuffer {
        return @ptrCast(@alignCast(ptr));
    }

    fn render(ptr: *anyopaque) c.WGPURenderPassEncoder {
        return switch (from(ptr).pass) {
            .render => |pass| pass,
            else => @panic("draw command recorded outside a render pass"),
        };
    }

    fn compute(ptr: *anyopaque) c.WGPUComputePassEncoder {
        return switch (from(ptr).pass) {
            .compute => |pass| pass,
            else => @panic("dispatch recorded outside a compute pass"),
        };
    }

    fn buffer(value: resource.Buffer) c.WGPUBuffer {
        return ptrOf(WgpuBuffer, value.handle).handle;
    }

    fn texture(value: resource.Texture) c.WGPUTexture {
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }

    const vtable: command.CommandBuffer.VTable = .{
        .deinitFn = deinit,
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
        .drawIndexedIndirectCountFn = drawIndirectCount,
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
        .beginQueryFn = query,
        .endQueryFn = query,
        .writeTimestampFn = query,
        .resolveQueriesFn = resolveQueries,
        .beginDebugGroupFn = beginDebugGroup,
        .endDebugGroupFn = endDebugGroup,
        .insertDebugMarkerFn = insertDebugMarker,
        .finishFn = finish,
    };

    fn deinit(ptr: *anyopaque) void {
        const self = from(ptr);
        switch (self.pass) {
            .none => {},
            .render => |pass| c.wgpuRenderPassEncoderRelease(pass),
            .compute => |pass| c.wgpuComputePassEncoderRelease(pass),
        }
        if (self.finished) |finished| c.wgpuCommandBufferRelease(finished);
        c.wgpuCommandEncoderRelease(self.encoder);
        self.device.allocator.destroy(self);
    }

    fn beginRenderPass(ptr: *anyopaque, desc: command.RenderPassDescriptor) anyerror!void {
        const self = from(ptr);
        var colors: [8]c.WGPURenderPassColorAttachment = undefined;
        if (desc.color_attachments.len > colors.len) return error.TooManyColorAttachments;
        for (desc.color_attachments, colors[0..desc.color_attachments.len]) |attachment, *out| out.* = .{
            .nextInChain = null,
            .view = ptrOf(WgpuView, attachment.view.handle).handle,
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = if (attachment.resolve_target) |target| ptrOf(WgpuView, target.handle).handle else null,
            .loadOp = loadOp(attachment.load_op),
            .storeOp = storeOp(attachment.store_op),
            .clearValue = .{ .r = attachment.clear_value.r, .g = attachment.clear_value.g, .b = attachment.clear_value.b, .a = attachment.clear_value.a },
        };
        var depth: c.WGPURenderPassDepthStencilAttachment = undefined;
        if (desc.depth_stencil_attachment) |ds| {
            const view = ptrOf(WgpuView, ds.view.handle);
            depth = zeroInit(c.WGPURenderPassDepthStencilAttachment, .{
                .view = view.handle,
                .depthClearValue = ds.depth_clear,
                .depthReadOnly = @intFromBool(ds.depth_read_only),
                .stencilClearValue = ds.stencil_clear,
                .stencilReadOnly = @intFromBool(ds.stencil_read_only),
            });
            // Load/store ops are only allowed for aspects the format has and that are writable.
            if (hasDepth(view.format) and !ds.depth_read_only) {
                depth.depthLoadOp = loadOp(ds.depth_load_op);
                depth.depthStoreOp = storeOp(ds.depth_store_op);
            }
            if (hasStencil(view.format) and !ds.stencil_read_only) {
                depth.stencilLoadOp = loadOp(ds.stencil_load_op);
                depth.stencilStoreOp = storeOp(ds.stencil_store_op);
            }
        }
        const pass = c.wgpuCommandEncoderBeginRenderPass(self.encoder, &zeroInit(c.WGPURenderPassDescriptor, .{
            .label = str(desc.label),
            .colorAttachmentCount = desc.color_attachments.len,
            .colorAttachments = &colors,
            .depthStencilAttachment = if (desc.depth_stencil_attachment != null) &depth else null,
        })) orelse return error.RenderPassFailed;
        self.pass = .{ .render = pass };
    }

    fn endRenderPass(ptr: *anyopaque) void {
        const self = from(ptr);
        const pass = render(ptr);
        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
        self.pass = .none;
    }

    fn beginComputePass(ptr: *anyopaque, label: ?[]const u8) anyerror!void {
        const self = from(ptr);
        const pass = c.wgpuCommandEncoderBeginComputePass(self.encoder, &zeroInit(c.WGPUComputePassDescriptor, .{ .label = str(label) })) orelse return error.ComputePassFailed;
        self.pass = .{ .compute = pass };
    }

    fn endComputePass(ptr: *anyopaque) void {
        const self = from(ptr);
        const pass = compute(ptr);
        c.wgpuComputePassEncoderEnd(pass);
        c.wgpuComputePassEncoderRelease(pass);
        self.pass = .none;
    }

    fn setGraphicsPipeline(ptr: *anyopaque, value: pipeline.GraphicsPipeline) void {
        c.wgpuRenderPassEncoderSetPipeline(render(ptr), @ptrFromInt(@as(usize, @intCast(value.handle))));
    }

    fn setComputePipeline(ptr: *anyopaque, value: pipeline.ComputePipeline) void {
        c.wgpuComputePassEncoderSetPipeline(compute(ptr), @ptrFromInt(@as(usize, @intCast(value.handle))));
    }

    fn setVertexBuffer(ptr: *anyopaque, slot: u32, value: resource.Buffer, offset: u64) void {
        c.wgpuRenderPassEncoderSetVertexBuffer(render(ptr), slot, buffer(value), offset, c.WGPU_WHOLE_SIZE);
    }

    fn setVertexBuffers(ptr: *anyopaque, first_slot: u32, bindings: []const command.VertexBufferBinding) void {
        for (bindings, 0..) |b, i| setVertexBuffer(ptr, first_slot + @as(u32, @intCast(i)), b.buffer, b.offset);
    }

    fn setIndexBuffer(ptr: *anyopaque, value: resource.Buffer, format: command.IndexFormat, offset: u64) void {
        c.wgpuRenderPassEncoderSetIndexBuffer(render(ptr), buffer(value), wgpuEnum("WGPUIndexFormat_", format), offset, c.WGPU_WHOLE_SIZE);
    }

    fn setBindGroup(ptr: *anyopaque, slot: u32, group: binding.BindGroup, dynamic_offsets: []const u32) void {
        const handle: c.WGPUBindGroup = @ptrFromInt(@as(usize, @intCast(group.handle)));
        switch (from(ptr).pass) {
            .render => |pass| c.wgpuRenderPassEncoderSetBindGroup(pass, slot, handle, dynamic_offsets.len, dynamic_offsets.ptr),
            .compute => |pass| c.wgpuComputePassEncoderSetBindGroup(pass, slot, handle, dynamic_offsets.len, dynamic_offsets.ptr),
            .none => @panic("bind group set outside a pass"),
        }
    }

    fn setViewport(ptr: *anyopaque, v: command.Viewport) void {
        c.wgpuRenderPassEncoderSetViewport(render(ptr), v.x, v.y, v.width, v.height, v.min_depth, v.max_depth);
    }

    fn setViewports(ptr: *anyopaque, viewports: []const command.Viewport) void {
        // WebGPU has a single viewport.
        if (viewports.len > 0) setViewport(ptr, viewports[0]);
    }

    fn setScissor(ptr: *anyopaque, rect: command.ScissorRect) void {
        c.wgpuRenderPassEncoderSetScissorRect(render(ptr), rect.x, rect.y, rect.width, rect.height);
    }

    fn setScissors(ptr: *anyopaque, rects: []const command.ScissorRect) void {
        if (rects.len > 0) setScissor(ptr, rects[0]);
    }

    fn setBlendConstant(ptr: *anyopaque, colour: command.Color) void {
        c.wgpuRenderPassEncoderSetBlendConstant(render(ptr), &.{ .r = colour.r, .g = colour.g, .b = colour.b, .a = colour.a });
    }

    fn setStencilReference(ptr: *anyopaque, value: u32) void {
        c.wgpuRenderPassEncoderSetStencilReference(render(ptr), value);
    }

    fn draw(ptr: *anyopaque, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
        c.wgpuRenderPassEncoderDraw(render(ptr), vertices, instances, first_vertex, first_instance);
    }

    fn drawIndexed(ptr: *anyopaque, indices: u32, instances: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        c.wgpuRenderPassEncoderDrawIndexed(render(ptr), indices, instances, first_index, base_vertex, first_instance);
    }

    fn drawIndirect(ptr: *anyopaque, value: resource.Buffer, offset: u64) void {
        c.wgpuRenderPassEncoderDrawIndirect(render(ptr), buffer(value), offset);
    }

    fn drawIndexedIndirect(ptr: *anyopaque, value: resource.Buffer, offset: u64) void {
        c.wgpuRenderPassEncoderDrawIndexedIndirect(render(ptr), buffer(value), offset);
    }

    fn drawIndirectMulti(ptr: *anyopaque, value: resource.Buffer, offset: u64, count: u32) void {
        for (0..count) |i| drawIndirect(ptr, value, offset + i * 16);
    }

    fn drawIndexedIndirectMulti(ptr: *anyopaque, value: resource.Buffer, offset: u64, count: u32) void {
        for (0..count) |i| drawIndexedIndirect(ptr, value, offset + i * 20);
    }

    fn drawIndirectCount(_: *anyopaque, _: resource.Buffer, _: u64, _: resource.Buffer, _: u64, _: u32) void {
        @panic("WebGPU has no GPU-driven draw counts");
    }

    fn dispatch(ptr: *anyopaque, x: u32, y: u32, z: u32) void {
        c.wgpuComputePassEncoderDispatchWorkgroups(compute(ptr), x, y, z);
    }

    fn dispatchIndirect(ptr: *anyopaque, value: resource.Buffer, offset: u64) void {
        c.wgpuComputePassEncoderDispatchWorkgroupsIndirect(compute(ptr), buffer(value), offset);
    }

    fn barrier(_: *anyopaque, _: []const command.ResourceBarrier) anyerror!void {
        // WebGPU tracks resource state itself.
    }

    fn copyBuffer(ptr: *anyopaque, region: command.BufferCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyBufferToBuffer(from(ptr).encoder, buffer(region.source), region.source_offset, buffer(region.destination), region.destination_offset, region.size);
    }

    fn textureInfo(view: command.TextureCopyView) c.WGPUTexelCopyTextureInfo {
        return .{
            .texture = texture(view.texture),
            .mipLevel = view.mip_level,
            .origin = .{ .x = view.origin.x, .y = view.origin.y, .z = view.origin.z + view.array_layer },
            .aspect = c.WGPUTextureAspect_All,
        };
    }

    fn bufferInfo(region: command.BufferTextureCopyRegion) !c.WGPUTexelCopyBufferInfo {
        const bytes_per_row = if (region.bytes_per_row != 0)
            region.bytes_per_row
        else
            std.mem.alignForward(u32, region.extent.width * try texelSize(c.wgpuTextureGetFormat(texture(region.texture.texture))), 256);
        return .{
            .layout = .{
                .offset = region.buffer_offset,
                .bytesPerRow = bytes_per_row,
                .rowsPerImage = if (region.rows_per_image != 0) region.rows_per_image else region.extent.height,
            },
            .buffer = buffer(region.buffer),
        };
    }

    fn extent(e: command.Extent3D) c.WGPUExtent3D {
        return .{ .width = e.width, .height = e.height, .depthOrArrayLayers = e.depth };
    }

    fn copyTexture(ptr: *anyopaque, region: command.TextureCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyTextureToTexture(from(ptr).encoder, &textureInfo(region.source), &textureInfo(region.destination), &extent(region.extent));
    }

    fn copyBufferToTexture(ptr: *anyopaque, region: command.BufferTextureCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyBufferToTexture(from(ptr).encoder, &try bufferInfo(region), &textureInfo(region.texture), &extent(region.extent));
    }

    fn copyTextureToBuffer(ptr: *anyopaque, region: command.BufferTextureCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyTextureToBuffer(from(ptr).encoder, &textureInfo(region.texture), &try bufferInfo(region), &extent(region.extent));
    }

    fn resolveTexture(_: *anyopaque, _: command.TextureResolveRegion) anyerror!void {
        // ponytail: WebGPU resolves only as a render-pass resolve target; emulate with an empty pass if needed.
        return error.Unsupported;
    }

    // `QuerySet.init` fails on this backend (no `createQuerySetFn`), so these are never reached.
    fn resetQueries(_: *anyopaque, _: command.QuerySet, _: u32, _: u32) void {
        unreachable;
    }

    fn query(_: *anyopaque, _: command.QuerySet, _: u32) void {
        unreachable;
    }

    fn resolveQueries(_: *anyopaque, _: command.QuerySet, _: u32, _: u32, _: resource.Buffer, _: u64) void {
        unreachable;
    }

    fn beginDebugGroup(ptr: *anyopaque, label: []const u8) void {
        switch (from(ptr).pass) {
            .none => c.wgpuCommandEncoderPushDebugGroup(from(ptr).encoder, str(label)),
            .render => |pass| c.wgpuRenderPassEncoderPushDebugGroup(pass, str(label)),
            .compute => |pass| c.wgpuComputePassEncoderPushDebugGroup(pass, str(label)),
        }
    }

    fn endDebugGroup(ptr: *anyopaque) void {
        switch (from(ptr).pass) {
            .none => c.wgpuCommandEncoderPopDebugGroup(from(ptr).encoder),
            .render => |pass| c.wgpuRenderPassEncoderPopDebugGroup(pass),
            .compute => |pass| c.wgpuComputePassEncoderPopDebugGroup(pass),
        }
    }

    fn insertDebugMarker(ptr: *anyopaque, label: []const u8) void {
        switch (from(ptr).pass) {
            .none => c.wgpuCommandEncoderInsertDebugMarker(from(ptr).encoder, str(label)),
            .render => |pass| c.wgpuRenderPassEncoderInsertDebugMarker(pass, str(label)),
            .compute => |pass| c.wgpuComputePassEncoderInsertDebugMarker(pass, str(label)),
        }
    }

    fn finish(ptr: *anyopaque) anyerror!void {
        const self = from(ptr);
        self.finished = c.wgpuCommandEncoderFinish(self.encoder, &.{ .nextInChain = null, .label = str(null) }) orelse return error.CommandBufferFinishFailed;
    }
};
