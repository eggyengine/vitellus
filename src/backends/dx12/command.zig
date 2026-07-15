//! DirectX 12 command allocator and graphics-list recording.

const std = @import("std");
const command = @import("../../interface/command.zig");
const pipeline = @import("../../interface/pipeline.zig");
const resource_interface = @import("../../interface/resource.zig");
const pipeline_impl = @import("pipeline.zig");
const resource = @import("resource.zig");
const binding_impl = @import("binding.zig");
const Dx12Device = @import("device.zig").Dx12Device;
const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

pub const Dx12QuerySet = struct {
    allocator: std.mem.Allocator,
    heap: ComPtr(dx.ID3D12QueryHeap) = .{},
    kind: command.QueryType,
    count: u32,
    fn fromHandle(value: command.QuerySet) !*Dx12QuerySet {
        if (value.handle == 0) return error.InvalidQuerySet;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const Dx12CommandBuffer = struct {
    allocator: std.mem.Allocator,
    command_allocator: ComPtr(dx.ID3D12CommandAllocator) = .{},
    list: ComPtr(dx.ID3D12GraphicsCommandList) = .{},
    finished: bool = false,
    active_pipeline: ?*pipeline_impl.Dx12GraphicsPipeline = null,
    active_compute_pipeline: ?*pipeline_impl.Dx12ComputePipeline = null,
    device: ?*Dx12Device = null,
    pool: *Dx12CommandPool,
    attachments: [8]?*resource.Dx12TextureView = [_]?*resource.Dx12TextureView{null} ** 8,
    resolve_attachments: [8]?*resource.Dx12TextureView = [_]?*resource.Dx12TextureView{null} ** 8,
    discard_at_end: [8]bool = [_]bool{false} ** 8,
    attachment_count: usize = 0,
    depth_attachment: ?*resource.Dx12TextureView = null,
    discard_depth_at_end: bool = false,
    in_render_pass: bool = false,
    in_compute_pass: bool = false,
    draw_signature: ComPtr(dx.ID3D12CommandSignature) = .{},
    draw_indexed_signature: ComPtr(dx.ID3D12CommandSignature) = .{},
    dispatch_signature: ComPtr(dx.ID3D12CommandSignature) = .{},
    dynamic_descriptors: [64]Dx12Device.DescriptorAllocation = undefined,
    dynamic_descriptor_count: usize = 0,

    pub fn fromCommandBuffer(value: command.CommandBuffer) *Dx12CommandBuffer {
        return @ptrCast(@alignCast(value.ptr));
    }
};

const Dx12CommandPool = struct {
    allocator: std.mem.Allocator,
    owner: *Dx12Device,
    device: *dx.ID3D12Device,
    kind: command.CommandPoolKind,
    live_buffers: usize = 0,

    fn fromHandle(value: command.CommandPool) !*Dx12CommandPool {
        if (value.handle == 0) return error.InvalidCommandPool;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const pool_vtable: command.CommandPool.VTable = .{
    .deinitFn = destroyPool,
    .resetFn = resetPool,
    .createCommandBufferFn = createBuffer,
};
const query_set_vtable: command.QuerySet.VTable = .{ .deinitFn = destroyQuerySet };

pub const command_buffer_vtable: command.CommandBuffer.VTable = .{
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

pub fn createPool(ptr: *anyopaque, desc: command.CommandPoolDescriptor) anyerror!command.CommandPool {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12CommandPool);
    self.* = .{ .allocator = device.allocator, .owner = device, .device = device.device.unwrap(), .kind = desc.kind };
    errdefer device.allocator.destroy(self);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &pool_vtable };
}

pub fn createBuffer(value: command.CommandPool) anyerror!command.CommandBuffer {
    const pool = try Dx12CommandPool.fromHandle(value);
    const self = try pool.allocator.create(Dx12CommandBuffer);
    self.* = .{ .allocator = pool.allocator, .pool = pool, .device = pool.owner };
    errdefer pool.allocator.destroy(self);
    const list_type = commandListType(pool.kind);
    try checkHr(pool.device.lpVtbl.*.CreateCommandAllocator.?(pool.device, list_type, &dx.IID_ID3D12CommandAllocator, @ptrCast(self.command_allocator.put())));
    errdefer self.command_allocator.deinit();
    try checkHr(pool.device.lpVtbl.*.CreateCommandList.?(pool.device, 0, list_type, self.command_allocator.unwrap(), null, &dx.IID_ID3D12GraphicsCommandList, @ptrCast(self.list.put())));
    pool.live_buffers += 1;
    return .{ .ptr = self, .vtable = &command_buffer_vtable };
}

pub fn destroyPool(value: command.CommandPool) void {
    const self = Dx12CommandPool.fromHandle(value) catch return;
    const allocator = self.allocator;
    if (self.live_buffers != 0) return;
    allocator.destroy(self);
}

pub fn resetPool(value: command.CommandPool) anyerror!void {
    const self = try Dx12CommandPool.fromHandle(value);
    if (self.live_buffers != 0) return error.CommandBuffersStillAlive;
}

pub fn destroyBuffer(ptr: *anyopaque) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    self.dispatch_signature.deinit();
    self.draw_indexed_signature.deinit();
    self.draw_signature.deinit();
    if (self.device) |device| for (self.dynamic_descriptors[0..self.dynamic_descriptor_count]) |allocation| device.freeResourceDescriptors(allocation.index, allocation.count);
    self.list.deinit();
    self.command_allocator.deinit();
    self.pool.live_buffers -= 1;
    self.allocator.destroy(self);
}

pub fn createQuerySet(ptr: *anyopaque, desc: command.QuerySetDescriptor) anyerror!command.QuerySet {
    if (desc.count == 0) return error.InvalidQueryCount;
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12QuerySet);
    self.* = .{ .allocator = device.allocator, .kind = desc.kind, .count = desc.count };
    errdefer device.allocator.destroy(self);
    const heap_desc = dx.D3D12_QUERY_HEAP_DESC{
        .Type = if (desc.kind == .occlusion) dx.D3D12_QUERY_HEAP_TYPE_OCCLUSION else dx.D3D12_QUERY_HEAP_TYPE_TIMESTAMP,
        .Count = desc.count,
        .NodeMask = 0,
    };
    try checkHr(device.device.unwrap().lpVtbl.*.CreateQueryHeap.?(device.device.unwrap(), &heap_desc, &dx.IID_ID3D12QueryHeap, @ptrCast(self.heap.put())));
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &query_set_vtable };
}

