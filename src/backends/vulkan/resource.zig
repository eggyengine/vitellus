const std = @import("std");
const vk = @import("vulkan");
const resource = @import("../../interface/resource.zig");
const texture_layout = @import("../../interface/texture_layout.zig");
const vkDevice = @import("device.zig").vkDevice;
const adapter_impl = @import("adapter.zig");
const vma = @import("vma.zig");

const log = std.log.scoped(.vk_resource);

pub const vkBuffer = struct {
    allocator: std.mem.Allocator,
    memory: vma.Allocator,
    buffer: vk.Buffer,
    allocation: vma.Allocation,
    /// The whole buffer, mapped for its life, unless it lives in `.device` memory without initial data.
    mapped: ?[*]u8,
    size: u64,
    location: resource.MemoryLocation,

    pub fn fromHandle(value: resource.Buffer) !*vkBuffer {
        if (value.handle == 0) return error.InvalidBuffer;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkTextureView = struct {
    allocator: ?std.mem.Allocator = null,
    device: ?vk.DeviceProxy = null,
    view: vk.ImageView,
    image: vk.Image,
    format: vk.Format,
    extent: vk.Extent2D,
    aspect: vk.ImageAspectFlags = .{ .color = true },
    layout: vk.ImageLayout = .undefined,

    pub fn fromHandle(value: resource.TextureView) !*vkTextureView {
        if (value.handle == 0) return error.InvalidTextureView;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkTexture = struct {
    allocator: std.mem.Allocator,
    memory: vma.Allocator,
    image: vk.Image,
    allocation: vma.Allocation,
    format: vk.Format,
    extent: vk.Extent3D,
    mip_levels: u32,
    layers: u32,
    dimension: resource.TextureDimension,
    layout: vk.ImageLayout = .undefined,
    pub fn fromHandle(value: resource.Texture) !*vkTexture {
        if (value.handle == 0) return error.InvalidTexture;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkSampler = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.Sampler,
    pub fn fromHandle(value: resource.Sampler) !*vkSampler {
        if (value.handle == 0) return error.InvalidSampler;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const buffer_vtable: resource.Buffer.VTable = .{
    .deinitFn = destroyBuffer,
    .mapFn = mapBuffer,
    .unmapFn = unmapBuffer,
};
pub const borrowed_texture_view_vtable: resource.TextureView.VTable = .{ .deinitFn = deinitBorrowedTextureView };
const texture_vtable: resource.Texture.VTable = .{ .deinitFn = destroyTexture };
const texture_view_vtable: resource.TextureView.VTable = .{ .deinitFn = destroyTextureView };
const sampler_vtable: resource.Sampler.VTable = .{ .deinitFn = destroySampler };

pub fn createBuffer(ptr: *anyopaque, desc: resource.BufferDescriptor) anyerror!resource.Buffer {
    if (desc.size == 0) return error.InvalidBufferSize;
    if (desc.initial_data) |data| {
        if (data.len > desc.size) return error.InitialDataTooLarge;
        if (desc.memory == .readback) return error.InvalidInitialData;
    }

    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    // Device memory with initial data stays CPU-writable, so the data is copied straight in.
    const host_access: vma.HostAccess = switch (desc.memory) {
        .device => if (desc.initial_data != null) .write else .none,
        .upload => .write,
        .readback => .read,
    };
    const made = try vma.createBuffer(device.memory, &.{
        .size = desc.size,
        .usage = toVkBufferUsage(desc.usage),
        .sharing_mode = .exclusive,
    }, host_access);
    errdefer vma.destroyBuffer(device.memory, made.buffer, made.allocation);
    if (desc.initial_data) |data| @memcpy(made.mapped.?[0..data.len], data);

    const self = try device.allocator.create(vkBuffer);
    self.* = .{
        .allocator = device.allocator,
        .memory = device.memory,
        .buffer = made.buffer,
        .allocation = made.allocation,
        .mapped = made.mapped,
        .size = desc.size,
        .location = desc.memory,
    };
    device.instance.nameObject(device.allocator, device.proxy, .buffer, @backingInt(made.buffer), desc.label);
    log.debug("created Vulkan buffer size={}", .{desc.size});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &buffer_vtable };
}

fn destroyBuffer(value: resource.Buffer) void {
    const self = vkBuffer.fromHandle(value) catch return;
    const allocator = self.allocator;
    vma.destroyBuffer(self.memory, self.buffer, self.allocation);
    allocator.destroy(self);
}

fn mapBuffer(value: resource.Buffer, mode: resource.MapMode, range: resource.BufferRange) anyerror![]u8 {
    const self = try vkBuffer.fromHandle(value);
    if (range.size == 0 or range.offset > self.size or range.size > self.size - range.offset) return error.InvalidMapRange;
    if ((mode == .read and self.location != .readback) or (mode == .write and self.location != .upload))
        return error.InvalidMapMode;
    const mapped = self.mapped orelse return error.InvalidMapMode;
    return mapped[@intCast(range.offset)..][0..@intCast(range.size)];
}

// Host memory is coherent and stays mapped, so there is nothing to flush or unmap.
fn unmapBuffer(_: resource.Buffer, _: ?resource.BufferRange) void {}

fn toVkBufferUsage(usage: resource.BufferUsage) vk.BufferUsageFlags {
    return .{
        .vertex_buffer = usage.vertex,
        .index_buffer = usage.index,
        .uniform_buffer = usage.uniform,
        .storage_buffer = usage.storage,
        .indirect_buffer = usage.indirect,
        .transfer_src = usage.transfer_src,
        .transfer_dst = usage.transfer_dst,
    };
}

pub fn createTexture(ptr: *anyopaque, desc: resource.TextureDescriptor) !resource.Texture {
    if (desc.width == 0 or desc.height == 0 or desc.depth_or_layers == 0 or desc.mip_levels == 0) return error.InvalidTextureSize;
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const made = try vma.createImage(device.memory, &.{
        .image_type = switch (desc.dimension) {
            .d1 => .@"1d",
            .d2 => .@"2d",
            .d3 => .@"3d",
        },
        .format = adapter_impl.toVkFormat(desc.format),
        .extent = .{ .width = desc.width, .height = desc.height, .depth = if (desc.dimension == .d3) desc.depth_or_layers else 1 },
        .mip_levels = desc.mip_levels,
        .array_layers = if (desc.dimension == .d3) 1 else desc.depth_or_layers,
        .samples = sampleCount(desc.sample_count),
        .tiling = .optimal,
        .usage = .{ .sampled = desc.usage.sampled, .storage = desc.usage.storage, .color_attachment = desc.usage.color_attachment, .depth_stencil_attachment = desc.usage.depth_stencil_attachment, .transfer_src = desc.usage.transfer_src, .transfer_dst = desc.usage.transfer_dst or desc.initial_data != null },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    });
    errdefer vma.destroyImage(device.memory, made.image, made.allocation);
    const image = made.image;
    if (desc.initial_data) |data| try uploadTexture(device, image, adapter_impl.toVkFormat(desc.format), desc, data);
    const self = try device.allocator.create(vkTexture);
    self.* = .{ .allocator = device.allocator, .memory = device.memory, .image = image, .allocation = made.allocation, .format = adapter_impl.toVkFormat(desc.format), .extent = .{ .width = desc.width, .height = desc.height, .depth = if (desc.dimension == .d3) desc.depth_or_layers else 1 }, .mip_levels = desc.mip_levels, .layers = if (desc.dimension == .d3) 1 else desc.depth_or_layers, .dimension = desc.dimension, .layout = if (desc.initial_data != null) .general else .undefined };
    device.instance.nameObject(device.allocator, device.proxy, .image, @backingInt(image), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &texture_vtable };
}

pub fn createTextureView(ptr: *anyopaque, desc: resource.TextureViewDescriptor) !resource.TextureView {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const texture = try vkTexture.fromHandle(desc.texture);
    const levels = desc.mip_count orelse texture.mip_levels - desc.base_mip;
    const layers = desc.layer_count orelse texture.layers - desc.base_layer;
    if (levels == 0 or layers == 0 or desc.base_mip >= texture.mip_levels or desc.base_layer >= texture.layers) return error.InvalidTextureViewRange;
    const aspect = aspectMask(desc.aspect, texture.format);
    const handle = try device.proxy.createImageView(&.{
        .image = texture.image,
        .view_type = viewType(desc.dimension orelse defaultViewDimension(texture.dimension, texture.layers)),
        .format = if (desc.format) |format| adapter_impl.toVkFormat(format) else texture.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{ .aspect_mask = aspect, .base_mip_level = desc.base_mip, .level_count = levels, .base_array_layer = desc.base_layer, .layer_count = layers },
    }, null);
    errdefer device.proxy.destroyImageView(handle, null);
    const self = try device.allocator.create(vkTextureView);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .view = handle, .image = texture.image, .format = texture.format, .extent = .{ .width = texture.extent.width, .height = texture.extent.height }, .aspect = aspect, .layout = texture.layout };
    device.instance.nameObject(device.allocator, device.proxy, .image_view, @backingInt(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &texture_view_vtable };
}

pub fn createSampler(ptr: *anyopaque, desc: resource.SamplerDescriptor) !resource.Sampler {
    if (desc.max_anisotropy == 0 or desc.lod_min > desc.lod_max) return error.InvalidSamplerDescriptor;
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const handle = try device.proxy.createSampler(&.{
        .mag_filter = filter(desc.mag_filter),
        .min_filter = filter(desc.min_filter),
        .mipmap_mode = if (desc.mipmap_filter == .linear) .linear else .nearest,
        .address_mode_u = address(desc.address_u),
        .address_mode_v = address(desc.address_v),
        .address_mode_w = address(desc.address_w),
        .anisotropy_enable = if (desc.max_anisotropy > 1) .true else .false,
        .max_anisotropy = @floatFromInt(desc.max_anisotropy),
        .compare_enable = if (desc.compare != null) .true else .false,
        .compare_op = compare(desc.compare orelse .always),
        .mip_lod_bias = 0,
        .min_lod = desc.lod_min,
        .max_lod = desc.lod_max,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    }, null);
    errdefer device.proxy.destroySampler(handle, null);
    const self = try device.allocator.create(vkSampler);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = handle };
    device.instance.nameObject(device.allocator, device.proxy, .sampler, @backingInt(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &sampler_vtable };
}

fn destroyTexture(value: resource.Texture) void {
    const self = vkTexture.fromHandle(value) catch return;
    const a = self.allocator;
    vma.destroyImage(self.memory, self.image, self.allocation);
    a.destroy(self);
}
fn destroyTextureView(value: resource.TextureView) void {
    const self = vkTextureView.fromHandle(value) catch return;
    const a = self.allocator orelse return;
    self.device.?.destroyImageView(self.view, null);
    a.destroy(self);
}
fn destroySampler(value: resource.Sampler) void {
    const self = vkSampler.fromHandle(value) catch return;
    const a = self.allocator;
    self.device.destroySampler(self.handle, null);
    a.destroy(self);
}

fn uploadTexture(device: *vkDevice, image: vk.Image, format: vk.Format, desc: resource.TextureDescriptor, data: []const u8) !void {
    // One copy per subresource the data covers; the walk validates it first.
    var regions: std.ArrayList(vk.BufferImageCopy) = .empty;
    defer regions.deinit(device.allocator);
    const aspect = aspectMask(.all, format);
    const block = texture_layout.block(desc.format).?;
    var walk: texture_layout.Iterator = try .init(desc);
    while (try walk.next()) |sub| try regions.append(device.allocator, .{
        .buffer_offset = sub.offset,
        .buffer_row_length = @intCast(sub.bytes_per_row / block.bytes * block.width),
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = aspect, .mip_level = sub.mip, .base_array_layer = sub.layer, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = sub.width, .height = sub.height, .depth = sub.depth },
    });

    const made = try vma.createBuffer(device.memory, &.{ .size = data.len, .usage = .{ .transfer_src = true }, .sharing_mode = .exclusive }, .write);
    defer vma.destroyBuffer(device.memory, made.buffer, made.allocation);
    @memcpy(made.mapped.?[0..data.len], data);
    const pool = try device.proxy.createCommandPool(&.{ .flags = .{ .transient = true }, .queue_family_index = device.queues.graphics_family }, null);
    defer device.proxy.destroyCommandPool(pool, null);
    var cmd: vk.CommandBuffer = undefined;
    try device.proxy.allocateCommandBuffers(&.{ .command_pool = pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&cmd));
    try device.proxy.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
    const range: vk.ImageSubresourceRange = .{ .aspect_mask = aspect, .base_mip_level = 0, .level_count = vk.REMAINING_MIP_LEVELS, .base_array_layer = 0, .layer_count = vk.REMAINING_ARRAY_LAYERS };
    device.proxy.cmdPipelineBarrier(cmd, .{ .top_of_pipe = true }, .{ .transfer = true }, .{}, null, null, &.{.{ .src_access_mask = .{}, .dst_access_mask = .{ .transfer_write = true }, .old_layout = .undefined, .new_layout = .transfer_dst_optimal, .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .image = image, .subresource_range = range }});
    device.proxy.cmdCopyBufferToImage(cmd, made.buffer, image, .transfer_dst_optimal, regions.items);
    device.proxy.cmdPipelineBarrier(cmd, .{ .transfer = true }, .{ .all_commands = true }, .{}, null, null, &.{.{ .src_access_mask = .{ .transfer_write = true }, .dst_access_mask = .{ .memory_read = true, .memory_write = true }, .old_layout = .transfer_dst_optimal, .new_layout = .general, .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .image = image, .subresource_range = range }});
    try device.proxy.endCommandBuffer(cmd);
    const queue = device.proxy.getDeviceQueue(device.queues.graphics_family, 0);
    try device.proxy.queueSubmit(queue, &.{.{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd) }}, .null);
    try device.proxy.queueWaitIdle(queue);
}

const FormatBlock = struct { width: u32 = 1, bytes: u32 };
fn formatBlock(format: vk.Format) !FormatBlock {
    return switch (format) {
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint, .s8_uint => .{ .bytes = 1 },
        .r8g8_unorm, .r8g8_snorm, .r8g8_uint, .r8g8_sint, .r16_unorm, .r16_snorm, .r16_uint, .r16_sint, .r16_sfloat, .d16_unorm => .{ .bytes = 2 },
        .r8g8b8a8_unorm, .r8g8b8a8_snorm, .r8g8b8a8_uint, .r8g8b8a8_sint, .r8g8b8a8_srgb, .b8g8r8a8_unorm, .b8g8r8a8_srgb, .r16g16_unorm, .r16g16_snorm, .r16g16_uint, .r16g16_sint, .r16g16_sfloat, .r32_uint, .r32_sint, .r32_sfloat, .a2b10g10r10_unorm_pack32, .b10g11r11_ufloat_pack32, .d24_unorm_s8_uint, .d32_sfloat => .{ .bytes = 4 },
        .r16g16b16a16_unorm, .r16g16b16a16_snorm, .r16g16b16a16_uint, .r16g16b16a16_sint, .r16g16b16a16_sfloat, .r32g32_uint, .r32g32_sint, .r32g32_sfloat, .d32_sfloat_s8_uint => .{ .bytes = 8 },
        .r32g32b32_uint, .r32g32b32_sint, .r32g32b32_sfloat => .{ .bytes = 12 },
        .r32g32b32a32_uint, .r32g32b32a32_sint, .r32g32b32a32_sfloat => .{ .bytes = 16 },
        .bc1_rgba_unorm_block, .bc1_rgba_srgb_block, .bc4_unorm_block, .bc4_snorm_block => .{ .width = 4, .bytes = 8 },
        .bc2_unorm_block, .bc2_srgb_block, .bc3_unorm_block, .bc3_srgb_block, .bc5_unorm_block, .bc5_snorm_block, .bc6h_ufloat_block, .bc6h_sfloat_block, .bc7_unorm_block, .bc7_srgb_block => .{ .width = 4, .bytes = 16 },
        else => error.UnsupportedCopyFormat,
    };
}

/// Convert a byte row pitch to Vulkan's texel count, accounting for compressed blocks.
pub fn bufferRowLength(format: vk.Format, bytes_per_row: u32) !u32 {
    if (bytes_per_row == 0) return 0;
    const block = try formatBlock(format);
    if (bytes_per_row % block.bytes != 0) return error.InvalidBytesPerRow;
    return bytes_per_row / block.bytes * block.width;
}
fn sampleCount(n: u32) vk.SampleCountFlags {
    return switch (n) {
        1 => .{ .@"1" = true },
        2 => .{ .@"2" = true },
        4 => .{ .@"4" = true },
        8 => .{ .@"8" = true },
        16 => .{ .@"16" = true },
        32 => .{ .@"32" = true },
        64 => .{ .@"64" = true },
        else => .{},
    };
}
fn defaultViewDimension(d: resource.TextureDimension, layers: u32) resource.TextureViewDimension {
    return switch (d) {
        .d1 => if (layers > 1) .d1_array else .d1,
        .d2 => if (layers > 1) .d2_array else .d2,
        .d3 => .d3,
    };
}
fn viewType(d: resource.TextureViewDimension) vk.ImageViewType {
    return switch (d) {
        .d1 => .@"1d",
        .d1_array => .@"1d_array",
        .d2 => .@"2d",
        .d2_array => .@"2d_array",
        .cube => .cube,
        .cube_array => .cube_array,
        .d3 => .@"3d",
    };
}
/// The aspects (depth, stencil, colour) a format has.
pub fn formatAspects(format: vk.Format) vk.ImageAspectFlags {
    return aspectMask(.all, format);
}

fn aspectMask(a: resource.TextureAspect, format: vk.Format) vk.ImageAspectFlags {
    return switch (a) {
        .color => .{ .color = true },
        .depth => .{ .depth = true },
        .stencil => .{ .stencil = true },
        .all => switch (format) {
            .s8_uint => .{ .stencil = true },
            .d16_unorm, .d32_sfloat => .{ .depth = true },
            .d24_unorm_s8_uint, .d32_sfloat_s8_uint => .{ .depth = true, .stencil = true },
            else => .{ .color = true },
        },
    };
}
fn filter(v: resource.FilterMode) vk.Filter {
    return if (v == .linear) .linear else .nearest;
}
fn address(v: resource.AddressMode) vk.SamplerAddressMode {
    return switch (v) {
        .repeat => .repeat,
        .mirror_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
    };
}
pub fn compare(v: resource.CompareOp) vk.CompareOp {
    return switch (v) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_or_equal,
        .always => .always,
    };
}

fn deinitBorrowedTextureView(_: resource.TextureView) void {}
