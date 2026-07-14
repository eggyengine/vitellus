//! DirectX 12 resource entry points.

const std = @import("std");
const resource = @import("../../interface/resource.zig");
const Dx12Device = @import("device.zig").Dx12Device;
const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

pub const Dx12Buffer = struct {
    allocator: std.mem.Allocator,
    resource: ComPtr(dx.ID3D12Resource) = .{},
    size: u64,

    pub fn fromHandle(value: resource.Buffer) !*Dx12Buffer {
        if (value.handle == 0) return error.InvalidBuffer;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

/// Borrowed swapchain view data. The swapchain owns the resource and RTV heap.
pub const Dx12TextureView = struct {
    resource: *dx.ID3D12Resource,
    rtv: dx.D3D12_CPU_DESCRIPTOR_HANDLE,
    width: u32,
    height: u32,
    state: dx.D3D12_RESOURCE_STATES = dx.D3D12_RESOURCE_STATE_PRESENT,

    pub fn fromHandle(value: resource.TextureView) !*Dx12TextureView {
        if (value.handle == 0) return error.InvalidTextureView;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub fn createBuffer(ptr: *anyopaque, desc: resource.BufferDescriptor) anyerror!resource.Buffer {
    if (desc.size == 0) return error.InvalidBufferSize;
    if (desc.initial_data) |data| {
        if (data.len > desc.size) return error.InitialDataTooLarge;
        if (desc.memory == .readback) return error.InvalidInitialData;
    }

    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12Buffer);
    self.* = .{ .allocator = device.allocator, .size = desc.size };
    errdefer {
        self.resource.deinit();
        device.allocator.destroy(self);
    }

    const initial_state: dx.D3D12_RESOURCE_STATES = switch (desc.memory) {
        .device => if (desc.initial_data != null) dx.D3D12_RESOURCE_STATE_COPY_DEST else dx.D3D12_RESOURCE_STATE_COMMON,
        .upload => dx.D3D12_RESOURCE_STATE_GENERIC_READ,
        .readback => dx.D3D12_RESOURCE_STATE_COPY_DEST,
    };
    try createCommittedBuffer(
        device.device.unwrap(),
        heapType(desc.memory),
        desc.size,
        bufferFlags(desc.usage),
        initial_state,
        &self.resource,
    );

    if (desc.initial_data) |data| switch (desc.memory) {
        .upload => try writeMapped(self.resource.unwrap(), data),
        .device => try uploadToDevice(device.device.unwrap(), self.resource.unwrap(), data),
        .readback => unreachable,
    };

    return .{ .handle = @intCast(@intFromPtr(self)) };
}

pub fn destroyBuffer(_: *anyopaque, value: resource.Buffer) void {
    const self = Dx12Buffer.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.resource.deinit();
    allocator.destroy(self);
}

fn createCommittedBuffer(
    device: *dx.ID3D12Device,
    heap_type: dx.D3D12_HEAP_TYPE,
    size: u64,
    flags: dx.D3D12_RESOURCE_FLAGS,
    initial_state: dx.D3D12_RESOURCE_STATES,
    output: *ComPtr(dx.ID3D12Resource),
) !void {
    const heap = dx.D3D12_HEAP_PROPERTIES{
        .Type = heap_type,
        .CPUPageProperty = dx.D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
        .MemoryPoolPreference = dx.D3D12_MEMORY_POOL_UNKNOWN,
        .CreationNodeMask = 1,
        .VisibleNodeMask = 1,
    };
    const resource_desc = dx.D3D12_RESOURCE_DESC{
        .Dimension = dx.D3D12_RESOURCE_DIMENSION_BUFFER,
        .Alignment = 0,
        .Width = size,
        .Height = 1,
        .DepthOrArraySize = 1,
        .MipLevels = 1,
        .Format = dx.DXGI_FORMAT_UNKNOWN,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Layout = dx.D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
        .Flags = flags,
    };
    try checkHr(device.lpVtbl.*.CreateCommittedResource.?(
        device,
        &heap,
        dx.D3D12_HEAP_FLAG_NONE,
        &resource_desc,
        initial_state,
        null,
        &dx.IID_ID3D12Resource,
        @ptrCast(output.put()),
    ));
}

fn writeMapped(buffer: *dx.ID3D12Resource, data: []const u8) !void {
    var mapped: ?*anyopaque = null;
    const read_range = dx.D3D12_RANGE{ .Begin = 0, .End = 0 };
    try checkHr(buffer.lpVtbl.*.Map.?(buffer, 0, &read_range, &mapped));
    defer buffer.lpVtbl.*.Unmap.?(buffer, 0, null);
    const destination: [*]u8 = @ptrCast(mapped orelse return error.MapFailed);
    @memcpy(destination[0..data.len], data);
}

fn uploadToDevice(device: *dx.ID3D12Device, destination: *dx.ID3D12Resource, data: []const u8) !void {
    var upload: ComPtr(dx.ID3D12Resource) = .{};
    defer upload.deinit();
    try createCommittedBuffer(device, dx.D3D12_HEAP_TYPE_UPLOAD, data.len, dx.D3D12_RESOURCE_FLAG_NONE, dx.D3D12_RESOURCE_STATE_GENERIC_READ, &upload);
    try writeMapped(upload.unwrap(), data);

    var queue: ComPtr(dx.ID3D12CommandQueue) = .{};
    defer queue.deinit();
    var allocator: ComPtr(dx.ID3D12CommandAllocator) = .{};
    defer allocator.deinit();
    var list: ComPtr(dx.ID3D12GraphicsCommandList) = .{};
    defer list.deinit();
    var fence: ComPtr(dx.ID3D12Fence) = .{};
    defer fence.deinit();

    const queue_desc = dx.D3D12_COMMAND_QUEUE_DESC{
        .Type = dx.D3D12_COMMAND_LIST_TYPE_COPY,
        .Priority = 0,
        .Flags = dx.D3D12_COMMAND_QUEUE_FLAG_NONE,
        .NodeMask = 0,
    };
    try checkHr(device.lpVtbl.*.CreateCommandQueue.?(device, &queue_desc, &dx.IID_ID3D12CommandQueue, @ptrCast(queue.put())));
    try checkHr(device.lpVtbl.*.CreateCommandAllocator.?(device, dx.D3D12_COMMAND_LIST_TYPE_COPY, &dx.IID_ID3D12CommandAllocator, @ptrCast(allocator.put())));
    try checkHr(device.lpVtbl.*.CreateCommandList.?(
        device,
        0,
        dx.D3D12_COMMAND_LIST_TYPE_COPY,
        allocator.unwrap(),
        null,
        &dx.IID_ID3D12GraphicsCommandList,
        @ptrCast(list.put()),
    ));

    const commands = list.unwrap();
    commands.lpVtbl.*.CopyBufferRegion.?(commands, destination, 0, upload.unwrap(), 0, data.len);
    const barrier = dx.D3D12_RESOURCE_BARRIER{
        .Type = dx.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        .Flags = dx.D3D12_RESOURCE_BARRIER_FLAG_NONE,
        .unnamed_0 = .{ .Transition = .{
            .pResource = destination,
            .Subresource = dx.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            .StateBefore = dx.D3D12_RESOURCE_STATE_COPY_DEST,
            .StateAfter = dx.D3D12_RESOURCE_STATE_COMMON,
        } },
    };
    commands.lpVtbl.*.ResourceBarrier.?(commands, 1, &barrier);
    try checkHr(commands.lpVtbl.*.Close.?(commands));

    var base_list: ?*dx.ID3D12CommandList = @ptrCast(commands);
    queue.unwrap().lpVtbl.*.ExecuteCommandLists.?(queue.unwrap(), 1, @ptrCast(&base_list));
    try checkHr(device.lpVtbl.*.CreateFence.?(device, 0, dx.D3D12_FENCE_FLAG_NONE, &dx.IID_ID3D12Fence, @ptrCast(fence.put())));
    try checkHr(queue.unwrap().lpVtbl.*.Signal.?(queue.unwrap(), fence.unwrap(), 1));
    // ponytail: synchronous one-shot upload; replace with a shared upload queue when asset streaming matters.
    while (fence.unwrap().lpVtbl.*.GetCompletedValue.?(fence.unwrap()) < 1) std.atomic.spinLoopHint();
}

fn heapType(location: resource.MemoryLocation) dx.D3D12_HEAP_TYPE {
    return switch (location) {
        .device => dx.D3D12_HEAP_TYPE_DEFAULT,
        .upload => dx.D3D12_HEAP_TYPE_UPLOAD,
        .readback => dx.D3D12_HEAP_TYPE_READBACK,
    };
}

fn bufferFlags(usage: resource.BufferUsage) dx.D3D12_RESOURCE_FLAGS {
    return if (usage.storage) dx.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS else dx.D3D12_RESOURCE_FLAG_NONE;
}

pub fn toDxFormat(format: resource.Format) dx.DXGI_FORMAT {
    return switch (format) {
        .undefined => dx.DXGI_FORMAT_UNKNOWN,
        .r8_unorm => dx.DXGI_FORMAT_R8_UNORM,
        .rg8_unorm => dx.DXGI_FORMAT_R8G8_UNORM,
        .rgba8_unorm => dx.DXGI_FORMAT_R8G8B8A8_UNORM,
        .rgba8_unorm_srgb => dx.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        .bgra8_unorm => dx.DXGI_FORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => dx.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        .r16_float => dx.DXGI_FORMAT_R16_FLOAT,
        .rg16_float => dx.DXGI_FORMAT_R16G16_FLOAT,
        .rgba16_float => dx.DXGI_FORMAT_R16G16B16A16_FLOAT,
        .r32_float => dx.DXGI_FORMAT_R32_FLOAT,
        .rg32_float => dx.DXGI_FORMAT_R32G32_FLOAT,
        .rgb32_float => dx.DXGI_FORMAT_R32G32B32_FLOAT,
        .rgba32_float => dx.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .d16_unorm => dx.DXGI_FORMAT_D16_UNORM,
        .d24_unorm_s8_uint => dx.DXGI_FORMAT_D24_UNORM_S8_UINT,
        .d32_float => dx.DXGI_FORMAT_D32_FLOAT,
    };
}

test "memory locations select their native heap types" {
    try std.testing.expectEqual(@as(dx.D3D12_HEAP_TYPE, dx.D3D12_HEAP_TYPE_DEFAULT), heapType(.device));
    try std.testing.expectEqual(@as(dx.D3D12_HEAP_TYPE, dx.D3D12_HEAP_TYPE_UPLOAD), heapType(.upload));
    try std.testing.expectEqual(@as(dx.D3D12_HEAP_TYPE, dx.D3D12_HEAP_TYPE_READBACK), heapType(.readback));
}