pub fn destroyQuerySet(value: command.QuerySet) void {
    const self = Dx12QuerySet.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.heap.deinit();
    allocator.destroy(self);
}

fn beginRenderPass(ptr: *anyopaque, desc: command.RenderPassDescriptor) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.pool.kind != .graphics) return error.InvalidCommandPoolKind;
    if (self.in_render_pass) return error.RenderPassAlreadyActive;
    if ((desc.color_attachments.len == 0 and desc.depth_stencil_attachment == null) or desc.color_attachments.len > self.attachments.len) return error.InvalidAttachments;

    var handles: [8]dx.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
    const list = self.list.unwrap();
    for (desc.color_attachments, 0..) |attachment, i| {
        const view = try resource.Dx12TextureView.fromHandle(attachment.view);
        if (view.rtv.ptr == 0) return error.InvalidColorAttachment;
        handles[i] = view.rtv;
        self.attachments[i] = view;
        self.resolve_attachments[i] = if (attachment.resolve_target) |target| try resource.Dx12TextureView.fromHandle(target) else null;
        self.discard_at_end[i] = attachment.store_op == .discard;
        switch (attachment.load_op) {
            .load => {},
            .discard => list.lpVtbl.*.DiscardResource.?(list, view.resource, null),
            .clear => {
                const color = [4]f32{ attachment.clear_value.r, attachment.clear_value.g, attachment.clear_value.b, attachment.clear_value.a };
                list.lpVtbl.*.ClearRenderTargetView.?(list, view.rtv, &color, 0, null);
            },
        }
    }
    self.attachment_count = desc.color_attachments.len;
    self.in_render_pass = true;
    var dsv: ?dx.D3D12_CPU_DESCRIPTOR_HANDLE = null;
    if (desc.depth_stencil_attachment) |attachment| {
        const view = try resource.Dx12TextureView.fromHandle(attachment.view);
        if (view.dsv.ptr == 0) return error.InvalidDepthStencilAttachment;
        self.depth_attachment = view;
        self.discard_depth_at_end = attachment.depth_store_op == .discard or attachment.stencil_store_op == .discard;
        dsv = view.dsv;
        var clear_flags: dx.D3D12_CLEAR_FLAGS = 0;
        if (attachment.depth_load_op == .clear) clear_flags |= dx.D3D12_CLEAR_FLAG_DEPTH;
        if (attachment.stencil_load_op == .clear) clear_flags |= dx.D3D12_CLEAR_FLAG_STENCIL;
        if (attachment.depth_load_op == .discard or attachment.stencil_load_op == .discard) list.lpVtbl.*.DiscardResource.?(list, view.resource, null);
        if (clear_flags != 0) list.lpVtbl.*.ClearDepthStencilView.?(list, view.dsv, clear_flags, attachment.depth_clear, attachment.stencil_clear, 0, null);
    }
    list.lpVtbl.*.OMSetRenderTargets.?(list, @intCast(self.attachment_count), if (self.attachment_count == 0) null else &handles, 0, if (dsv) |*value| value else null);

    const first = if (self.attachment_count != 0) self.attachments[0].? else self.depth_attachment.?;
    const viewport = dx.D3D12_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(first.width),
        .Height = @floatFromInt(first.height),
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    const scissor = dx.D3D12_RECT{ .left = 0, .top = 0, .right = @intCast(first.width), .bottom = @intCast(first.height) };
    list.lpVtbl.*.RSSetViewports.?(list, 1, &viewport);
    list.lpVtbl.*.RSSetScissorRects.?(list, 1, &scissor);
}

fn setGraphicsPipeline(ptr: *anyopaque, value: pipeline.GraphicsPipeline) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const state = pipeline_impl.Dx12GraphicsPipeline.fromHandle(value) catch return;
    const list = self.list.unwrap();
    list.lpVtbl.*.SetGraphicsRootSignature.?(list, state.root_signature.unwrap());
    list.lpVtbl.*.SetPipelineState.?(list, state.state.unwrap());
    list.lpVtbl.*.IASetPrimitiveTopology.?(list, state.topology);
    self.active_pipeline = state;
}

fn beginComputePass(ptr: *anyopaque, label: ?[]const u8) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.pool.kind == .copy) return error.InvalidCommandPoolKind;
    if (self.in_render_pass or self.in_compute_pass) return error.PassAlreadyActive;
    self.in_compute_pass = true;
    if (label) |value| beginDebugGroup(ptr, value);
}

fn setComputePipeline(ptr: *anyopaque, value: pipeline.ComputePipeline) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const state = pipeline_impl.Dx12ComputePipeline.fromHandle(value) catch return;
    const list = self.list.unwrap();
    list.lpVtbl.*.SetComputeRootSignature.?(list, state.layout.root_signature.unwrap());
    list.lpVtbl.*.SetPipelineState.?(list, state.state.unwrap());
    self.active_compute_pipeline = state;
}

