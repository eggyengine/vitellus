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
    memory: resource.MemoryLocation,

    pub fn fromHandle(value: resource.Buffer) !*Dx12Buffer {
        if (value.handle == 0) return error.InvalidBuffer;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const Dx12Texture = struct {
    allocator: std.mem.Allocator,
    resource: ComPtr(dx.ID3D12Resource) = .{},
    desc: resource.TextureDescriptor,

    pub fn fromHandle(value: resource.Texture) !*Dx12Texture {
        if (value.handle == 0) return error.InvalidTexture;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

/// Borrowed swapchain view data. The swapchain owns the resource and RTV heap.
pub const Dx12TextureView = struct {
    owner: ?*Dx12Device,
    resource: *dx.ID3D12Resource,
    rtv: dx.D3D12_CPU_DESCRIPTOR_HANDLE,
    dsv: dx.D3D12_CPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 },
    width: u32,
    height: u32,
    dimension: resource.TextureDimension = .d2,
    view_dimension: resource.TextureViewDimension = .d2,
    depth_or_layers: u32 = 1,
    format: dx.DXGI_FORMAT,
    base_mip: u32 = 0,
    mip_count: u32 = 1,
    resource_mip_levels: u32 = 1,
    base_layer: u32 = 0,
    layer_count: u32 = 1,
    state: dx.D3D12_RESOURCE_STATES = dx.D3D12_RESOURCE_STATE_PRESENT,
    rest_state: dx.D3D12_RESOURCE_STATES = dx.D3D12_RESOURCE_STATE_PRESENT,
    allocator: ?std.mem.Allocator = null,
    rtv_index: ?u32 = null,
    dsv_index: ?u32 = null,

    pub fn fromHandle(value: resource.TextureView) !*Dx12TextureView {
        if (value.handle == 0) return error.InvalidTextureView;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const buffer_vtable: resource.Buffer.VTable = .{
    .deinitFn = destroyBuffer,
    .mapFn = mapBuffer,
    .unmapFn = unmapBuffer,
};
const texture_vtable: resource.Texture.VTable = .{ .deinitFn = destroyTexture };
pub const texture_view_vtable: resource.TextureView.VTable = .{ .deinitFn = destroyTextureView };

pub fn createBuffer(ptr: *anyopaque, desc: resource.BufferDescriptor) anyerror!resource.Buffer {
    if (desc.size == 0) return error.InvalidBufferSize;
    if (desc.initial_data) |data| {
        if (data.len > desc.size) return error.InitialDataTooLarge;
        if (desc.memory == .readback) return error.InvalidInitialData;
    }

    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12Buffer);
    self.* = .{ .allocator = device.allocator, .size = desc.size, .memory = desc.memory };
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

    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &buffer_vtable };
}

pub fn destroyBuffer(value: resource.Buffer) void {
    const self = Dx12Buffer.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.resource.deinit();
    allocator.destroy(self);
}

pub fn mapBuffer(value: resource.Buffer, mode: resource.MapMode, range: resource.BufferRange) anyerror![]u8 {
    const self = try Dx12Buffer.fromHandle(value);
    if (range.size == 0 or range.offset > self.size or range.size > self.size - range.offset) return error.InvalidMapRange;
    if ((mode == .read and self.memory != .readback) or (mode == .write and self.memory != .upload)) return error.InvalidMapMode;
    const native_range = dx.D3D12_RANGE{
        .Begin = if (mode == .read) @intCast(range.offset) else 0,
        .End = if (mode == .read) @intCast(range.offset + range.size) else 0,
    };
    var data: ?*anyopaque = null;
    try checkHr(self.resource.unwrap().lpVtbl.*.Map.?(self.resource.unwrap(), 0, &native_range, &data));
    const bytes: [*]u8 = @ptrCast(data orelse return error.MapFailed);
    return bytes[@intCast(range.offset)..@intCast(range.offset + range.size)];
}

pub fn unmapBuffer(value: resource.Buffer, written: ?resource.BufferRange) void {
    const self = Dx12Buffer.fromHandle(value) catch return;
    var native_range: dx.D3D12_RANGE = .{ .Begin = 0, .End = 0 };
    if (written) |range| {
        if (range.offset <= self.size and range.size <= self.size - range.offset) {
            native_range = .{ .Begin = @intCast(range.offset), .End = @intCast(range.offset + range.size) };
        }
    }
    self.resource.unwrap().lpVtbl.*.Unmap.?(self.resource.unwrap(), 0, &native_range);
}

pub fn createTexture(ptr: *anyopaque, desc: resource.TextureDescriptor) anyerror!resource.Texture {
    if (desc.width == 0 or desc.height == 0 or desc.depth_or_layers == 0 or desc.mip_levels == 0 or desc.sample_count == 0) return error.InvalidTextureSize;
    if (desc.initial_data != null and (desc.dimension != .d2 or desc.depth_or_layers != 1 or desc.sample_count != 1)) return error.UnsupportedInitialTextureShape;
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12Texture);
    self.* = .{ .allocator = device.allocator, .desc = desc };
    errdefer {
        self.resource.deinit();
        device.allocator.destroy(self);
    }

    const heap = dx.D3D12_HEAP_PROPERTIES{
        .Type = dx.D3D12_HEAP_TYPE_DEFAULT,
        .CPUPageProperty = dx.D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
        .MemoryPoolPreference = dx.D3D12_MEMORY_POOL_UNKNOWN,
        .CreationNodeMask = 1,
        .VisibleNodeMask = 1,
    };
    const native_desc = dx.D3D12_RESOURCE_DESC{
        .Dimension = switch (desc.dimension) {
            .d1 => dx.D3D12_RESOURCE_DIMENSION_TEXTURE1D,
            .d2 => dx.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            .d3 => dx.D3D12_RESOURCE_DIMENSION_TEXTURE3D,
        },
        .Alignment = 0,
        .Width = desc.width,
        .Height = desc.height,
        .DepthOrArraySize = @intCast(desc.depth_or_layers),
        .MipLevels = @intCast(desc.mip_levels),
        .Format = toDxFormat(desc.format),
        .SampleDesc = .{ .Count = desc.sample_count, .Quality = 0 },
        .Layout = dx.D3D12_TEXTURE_LAYOUT_UNKNOWN,
        .Flags = textureFlags(desc.usage),
    };
    try checkHr(device.device.unwrap().lpVtbl.*.CreateCommittedResource.?(
        device.device.unwrap(),
        &heap,
        dx.D3D12_HEAP_FLAG_NONE,
        &native_desc,
        if (desc.initial_data != null) dx.D3D12_RESOURCE_STATE_COPY_DEST else dx.D3D12_RESOURCE_STATE_COMMON,
        null,
        &dx.IID_ID3D12Resource,
        @ptrCast(self.resource.put()),
    ));
    if (desc.initial_data) |data| try uploadTexture(device.device.unwrap(), self.resource.unwrap(), &native_desc, desc, data);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &texture_vtable };
}

