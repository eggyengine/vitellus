const bind_group = @import("bind_group.zig");
const buffer = @import("buffer.zig");
const def = @import("def.zig");
const pipeline = @import("pipeline.zig");
const texture = @import("texture.zig");

pub const CommandBuffer = struct {
    label: ?[*:0]const u8 = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };
};

pub const CommandEncoder = struct {
    label: ?[*:0]const u8 = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub fn beginRenderPass(self: *@This(), descriptor: RenderPassEncoder.Descriptor) RenderPassEncoder {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn beginComputePass(self: *@This(), descriptor: ?ComputePassEncoder.Descriptor) ComputePassEncoder {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn copyBufferToBuffer(self: *@This(), source: *buffer.Buffer, destination: *buffer.Buffer, size: ?def.Size64) void {
        _ = self;
        _ = source;
        _ = destination;
        _ = size;
    }

    pub fn copyBufferToBufferWithOffsets(
        self: *@This(),
        source: *buffer.Buffer,
        sourceOffset: def.Size64,
        destination: *buffer.Buffer,
        destinationOffset: def.Size64,
        size: ?def.Size64,
    ) void {
        _ = self;
        _ = source;
        _ = sourceOffset;
        _ = destination;
        _ = destinationOffset;
        _ = size;
    }

    pub fn copyBufferToTexture(
        self: *@This(),
        source: texture.TexelCopyBufferInfo,
        destination: texture.TexelCopyTextureInfo,
        copySize: texture.Texture.Extent3D,
    ) void {
        _ = self;
        _ = source;
        _ = destination;
        _ = copySize;
    }

    pub fn copyTextureToBuffer(
        self: *@This(),
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyBufferInfo,
        copySize: texture.Texture.Extent3D,
    ) void {
        _ = self;
        _ = source;
        _ = destination;
        _ = copySize;
    }

    pub fn copyTextureToTexture(
        self: *@This(),
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyTextureInfo,
        copySize: texture.Texture.Extent3D,
    ) void {
        _ = self;
        _ = source;
        _ = destination;
        _ = copySize;
    }

    pub fn clearBuffer(self: *@This(), target: *buffer.Buffer, offset: ?def.Size64, size: ?def.Size64) void {
        _ = self;
        _ = target;
        _ = offset;
        _ = size;
    }

    pub fn resolveQuerySet(
        self: *@This(),
        querySet: *@import("gpu.zig").QuerySet,
        firstQuery: def.Size32,
        queryCount: def.Size32,
        destination: *buffer.Buffer,
        destinationOffset: def.Size64,
    ) void {
        _ = self;
        _ = querySet;
        _ = firstQuery;
        _ = queryCount;
        _ = destination;
        _ = destinationOffset;
    }

    pub fn finish(self: *@This()) CommandBuffer {
        _ = self;
        return .{};
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        _ = self;
        _ = groupLabel;
    }

    pub fn popDebugGroup(self: *@This()) void {
        _ = self;
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        _ = self;
        _ = markerLabel;
    }
};

pub const BindingCommands = struct {
    pub fn setBindGroup(
        encoder: anytype,
        index: def.Index32,
        group: ?*bind_group.BindGroup,
        dynamicOffsets: []const def.BufferDynamicOffset,
    ) void {
        _ = encoder;
        _ = index;
        _ = group;
        _ = dynamicOffsets;
    }

    pub fn setBindGroupFromData(
        encoder: anytype,
        index: def.Index32,
        group: ?*bind_group.BindGroup,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        _ = encoder;
        _ = index;
        _ = group;
        _ = dynamicOffsetsData;
        _ = dynamicOffsetsDataStart;
        _ = dynamicOffsetsDataLength;
    }
};

pub const ComputePassEncoder = struct {
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
        _ = self;
        _ = target;
    }

    pub fn dispatchWorkgroups(
        self: *@This(),
        workgroupCountX: def.Size32,
        workgroupCountY: def.Size32,
        workgroupCountZ: def.Size32,
    ) void {
        _ = self;
        _ = workgroupCountX;
        _ = workgroupCountY;
        _ = workgroupCountZ;
    }

    pub fn dispatchWorkgroupsIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        _ = self;
        _ = indirectBuffer;
        _ = indirectOffset;
    }

    pub fn end(self: *@This()) void {
        _ = self;
    }

    pub fn setBindGroup(self: *@This(), index: def.Index32, group: ?*bind_group.BindGroup, dynamicOffsets: []const def.BufferDynamicOffset) void {
        BindingCommands.setBindGroup(self, index, group, dynamicOffsets);
    }

    pub fn setBindGroupFromData(
        self: *@This(),
        index: def.Index32,
        group: ?*bind_group.BindGroup,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        BindingCommands.setBindGroupFromData(self, index, group, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength);
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        _ = self;
        _ = groupLabel;
    }

    pub fn popDebugGroup(self: *@This()) void {
        _ = self;
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        _ = self;
        _ = markerLabel;
    }
};

