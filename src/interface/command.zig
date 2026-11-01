//! Backend-neutral command recording for graphics work.

const pipeline = @import("pipeline.zig");
const resource = @import("resource.zig");
const binding = @import("binding.zig");

/// Action performed on an attachment when a render pass begins.
pub const LoadOp = enum { load, clear, discard };
/// Action performed on an attachment when a render pass ends.
pub const StoreOp = enum { store, discard };
/// Linear RGBA colour used when clearing a colour attachment.
pub const Color = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };
/// Colour target and its render-pass load/store behaviour.
pub const ColorAttachment = struct { view: resource.TextureView, resolve_target: ?resource.TextureView = null, load_op: LoadOp = .clear, store_op: StoreOp = .store, clear_value: Color = .{} };
pub const DepthStencilAttachment = struct {
    view: resource.TextureView,
    depth_load_op: LoadOp = .clear,
    depth_store_op: StoreOp = .store,
    depth_clear: f32 = 1,
    depth_read_only: bool = false,
    stencil_load_op: LoadOp = .clear,
    stencil_store_op: StoreOp = .store,
    stencil_clear: u8 = 0,
    stencil_read_only: bool = false,
};
/// Attachments used by one render pass.
pub const RenderPassDescriptor = struct { label: ?[]const u8 = null, color_attachments: []const ColorAttachment = &.{}, depth_stencil_attachment: ?DepthStencilAttachment = null };
/// Allocation and reset hints for a command pool.
pub const CommandPoolKind = enum { graphics, compute, copy };
pub const CommandPoolDescriptor = struct { label: ?[]const u8 = null, kind: CommandPoolKind = .graphics, transient: bool = false, reset_individually: bool = true };
/// Parameters used to allocate a command buffer from a pool.
pub const CommandBufferDescriptor = struct { label: ?[]const u8 = null };
/// Opaque backend command-pool handle.
pub const CommandPool = struct {
    handle: u64 = 0,
    vtable: *const VTable,

    pub const VTable = struct {
        deinitFn: *const fn (CommandPool) void,
        resetFn: *const fn (CommandPool) anyerror!void,
        createCommandBufferFn: *const fn (CommandPool, CommandBufferDescriptor) anyerror!CommandBuffer,
    };

    /// Make a pool to allocate command buffers from, for queues of `desc.kind`. Pools aren't
    /// thread-safe: record from one thread per pool.
    pub fn init(device: anytype, desc: CommandPoolDescriptor) !CommandPool {
        return if (device.vtable.createCommandPoolFn) |f| f(device.ptr, desc) else error.Unsupported;
    }

    /// Reclaim the memory of every command buffer allocated from the pool. Fails with
    /// `CommandBuffersStillAlive` until they have all been destroyed.
    pub fn reset(self: CommandPool) !void {
        return self.vtable.resetFn(self);
    }

    /// Destroy the pool, after every command buffer allocated from it.
    pub fn deinit(self: CommandPool) void {
        self.vtable.deinitFn(self);
    }
};
/// Integer width used by an index buffer.
pub const IndexFormat = enum { uint16, uint32 };
/// Floating-point viewport in the D3D/Metal convention: top-left origin,
/// positive width/height, and depth values in `[0, 1]`.
pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};
/// Integer scissor rectangle used to clip fragments.
pub const ScissorRect = struct { x: u32 = 0, y: u32 = 0, width: u32, height: u32 };
/// Three-dimensional texture origin.
pub const Origin3D = struct { x: u32 = 0, y: u32 = 0, z: u32 = 0 };
/// Three-dimensional copy extent.
pub const Extent3D = struct { width: u32, height: u32 = 1, depth: u32 = 1 };
pub const TextureSubresourceRange = struct { base_mip: u32 = 0, mip_count: ?u32 = null, base_layer: u32 = 0, layer_count: ?u32 = null, aspect: resource.TextureAspect = .all };
pub const BufferState = enum { common, copy_source, copy_destination, vertex, index, uniform, storage_read, storage_write, indirect, host_read, host_write };
pub const TextureState = enum { common, copy_source, copy_destination, resolve_source, resolve_destination, sampled, storage_read, storage_write, color_attachment, depth_stencil_read, depth_stencil_write, present };
pub const ResourceBarrier = union(enum) {
    buffer: struct { buffer: resource.Buffer, before: BufferState, after: BufferState },
    texture: struct { texture: resource.Texture, before: TextureState, after: TextureState, range: TextureSubresourceRange = .{} },
    texture_view: struct { view: resource.TextureView, before: TextureState, after: TextureState },
};
pub const QueryType = enum { occlusion, timestamp };
pub const QuerySetDescriptor = struct { label: ?[]const u8 = null, kind: QueryType, count: u32 };
pub const QuerySet = struct {
    handle: u64 = 0,
    vtable: *const VTable,
    pub const VTable = struct { deinitFn: *const fn (QuerySet) void };

    /// Make `desc.count` occlusion or timestamp queries. Timestamps need the
    /// `timestamp_query` feature; occlusion queries `occlusion_query`.
    pub fn init(device: anytype, desc: QuerySetDescriptor) !QuerySet {
        return if (device.vtable.createQuerySetFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
    /// Destroy the queries, once no submitted work still writes or resolves them.
    pub fn deinit(self: QuerySet) void {
        self.vtable.deinitFn(self);
    }
};
/// One texture subresource used by a copy command.
pub const TextureCopyView = struct {
    texture: resource.Texture,
    mip_level: u32 = 0,
    array_layer: u32 = 0,
    origin: Origin3D = .{},
};
/// One complete texture subresource selected for a resolve operation.
pub const TextureSubresource = struct {
    texture: resource.Texture,
    mip_level: u32 = 0,
    array_layer: u32 = 0,
};
/// Resolves one complete multisampled subresource into a single-sampled one.
pub const TextureResolveRegion = struct {
    source: TextureSubresource,
    destination: TextureSubresource,
};
/// Vertex buffer and byte offset used by a batched binding command.
pub const VertexBufferBinding = struct {
    buffer: resource.Buffer,
    offset: u64 = 0,
};
/// Buffer-to-buffer copy parameters.
pub const BufferCopyRegion = struct {
    source: resource.Buffer,
    source_offset: u64 = 0,
    destination: resource.Buffer,
    destination_offset: u64 = 0,
    size: u64,
};
/// Texture-to-texture copy parameters.
pub const TextureCopyRegion = struct {
    source: TextureCopyView,
    destination: TextureCopyView,
    extent: Extent3D,
};
/// Layout shared by buffer-to-texture and texture-to-buffer copies.
pub const BufferTextureCopyRegion = struct {
    buffer: resource.Buffer,
    buffer_offset: u64 = 0,
    /// Bytes between buffer rows; `0` asks the backend for its required alignment.
    bytes_per_row: u32 = 0,
    /// Rows between 3D image slices; `0` uses `extent.height`.
    rows_per_image: u32 = 0,
    texture: TextureCopyView,
    extent: Extent3D,
};

/// Recording interface. Backends store their encoder in `ptr`.
pub const CommandBuffer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        deinitFn: *const fn (*anyopaque) void,
        beginRenderPassFn: *const fn (*anyopaque, RenderPassDescriptor) anyerror!void,
        setGraphicsPipelineFn: *const fn (*anyopaque, pipeline.GraphicsPipeline) void,
        beginComputePassFn: *const fn (*anyopaque, ?[]const u8) anyerror!void,
        setComputePipelineFn: *const fn (*anyopaque, pipeline.ComputePipeline) void,
        setVertexBufferFn: *const fn (*anyopaque, u32, resource.Buffer, u64) void,
        setVertexBuffersFn: *const fn (*anyopaque, u32, []const VertexBufferBinding) void,
        setIndexBufferFn: *const fn (*anyopaque, resource.Buffer, IndexFormat, u64) void,
        setBindGroupFn: *const fn (*anyopaque, u32, binding.BindGroup, []const u32) void,
        setViewportFn: *const fn (*anyopaque, Viewport) void,
        setViewportsFn: *const fn (*anyopaque, []const Viewport) void,
        setScissorFn: *const fn (*anyopaque, ScissorRect) void,
        setScissorsFn: *const fn (*anyopaque, []const ScissorRect) void,
        setBlendConstantFn: *const fn (*anyopaque, Color) void,
        setStencilReferenceFn: *const fn (*anyopaque, u32) void,
        drawFn: *const fn (*anyopaque, u32, u32, u32, u32) void,
        drawIndexedFn: *const fn (*anyopaque, u32, u32, u32, i32, u32) void,
        drawIndirectFn: *const fn (*anyopaque, resource.Buffer, u64) void,
        drawIndexedIndirectFn: *const fn (*anyopaque, resource.Buffer, u64) void,
        drawIndirectMultiFn: *const fn (*anyopaque, resource.Buffer, u64, u32) void,
        drawIndexedIndirectMultiFn: *const fn (*anyopaque, resource.Buffer, u64, u32) void,
        drawIndirectCountFn: *const fn (*anyopaque, resource.Buffer, u64, resource.Buffer, u64, u32) void,
        drawIndexedIndirectCountFn: *const fn (*anyopaque, resource.Buffer, u64, resource.Buffer, u64, u32) void,
        dispatchFn: *const fn (*anyopaque, u32, u32, u32) void,
        dispatchIndirectFn: *const fn (*anyopaque, resource.Buffer, u64) void,
        endComputePassFn: *const fn (*anyopaque) void,
        endRenderPassFn: *const fn (*anyopaque) void,
        barrierFn: *const fn (*anyopaque, []const ResourceBarrier) anyerror!void,
        copyBufferFn: *const fn (*anyopaque, BufferCopyRegion) anyerror!void,
        copyTextureFn: *const fn (*anyopaque, TextureCopyRegion) anyerror!void,
        copyBufferToTextureFn: *const fn (*anyopaque, BufferTextureCopyRegion) anyerror!void,
        copyTextureToBufferFn: *const fn (*anyopaque, BufferTextureCopyRegion) anyerror!void,
        resolveTextureFn: *const fn (*anyopaque, TextureResolveRegion) anyerror!void,
        resetQueriesFn: *const fn (*anyopaque, QuerySet, u32, u32) void,
        beginQueryFn: *const fn (*anyopaque, QuerySet, u32) void,
        endQueryFn: *const fn (*anyopaque, QuerySet, u32) void,
        writeTimestampFn: *const fn (*anyopaque, QuerySet, u32) void,
        resolveQueriesFn: *const fn (*anyopaque, QuerySet, u32, u32, resource.Buffer, u64) void,
        beginDebugGroupFn: *const fn (*anyopaque, []const u8) void,
        endDebugGroupFn: *const fn (*anyopaque) void,
        insertDebugMarkerFn: *const fn (*anyopaque, []const u8) void,
        finishFn: *const fn (*anyopaque) anyerror!void,
    };
    /// Allocate a command buffer from `pool`, ready to record. Record, `finish`, then submit it
    /// to a queue of the pool's kind; destroy it once the GPU has run it.
    pub fn init(pool: CommandPool, desc: CommandBufferDescriptor) !CommandBuffer {
        return pool.vtable.createCommandBufferFn(pool, desc);
    }
    /// Free the command buffer. The GPU must have finished running it.
    pub fn deinit(self: CommandBuffer) void {
        self.vtable.deinitFn(self.ptr);
    }
    /// Begins a render pass targeting the supplied attachments.
    pub fn beginRenderPass(self: CommandBuffer, desc: RenderPassDescriptor) !void {
        return self.vtable.beginRenderPassFn(self.ptr, desc);
    }
    /// Binds graphics-pipeline state for subsequent draw commands.
    pub fn setGraphicsPipeline(self: CommandBuffer, value: pipeline.GraphicsPipeline) void {
        self.vtable.setGraphicsPipelineFn(self.ptr, value);
    }
    /// Start a compute pass: set a compute pipeline and its bind groups, then `dispatch`.
    /// Barriers go between passes, not inside one. `label` names the pass in GPU debuggers.
    pub fn beginComputePass(self: CommandBuffer, label: ?[]const u8) !void {
        return self.vtable.beginComputePassFn(self.ptr, label);
    }
    /// Use `value` for the dispatches that follow in this compute pass. Set bind groups after
    /// it: they are checked against its layout.
    pub fn setComputePipeline(self: CommandBuffer, value: pipeline.ComputePipeline) void {
        self.vtable.setComputePipelineFn(self.ptr, value);
    }
    /// Binds `buffer` to a vertex slot starting at the byte `offset`.
    pub fn setVertexBuffer(self: CommandBuffer, slot: u32, buffer: resource.Buffer, offset: u64) void {
        self.vtable.setVertexBufferFn(self.ptr, slot, buffer, offset);
    }
    /// Binds consecutive vertex-buffer slots in one command.
    pub fn setVertexBuffers(self: CommandBuffer, first_slot: u32, bindings: []const VertexBufferBinding) void {
        self.vtable.setVertexBuffersFn(self.ptr, first_slot, bindings);
    }
    /// Binds an integer index buffer starting at the byte `offset`.
    pub fn setIndexBuffer(self: CommandBuffer, buffer: resource.Buffer, format: IndexFormat, offset: u64) void {
        self.vtable.setIndexBufferFn(self.ptr, buffer, format, offset);
    }
    /// Binds shader resources at a pipeline bind-group slot.
    pub fn setBindGroup(self: CommandBuffer, slot: u32, group: binding.BindGroup, dynamic_offsets: []const u32) void {
        self.vtable.setBindGroupFn(self.ptr, slot, group, dynamic_offsets);
    }
    /// Sets the viewport for subsequent draw commands.
    pub fn setViewport(self: CommandBuffer, viewport: Viewport) void {
        self.vtable.setViewportFn(self.ptr, viewport);
    }
    /// Replaces the active viewport array.
    pub fn setViewports(self: CommandBuffer, viewports: []const Viewport) void {
        self.vtable.setViewportsFn(self.ptr, viewports);
    }
    /// Sets the scissor rectangle for subsequent draw commands.
    pub fn setScissor(self: CommandBuffer, rect: ScissorRect) void {
        self.vtable.setScissorFn(self.ptr, rect);
    }
    /// Replaces the active scissor-rectangle array.
    pub fn setScissors(self: CommandBuffer, rects: []const ScissorRect) void {
        self.vtable.setScissorsFn(self.ptr, rects);
    }
    /// Sets the constant colour used by blend factors.
    pub fn setBlendConstant(self: CommandBuffer, colour: Color) void {
        self.vtable.setBlendConstantFn(self.ptr, colour);
    }
    /// Sets the reference value used by stencil tests.
    pub fn setStencilReference(self: CommandBuffer, value: u32) void {
        self.vtable.setStencilReferenceFn(self.ptr, value);
    }
    /// Records a non-indexed draw.
    pub fn draw(self: CommandBuffer, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
        self.vtable.drawFn(self.ptr, vertices, instances, first_vertex, first_instance);
    }
    /// Records an indexed, optionally instanced draw.
    pub fn drawIndexed(self: CommandBuffer, indices: u32, instances: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        self.vtable.drawIndexedFn(self.ptr, indices, instances, first_index, base_vertex, first_instance);
    }
    /// Draw with arguments the GPU reads from `buffer` at `offset`: vertex count, instance
    /// count, first vertex, first instance, as four u32s. `buffer` needs `indirect` usage.
    pub fn drawIndirect(self: CommandBuffer, buffer: resource.Buffer, offset: u64) void {
        self.vtable.drawIndirectFn(self.ptr, buffer, offset);
    }
    /// Draw indexed with arguments read from `buffer` at `offset`: index count, instance count,
    /// first index, vertex offset (i32), first instance, as five 32-bit values.
    pub fn drawIndexedIndirect(self: CommandBuffer, buffer: resource.Buffer, offset: u64) void {
        self.vtable.drawIndexedIndirectFn(self.ptr, buffer, offset);
    }
    /// Executes `draw_count` tightly packed non-indexed indirect draws.
    pub fn drawIndirectMulti(self: CommandBuffer, buffer: resource.Buffer, offset: u64, draw_count: u32) void {
        self.vtable.drawIndirectMultiFn(self.ptr, buffer, offset, draw_count);
    }
    /// Executes `draw_count` tightly packed indexed indirect draws.
    pub fn drawIndexedIndirectMulti(self: CommandBuffer, buffer: resource.Buffer, offset: u64, draw_count: u32) void {
        self.vtable.drawIndexedIndirectMultiFn(self.ptr, buffer, offset, draw_count);
    }
    /// Executes up to `max_draw_count` indirect draws, with the actual count read from `count_buffer`.
    pub fn drawIndirectCount(self: CommandBuffer, buffer: resource.Buffer, offset: u64, count_buffer: resource.Buffer, count_offset: u64, max_draw_count: u32) void {
        self.vtable.drawIndirectCountFn(self.ptr, buffer, offset, count_buffer, count_offset, max_draw_count);
    }
    /// Indexed variant of `drawIndirectCount`.
    pub fn drawIndexedIndirectCount(self: CommandBuffer, buffer: resource.Buffer, offset: u64, count_buffer: resource.Buffer, count_offset: u64, max_draw_count: u32) void {
        self.vtable.drawIndexedIndirectCountFn(self.ptr, buffer, offset, count_buffer, count_offset, max_draw_count);
    }
    /// Run the compute pipeline over `x` × `y` × `z` workgroups, each the size the shader's
    /// `numthreads` declares; round up so the groups cover the data, and bounds-check in the
    /// shader. Stay within `max_compute_workgroups` in `Adapter.capabilities().limits`.
    pub fn dispatch(self: CommandBuffer, x: u32, y: u32, z: u32) void {
        self.vtable.dispatchFn(self.ptr, x, y, z);
    }
    /// Dispatch with the workgroup counts the GPU reads from `buffer` at `offset` (three u32s),
    /// so GPU work can size the next dispatch. `buffer` needs `indirect` usage.
    pub fn dispatchIndirect(self: CommandBuffer, buffer: resource.Buffer, offset: u64) void {
        self.vtable.dispatchIndirectFn(self.ptr, buffer, offset);
    }
    /// End the active compute pass.
    pub fn endComputePass(self: CommandBuffer) void {
        self.vtable.endComputePassFn(self.ptr);
    }
    /// Ends the active render pass.
    pub fn endRenderPass(self: CommandBuffer) void {
        self.vtable.endRenderPassFn(self.ptr);
    }
    /// Order GPU work around resources changing use: each barrier says how a resource was
    /// used and how it is used next (a storage write, then a read or another storage write, as
    /// between two dispatches). Outside render and compute passes only.
    pub fn barrier(self: CommandBuffer, barriers: []const ResourceBarrier) !void {
        return self.vtable.barrierFn(self.ptr, barriers);
    }
    /// Copies bytes between buffers outside a render pass.
    pub fn copyBuffer(self: CommandBuffer, region: BufferCopyRegion) !void {
        return self.vtable.copyBufferFn(self.ptr, region);
    }
    /// Copies texels between matching texture subresources outside a render pass.
    pub fn copyTexture(self: CommandBuffer, region: TextureCopyRegion) !void {
        return self.vtable.copyTextureFn(self.ptr, region);
    }
    /// Copies a laid-out buffer region into a texture subresource.
    pub fn copyBufferToTexture(self: CommandBuffer, region: BufferTextureCopyRegion) !void {
        return self.vtable.copyBufferToTextureFn(self.ptr, region);
    }
    /// Copies a texture subresource into a laid-out buffer region.
    pub fn copyTextureToBuffer(self: CommandBuffer, region: BufferTextureCopyRegion) !void {
        return self.vtable.copyTextureToBufferFn(self.ptr, region);
    }
    /// Resolves a complete multisampled texture subresource.
    pub fn resolveTexture(self: CommandBuffer, region: TextureResolveRegion) !void {
        return self.vtable.resolveTextureFn(self.ptr, region);
    }
    /// Reset queries `first..first + count` before they are written again. Outside passes.
    pub fn resetQueries(self: CommandBuffer, set: QuerySet, first: u32, count: u32) void {
        self.vtable.resetQueriesFn(self.ptr, set, first, count);
    }
    /// Start counting samples that pass depth testing into occlusion query `index`.
    pub fn beginQuery(self: CommandBuffer, set: QuerySet, index: u32) void {
        self.vtable.beginQueryFn(self.ptr, set, index);
    }
    /// Stop the occlusion query `beginQuery` started.
    pub fn endQuery(self: CommandBuffer, set: QuerySet, index: u32) void {
        self.vtable.endQueryFn(self.ptr, set, index);
    }
    /// Write the GPU's clock into timestamp query `index` once earlier commands finish.
    /// Timestamps are raw ticks; compare two from the same queue.
    pub fn writeTimestamp(self: CommandBuffer, set: QuerySet, index: u32) void {
        self.vtable.writeTimestampFn(self.ptr, set, index);
    }
    /// Copy queries `first..first + count` into `destination` at `offset`, one u64 each, for
    /// reading back after the submit completes. `destination` needs `transfer_dst` usage.
    pub fn resolveQueries(self: CommandBuffer, set: QuerySet, first: u32, count: u32, destination: resource.Buffer, offset: u64) void {
        self.vtable.resolveQueriesFn(self.ptr, set, first, count, destination, offset);
    }
    /// Starts a named GPU debug region.
    pub fn beginDebugGroup(self: CommandBuffer, label: []const u8) void {
        self.vtable.beginDebugGroupFn(self.ptr, label);
    }
    /// Ends the current GPU debug region.
    pub fn endDebugGroup(self: CommandBuffer) void {
        self.vtable.endDebugGroupFn(self.ptr);
    }
    /// Inserts a named point into GPU debugging tools.
    pub fn insertDebugMarker(self: CommandBuffer, label: []const u8) void {
        self.vtable.insertDebugMarkerFn(self.ptr, label);
    }
    /// Ends recording and makes the command buffer ready for submission.
    pub fn finish(self: CommandBuffer) !void {
        return self.vtable.finishFn(self.ptr);
    }
};

