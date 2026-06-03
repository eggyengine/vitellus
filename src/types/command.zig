const std = @import("std");
const descriptor_set = @import("descriptor_set.zig");
const buffer = @import("buffer.zig");
const def = @import("def.zig");
const pipeline = @import("pipeline.zig");
const texture = @import("texture.zig");
const backend = @import("../backends/hal.zig");
const Range = @import("../utils/range.zig").Range;

pub const CommandBuffer = struct {
    backend: ?backend.CommandBuffer = null,
    label: ?[*:0]const u8 = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub fn destroy(self: *@This()) void {
        if (self.backend) |back| {
            back.destroy();
            self.backend = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }
};

pub const CommandEncoder = struct {
    backend: ?backend.CommandEncoder = null,
    label: ?[*:0]const u8 = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub fn beginRenderPass(self: *@This(), descriptor: RenderPassEncoder.Descriptor) RenderPassEncoder {
        return .{
            .backend = if (self.backend) |back| back.beginRenderPass(descriptor) catch null else null,
            .label = descriptor.label,
        };
    }

    pub fn beginComputePass(self: *@This(), descriptor: ?ComputePassEncoder.Descriptor) anyerror!ComputePassEncoder {
        return .{
            .backend = if (self.backend) |back| try back.beginComputePass(descriptor) else null,
            .label = if (descriptor) |d| d.label else null,
        };
    }

    pub fn copyBufferToBuffer(self: *@This(), source: *buffer.Buffer, destination: *buffer.Buffer, size: ?def.Size64) void {
        if (self.backend) |back| if (source.backend) |source_backend| if (destination.backend) |destination_backend| {
            back.copyBufferToBuffer(source_backend, destination_backend, size);
        };
    }

    pub fn copyBufferToBufferWithOffsets(
        self: *@This(),
        source: *buffer.Buffer,
        sourceOffset: def.Size64,
        destination: *buffer.Buffer,
        destinationOffset: def.Size64,
        size: ?def.Size64,
    ) void {
        if (self.backend) |back| if (source.backend) |source_backend| if (destination.backend) |destination_backend| {
            back.copyBufferToBufferWithOffsets(source_backend, sourceOffset, destination_backend, destinationOffset, size);
        };
    }

    pub fn copyBufferToTexture(
        self: *@This(),
        source: texture.TexelCopyBufferInfo,
        destination: texture.TexelCopyTextureInfo,
        copySize: texture.Texture.Extent3D,
    ) void {
        if (self.backend) |back| back.copyBufferToTexture(source, destination, copySize);
    }

    pub fn copyTextureToBuffer(
        self: *@This(),
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyBufferInfo,
        copySize: texture.Texture.Extent3D,
    ) void {
        if (self.backend) |back| back.copyTextureToBuffer(source, destination, copySize);
    }

    pub fn copyTextureToTexture(
        self: *@This(),
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyTextureInfo,
        copySize: texture.Texture.Extent3D,
    ) void {
        if (self.backend) |back| back.copyTextureToTexture(source, destination, copySize);
    }

    pub fn clearBuffer(self: *@This(), target: *buffer.Buffer, offset: ?def.Size64, size: ?def.Size64) void {
        if (self.backend) |back| if (target.backend) |target_backend| {
            back.clearBuffer(target_backend, offset, size);
        };
    }

    pub fn resolveQuerySet(
        self: *@This(),
        querySet: *@import("gpu.zig").QuerySet,
        firstQuery: def.Size32,
        queryCount: def.Size32,
        destination: *buffer.Buffer,
        destinationOffset: def.Size64,
    ) void {
        if (self.backend) |back| if (querySet.backend) |query_backend| if (destination.backend) |destination_backend| {
            back.resolveQuerySet(query_backend, firstQuery, queryCount, destination_backend, destinationOffset);
        };
    }

    pub fn finish(self: *@This()) CommandBuffer {
        const back = self.backend orelse return .{};
        self.backend = null;
        return .{
            .backend = back.finish(null) catch null,
        };
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        if (self.backend) |back| back.pushDebugGroup(groupLabel);
    }

    pub fn popDebugGroup(self: *@This()) void {
        if (self.backend) |back| back.popDebugGroup();
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        if (self.backend) |back| back.insertDebugMarker(markerLabel);
    }
};

pub const BindingCommands = struct {
    pub fn setDescriptorSet(
        encoder: anytype,
        index: def.Index32,
        group: ?*descriptor_set.DescriptorSet,
        dynamicOffsets: []const def.BufferDynamicOffset,
    ) void {
        if (encoder.backend) |back| {
            const group_backend = if (group) |target_group| target_group.backend else null;
            back.setDescriptorSet(index, group_backend, dynamicOffsets);
        }
    }

    pub fn setDescriptorSetFromData(
        encoder: anytype,
        index: def.Index32,
        group: ?*descriptor_set.DescriptorSet,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        if (encoder.backend) |back| {
            const group_backend = if (group) |target_group| target_group.backend else null;
            back.setDescriptorSetFromData(index, group_backend, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength);
        }
    }
};

pub const ComputePassEncoder = struct {
    backend: ?backend.ComputePassEncoder = null,
    label: ?[*:0]const u8 = null,

    pub const TimestampWrites = struct {
        querySet: *@import("gpu.zig").QuerySet,
        beginningOfPassWriteIndex: ?def.Size32 = null,
        endOfPassWriteIndex: ?def.Size32 = null,
    };

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        timestampWrites: ?TimestampWrites = null,
    };

    pub fn setPipeline(self: *@This(), target: *pipeline.ComputePipeline) void {
        if (self.backend) |back| if (target.backend) |target_backend| back.setPipeline(target_backend);
    }

    pub fn dispatchWorkgroups(
        self: *@This(),
        workgroupCountX: def.Size32,
        workgroupCountY: def.Size32,
        workgroupCountZ: def.Size32,
    ) void {
        if (self.backend) |back| back.dispatchWorkgroups(workgroupCountX, workgroupCountY, workgroupCountZ);
    }

    pub fn dispatchWorkgroupsIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        if (self.backend) |back| if (indirectBuffer.backend) |indirect_backend| {
            back.dispatchWorkgroupsIndirect(indirect_backend, indirectOffset);
        };
    }

    pub fn end(self: *@This()) void {
        if (self.backend) |back| {
            self.backend = null;
            back.end();
        }
    }

    pub fn setDescriptorSet(self: *@This(), index: def.Index32, group: ?*descriptor_set.DescriptorSet, dynamicOffsets: []const def.BufferDynamicOffset) void {
        BindingCommands.setDescriptorSet(self, index, group, dynamicOffsets);
    }

    pub fn setDescriptorSetFromData(
        self: *@This(),
        index: def.Index32,
        group: ?*descriptor_set.DescriptorSet,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        BindingCommands.setDescriptorSetFromData(self, index, group, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength);
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        if (self.backend) |back| back.pushDebugGroup(groupLabel);
    }

    pub fn popDebugGroup(self: *@This()) void {
        if (self.backend) |back| back.popDebugGroup();
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        if (self.backend) |back| back.insertDebugMarker(markerLabel);
    }
};