pub const RenderPassEncoder = struct {
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

    pub const AttachmentView = union(enum) {
        texture: *texture.Texture,
        texture_view: *texture.Texture.View,
    };

    pub const ColorAttachment = struct {
        view: AttachmentView,
        depthSlice: ?def.IntegerCoordinate = null,
        resolveTarget: ?AttachmentView = null,
        clearValue: ?def.Color = null,
        loadOp: LoadOp,
        storeOp: StoreOp,
    };

    pub const DepthStencilAttachment = struct {
        view: AttachmentView,
        depthClearValue: ?f32 = null,
        depthLoadOp: ?LoadOp = null,
        depthStoreOp: ?StoreOp = null,
        depthReadOnly: bool = false,
        stencilClearValue: def.StencilValue = 0,
        stencilLoadOp: ?LoadOp = null,
        stencilStoreOp: ?StoreOp = null,
        stencilReadOnly: bool = false,
    };

    pub const LoadOp = enum {
        load,
        clear,
    };

    pub const StoreOp = enum {
        store,
        discard,
    };

    pub fn setViewport(self: *@This(), x: f32, y: f32, width: f32, height: f32, minDepth: f32, maxDepth: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = minDepth;
        _ = maxDepth;
    }

    pub fn setScissorRect(self: *@This(), x: def.IntegerCoordinate, y: def.IntegerCoordinate, width: def.IntegerCoordinate, height: def.IntegerCoordinate) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
    }

    pub fn setBlendConstant(self: *@This(), color: def.Color) void {
        _ = self;
        _ = color;
    }

    pub fn setStencilReference(self: *@This(), reference: def.StencilValue) void {
        _ = self;
        _ = reference;
    }

    pub fn beginOcclusionQuery(self: *@This(), queryIndex: def.Size32) void {
        _ = self;
        _ = queryIndex;
    }

    pub fn endOcclusionQuery(self: *@This()) void {
        _ = self;
    }

    pub fn executeBundles(self: *@This(), bundles: []const RenderBundle) void {
        _ = self;
        _ = bundles;
    }

    pub fn end(self: *@This()) void {
        _ = self;
    }

    pub fn setPipeline(self: *@This(), target: *pipeline.RenderPipeline) void {
        _ = self;
        _ = target;
    }

    pub fn setIndexBuffer(self: *@This(), target: *buffer.Buffer, indexFormat: pipeline.IndexFormat, offset: def.Size64, size: ?def.Size64) void {
        _ = self;
        _ = target;
        _ = indexFormat;
        _ = offset;
        _ = size;
    }

    pub fn setVertexBuffer(self: *@This(), slot: def.Index32, target: ?*buffer.Buffer, offset: def.Size64, size: ?def.Size64) void {
        _ = self;
        _ = slot;
        _ = target;
        _ = offset;
        _ = size;
    }

    pub fn draw(self: *@This(), vertexCount: def.Size32, instanceCount: def.Size32, firstVertex: def.Size32, firstInstance: def.Size32) void {
        _ = self;
        _ = vertexCount;
        _ = instanceCount;
        _ = firstVertex;
        _ = firstInstance;
    }

    pub fn drawIndexed(
        self: *@This(),
        indexCount: def.Size32,
        instanceCount: def.Size32,
        firstIndex: def.Size32,
        baseVertex: def.SignedOffset32,
        firstInstance: def.Size32,
    ) void {
        _ = self;
        _ = indexCount;
        _ = instanceCount;
        _ = firstIndex;
        _ = baseVertex;
        _ = firstInstance;
    }

    pub fn drawIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        _ = self;
        _ = indirectBuffer;
        _ = indirectOffset;
    }

    pub fn drawIndexedIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        _ = self;
        _ = indirectBuffer;
        _ = indirectOffset;
    }

    pub fn setBindGroup(self: *@This(), index: def.Index32, group: ?*bind_group.BindGroup, dynamicOffsets: []const def.BufferDynamicOffset) void {
        BindingCommands.setBindGroup(self, index, group, dynamicOffsets);
    }

    pub fn setBindGroupFromData(
        self: *@This(),
        index: def.Index32,
        group: ?*bind_group.BindGroup,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        BindingCommands.setBindGroupFromData(self, index, group, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength);
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        _ = self;
        _ = groupLabel;
    }

    pub fn popDebugGroup(self: *@This()) void {
        _ = self;
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        _ = self;
        _ = markerLabel;
    }
};