const std = @import("std");
// Doc tests below: Zig's generated docs show each one as its type's example, and
// `zig build test` runs it, on the machine's GPU when it has one.
const vit = @import("../root.zig");
const ExampleGpu = @import("example_gpu.zig");

test CommandPool {
    const gpu = try ExampleGpu.open(.{});
    defer gpu.close();

    // One pool for each thread that records and each frame in flight. `.transient` says
    // its buffers live a frame.
    const pool = try vit.CommandPool.init(gpu.device, .{ .kind = .graphics, .transient = true });
    defer pool.deinit();
    for (0..3) |_| {
        const cmd = try vit.CommandBuffer.init(pool, .{ .label = "frame" });
        try cmd.finish();
        try gpu.queue.submit(.{ .command_buffers = &.{cmd} });
        try gpu.queue.waitIdle();
        // Once the GPU is done and the buffers are freed, reuse all their memory at once.
        cmd.deinit();
        try pool.reset();
    }
}

test CommandBuffer {
    const gpu = try ExampleGpu.open(.{});
    defer gpu.close();
    const numbers = [4]u32{ 1, 2, 3, 4 };
    const staging = try vit.Buffer.init(gpu.device, .{ .size = 16, .usage = .{ .transfer_src = true }, .memory = .upload, .initial_data = std.mem.asBytes(&numbers) });
    defer staging.deinit();
    const on_gpu = try vit.Buffer.init(gpu.device, .{ .size = 16, .usage = .{ .storage = true, .transfer_src = true, .transfer_dst = true } });
    defer on_gpu.deinit();
    const readback = try vit.Buffer.init(gpu.device, .{ .size = 16, .usage = .{ .transfer_dst = true }, .memory = .readback });
    defer readback.deinit();

    // Record, finish, submit. Vitellus inserts no barriers: move each resource into the
    // state the next command needs, as here between the two copies.
    const pool = try vit.CommandPool.init(gpu.device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.barrier(&.{
        .{ .buffer = .{ .buffer = staging, .before = .common, .after = .copy_source } },
        .{ .buffer = .{ .buffer = on_gpu, .before = .common, .after = .copy_destination } },
    });
    try cmd.copyBuffer(.{ .source = staging, .destination = on_gpu, .size = 16 });
    try cmd.barrier(&.{
        .{ .buffer = .{ .buffer = on_gpu, .before = .copy_destination, .after = .copy_source } },
        .{ .buffer = .{ .buffer = readback, .before = .common, .after = .copy_destination } },
    });
    try cmd.copyBuffer(.{ .source = on_gpu, .destination = readback, .size = 16 });
    try cmd.barrier(&.{.{ .buffer = .{ .buffer = readback, .before = .copy_destination, .after = .host_read } }});
    try cmd.finish();
    try gpu.queue.submit(.{ .command_buffers = &.{cmd} });
    try gpu.queue.waitIdle();

    const read = try readback.map(.read, .{ .size = 16 });
    defer readback.unmap(null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&numbers), read[0..16]);
}