fn setVertexBuffer(ptr: *anyopaque, slot: u32, value: resource_interface.Buffer, offset: u64) void {
    const bindings = [_]command.VertexBufferBinding{.{ .buffer = value, .offset = offset }};
    setVertexBuffers(ptr, slot, &bindings);
}

fn setVertexBuffers(ptr: *anyopaque, first_slot: u32, bindings: []const command.VertexBufferBinding) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const state = self.active_pipeline orelse return;
    if (bindings.len == 0 or bindings.len > 32 or first_slot > state.vertex_buffer_count or bindings.len > state.vertex_buffer_count - first_slot) return;
    var views: [32]dx.D3D12_VERTEX_BUFFER_VIEW = undefined;
    for (bindings, 0..) |binding, i| {
        const buffer = resource.Dx12Buffer.fromHandle(binding.buffer) catch return;
        if (binding.offset >= buffer.size) return;
        views[i] = .{
            .BufferLocation = buffer.resource.unwrap().lpVtbl.*.GetGPUVirtualAddress.?(buffer.resource.unwrap()) + binding.offset,
            .SizeInBytes = @intCast(@min(buffer.size - binding.offset, std.math.maxInt(u32))),
            .StrideInBytes = state.vertex_strides[first_slot + @as(u32, @intCast(i))],
        };
    }
    self.list.unwrap().lpVtbl.*.IASetVertexBuffers.?(self.list.unwrap(), first_slot, @intCast(bindings.len), &views);
}

fn setIndexBuffer(ptr: *anyopaque, value: resource_interface.Buffer, format: command.IndexFormat, offset: u64) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const buffer = resource.Dx12Buffer.fromHandle(value) catch return;
    const alignment: u64 = if (format == .uint16) 2 else 4;
    if (offset >= buffer.size or offset % alignment != 0) return;
    const view = dx.D3D12_INDEX_BUFFER_VIEW{
        .BufferLocation = buffer.resource.unwrap().lpVtbl.*.GetGPUVirtualAddress.?(buffer.resource.unwrap()) + offset,
        .SizeInBytes = @intCast(@min(buffer.size - offset, std.math.maxInt(u32))),
        .Format = if (format == .uint16) dx.DXGI_FORMAT_R16_UINT else dx.DXGI_FORMAT_R32_UINT,
    };
    self.list.unwrap().lpVtbl.*.IASetIndexBuffer.?(self.list.unwrap(), &view);
}

fn setBindGroup(ptr: *anyopaque, slot: u32, value: @import("../../interface/binding.zig").BindGroup, dynamic_offsets: []const u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const group = binding_impl.Dx12BindGroup.fromHandle(value) catch return;
    const device = self.device orelse return;
    var roots: pipeline_impl.BindGroupRoots = .{};
    var compute = false;
    if (self.in_compute_pass) {
        const state = self.active_compute_pipeline orelse return;
        if (slot >= state.layout.bind_group_count or group.layout != state.layout.bind_group_layouts[slot]) return;
        roots = state.layout.bind_group_roots[slot];
        compute = true;
    } else {
        const state = self.active_pipeline orelse return;
        if (slot >= state.bind_group_count or group.layout != state.bind_group_layouts[slot]) return;
        roots = state.bind_group_roots[slot];
    }
    var expected_offsets: usize = 0;
    for (group.layout.entries) |entry| if (entry.kind == .buffer and entry.kind.buffer.dynamic_offset) {
        expected_offsets += entry.count;
    };
    if (dynamic_offsets.len != expected_offsets) return;
    var heaps = [_]?*dx.ID3D12DescriptorHeap{ device.resource_heap.get(), device.sampler_heap.get() };
    self.list.unwrap().lpVtbl.*.SetDescriptorHeaps.?(self.list.unwrap(), 2, @ptrCast(&heaps));
    var resource_handle = group.resources;
    if (dynamic_offsets.len != 0) {
        if (self.dynamic_descriptor_count == self.dynamic_descriptors.len) return;
        const allocation = binding_impl.dynamicResources(device, group, dynamic_offsets) catch return;
        self.dynamic_descriptors[self.dynamic_descriptor_count] = allocation;
        self.dynamic_descriptor_count += 1;
        resource_handle = allocation.gpu;
    }
    if (resource_handle) |handle| if (roots.resources) |root| {
        if (compute) self.list.unwrap().lpVtbl.*.SetComputeRootDescriptorTable.?(self.list.unwrap(), root, handle) else self.list.unwrap().lpVtbl.*.SetGraphicsRootDescriptorTable.?(self.list.unwrap(), root, handle);
    };
    if (group.samplers) |handle| if (roots.samplers) |root| {
        if (compute) self.list.unwrap().lpVtbl.*.SetComputeRootDescriptorTable.?(self.list.unwrap(), root, handle) else self.list.unwrap().lpVtbl.*.SetGraphicsRootDescriptorTable.?(self.list.unwrap(), root, handle);
    };
}

fn setViewport(ptr: *anyopaque, value: command.Viewport) void {
    const values = [_]command.Viewport{value};
    setViewports(ptr, &values);
}

fn setViewports(ptr: *anyopaque, values: []const command.Viewport) void {
    if (values.len == 0 or values.len > 16) return;
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    var viewports: [16]dx.D3D12_VIEWPORT = undefined;
    for (values, 0..) |value, i| viewports[i] = .{
        .TopLeftX = value.x,
        .TopLeftY = value.y,
        .Width = value.width,
        .Height = value.height,
        .MinDepth = value.min_depth,
        .MaxDepth = value.max_depth,
    };
    self.list.unwrap().lpVtbl.*.RSSetViewports.?(self.list.unwrap(), @intCast(values.len), &viewports);
}