pub fn destroyTexture(value: resource.Texture) void {
    const self = Dx12Texture.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.resource.deinit();
    allocator.destroy(self);
}

pub fn createTextureView(ptr: *anyopaque, desc: resource.TextureViewDescriptor) anyerror!resource.TextureView {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const texture = try Dx12Texture.fromHandle(desc.texture);
    if (desc.base_mip >= texture.desc.mip_levels) return error.InvalidMipRange;
    const mip_count = desc.mip_count orelse texture.desc.mip_levels - desc.base_mip;
    if (mip_count == 0 or mip_count > texture.desc.mip_levels - desc.base_mip) return error.InvalidMipRange;
    const layer_count = desc.layer_count orelse texture.desc.depth_or_layers - desc.base_layer;
    if (layer_count == 0 or desc.base_layer >= texture.desc.depth_or_layers or layer_count > texture.desc.depth_or_layers - desc.base_layer) return error.InvalidLayerRange;
    const view_dimension = desc.dimension orelse defaultViewDimension(texture.desc.dimension, texture.desc.depth_or_layers);
    if (texture.desc.usage.depth_stencil_attachment and view_dimension == .d3) return error.InvalidDepthStencilDimension;
    if ((view_dimension == .cube or view_dimension == .cube_array) and (desc.base_layer % 6 != 0 or layer_count % 6 != 0)) return error.InvalidCubeLayers;

    const self = try device.allocator.create(Dx12TextureView);
    errdefer device.allocator.destroy(self);
    self.* = .{
        .owner = device,
        .resource = texture.resource.unwrap(),
        .rtv = .{ .ptr = 0 },
        .width = @max(texture.desc.width >> @intCast(desc.base_mip), 1),
        .height = @max(texture.desc.height >> @intCast(desc.base_mip), 1),
        .dimension = texture.desc.dimension,
        .view_dimension = view_dimension,
        .depth_or_layers = texture.desc.depth_or_layers,
        .format = toDxFormat(desc.format orelse texture.desc.format),
        .base_mip = desc.base_mip,
        .mip_count = mip_count,
        .resource_mip_levels = texture.desc.mip_levels,
        .base_layer = desc.base_layer,
        .layer_count = layer_count,
        .state = dx.D3D12_RESOURCE_STATE_COMMON,
        .rest_state = dx.D3D12_RESOURCE_STATE_COMMON,
        .allocator = device.allocator,
    };
    errdefer {
        if (self.rtv_index) |index| device.freeRtv(index);
        if (self.dsv_index) |index| device.freeDsv(index);
    }
    if (texture.desc.usage.color_attachment) {
        const allocation = try device.allocateRtv();
        self.rtv = allocation.cpu;
        self.rtv_index = allocation.index;
        var rtv = renderTargetViewDesc(self.format, view_dimension, desc.base_mip, desc.base_layer, layer_count);
        device.device.unwrap().lpVtbl.*.CreateRenderTargetView.?(device.device.unwrap(), self.resource, &rtv, self.rtv);
    }
    if (texture.desc.usage.depth_stencil_attachment) {
        const allocation = try device.allocateDsv();
        self.dsv = allocation.cpu;
        self.dsv_index = allocation.index;
        var dsv = depthStencilViewDesc(self.format, view_dimension, desc.base_mip, desc.base_layer, layer_count);
        device.device.unwrap().lpVtbl.*.CreateDepthStencilView.?(device.device.unwrap(), self.resource, &dsv, self.dsv);
    }
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &texture_view_vtable };
}