pub const RenderPassLayout = struct {
    label: ?[*:0]const u8 = null,
    colorFormats: []const ?texture.Texture.Format,
    depthStencilFormat: ?texture.Texture.Format = null,
    sampleCount: def.Size32 = 1,
};

pub const RenderBundle = struct {
    label: ?[*:0]const u8 = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };
};

pub const RenderBundleEncoder = struct {
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
        _ = self;
        return .{ .label = if (descriptor) |d| d.label else null };
    }

    pub fn setPipeline(self: *@This(), target: *pipeline.RenderPipeline) void {
        _ = self;
        _ = target;
    }

    pub fn setIndexBuffer(self: *@This(), target: *buffer.Buffer, indexFormat: pipeline.IndexFormat, offset: def.Size64, size: ?def.Size64) void {
        _ = self;
        _ = target;
        _ = indexFormat;
        _ = offset;
        _ = size;
    }

    pub fn setVertexBuffer(self: *@This(), slot: def.Index32, target: ?*buffer.Buffer, offset: def.Size64, size: ?def.Size64) void {
        _ = self;
        _ = slot;
        _ = target;
        _ = offset;
        _ = size;
    }

    pub fn draw(self: *@This(), vertexCount: def.Size32, instanceCount: def.Size32, firstVertex: def.Size32, firstInstance: def.Size32) void {
        _ = self;
        _ = vertexCount;
        _ = instanceCount;
        _ = firstVertex;
        _ = firstInstance;
    }

    pub fn drawIndexed(
        self: *@This(),
        indexCount: def.Size32,
        instanceCount: def.Size32,
        firstIndex: def.Size32,
        baseVertex: def.SignedOffset32,
        firstInstance: def.Size32,
    ) void {
        _ = self;
        _ = indexCount;
        _ = instanceCount;
        _ = firstIndex;
        _ = baseVertex;
        _ = firstInstance;
    }

    pub fn drawIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        _ = self;
        _ = indirectBuffer;
        _ = indirectOffset;
    }

    pub fn drawIndexedIndirect(self: *@This(), indirectBuffer: *buffer.Buffer, indirectOffset: def.Size64) void {
        _ = self;
        _ = indirectBuffer;
        _ = indirectOffset;
    }

    pub fn setBindGroup(self: *@This(), index: def.Index32, group: ?*bind_group.BindGroup, dynamicOffsets: []const def.BufferDynamicOffset) void {
        BindingCommands.setBindGroup(self, index, group, dynamicOffsets);
    }

    pub fn setBindGroupFromData(
        self: *@This(),
        index: def.Index32,
        group: ?*bind_group.BindGroup,
        dynamicOffsetsData: []const u32,
        dynamicOffsetsDataStart: def.Size64,
        dynamicOffsetsDataLength: def.Size32,
    ) void {
        BindingCommands.setBindGroupFromData(self, index, group, dynamicOffsetsData, dynamicOffsetsDataStart, dynamicOffsetsDataLength);
    }

    pub fn pushDebugGroup(self: *@This(), groupLabel: []const u8) void {
        _ = self;
        _ = groupLabel;
    }

    pub fn popDebugGroup(self: *@This()) void {
        _ = self;
    }

    pub fn insertDebugMarker(self: *@This(), markerLabel: []const u8) void {
        _ = self;
        _ = markerLabel;
    }
};
