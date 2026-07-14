//! DirectX 12 command recording entry points.

const command = @import("../../interface/command.zig");
const pipeline = @import("../../interface/pipeline.zig");
const resource = @import("../../interface/resource.zig");

/// Typed command-buffer dispatch table. The callbacks deliberately remain
/// inert until DX12 command allocator/list ownership is implemented.
pub const command_buffer_vtable: command.CommandBuffer.VTable = .{
    .beginRenderPassFn = beginRenderPass,
    .setPipelineFn = setPipeline,
    .setVertexBufferFn = setVertexBuffer,
    .drawFn = draw,
    .endRenderPassFn = endRenderPass,
    .finishFn = finish,
};

pub fn createPool(_: *anyopaque, _: command.CommandPoolDescriptor) anyerror!command.CommandPool {
    return error.Unsupported;
}

pub fn createBuffer(_: *anyopaque, _: command.CommandPool) anyerror!command.CommandBuffer {
    // Keep the complete command-buffer vtable type-checked even while creation
    // remains unavailable.
    _ = &command_buffer_vtable;
    return error.Unsupported;
}

pub fn destroyPool(_: *anyopaque, _: command.CommandPool) void {}

fn beginRenderPass(_: *anyopaque, _: command.RenderPassDescriptor) anyerror!void {
    return error.Unsupported;
}

fn setPipeline(_: *anyopaque, _: pipeline.GraphicsPipeline) void {}

fn setVertexBuffer(_: *anyopaque, _: u32, _: resource.Buffer, _: u64) void {}

fn draw(_: *anyopaque, _: u32, _: u32, _: u32, _: u32) void {}

fn endRenderPass(_: *anyopaque) void {}

fn finish(_: *anyopaque) anyerror!void {
    return error.Unsupported;
}