fn defaultViewDimension(dimension: resource.TextureDimension, layers: u32) resource.TextureViewDimension {
    return switch (dimension) {
        .d1 => if (layers == 1) .d1 else .d1_array,
        .d2 => if (layers == 1) .d2 else .d2_array,
        .d3 => .d3,
    };
}

fn renderTargetViewDesc(format: dx.DXGI_FORMAT, dimension: resource.TextureViewDimension, mip: u32, base_layer: u32, layers: u32) dx.D3D12_RENDER_TARGET_VIEW_DESC {
    var result: dx.D3D12_RENDER_TARGET_VIEW_DESC = std.mem.zeroes(dx.D3D12_RENDER_TARGET_VIEW_DESC);
    result.Format = format;
    switch (dimension) {
        .d1 => {
            result.ViewDimension = dx.D3D12_RTV_DIMENSION_TEXTURE1D;
            result.unnamed_0.Texture1D.MipSlice = mip;
        },
        .d1_array => {
            result.ViewDimension = dx.D3D12_RTV_DIMENSION_TEXTURE1DARRAY;
            result.unnamed_0.Texture1DArray = .{ .MipSlice = mip, .FirstArraySlice = base_layer, .ArraySize = layers };
        },
        .d2 => {
            result.ViewDimension = dx.D3D12_RTV_DIMENSION_TEXTURE2D;
            result.unnamed_0.Texture2D = .{ .MipSlice = mip, .PlaneSlice = 0 };
        },
        .d2_array, .cube, .cube_array => {
            result.ViewDimension = dx.D3D12_RTV_DIMENSION_TEXTURE2DARRAY;
            result.unnamed_0.Texture2DArray = .{ .MipSlice = mip, .FirstArraySlice = base_layer, .ArraySize = layers, .PlaneSlice = 0 };
        },
        .d3 => {
            result.ViewDimension = dx.D3D12_RTV_DIMENSION_TEXTURE3D;
            result.unnamed_0.Texture3D = .{ .MipSlice = mip, .FirstWSlice = base_layer, .WSize = layers };
        },
    }
    return result;
}