fn setScissor(ptr: *anyopaque, value: command.ScissorRect) void {
    const values = [_]command.ScissorRect{value};
    setScissors(ptr, &values);
}

fn setScissors(ptr: *anyopaque, values: []const command.ScissorRect) void {
    if (values.len == 0 or values.len > 16) return;
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const max = std.math.maxInt(i32);
    var rects: [16]dx.D3D12_RECT = undefined;
    for (values, 0..) |value, i| rects[i] = .{
        .left = @intCast(@min(value.x, max)),
        .top = @intCast(@min(value.y, max)),
        .right = @intCast(@min(@as(u64, value.x) + value.width, max)),
        .bottom = @intCast(@min(@as(u64, value.y) + value.height, max)),
    };
    self.list.unwrap().lpVtbl.*.RSSetScissorRects.?(self.list.unwrap(), @intCast(values.len), &rects);
}

fn setBlendConstant(ptr: *anyopaque, value: command.Color) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const colour = [4]f32{ value.r, value.g, value.b, value.a };
    self.list.unwrap().lpVtbl.*.OMSetBlendFactor.?(self.list.unwrap(), &colour);
}

fn setStencilReference(ptr: *anyopaque, value: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    self.list.unwrap().lpVtbl.*.OMSetStencilRef.?(self.list.unwrap(), value);
}

fn draw(ptr: *anyopaque, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (!self.in_render_pass) return;
    self.list.unwrap().lpVtbl.*.DrawInstanced.?(self.list.unwrap(), vertices, instances, first_vertex, first_instance);
}

fn drawIndexed(ptr: *anyopaque, indices: u32, instances: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (!self.in_render_pass) return;
    self.list.unwrap().lpVtbl.*.DrawIndexedInstanced.?(self.list.unwrap(), indices, instances, first_index, base_vertex, first_instance);
}

fn drawIndirect(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64) void {
    executeIndirect(ptr, value, offset, 1, null, 0, .draw);
}
fn drawIndexedIndirect(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64) void {
    executeIndirect(ptr, value, offset, 1, null, 0, .draw_indexed);
}
fn drawIndirectMulti(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64, count: u32) void {
    executeIndirect(ptr, value, offset, count, null, 0, .draw);
}
fn drawIndexedIndirectMulti(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64, count: u32) void {
    executeIndirect(ptr, value, offset, count, null, 0, .draw_indexed);
}
fn drawIndirectCount(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64, count_buffer: resource_interface.Buffer, count_offset: u64, max_count: u32) void {
    executeIndirect(ptr, value, offset, max_count, count_buffer, count_offset, .draw);
}
fn drawIndexedIndirectCount(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64, count_buffer: resource_interface.Buffer, count_offset: u64, max_count: u32) void {
    executeIndirect(ptr, value, offset, max_count, count_buffer, count_offset, .draw_indexed);
}
fn dispatchIndirect(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64) void {
    executeIndirect(ptr, value, offset, 1, null, 0, .dispatch);
}

fn dispatch(ptr: *anyopaque, x: u32, y: u32, z: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (!self.in_compute_pass) return;
    self.list.unwrap().lpVtbl.*.Dispatch.?(self.list.unwrap(), x, y, z);
}

fn endComputePass(ptr: *anyopaque) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (!self.in_compute_pass) return;
    self.in_compute_pass = false;
    self.active_compute_pipeline = null;
}

fn resetQueries(_: *anyopaque, _: command.QuerySet, _: u32, _: u32) void {}

fn beginQuery(ptr: *anyopaque, value: command.QuerySet, index: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const set = Dx12QuerySet.fromHandle(value) catch return;
    if (set.kind != .occlusion or index >= set.count) return;
    self.list.unwrap().lpVtbl.*.BeginQuery.?(self.list.unwrap(), set.heap.unwrap(), dx.D3D12_QUERY_TYPE_OCCLUSION, index);
}

fn endQuery(ptr: *anyopaque, value: command.QuerySet, index: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const set = Dx12QuerySet.fromHandle(value) catch return;
    if (set.kind != .occlusion or index >= set.count) return;
    self.list.unwrap().lpVtbl.*.EndQuery.?(self.list.unwrap(), set.heap.unwrap(), dx.D3D12_QUERY_TYPE_OCCLUSION, index);
}

fn writeTimestamp(ptr: *anyopaque, value: command.QuerySet, index: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const set = Dx12QuerySet.fromHandle(value) catch return;
    if (set.kind != .timestamp or index >= set.count) return;
    self.list.unwrap().lpVtbl.*.EndQuery.?(self.list.unwrap(), set.heap.unwrap(), dx.D3D12_QUERY_TYPE_TIMESTAMP, index);
}

fn resolveQueries(ptr: *anyopaque, value: command.QuerySet, first: u32, count: u32, destination: resource_interface.Buffer, offset: u64) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const set = Dx12QuerySet.fromHandle(value) catch return;
    const buffer = resource.Dx12Buffer.fromHandle(destination) catch return;
    if (count == 0 or first + count > set.count or offset + @as(u64, count) * 8 > buffer.size) return;
    const kind: dx.D3D12_QUERY_TYPE = if (set.kind == .occlusion) dx.D3D12_QUERY_TYPE_OCCLUSION else dx.D3D12_QUERY_TYPE_TIMESTAMP;
    self.list.unwrap().lpVtbl.*.ResolveQueryData.?(self.list.unwrap(), set.heap.unwrap(), kind, first, count, buffer.resource.unwrap(), offset);
}

