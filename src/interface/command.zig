const pipeline = @import("pipeline.zig");
const resource = @import("resource.zig");

pub const LoadOp = enum { load, clear, discard };
pub const StoreOp = enum { store, discard };
pub const Color = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };
pub const ColorAttachment = struct { view: resource.TextureView, load_op: LoadOp = .clear, store_op: StoreOp = .store, clear_value: Color = .{} };
pub const RenderPassDescriptor = struct { label: ?[]const u8 = null, color_attachments: []const ColorAttachment };
pub const CommandPoolDescriptor = struct { transient: bool = false, reset_individually: bool = true };
pub const CommandPool = struct { handle: u64 = 0 };

/// Recording interface. Backends store their encoder in `ptr`.
pub const CommandBuffer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        beginRenderPassFn: *const fn (*anyopaque, RenderPassDescriptor) anyerror!void,
        setPipelineFn: *const fn (*anyopaque, pipeline.GraphicsPipeline) void,
        setVertexBufferFn: *const fn (*anyopaque, u32, resource.Buffer, u64) void,
        drawFn: *const fn (*anyopaque, u32, u32, u32, u32) void,
        endRenderPassFn: *const fn (*anyopaque) void,
        finishFn: *const fn (*anyopaque) anyerror!void,
    };
    pub fn beginRenderPass(self: CommandBuffer, desc: RenderPassDescriptor) !void { return self.vtable.beginRenderPassFn(self.ptr, desc); }
    pub fn setPipeline(self: CommandBuffer, value: pipeline.GraphicsPipeline) void { self.vtable.setPipelineFn(self.ptr, value); }
    pub fn setVertexBuffer(self: CommandBuffer, slot: u32, buffer: resource.Buffer, offset: u64) void { self.vtable.setVertexBufferFn(self.ptr, slot, buffer, offset); }
    pub fn draw(self: CommandBuffer, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void { self.vtable.drawFn(self.ptr, vertices, instances, first_vertex, first_instance); }
    pub fn endRenderPass(self: CommandBuffer) void { self.vtable.endRenderPassFn(self.ptr); }
    pub fn finish(self: CommandBuffer) !void { return self.vtable.finishFn(self.ptr); }
};

