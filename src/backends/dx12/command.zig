//! DirectX 12 command allocator and graphics-list recording.

const std = @import("std");
const command = @import("../../interface/command.zig");
const pipeline = @import("../../interface/pipeline.zig");
const resource_interface = @import("../../interface/resource.zig");
const pipeline_impl = @import("pipeline.zig");
const resource = @import("resource.zig");
const Dx12Device = @import("device.zig").Dx12Device;
const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

pub const Dx12CommandBuffer = struct {
    list: ComPtr(dx.ID3D12GraphicsCommandList) = .{},
    finished: bool = false,
    active_pipeline: ?*pipeline_impl.Dx12GraphicsPipeline = null,
    attachments: [8]?*resource.Dx12TextureView = [_]?*resource.Dx12TextureView{null} ** 8,
    discard_at_end: [8]bool = [_]bool{false} ** 8,
    attachment_count: usize = 0,

    pub fn fromCommandBuffer(value: command.CommandBuffer) *Dx12CommandBuffer {
        return @ptrCast(@alignCast(value.ptr));
    }
};

const Dx12CommandPool = struct {
    allocator: std.mem.Allocator,
    device: *dx.ID3D12Device,
    command_allocator: ComPtr(dx.ID3D12CommandAllocator) = .{},
    buffer: Dx12CommandBuffer = .{},
    initialized: bool = false,

    fn fromHandle(value: command.CommandPool) !*Dx12CommandPool {
        if (value.handle == 0) return error.InvalidCommandPool;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const command_buffer_vtable: command.CommandBuffer.VTable = .{
    .beginRenderPassFn = beginRenderPass,
    .setPipelineFn = setPipeline,
    .setVertexBufferFn = setVertexBuffer,
    .drawFn = draw,
    .endRenderPassFn = endRenderPass,
    .finishFn = finish,
};

pub fn createPool(ptr: *anyopaque, _: command.CommandPoolDescriptor) anyerror!command.CommandPool {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12CommandPool);
    self.* = .{ .allocator = device.allocator, .device = device.device.unwrap() };
    errdefer device.allocator.destroy(self);
    try checkHr(self.device.lpVtbl.*.CreateCommandAllocator.?(
        self.device,
        dx.D3D12_COMMAND_LIST_TYPE_DIRECT,
        &dx.IID_ID3D12CommandAllocator,
        @ptrCast(self.command_allocator.put()),
    ));
    return .{ .handle = @intCast(@intFromPtr(self)) };
}

pub fn createBuffer(_: *anyopaque, value: command.CommandPool) anyerror!command.CommandBuffer {
    const self = try Dx12CommandPool.fromHandle(value);
    if (!self.initialized) {
        try checkHr(self.device.lpVtbl.*.CreateCommandList.?(
            self.device,
            0,
            dx.D3D12_COMMAND_LIST_TYPE_DIRECT,
            self.command_allocator.unwrap(),
            null,
            &dx.IID_ID3D12GraphicsCommandList,
            @ptrCast(self.buffer.list.put()),
        ));
        self.initialized = true;
    } else {
        try checkHr(self.command_allocator.unwrap().lpVtbl.*.Reset.?(self.command_allocator.unwrap()));
        try checkHr(self.buffer.list.unwrap().lpVtbl.*.Reset.?(
            self.buffer.list.unwrap(),
            self.command_allocator.unwrap(),
            null,
        ));
    }
    self.buffer.finished = false;
    self.buffer.active_pipeline = null;
    self.buffer.attachment_count = 0;
    return .{ .ptr = &self.buffer, .vtable = &command_buffer_vtable };
}

pub fn destroyPool(_: *anyopaque, value: command.CommandPool) void {
    const self = Dx12CommandPool.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.buffer.list.deinit();
    self.command_allocator.deinit();
    allocator.destroy(self);
}

fn beginRenderPass(ptr: *anyopaque, desc: command.RenderPassDescriptor) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    if (desc.color_attachments.len == 0 or desc.color_attachments.len > self.attachments.len) return error.InvalidColorAttachments;

    var handles: [8]dx.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
    const list = self.list.unwrap();
    for (desc.color_attachments, 0..) |attachment, i| {
        const view = try resource.Dx12TextureView.fromHandle(attachment.view);
        transition(list, view, dx.D3D12_RESOURCE_STATE_RENDER_TARGET);
        handles[i] = view.rtv;
        self.attachments[i] = view;
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
    list.lpVtbl.*.OMSetRenderTargets.?(list, @intCast(self.attachment_count), &handles, 0, null);

    const first = self.attachments[0].?;
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

fn setPipeline(ptr: *anyopaque, value: pipeline.GraphicsPipeline) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const state = pipeline_impl.Dx12GraphicsPipeline.fromHandle(value) catch return;
    const list = self.list.unwrap();
    list.lpVtbl.*.SetGraphicsRootSignature.?(list, state.root_signature.unwrap());
    list.lpVtbl.*.SetPipelineState.?(list, state.state.unwrap());
    list.lpVtbl.*.IASetPrimitiveTopology.?(list, state.topology);
    self.active_pipeline = state;
}

fn setVertexBuffer(ptr: *anyopaque, slot: u32, value: resource_interface.Buffer, offset: u64) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    const state = self.active_pipeline orelse return;
    if (slot >= state.vertex_buffer_count) return;
    const buffer = resource.Dx12Buffer.fromHandle(value) catch return;
    if (offset >= buffer.size) return;
    const view = dx.D3D12_VERTEX_BUFFER_VIEW{
        .BufferLocation = buffer.resource.unwrap().lpVtbl.*.GetGPUVirtualAddress.?(buffer.resource.unwrap()) + offset,
        .SizeInBytes = @intCast(@min(buffer.size - offset, std.math.maxInt(u32))),
        .StrideInBytes = state.vertex_strides[slot],
    };
    self.list.unwrap().lpVtbl.*.IASetVertexBuffers.?(self.list.unwrap(), slot, 1, &view);
}

fn draw(ptr: *anyopaque, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    self.list.unwrap().lpVtbl.*.DrawInstanced.?(self.list.unwrap(), vertices, instances, first_vertex, first_instance);
}

fn endRenderPass(ptr: *anyopaque) void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    for (self.attachments[0..self.attachment_count], self.discard_at_end[0..self.attachment_count]) |maybe_view, discard| if (maybe_view) |view| {
        if (discard) self.list.unwrap().lpVtbl.*.DiscardResource.?(self.list.unwrap(), view.resource, null);
        transition(self.list.unwrap(), view, dx.D3D12_RESOURCE_STATE_PRESENT);
    };
    self.attachment_count = 0;
}

fn finish(ptr: *anyopaque) anyerror!void {
    const self: *Dx12CommandBuffer = @ptrCast(@alignCast(ptr));
    try checkHr(self.list.unwrap().lpVtbl.*.Close.?(self.list.unwrap()));
    self.finished = true;
}

fn transition(list: *dx.ID3D12GraphicsCommandList, view: *resource.Dx12TextureView, after: dx.D3D12_RESOURCE_STATES) void {
    if (view.state == after) return;
    const barrier = dx.D3D12_RESOURCE_BARRIER{
        .Type = dx.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        .Flags = dx.D3D12_RESOURCE_BARRIER_FLAG_NONE,
        .unnamed_0 = .{ .Transition = .{
            .pResource = view.resource,
            .Subresource = dx.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            .StateBefore = view.state,
            .StateAfter = after,
        } },
    };
    list.lpVtbl.*.ResourceBarrier.?(list, 1, &barrier);
    view.state = after;
}