fn endRenderPass(ptr: *anyopaque) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    for (self.attachments[0..self.attachment_count], self.discard_at_end[0..self.attachment_count]) |maybe_view, discard| if (maybe_view) |view| {
        if (discard) self.list.unwrap().lpVtbl.*.DiscardResource.?(self.list.unwrap(), view.resource, null);
    };
    for (self.attachments[0..self.attachment_count], self.resolve_attachments[0..self.attachment_count]) |source, destination| if (source) |src| if (destination) |dst| {
        const source_subresource = src.base_mip + src.base_layer * src.resource_mip_levels;
        const destination_subresource = dst.base_mip + dst.base_layer * dst.resource_mip_levels;
        transitionResource(self.list.unwrap(), src.resource, dx.D3D12_RESOURCE_STATE_RENDER_TARGET, dx.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, source_subresource);
        self.list.unwrap().lpVtbl.*.ResolveSubresource.?(self.list.unwrap(), dst.resource, destination_subresource, src.resource, source_subresource, src.format);
        transitionResource(self.list.unwrap(), src.resource, dx.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, dx.D3D12_RESOURCE_STATE_RENDER_TARGET, source_subresource);
    };
    if (self.depth_attachment) |view| if (self.discard_depth_at_end) self.list.unwrap().lpVtbl.*.DiscardResource.?(self.list.unwrap(), view.resource, null);
    self.attachment_count = 0;
    self.depth_attachment = null;
    self.in_render_pass = false;
}

fn copyBuffer(ptr: *anyopaque, region: command.BufferCopyRegion) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.in_render_pass) return error.TransferInsideRenderPass;
    const source = try resource.Dx12Buffer.fromHandle(region.source);
    const destination = try resource.Dx12Buffer.fromHandle(region.destination);
    if (source.memory == .readback) return error.InvalidCopySource;
    if (destination.memory == .upload) return error.InvalidCopyDestination;
    if (source == destination) return error.SameBufferCopyUnsupported;
    if (region.size == 0 or region.source_offset > source.size or region.size > source.size - region.source_offset or region.destination_offset > destination.size or region.size > destination.size - region.destination_offset) return error.InvalidBufferCopy;

    const list = self.list.unwrap();
    list.lpVtbl.*.CopyBufferRegion.?(list, destination.resource.unwrap(), region.destination_offset, source.resource.unwrap(), region.source_offset, region.size);
}

fn copyTexture(ptr: *anyopaque, region: command.TextureCopyRegion) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.in_render_pass) return error.TransferInsideRenderPass;
    const source = try resource.Dx12Texture.fromHandle(region.source.texture);
    const destination = try resource.Dx12Texture.fromHandle(region.destination.texture);
    if (source == destination) return error.SameTextureCopyUnsupported;
    if (source.desc.format != destination.desc.format or source.desc.sample_count != 1 or destination.desc.sample_count != 1) return error.IncompatibleTextureCopy;
    const source_subresource = try validateTextureCopy(source, region.source, region.extent);
    const destination_subresource = try validateTextureCopy(destination, region.destination, region.extent);
    const source_location = textureLocation(source, source_subresource);
    const destination_location = textureLocation(destination, destination_subresource);
    const source_box = copyBox(region.source.origin, region.extent);
    const list = self.list.unwrap();
    list.lpVtbl.*.CopyTextureRegion.?(list, &destination_location, region.destination.origin.x, region.destination.origin.y, region.destination.origin.z, &source_location, &source_box);
}

fn copyBufferToTexture(ptr: *anyopaque, region: command.BufferTextureCopyRegion) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.in_render_pass) return error.TransferInsideRenderPass;
    const buffer = try resource.Dx12Buffer.fromHandle(region.buffer);
    const texture = try resource.Dx12Texture.fromHandle(region.texture.texture);
    const subresource = try validateTextureCopy(texture, region.texture, region.extent);
    const footprint = try bufferTextureFootprint(buffer, texture, region);
    const source = bufferLocation(buffer, footprint);
    const destination = textureLocation(texture, subresource);
    const list = self.list.unwrap();
    list.lpVtbl.*.CopyTextureRegion.?(list, &destination, region.texture.origin.x, region.texture.origin.y, region.texture.origin.z, &source, null);
}

fn copyTextureToBuffer(ptr: *anyopaque, region: command.BufferTextureCopyRegion) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.in_render_pass) return error.TransferInsideRenderPass;
    const buffer = try resource.Dx12Buffer.fromHandle(region.buffer);
    const texture = try resource.Dx12Texture.fromHandle(region.texture.texture);
    const subresource = try validateTextureCopy(texture, region.texture, region.extent);
    const footprint = try bufferTextureFootprint(buffer, texture, region);
    const source = textureLocation(texture, subresource);
    const destination = bufferLocation(buffer, footprint);
    const source_box = copyBox(region.texture.origin, region.extent);
    const list = self.list.unwrap();
    list.lpVtbl.*.CopyTextureRegion.?(list, &destination, 0, 0, 0, &source, &source_box);
}

fn resolveTexture(ptr: *anyopaque, region: command.TextureResolveRegion) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.pool.kind != .graphics) return error.InvalidCommandPoolKind;
    if (self.in_render_pass or self.in_compute_pass) return error.ResolveInsidePass;
    const source = try resource.Dx12Texture.fromHandle(region.source.texture);
    const destination = try resource.Dx12Texture.fromHandle(region.destination.texture);
    if (source == destination) return error.SameTextureResolveUnsupported;
    if (source.desc.sample_count == 1 or destination.desc.sample_count != 1 or source.desc.format != destination.desc.format or source.desc.dimension != destination.desc.dimension) return error.IncompatibleTextureResolve;
    if (!source.desc.usage.transfer_src or !destination.desc.usage.transfer_dst) return error.InvalidTextureResolveUsage;
    const source_subresource = try validateTextureSubresource(source, region.source);
    const destination_subresource = try validateTextureSubresource(destination, region.destination);
    if (mipExtent(source, region.source.mip_level).width != mipExtent(destination, region.destination.mip_level).width or mipExtent(source, region.source.mip_level).height != mipExtent(destination, region.destination.mip_level).height or mipExtent(source, region.source.mip_level).depth != mipExtent(destination, region.destination.mip_level).depth) return error.IncompatibleTextureResolve;
    self.list.unwrap().lpVtbl.*.ResolveSubresource.?(self.list.unwrap(), destination.resource.unwrap(), destination_subresource, source.resource.unwrap(), source_subresource, resource.toDxFormat(source.desc.format));
}