pub const RenderPassEncoder = struct {
    backend: ?backend.RenderPassEncoder = null,
    label: ?[*:0]const u8 = null,

    pub const TimestampWrites = struct {
        querySet: *@import("gpu.zig").QuerySet,
        beginningOfPassWriteIndex: ?def.Size32 = null,
        endOfPassWriteIndex: ?def.Size32 = null,
    };

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        colorAttachments: []const ?ColorAttachment,
        depthStencilAttachment: ?DepthStencilAttachment = null,
        occlusionQuerySet: ?*@import("gpu.zig").QuerySet = null,
        timestampWrites: ?TimestampWrites = null,
        multiviewMask: ?u32 = null,
        maxDrawCount: def.Size64 = 50000000,
    };

    pub const ColorAttachment = struct {
        view: *texture.Texture.View,
        depthSlice: ?def.IntegerCoordinate = null,
        resolveTarget: ?*texture.Texture.View = null,
        clearValue: ?def.Color = null,
        loadOp: LoadOp,
        storeOp: StoreOp,
    };

    pub const DepthStencilAttachment = struct {
        view: *texture.Texture.View,
        depthClearValue: ?f32 = null,
        depthOperations: ?Operations = null,
        stencilOperations: ?Operations = null,
    };

    pub const Operations = struct {
        loadOp: LoadOp,
        storeOp: StoreOp,
    };

    pub const LoadOp = union(enum) {
        load,
        clear: f32,
    };

    pub const StoreOp = enum {
        store,
        discard,
    };

    pub fn setViewport(self: *@This(), x: f32, y: f32, width: f32, height: f32, minDepth: f32, maxDepth: f32) void {
        if (self.backend) |back| back.setViewport(x, y, width, height, minDepth, maxDepth);
    }

    pub fn setScissorRect(self: *@This(), x: def.IntegerCoordinate, y: def.IntegerCoordinate, width: def.IntegerCoordinate, height: def.IntegerCoordinate) void {
        if (self.backend) |back| back.setScissorRect(x, y, width, height);
    }

    pub fn setBlendConstant(self: *@This(), color: def.Color) void {
        if (self.backend) |back| back.setBlendConstant(color);
    }

    pub fn setStencilReference(self: *@This(), reference: def.StencilValue) void {
        if (self.backend) |back| back.setStencilReference(reference);
    }

    pub fn beginOcclusionQuery(self: *@This(), queryIndex: def.Size32) void {
        if (self.backend) |back| back.beginOcclusionQuery(queryIndex);
    }

    pub fn endOcclusionQuery(self: *@This()) void {
        if (self.backend) |back| back.endOcclusionQuery();
    }

    pub fn executeBundles(self: *@This(), bundles: []const RenderBundle) void {
        if (self.backend) |back| {
            var backend_bundles = std.heap.page_allocator.alloc(backend.RenderBundle, bundles.len) catch return;
            defer std.heap.page_allocator.free(backend_bundles);
            var count: usize = 0;
            for (bundles) |bundle| {
                if (bundle.backend) |bundle_backend| {
                    backend_bundles[count] = bundle_backend;
                    count += 1;
                }
            }
            back.executeBundles(backend_bundles[0..count]);
        }
    }

    pub fn end(self: *@This()) void {
        if (self.backend) |back| {
            self.backend = null;
            back.end();
        }
    }

    pub fn setPipeline(self: *@This(), target: *pipeline.RenderPipeline) void {
        if (self.backend) |back| if (target.backend) |target_backend| back.setPipeline(target_backend);
    }

    pub fn setIndexBuffer(self: *@This(), target: *buffer.Buffer, indexFormat: pipeline.IndexFormat, offset: def.Size64, size: ?def.Size64) void {
        if (self.backend) |back| if (target.backend) |target_backend| {
            back.setIndexBuffer(target_backend, indexFormat, offset, size);
        };
    }

    pub fn setVertexBuffer(self: *@This(), slot: def.Index32, target: ?*buffer.Buffer, offset: def.Size64, size: ?def.Size64) void {
        if (self.backend) |back| {
            const target_backend = if (target) |target_buffer| target_buffer.backend else null;
            back.setVertexBuffer(slot, target_backend, offset, size);
        }
    }

    pub fn draw(self: *@This(), vertices: Range, instances: Range) void {
        if (self.backend) |back| back.draw(vertices, instances);
    }

    pub fn drawIndexed(
        self: *@This(),
        indices: Range,
        instances: Range,
        baseVertex: def.SignedOffset32,
    ) void {
        if (self.backend) |back| back.drawIndexed(indices, instances, baseVertex);
    }

    pub fn drawIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        if (self.backend) |back| if (indirectBuffer.backend) |indirect_backend| {
            back.drawIndirect(indirect_backend, indirectOffset);
        };
    }

    pub fn drawIndexedIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        if (self.backend) |back| if (indirectBuffer.backend) |indirect_backend| {
            back.drawIndexedIndirect(indirect_backend, indirectOffset);
        };
    }

    pub fn setDescriptorSet(self: *@This(), index: def.Index32, group: ?*descriptor_set.DescriptorSet, dynamicOffsets: []const def.BufferDynamicOffset) void {
        BindingCommands.setDescriptorSet(self, index, group, dynamicOffsets);
    }

    pub fn setDescriptorSetFromData(
        self: *@This(),
        index: def.Index32,
        group: ?*descriptor_set.DescriptorSet,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        BindingCommands.setDescriptorSetFromData(self, index, group, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength);
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        if (self.backend) |back| back.pushDebugGroup(groupLabel);
    }

    pub fn popDebugGroup(self: *@This()) void {
        if (self.backend) |back| back.popDebugGroup();
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        if (self.backend) |back| back.insertDebugMarker(markerLabel);
    }
};