fn depthStencilViewDesc(format: dx.DXGI_FORMAT, dimension: resource.TextureViewDimension, mip: u32, base_layer: u32, layers: u32) dx.D3D12_DEPTH_STENCIL_VIEW_DESC {
    var result: dx.D3D12_DEPTH_STENCIL_VIEW_DESC = std.mem.zeroes(dx.D3D12_DEPTH_STENCIL_VIEW_DESC);
    result.Format = format;
    result.Flags = dx.D3D12_DSV_FLAG_NONE;
    switch (dimension) {
        .d1 => {
            result.ViewDimension = dx.D3D12_DSV_DIMENSION_TEXTURE1D;
            result.unnamed_0.Texture1D.MipSlice = mip;
        },
        .d1_array => {
            result.ViewDimension = dx.D3D12_DSV_DIMENSION_TEXTURE1DARRAY;
            result.unnamed_0.Texture1DArray = .{ .MipSlice = mip, .FirstArraySlice = base_layer, .ArraySize = layers };
        },
        .d2 => {
            result.ViewDimension = dx.D3D12_DSV_DIMENSION_TEXTURE2D;
            result.unnamed_0.Texture2D.MipSlice = mip;
        },
        .d2_array, .cube, .cube_array => {
            result.ViewDimension = dx.D3D12_DSV_DIMENSION_TEXTURE2DARRAY;
            result.unnamed_0.Texture2DArray = .{ .MipSlice = mip, .FirstArraySlice = base_layer, .ArraySize = layers };
        },
        .d3 => {},
    }
    return result;
}

pub fn destroyTextureView(value: resource.TextureView) void {
    const self = Dx12TextureView.fromHandle(value) catch return;
    if (self.rtv_index) |index| self.owner.?.freeRtv(index);
    if (self.dsv_index) |index| self.owner.?.freeDsv(index);
    if (self.allocator) |allocator| allocator.destroy(self);
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

fn uploadTexture(
    device: *dx.ID3D12Device,
    destination: *dx.ID3D12Resource,
    texture_desc: *const dx.D3D12_RESOURCE_DESC,
    desc: resource.TextureDescriptor,
    data: []const u8,
) !void {
    const packed_row_size = @as(u64, desc.width) * (bytesPerPixel(desc.format) orelse return error.UnsupportedUploadFormat);
    const source_row_size = if (desc.bytes_per_row == 0) packed_row_size else desc.bytes_per_row;
    if (source_row_size < packed_row_size or data.len < source_row_size * desc.height) return error.InitialDataTooSmall;

    var footprint: dx.D3D12_PLACED_SUBRESOURCE_FOOTPRINT = undefined;
    var row_count: u32 = 0;
    var row_size: u64 = 0;
    var upload_size: u64 = 0;
    device.lpVtbl.*.GetCopyableFootprints.?(device, texture_desc, 0, 1, 0, &footprint, &row_count, &row_size, &upload_size);

    var upload: ComPtr(dx.ID3D12Resource) = .{};
    defer upload.deinit();
    try createCommittedBuffer(device, dx.D3D12_HEAP_TYPE_UPLOAD, upload_size, dx.D3D12_RESOURCE_FLAG_NONE, dx.D3D12_RESOURCE_STATE_GENERIC_READ, &upload);
    var mapped: ?*anyopaque = null;
    const read_range = dx.D3D12_RANGE{ .Begin = 0, .End = 0 };
    try checkHr(upload.unwrap().lpVtbl.*.Map.?(upload.unwrap(), 0, &read_range, &mapped));
    const destination_bytes: [*]u8 = @ptrCast(mapped orelse return error.MapFailed);
    for (0..row_count) |row| {
        const source_offset = row * source_row_size;
        const destination_offset = footprint.Offset + row * footprint.Footprint.RowPitch;
        @memcpy(destination_bytes[destination_offset..][0..row_size], data[source_offset..][0..row_size]);
    }
    upload.unwrap().lpVtbl.*.Unmap.?(upload.unwrap(), 0, null);

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
    try checkHr(device.lpVtbl.*.CreateCommandList.?(device, 0, dx.D3D12_COMMAND_LIST_TYPE_COPY, allocator.unwrap(), null, &dx.IID_ID3D12GraphicsCommandList, @ptrCast(list.put())));

    const commands = list.unwrap();
    const source = dx.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = upload.unwrap(),
        .Type = dx.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
        .unnamed_0 = .{ .PlacedFootprint = footprint },
    };
    const target = dx.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = destination,
        .Type = dx.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
        .unnamed_0 = .{ .SubresourceIndex = 0 },
    };
    commands.lpVtbl.*.CopyTextureRegion.?(commands, &target, 0, 0, 0, &source, null);
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

