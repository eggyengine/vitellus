//! Texture views and buffers.

const std = @import("std");
const c = @import("webgpu_c");
const resource = @import("../../interface/resource.zig");
const str = @import("utils.zig").str;
const zeroInit = @import("utils.zig").zeroInit;
const ptrOf = @import("utils.zig").ptrOf;
const handleOf = @import("utils.zig").handleOf;
const textureFormat = @import("utils.zig").textureFormat;
const viewDimension = @import("utils.zig").viewDimension;
const aspect = @import("utils.zig").aspect;
const WgpuDevice = @import("device.zig").WgpuDevice;

/// A view and the format it was created with; render passes need the format to know which
/// depth/stencil aspects to set up.
pub const WgpuView = struct {
    allocator: std.mem.Allocator,
    handle: c.WGPUTextureView,
    format: c.WGPUTextureFormat,

    const vtable: resource.TextureView.VTable = .{ .deinitFn = deinit };

    pub fn create(ptr: *anyopaque, desc: resource.TextureViewDescriptor) anyerror!resource.TextureView {
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const texture: c.WGPUTexture = @ptrFromInt(@as(usize, @intCast(desc.texture.handle)));
        const format = if (desc.format) |f| try textureFormat(f) else c.wgpuTextureGetFormat(texture);
        const view = c.wgpuTextureCreateView(texture, &zeroInit(c.WGPUTextureViewDescriptor, .{
            .label = str(desc.label),
            .format = format,
            .dimension = if (desc.dimension) |d| viewDimension(d) else c.WGPUTextureViewDimension_Undefined,
            .baseMipLevel = desc.base_mip,
            .mipLevelCount = desc.mip_count orelse c.WGPU_MIP_LEVEL_COUNT_UNDEFINED,
            .baseArrayLayer = desc.base_layer,
            .arrayLayerCount = desc.layer_count orelse c.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
            .aspect = aspect(desc.aspect),
        })) orelse return error.TextureViewCreationFailed;
        return wrap(device.allocator, view, format);
    }

    pub fn wrap(allocator: std.mem.Allocator, view: c.WGPUTextureView, format: c.WGPUTextureFormat) !resource.TextureView {
        errdefer c.wgpuTextureViewRelease(view);
        const self = try allocator.create(WgpuView);
        self.* = .{ .allocator = allocator, .handle = view, .format = format };
        return .{ .handle = handleOf(self), .vtable = &vtable };
    }

    fn deinit(value: resource.TextureView) void {
        const self = ptrOf(WgpuView, value.handle);
        c.wgpuTextureViewRelease(self.handle);
        self.allocator.destroy(self);
    }
};

/// WebGPU only maps buffers asynchronously, and never while the GPU may use them. Writes go
/// through a CPU copy that `unmap` uploads with `wgpuQueueWriteBuffer`, which the queue
/// orders after earlier work, so frames in flight never see a half-written buffer.
pub const WgpuBuffer = struct {
    allocator: std.mem.Allocator,
    handle: c.WGPUBuffer,
    queue: c.WGPUQueue,
    size: u64,
    shadow: ?[]align(4) u8 = null,

    const vtable: resource.Buffer.VTable = .{ .deinitFn = deinit, .mapFn = map, .unmapFn = unmap };

    pub fn create(ptr: *anyopaque, desc: resource.BufferDescriptor) anyerror!resource.Buffer {
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        if (desc.memory == .readback) return error.ReadbackUnsupported; // ponytail: add mapAsync(read) when something reads results back
        var usage: c.WGPUBufferUsage = c.WGPUBufferUsage_CopyDst;
        if (desc.usage.vertex) usage |= c.WGPUBufferUsage_Vertex;
        if (desc.usage.index) usage |= c.WGPUBufferUsage_Index;
        if (desc.usage.uniform) usage |= c.WGPUBufferUsage_Uniform;
        if (desc.usage.storage) usage |= c.WGPUBufferUsage_Storage;
        if (desc.usage.indirect) usage |= c.WGPUBufferUsage_Indirect;
        if (desc.usage.transfer_src) usage |= c.WGPUBufferUsage_CopySrc;
        if (desc.usage.query_resolve) usage |= c.WGPUBufferUsage_QueryResolve;
        const size = std.mem.alignForward(u64, desc.size, 4);
        const handle = c.wgpuDeviceCreateBuffer(device.handle, &.{
            .nextInChain = null,
            .label = str(desc.label),
            .usage = usage,
            .size = size,
            .mappedAtCreation = @intFromBool(desc.initial_data != null),
        }) orelse return error.BufferCreationFailed;
        errdefer c.wgpuBufferRelease(handle);
        if (desc.initial_data) |data| {
            const mapped: [*]u8 = @ptrCast(c.wgpuBufferGetMappedRange(handle, 0, @intCast(size)) orelse return error.BufferMapFailed);
            @memcpy(mapped[0..data.len], data);
            c.wgpuBufferUnmap(handle);
        }
        const self = try device.allocator.create(WgpuBuffer);
        self.* = .{ .allocator = device.allocator, .handle = handle, .queue = c.wgpuDeviceGetQueue(device.handle), .size = size };
        return .{ .handle = handleOf(self), .vtable = &vtable };
    }

    fn map(value: resource.Buffer, mode: resource.MapMode, range: resource.BufferRange) anyerror![]u8 {
        const self = ptrOf(WgpuBuffer, value.handle);
        if (mode == .read) return error.ReadbackUnsupported;
        if (range.offset + range.size > self.size) return error.OutOfBounds;
        const shadow = self.shadow orelse blk: {
            const bytes = try self.allocator.alignedAlloc(u8, .@"4", @intCast(self.size));
            self.shadow = bytes;
            break :blk bytes;
        };
        return shadow[@intCast(range.offset)..@intCast(range.offset + range.size)];
    }

    fn unmap(value: resource.Buffer, written: ?resource.BufferRange) void {
        const self = ptrOf(WgpuBuffer, value.handle);
        const shadow = self.shadow orelse return;
        const range = written orelse resource.BufferRange{ .size = self.size };
        // writeBuffer wants 4-byte aligned offsets and sizes.
        const start = std.mem.alignBackward(u64, range.offset, 4);
        const end = @min(self.size, std.mem.alignForward(u64, range.offset + range.size, 4));
        c.wgpuQueueWriteBuffer(self.queue, self.handle, start, shadow.ptr + @as(usize, @intCast(start)), @intCast(end - start));
    }

    fn deinit(value: resource.Buffer) void {
        const self = ptrOf(WgpuBuffer, value.handle);
        if (self.shadow) |shadow| self.allocator.free(shadow);
        c.wgpuQueueRelease(self.queue);
        c.wgpuBufferRelease(self.handle);
        self.allocator.destroy(self);
    }
};