fn barrier(ptr: *anyopaque, values: []const command.ResourceBarrier) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.in_render_pass or self.in_compute_pass) return error.BarrierInsidePass;
    const list = self.list.unwrap();
    for (values) |value| switch (value) {
        .buffer => |item| {
            const buffer = try resource.Dx12Buffer.fromHandle(item.buffer);
            if (item.before == .storage_write and item.after == .storage_write) {
                uavBarrier(list, buffer.resource.unwrap());
            } else {
                transitionResource(list, buffer.resource.unwrap(), bufferState(item.before), bufferState(item.after), dx.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES);
            }
        },
        .texture => |item| {
            const texture = try resource.Dx12Texture.fromHandle(item.texture);
            if (item.before == .storage_write and item.after == .storage_write) {
                uavBarrier(list, texture.resource.unwrap());
            } else if (isWholeTextureRange(texture, item.range)) {
                transitionResource(list, texture.resource.unwrap(), textureState(item.before), textureState(item.after), dx.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES);
            } else {
                const mip_count = item.range.mip_count orelse texture.desc.mip_levels - item.range.base_mip;
                const layer_count = item.range.layer_count orelse texture.desc.depth_or_layers - item.range.base_layer;
                if (item.range.base_mip + mip_count > texture.desc.mip_levels or item.range.base_layer + layer_count > texture.desc.depth_or_layers) return error.InvalidSubresourceRange;
                for (item.range.base_layer..item.range.base_layer + layer_count) |layer| for (item.range.base_mip..item.range.base_mip + mip_count) |mip| {
                    const subresource: u32 = @intCast(mip + layer * texture.desc.mip_levels);
                    transitionResource(list, texture.resource.unwrap(), textureState(item.before), textureState(item.after), subresource);
                };
            }
        },
        .texture_view => |item| {
            const view = try resource.Dx12TextureView.fromHandle(item.view);
            transitionResource(list, view.resource, textureState(item.before), textureState(item.after), dx.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES);
        },
    };
}

fn beginDebugGroup(ptr: *anyopaque, label: []const u8) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    self.list.unwrap().lpVtbl.*.BeginEvent.?(self.list.unwrap(), 0, debugData(label), @intCast(label.len));
}

fn endDebugGroup(ptr: *anyopaque) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    self.list.unwrap().lpVtbl.*.EndEvent.?(self.list.unwrap());
}

fn insertDebugMarker(ptr: *anyopaque, label: []const u8) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    self.list.unwrap().lpVtbl.*.SetMarker.?(self.list.unwrap(), 0, debugData(label), @intCast(label.len));
}

fn finish(ptr: *anyopaque) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (self.in_render_pass or self.in_compute_pass) return error.PassStillActive;
    try checkHr(self.list.unwrap().lpVtbl.*.Close.?(self.list.unwrap()));
    self.finished = true;
}

fn bufferRestState(buffer: *resource.Dx12Buffer) dx.D3D12_RESOURCE_STATES {
    return switch (buffer.memory) {
        .device => dx.D3D12_RESOURCE_STATE_COMMON,
        .upload => dx.D3D12_RESOURCE_STATE_GENERIC_READ,
        .readback => dx.D3D12_RESOURCE_STATE_COPY_DEST,
    };
}

fn bufferCopyState(buffer: *resource.Dx12Buffer, source: bool) !dx.D3D12_RESOURCE_STATES {
    return if (source) switch (buffer.memory) {
        .device => dx.D3D12_RESOURCE_STATE_COPY_SOURCE,
        .upload => dx.D3D12_RESOURCE_STATE_GENERIC_READ,
        .readback => error.InvalidCopySource,
    } else switch (buffer.memory) {
        .device, .readback => dx.D3D12_RESOURCE_STATE_COPY_DEST,
        .upload => error.InvalidCopyDestination,
    };
}

fn validateTextureSubresource(texture: *resource.Dx12Texture, subresource: command.TextureSubresource) !u32 {
    if (subresource.mip_level >= texture.desc.mip_levels) return error.InvalidTextureSubresource;
    switch (texture.desc.dimension) {
        .d1, .d2 => if (subresource.array_layer >= texture.desc.depth_or_layers) return error.InvalidTextureSubresource,
        .d3 => if (subresource.array_layer != 0) return error.InvalidTextureSubresource,
    }
    return subresource.mip_level + subresource.array_layer * texture.desc.mip_levels;
}

fn mipExtent(texture: *resource.Dx12Texture, mip_level: u32) command.Extent3D {
    return .{
        .width = @max(texture.desc.width >> @intCast(mip_level), 1),
        .height = if (texture.desc.dimension == .d1) 1 else @max(texture.desc.height >> @intCast(mip_level), 1),
        .depth = if (texture.desc.dimension == .d3) @max(texture.desc.depth_or_layers >> @intCast(mip_level), 1) else 1,
    };
}