fn textureFlags(usage: resource.TextureUsage) dx.D3D12_RESOURCE_FLAGS {
    var flags: dx.D3D12_RESOURCE_FLAGS = dx.D3D12_RESOURCE_FLAG_NONE;
    if (usage.storage) flags |= dx.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    if (usage.color_attachment) flags |= dx.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    if (usage.depth_stencil_attachment) flags |= dx.D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    return flags;
}

test "every public texture format has a DXGI mapping" {
    for (std.meta.tags(resource.Format)) |format| {
        if (format == .undefined) continue;
        try std.testing.expect(toDxFormat(format) != dx.DXGI_FORMAT_UNKNOWN);
    }
}

pub fn bytesPerPixel(format: resource.Format) ?u64 {
    return switch (format) {
        .undefined => null,
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint, .stencil8 => 1,
        .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint, .r16_unorm, .r16_snorm, .r16_uint, .r16_sint, .r16_float, .d16_unorm => 2,
        .rgba8_unorm, .rgba8_snorm, .rgba8_uint, .rgba8_sint, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb, .rg16_unorm, .rg16_snorm, .rg16_uint, .rg16_sint, .rg16_float, .r32_uint, .r32_sint, .r32_float, .rgb10a2_unorm, .rg11b10_float, .d24_unorm_s8_uint, .d32_float => 4,
        .rgba16_unorm, .rgba16_snorm, .rgba16_uint, .rgba16_sint, .rgba16_float, .rg32_uint, .rg32_sint, .rg32_float, .d32_float_s8_uint => 8,
        .rgb32_uint, .rgb32_sint, .rgb32_float => 12,
        .rgba32_uint, .rgba32_sint, .rgba32_float => 16,
        .bc1_rgba_unorm, .bc1_rgba_unorm_srgb, .bc2_rgba_unorm, .bc2_rgba_unorm_srgb, .bc3_rgba_unorm, .bc3_rgba_unorm_srgb, .bc4_r_unorm, .bc4_r_snorm, .bc5_rg_unorm, .bc5_rg_snorm, .bc6h_rgb_ufloat, .bc6h_rgb_float, .bc7_rgba_unorm, .bc7_rgba_unorm_srgb => null,
    };
}