pub const RenderPassLayout = struct {
    label: ?[*:0]const u8 = null,
    colorFormats: []const ?texture.Texture.Format,
    depthStencilFormat: ?texture.Texture.Format = null,
    sampleCount: def.Size32 = 1,
};

pub const RenderBundle = struct {
    backend: ?backend.RenderBundle = null,
    label: ?[*:0]const u8 = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub fn destroy(self: *@This()) void {
        if (self.backend) |back| {
            back.destroy();
            self.backend = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }
};

pub const RenderBundleEncoder = struct {
    backend: ?backend.RenderBundleEncoder = null,
    label: ?[*:0]const u8 = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        colorFormats: []const ?texture.Texture.Format,
        depthStencilFormat: ?texture.Texture.Format = null,
        sampleCount: def.Size32 = 1,
        depthReadOnly: bool = false,
        stencilReadOnly: bool = false,
    };

    pub fn finish(self: *@This(), descriptor: ?RenderBundle.Descriptor) RenderBundle {
        const back = self.backend orelse return .{
            .label = if (descriptor) |d| d.label else null,
        };
        self.backend = null;
        return .{
            .backend = back.finish(descriptor) catch null,
            .label = if (descriptor) |d| d.label else null,
        };
    }

    pub fn setPipeline(self: *@This(), target: *pipeline.RenderPipeline) void {
        if (self.backend) |back| if (target.backend) |target_backend| back.setPipeline(target_backend);
    }

    pub fn setIndexBuffer(self: *@This(), target: *buffer.Buffer, indexFormat: pipeline.IndexFormat, offset: def.Size64, size: ?def.Size64) void {
        if (self.backend) |back| if (target.backend) |target_backend| {
            back.setIndexBuffer(target_backend, indexFormat, offset, size);
        };
    }

    pub fn setVertexBuffer(self: *@This(), slot: def.Index32, target: ?*buffer.Buffer, offset: def.Size64, size: ?def.Size64) void {
        if (self.backend) |back| {
            const target_backend = if (target) |target_buffer| target_buffer.backend else null;
            back.setVertexBuffer(slot, target_backend, offset, size);
        }
    }

    pub fn draw(self: *@This(), vertices: Range, instances: Range) void {
        if (self.backend) |back| back.draw(vertices, instances);
    }

    pub fn drawIndexed(
        self: *@This(),
        indices: Range,
        instances: Range,
        baseVertex: def.SignedOffset32,
    ) void {
        if (self.backend) |back| back.drawIndexed(indices, instances, baseVertex);
    }

    pub fn drawIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        if (self.backend) |back| if (indirectBuffer.backend) |indirect_backend| {
            back.drawIndirect(indirect_backend, indirectOffset);
        };
    }

    pub fn drawIndexedIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        if (self.backend) |back| if (indirectBuffer.backend) |indirect_backend| {
            back.drawIndexedIndirect(indirect_backend, indirectOffset);
        };
    }

    pub fn setDescriptorSet(self: *@This(), index: def.Index32, group: ?*descriptor_set.DescriptorSet, dynamicOffsets: []const def.BufferDynamicOffset) void {
        BindingCommands.setDescriptorSet(self, index, group, dynamicOffsets);
    }

    pub fn setDescriptorSetFromData(
        self: *@This(),
        index: def.Index32,
        group: ?*descriptor_set.DescriptorSet,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        BindingCommands.setDescriptorSetFromData(self, index, group, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength);
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        if (self.backend) |back| back.pushDebugGroup(groupLabel);
    }

    pub fn popDebugGroup(self: *@This()) void {
        if (self.backend) |back| back.popDebugGroup();
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        if (self.backend) |back| back.insertDebugMarker(markerLabel);
    }
};