test QuerySet {
    const gpu = try ExampleGpu.open(.{ .required_features = .{ .timestamp_query = true } });
    defer gpu.close();

    // Two timestamps around the GPU work to time, resolved into a buffer to read.
    const queries = try vit.QuerySet.init(gpu.device, .{ .kind = .timestamp, .count = 2 });
    defer queries.deinit();
    const results = try vit.Buffer.init(gpu.device, .{ .size = 2 * @sizeOf(u64), .usage = .{ .query_resolve = true, .transfer_dst = true }, .memory = .readback });
    defer results.deinit();
    const pool = try vit.CommandPool.init(gpu.device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    cmd.resetQueries(queries, 0, 2);
    cmd.writeTimestamp(queries, 0);
    // The work being timed goes here.
    cmd.writeTimestamp(queries, 1);
    try cmd.barrier(&.{.{ .buffer = .{ .buffer = results, .before = .common, .after = .copy_destination } }});
    cmd.resolveQueries(queries, 0, 2, results, 0);
    try cmd.barrier(&.{.{ .buffer = .{ .buffer = results, .before = .copy_destination, .after = .host_read } }});
    try cmd.finish();
    try gpu.queue.submit(.{ .command_buffers = &.{cmd} });
    try gpu.queue.waitIdle();

    // Raw GPU ticks, whose length depends on the backend and GPU.
    const read = try results.map(.read, .{ .size = 2 * @sizeOf(u64) });
    defer results.unmap(null);
    var ticks: [2]u64 = undefined;
    @memcpy(std.mem.asBytes(&ticks), read[0 .. 2 * @sizeOf(u64)]);
    try std.testing.expect(ticks[1] >= ticks[0]);
}