fn validateTextureCopy(texture: *resource.Dx12Texture, view: command.TextureCopyView, extent: command.Extent3D) !u32 {
    if (extent.width == 0 or extent.height == 0 or extent.depth == 0 or view.mip_level >= texture.desc.mip_levels) return error.InvalidTextureCopy;
    const width = @max(texture.desc.width >> @intCast(view.mip_level), 1);
    const height = @max(texture.desc.height >> @intCast(view.mip_level), 1);
    const depth = if (texture.desc.dimension == .d3) @max(texture.desc.depth_or_layers >> @intCast(view.mip_level), 1) else 1;
    switch (texture.desc.dimension) {
        .d1 => if (view.array_layer >= texture.desc.depth_or_layers or view.origin.y != 0 or view.origin.z != 0 or extent.height != 1 or extent.depth != 1) return error.InvalidTextureCopy,
        .d2 => if (view.array_layer >= texture.desc.depth_or_layers or view.origin.z != 0 or extent.depth != 1) return error.InvalidTextureCopy,
        .d3 => if (view.array_layer != 0) return error.InvalidTextureCopy,
    }
    if (!fits(view.origin.x, extent.width, width) or !fits(view.origin.y, extent.height, height) or !fits(view.origin.z, extent.depth, depth)) return error.InvalidTextureCopy;
    return view.mip_level + view.array_layer * texture.desc.mip_levels;
}

fn fits(origin: u32, size: u32, limit: u32) bool {
    return @as(u64, origin) + size <= limit;
}

fn bufferTextureFootprint(buffer: *resource.Dx12Buffer, texture: *resource.Dx12Texture, region: command.BufferTextureCopyRegion) !dx.D3D12_PLACED_SUBRESOURCE_FOOTPRINT {
    if (texture.desc.sample_count != 1 or region.buffer_offset % dx.D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT != 0) return error.InvalidBufferTextureCopy;
    const packed_row = try std.math.mul(u64, region.extent.width, resource.bytesPerPixel(texture.desc.format) orelse return error.UnsupportedCopyFormat);
    const row_pitch = if (region.bytes_per_row == 0)
        std.mem.alignForward(u64, packed_row, dx.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT)
    else
        region.bytes_per_row;
    const rows_per_image: u64 = if (region.rows_per_image == 0) region.extent.height else region.rows_per_image;
    if (row_pitch < packed_row or row_pitch % dx.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT != 0 or row_pitch > std.math.maxInt(u32) or rows_per_image < region.extent.height) return error.InvalidBufferTextureLayout;
    const image_stride = try std.math.mul(u64, row_pitch, rows_per_image);
    const preceding_images = try std.math.mul(u64, image_stride, region.extent.depth - 1);
    const preceding_rows = try std.math.mul(u64, row_pitch, region.extent.height - 1);
    var required = try std.math.add(u64, region.buffer_offset, preceding_images);
    required = try std.math.add(u64, required, preceding_rows);
    required = try std.math.add(u64, required, packed_row);
    if (required > buffer.size) return error.BufferCopyOutOfBounds;
    return .{
        .Offset = region.buffer_offset,
        .Footprint = .{
            .Format = resource.toDxFormat(texture.desc.format),
            .Width = region.extent.width,
            .Height = region.extent.height,
            .Depth = region.extent.depth,
            .RowPitch = @intCast(row_pitch),
        },
    };
}

fn textureLocation(texture: *resource.Dx12Texture, subresource: u32) dx.D3D12_TEXTURE_COPY_LOCATION {
    return .{
        .pResource = texture.resource.unwrap(),
        .Type = dx.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
        .unnamed_0 = .{ .SubresourceIndex = subresource },
    };
}

fn bufferLocation(buffer: *resource.Dx12Buffer, footprint: dx.D3D12_PLACED_SUBRESOURCE_FOOTPRINT) dx.D3D12_TEXTURE_COPY_LOCATION {
    return .{
        .pResource = buffer.resource.unwrap(),
        .Type = dx.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
        .unnamed_0 = .{ .PlacedFootprint = footprint },
    };
}

fn copyBox(origin: command.Origin3D, extent: command.Extent3D) dx.D3D12_BOX {
    return .{
        .left = origin.x,
        .top = origin.y,
        .front = origin.z,
        .right = origin.x + extent.width,
        .bottom = origin.y + extent.height,
        .back = origin.z + extent.depth,
    };
}

fn debugData(label: []const u8) ?*const anyopaque {
    return if (label.len == 0) null else @ptrCast(label.ptr);
}

const IndirectKind = enum { draw, draw_indexed, dispatch };

fn executeIndirect(ptr: *anyopaque, value: resource_interface.Buffer, offset: u64, max_count: u32, count_value: ?resource_interface.Buffer, count_offset: u64, kind: IndirectKind) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (max_count == 0 or offset % 4 != 0) return;
    if ((kind == .dispatch and !self.in_compute_pass) or (kind != .dispatch and !self.in_render_pass)) return;
    const buffer = resource.Dx12Buffer.fromHandle(value) catch return;
    if (buffer.memory == .readback) return;
    const stride: u64 = indirectStride(kind);
    const byte_count = std.math.mul(u64, stride, max_count) catch return;
    if (offset > buffer.size or byte_count > buffer.size - offset) return;
    var count_resource: ?*dx.ID3D12Resource = null;
    if (count_value) |count_handle| {
        const count_buffer = resource.Dx12Buffer.fromHandle(count_handle) catch return;
        if (count_buffer.memory == .readback or count_offset % 4 != 0 or count_offset > count_buffer.size or 4 > count_buffer.size - count_offset) return;
        count_resource = count_buffer.resource.unwrap();
    }
    const signature = indirectSignature(self, kind) catch return;
    self.list.unwrap().lpVtbl.*.ExecuteIndirect.?(self.list.unwrap(), signature, max_count, buffer.resource.unwrap(), offset, count_resource, count_offset);
}

