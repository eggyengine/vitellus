const std = @import("std");

const command = @import("../../types/command.zig");
const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const pipeline = @import("../../types/pipeline.zig");
const texture = @import("../../types/texture.zig");

pub const DX_CommandBuffer = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.CommandBuffer.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.CommandBuffer {
        const value = try allocator.create(DX_CommandBuffer);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_CommandBuffer = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 command buffer", .{});
        typed.allocator.destroy(typed);
    }
};

pub const DX_CommandEncoder = struct {
    allocator: std.mem.Allocator,

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

    pub fn init(allocator: std.mem.Allocator) !hal.CommandEncoder {
        const value = try allocator.create(DX_CommandEncoder);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn beginRenderPass(ptr: *anyopaque, descriptor: command.RenderPassEncoder.Descriptor) anyerror!hal.RenderPassEncoder {
        const typed: *DX_CommandEncoder = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return DX_RenderPassEncoder.init(typed.allocator);
    }

    fn beginComputePass(ptr: *anyopaque, descriptor: ?command.ComputePassEncoder.Descriptor) anyerror!hal.ComputePassEncoder {
        const typed: *DX_CommandEncoder = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return DX_ComputePassEncoder.init(typed.allocator);
    }

    fn copyBufferToBuffer(ptr: *anyopaque, source: hal.Buffer, destination: hal.Buffer, size: ?def.Size64) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = size;
    }

    fn copyBufferToBufferWithOffsets(
        ptr: *anyopaque,
        source: hal.Buffer,
        source_offset: def.Size64,
        destination: hal.Buffer,
        destination_offset: def.Size64,
        size: ?def.Size64,
    ) void {
        _ = ptr;
        _ = source;
        _ = source_offset;
        _ = destination;
        _ = destination_offset;
        _ = size;
    }

    fn copyBufferToTexture(
        ptr: *anyopaque,
        source: texture.TexelCopyBufferInfo,
        destination: texture.TexelCopyTextureInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = copy_size;
    }

    fn copyTextureToBuffer(
        ptr: *anyopaque,
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyBufferInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = copy_size;
    }

    fn copyTextureToTexture(
        ptr: *anyopaque,
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyTextureInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
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

    fn resolveQuerySet(
        ptr: *anyopaque,
        query_set: hal.QuerySet,
        first_query: def.Size32,
        query_count: def.Size32,
        destination: hal.Buffer,
        destination_offset: def.Size64,
    ) void {
        _ = ptr;
        _ = query_set;
        _ = first_query;
        _ = query_count;
        _ = destination;
        _ = destination_offset;
    }

    fn finish(ptr: *anyopaque, descriptor: ?command.CommandBuffer.Descriptor) anyerror!hal.CommandBuffer {
        const typed: *DX_CommandEncoder = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        const command_buffer = try DX_CommandBuffer.init(typed.allocator);
        typed.allocator.destroy(typed);
        return command_buffer;
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

pub const DX_ComputePassEncoder = struct {
    allocator: std.mem.Allocator,

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

    pub fn init(allocator: std.mem.Allocator) !hal.ComputePassEncoder {
        const value = try allocator.create(DX_ComputePassEncoder);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

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
        const typed: *DX_ComputePassEncoder = @ptrCast(@alignCast(ptr));
        typed.allocator.destroy(typed);
    }

    fn setBindGroup(ptr: *anyopaque, index: def.Index32, group: ?hal.BindGroup, dynamic_offsets: []const def.BufferDynamicOffset) void {
        _ = ptr;
        _ = index;
        _ = group;
        _ = dynamic_offsets;
    }

    fn setBindGroupFromData(
        ptr: *anyopaque,
        index: def.Index32,
        group: ?hal.BindGroup,
        dynamic_offsets_data: []const u32,
        dynamic_offsets_data_start: def.Size64,
        dynamic_offsets_data_length: def.Size32,
    ) void {
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

pub const DX_RenderPassEncoder = struct {
    allocator: std.mem.Allocator,

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

    pub fn init(allocator: std.mem.Allocator) !hal.RenderPassEncoder {
        const value = try allocator.create(DX_RenderPassEncoder);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn setViewport(ptr: *anyopaque, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void {
        _ = ptr;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = min_depth;
        _ = max_depth;
    }

    fn setScissorRect(ptr: *anyopaque, x: def.IntegerCoordinate, y: def.IntegerCoordinate, width: def.IntegerCoordinate, height: def.IntegerCoordinate) void {
        _ = ptr;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
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
        const typed: *DX_RenderPassEncoder = @ptrCast(@alignCast(ptr));
        typed.allocator.destroy(typed);
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

    fn drawIndexed(
        ptr: *anyopaque,
        index_count: def.Size32,
        instance_count: def.Size32,
        first_index: def.Size32,
        base_vertex: def.SignedOffset32,
        first_instance: def.Size32,
    ) void {
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

    fn setBindGroupFromData(
        ptr: *anyopaque,
        index: def.Index32,
        group: ?hal.BindGroup,
        dynamic_offsets_data: []const u32,
        dynamic_offsets_data_start: def.Size64,
        dynamic_offsets_data_length: def.Size32,
    ) void {
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

pub const DX_RenderBundle = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.RenderBundle.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.RenderBundle {
        const value = try allocator.create(DX_RenderBundle);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_RenderBundle = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 render bundle", .{});
        typed.allocator.destroy(typed);
    }
};

pub const DX_RenderBundleEncoder = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.RenderBundleEncoder.VTable{
        .finish = finish,
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

    pub fn init(allocator: std.mem.Allocator) !hal.RenderBundleEncoder {
        const value = try allocator.create(DX_RenderBundleEncoder);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn finish(ptr: *anyopaque, descriptor: ?command.RenderBundle.Descriptor) anyerror!hal.RenderBundle {
        const typed: *DX_RenderBundleEncoder = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        const bundle = try DX_RenderBundle.init(typed.allocator);
        typed.allocator.destroy(typed);
        return bundle;
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

    fn drawIndexed(
        ptr: *anyopaque,
        index_count: def.Size32,
        instance_count: def.Size32,
        first_index: def.Size32,
        base_vertex: def.SignedOffset32,
        first_instance: def.Size32,
    ) void {
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

    fn setBindGroupFromData(
        ptr: *anyopaque,
        index: def.Index32,
        group: ?hal.BindGroup,
        dynamic_offsets_data: []const u32,
        dynamic_offsets_data_start: def.Size64,
        dynamic_offsets_data_length: def.Size32,
    ) void {
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