pub fn toDxFormat(format: resource.Format) dx.DXGI_FORMAT {
    return switch (format) {
        .undefined => dx.DXGI_FORMAT_UNKNOWN,
        .r8_unorm => dx.DXGI_FORMAT_R8_UNORM,
        .r8_snorm => dx.DXGI_FORMAT_R8_SNORM,
        .r8_uint => dx.DXGI_FORMAT_R8_UINT,
        .r8_sint => dx.DXGI_FORMAT_R8_SINT,
        .rg8_unorm => dx.DXGI_FORMAT_R8G8_UNORM,
        .rg8_snorm => dx.DXGI_FORMAT_R8G8_SNORM,
        .rg8_uint => dx.DXGI_FORMAT_R8G8_UINT,
        .rg8_sint => dx.DXGI_FORMAT_R8G8_SINT,
        .rgba8_unorm => dx.DXGI_FORMAT_R8G8B8A8_UNORM,
        .rgba8_snorm => dx.DXGI_FORMAT_R8G8B8A8_SNORM,
        .rgba8_uint => dx.DXGI_FORMAT_R8G8B8A8_UINT,
        .rgba8_sint => dx.DXGI_FORMAT_R8G8B8A8_SINT,
        .rgba8_unorm_srgb => dx.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        .bgra8_unorm => dx.DXGI_FORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => dx.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        .r16_float => dx.DXGI_FORMAT_R16_FLOAT,
        .r16_unorm => dx.DXGI_FORMAT_R16_UNORM,
        .r16_snorm => dx.DXGI_FORMAT_R16_SNORM,
        .r16_uint => dx.DXGI_FORMAT_R16_UINT,
        .r16_sint => dx.DXGI_FORMAT_R16_SINT,
        .rg16_float => dx.DXGI_FORMAT_R16G16_FLOAT,
        .rg16_unorm => dx.DXGI_FORMAT_R16G16_UNORM,
        .rg16_snorm => dx.DXGI_FORMAT_R16G16_SNORM,
        .rg16_uint => dx.DXGI_FORMAT_R16G16_UINT,
        .rg16_sint => dx.DXGI_FORMAT_R16G16_SINT,
        .rgba16_float => dx.DXGI_FORMAT_R16G16B16A16_FLOAT,
        .rgba16_unorm => dx.DXGI_FORMAT_R16G16B16A16_UNORM,
        .rgba16_snorm => dx.DXGI_FORMAT_R16G16B16A16_SNORM,
        .rgba16_uint => dx.DXGI_FORMAT_R16G16B16A16_UINT,
        .rgba16_sint => dx.DXGI_FORMAT_R16G16B16A16_SINT,
        .r32_float => dx.DXGI_FORMAT_R32_FLOAT,
        .r32_uint => dx.DXGI_FORMAT_R32_UINT,
        .r32_sint => dx.DXGI_FORMAT_R32_SINT,
        .rg32_float => dx.DXGI_FORMAT_R32G32_FLOAT,
        .rg32_uint => dx.DXGI_FORMAT_R32G32_UINT,
        .rg32_sint => dx.DXGI_FORMAT_R32G32_SINT,
        .rgb32_float => dx.DXGI_FORMAT_R32G32B32_FLOAT,
        .rgb32_uint => dx.DXGI_FORMAT_R32G32B32_UINT,
        .rgb32_sint => dx.DXGI_FORMAT_R32G32B32_SINT,
        .rgba32_float => dx.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .rgba32_uint => dx.DXGI_FORMAT_R32G32B32A32_UINT,
        .rgba32_sint => dx.DXGI_FORMAT_R32G32B32A32_SINT,
        .rgb10a2_unorm => dx.DXGI_FORMAT_R10G10B10A2_UNORM,
        .rg11b10_float => dx.DXGI_FORMAT_R11G11B10_FLOAT,
        .bc1_rgba_unorm => dx.DXGI_FORMAT_BC1_UNORM,
        .bc1_rgba_unorm_srgb => dx.DXGI_FORMAT_BC1_UNORM_SRGB,
        .bc2_rgba_unorm => dx.DXGI_FORMAT_BC2_UNORM,
        .bc2_rgba_unorm_srgb => dx.DXGI_FORMAT_BC2_UNORM_SRGB,
        .bc3_rgba_unorm => dx.DXGI_FORMAT_BC3_UNORM,
        .bc3_rgba_unorm_srgb => dx.DXGI_FORMAT_BC3_UNORM_SRGB,
        .bc4_r_unorm => dx.DXGI_FORMAT_BC4_UNORM,
        .bc4_r_snorm => dx.DXGI_FORMAT_BC4_SNORM,
        .bc5_rg_unorm => dx.DXGI_FORMAT_BC5_UNORM,
        .bc5_rg_snorm => dx.DXGI_FORMAT_BC5_SNORM,
        .bc6h_rgb_ufloat => dx.DXGI_FORMAT_BC6H_UF16,
        .bc6h_rgb_float => dx.DXGI_FORMAT_BC6H_SF16,
        .bc7_rgba_unorm => dx.DXGI_FORMAT_BC7_UNORM,
        .bc7_rgba_unorm_srgb => dx.DXGI_FORMAT_BC7_UNORM_SRGB,
        .stencil8 => dx.DXGI_FORMAT_X24_TYPELESS_G8_UINT,
        .d16_unorm => dx.DXGI_FORMAT_D16_UNORM,
        .d24_unorm_s8_uint => dx.DXGI_FORMAT_D24_UNORM_S8_UINT,
        .d32_float => dx.DXGI_FORMAT_D32_FLOAT,
        .d32_float_s8_uint => dx.DXGI_FORMAT_D32_FLOAT_S8X24_UINT,
    };
}

test "memory locations select their native heap types" {
    try std.testing.expectEqual(@as(dx.D3D12_HEAP_TYPE, dx.D3D12_HEAP_TYPE_DEFAULT), heapType(.device));
    try std.testing.expectEqual(@as(dx.D3D12_HEAP_TYPE, dx.D3D12_HEAP_TYPE_UPLOAD), heapType(.upload));
    try std.testing.expectEqual(@as(dx.D3D12_HEAP_TYPE, dx.D3D12_HEAP_TYPE_READBACK), heapType(.readback));
}