fn indirectStride(kind: IndirectKind) u32 {
    return switch (kind) {
        .draw => @sizeOf(dx.D3D12_DRAW_ARGUMENTS),
        .draw_indexed => @sizeOf(dx.D3D12_DRAW_INDEXED_ARGUMENTS),
        .dispatch => @sizeOf(dx.D3D12_DISPATCH_ARGUMENTS),
    };
}

fn indirectSignature(self: *Dx12CommandBuffer, kind: IndirectKind) !*dx.ID3D12CommandSignature {
    const target = switch (kind) {
        .draw => &self.draw_signature,
        .draw_indexed => &self.draw_indexed_signature,
        .dispatch => &self.dispatch_signature,
    };
    if (target.get()) |value| return value;
    var argument = dx.D3D12_INDIRECT_ARGUMENT_DESC{ .Type = switch (kind) {
        .draw => dx.D3D12_INDIRECT_ARGUMENT_TYPE_DRAW,
        .draw_indexed => dx.D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED,
        .dispatch => dx.D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH,
    }, .unnamed_0 = undefined };
    const stride = indirectStride(kind);
    const desc = dx.D3D12_COMMAND_SIGNATURE_DESC{ .ByteStride = stride, .NumArgumentDescs = 1, .pArgumentDescs = &argument, .NodeMask = 0 };
    const device = self.device orelse return error.InvalidDevice;
    try checkHr(device.device.unwrap().lpVtbl.*.CreateCommandSignature.?(device.device.unwrap(), &desc, null, &dx.IID_ID3D12CommandSignature, @ptrCast(target.put())));
    return target.unwrap();
}

fn commandListType(kind: command.CommandPoolKind) dx.D3D12_COMMAND_LIST_TYPE {
    return switch (kind) {
        .graphics => dx.D3D12_COMMAND_LIST_TYPE_DIRECT,
        .compute => dx.D3D12_COMMAND_LIST_TYPE_COMPUTE,
        .copy => dx.D3D12_COMMAND_LIST_TYPE_COPY,
    };
}

fn bufferState(value: command.BufferState) dx.D3D12_RESOURCE_STATES {
    return switch (value) {
        .common => dx.D3D12_RESOURCE_STATE_COMMON,
        .copy_source => dx.D3D12_RESOURCE_STATE_COPY_SOURCE,
        .copy_destination => dx.D3D12_RESOURCE_STATE_COPY_DEST,
        .vertex, .uniform => dx.D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER,
        .index => dx.D3D12_RESOURCE_STATE_INDEX_BUFFER,
        .storage_read => dx.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | dx.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
        .storage_write => dx.D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
        .indirect => dx.D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT,
        .host_read => dx.D3D12_RESOURCE_STATE_COPY_DEST,
        .host_write => dx.D3D12_RESOURCE_STATE_GENERIC_READ,
    };
}

fn textureState(value: command.TextureState) dx.D3D12_RESOURCE_STATES {
    return switch (value) {
        .common => dx.D3D12_RESOURCE_STATE_COMMON,
        .copy_source => dx.D3D12_RESOURCE_STATE_COPY_SOURCE,
        .copy_destination => dx.D3D12_RESOURCE_STATE_COPY_DEST,
        .resolve_source => dx.D3D12_RESOURCE_STATE_RESOLVE_SOURCE,
        .resolve_destination => dx.D3D12_RESOURCE_STATE_RESOLVE_DEST,
        .sampled, .storage_read => dx.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | dx.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
        .storage_write => dx.D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
        .color_attachment => dx.D3D12_RESOURCE_STATE_RENDER_TARGET,
        .depth_stencil_read => dx.D3D12_RESOURCE_STATE_DEPTH_READ,
        .depth_stencil_write => dx.D3D12_RESOURCE_STATE_DEPTH_WRITE,
        .present => dx.D3D12_RESOURCE_STATE_PRESENT,
    };
}

fn isWholeTextureRange(texture: *resource.Dx12Texture, range: command.TextureSubresourceRange) bool {
    return range.base_mip == 0 and (range.mip_count == null or range.mip_count.? == texture.desc.mip_levels) and range.base_layer == 0 and (range.layer_count == null or range.layer_count.? == texture.desc.depth_or_layers);
}

fn uavBarrier(list: *dx.ID3D12GraphicsCommandList, value: *dx.ID3D12Resource) void {
    const item = dx.D3D12_RESOURCE_BARRIER{ .Type = dx.D3D12_RESOURCE_BARRIER_TYPE_UAV, .Flags = dx.D3D12_RESOURCE_BARRIER_FLAG_NONE, .unnamed_0 = .{ .UAV = .{ .pResource = value } } };
    list.lpVtbl.*.ResourceBarrier.?(list, 1, &item);
}

fn transitionResource(list: *dx.ID3D12GraphicsCommandList, value: *dx.ID3D12Resource, before: dx.D3D12_RESOURCE_STATES, after: dx.D3D12_RESOURCE_STATES, subresource: u32) void {
    if (before == after) return;
    const item = dx.D3D12_RESOURCE_BARRIER{
        .Type = dx.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        .Flags = dx.D3D12_RESOURCE_BARRIER_FLAG_NONE,
        .unnamed_0 = .{ .Transition = .{
            .pResource = value,
            .Subresource = subresource,
            .StateBefore = before,
            .StateAfter = after,
        } },
    };
    list.lpVtbl.*.ResourceBarrier.?(list, 1, &item);
}

test "all public resource states map to D3D12" {
    for (std.meta.tags(command.BufferState)) |state| _ = bufferState(state);
    for (std.meta.tags(command.TextureState)) |state| _ = textureState(state);
}
