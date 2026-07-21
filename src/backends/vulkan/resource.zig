const std = @import("std");
const vk = @import("vulkan");
const resource = @import("../../interface/resource.zig");
const vkDevice = @import("device.zig").vkDevice;
const adapter_impl = @import("adapter.zig");

const log = std.log.scoped(.vk_resource);

pub const vkBuffer = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
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
    aspect: vk.ImageAspectFlags = .{ .color_bit = true },
    layout: vk.ImageLayout = .undefined,

    pub fn fromHandle(value: resource.TextureView) !*vkTextureView {
        if (value.handle == 0) return error.InvalidTextureView;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkTexture = struct {
    allocator: std.mem.Allocator, device: vk.DeviceProxy, image: vk.Image, memory: vk.DeviceMemory,
    format: vk.Format, extent: vk.Extent3D, mip_levels: u32, layers: u32, dimension: resource.TextureDimension,
    layout: vk.ImageLayout = .undefined,
    pub fn fromHandle(value: resource.Texture) !*vkTexture {
        if (value.handle == 0) return error.InvalidTexture;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkSampler = struct {
    allocator: std.mem.Allocator, device: vk.DeviceProxy, handle: vk.Sampler,
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
    const buffer = try device.proxy.createBuffer(&.{
        .size = desc.size,
        .usage = toVkBufferUsage(desc.usage),
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.proxy.destroyBuffer(buffer, null);
    const requirements = device.proxy.getBufferMemoryRequirements(buffer);
    const properties: vk.MemoryPropertyFlags = switch (desc.memory) {
        .device => if (desc.initial_data != null)
            .{ .host_visible_bit = true, .host_coherent_bit = true }
        else
            .{ .device_local_bit = true },
        .upload => .{ .host_visible_bit = true, .host_coherent_bit = true },
        .readback => .{ .host_visible_bit = true, .host_coherent_bit = true, .host_cached_bit = true },
    };
    const memory_type = findMemoryType(device, requirements.memory_type_bits, properties) orelse memory_type: {
        if (desc.memory == .readback) {
            break :memory_type findMemoryType(
                device,
                requirements.memory_type_bits,
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            ) orelse return error.NoSuitableMemoryType;
        }
        return error.NoSuitableMemoryType;
    };
    const memory = try device.proxy.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null);
    errdefer device.proxy.freeMemory(memory, null);
    try device.proxy.bindBufferMemory(buffer, memory, 0);

    const self = try device.allocator.create(vkBuffer);
    self.* = .{
        .allocator = device.allocator,
        .device = device.proxy,
        .buffer = buffer,
        .memory = memory,
        .size = desc.size,
        .location = desc.memory,
    };
    errdefer device.allocator.destroy(self);
    if (desc.initial_data) |data| try writeMemory(self, data);
    device.instance.nameObject(device.allocator, device.proxy, .buffer, @intFromEnum(buffer), desc.label);
    log.debug("created Vulkan buffer size={}", .{desc.size});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &buffer_vtable };
}

fn destroyBuffer(value: resource.Buffer) void {
    const self = vkBuffer.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.device.destroyBuffer(self.buffer, null);
    self.device.freeMemory(self.memory, null);
    allocator.destroy(self);
}

fn mapBuffer(value: resource.Buffer, mode: resource.MapMode, range: resource.BufferRange) anyerror![]u8 {
    const self = try vkBuffer.fromHandle(value);
    if (range.size == 0 or range.offset > self.size or range.size > self.size - range.offset) return error.InvalidMapRange;
    if ((mode == .read and self.location != .readback) or (mode == .write and self.location != .upload))
        return error.InvalidMapMode;
    const data = try self.device.mapMemory(self.memory, range.offset, range.size, .{});
    return @as([*]u8, @ptrCast(data))[0..@intCast(range.size)];
}

fn unmapBuffer(value: resource.Buffer, _: ?resource.BufferRange) void {
    const self = vkBuffer.fromHandle(value) catch return;
    self.device.unmapMemory(self.memory);
}

fn writeMemory(self: *vkBuffer, data: []const u8) !void {
    const mapped = try self.device.mapMemory(self.memory, 0, data.len, .{});
    defer self.device.unmapMemory(self.memory);
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..data.len], data);
}

fn findMemoryType(device: *vkDevice, bits: u32, required: vk.MemoryPropertyFlags) ?u32 {
    for (device.memory_props.memory_types[0..device.memory_props.memory_type_count], 0..) |memory_type, index| {
        if ((bits & (@as(u32, 1) << @intCast(index))) != 0 and memory_type.property_flags.contains(required))
            return @intCast(index);
    }
    return null;
}

fn toVkBufferUsage(usage: resource.BufferUsage) vk.BufferUsageFlags {
    return .{
        .vertex_buffer_bit = usage.vertex,
        .index_buffer_bit = usage.index,
        .uniform_buffer_bit = usage.uniform,
        .storage_buffer_bit = usage.storage,
        .indirect_buffer_bit = usage.indirect,
        .transfer_src_bit = usage.transfer_src,
        .transfer_dst_bit = usage.transfer_dst,
    };
}

pub fn createTexture(ptr: *anyopaque, desc: resource.TextureDescriptor) !resource.Texture {
    if (desc.width == 0 or desc.height == 0 or desc.depth_or_layers == 0 or desc.mip_levels == 0) return error.InvalidTextureSize;
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const image = try device.proxy.createImage(&.{
        .image_type = switch (desc.dimension) { .d1 => .@"1d", .d2 => .@"2d", .d3 => .@"3d" },
        .format = adapter_impl.toVkFormat(desc.format),
        .extent = .{ .width = desc.width, .height = desc.height, .depth = if (desc.dimension == .d3) desc.depth_or_layers else 1 },
        .mip_levels = desc.mip_levels,
        .array_layers = if (desc.dimension == .d3) 1 else desc.depth_or_layers,
        .samples = sampleCount(desc.sample_count), .tiling = .optimal,
        .usage = .{ .sampled_bit = desc.usage.sampled, .storage_bit = desc.usage.storage,
            .color_attachment_bit = desc.usage.color_attachment, .depth_stencil_attachment_bit = desc.usage.depth_stencil_attachment,
            .transfer_src_bit = desc.usage.transfer_src, .transfer_dst_bit = desc.usage.transfer_dst or desc.initial_data != null },
        .sharing_mode = .exclusive, .initial_layout = .undefined,
    }, null);
    errdefer device.proxy.destroyImage(image, null);
    const req = device.proxy.getImageMemoryRequirements(image);
    const memory_type = findMemoryType(device, req.memory_type_bits, .{ .device_local_bit = true }) orelse return error.NoSuitableMemoryType;
    const memory = try device.proxy.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = memory_type }, null);
    errdefer device.proxy.freeMemory(memory, null);
    try device.proxy.bindImageMemory(image, memory, 0);
    if (desc.initial_data) |data| try uploadTexture(device, image, adapter_impl.toVkFormat(desc.format), desc, data);
    const self = try device.allocator.create(vkTexture);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .image = image, .memory = memory,
        .format = adapter_impl.toVkFormat(desc.format), .extent = .{ .width = desc.width, .height = desc.height, .depth = if (desc.dimension == .d3) desc.depth_or_layers else 1 },
        .mip_levels = desc.mip_levels, .layers = if (desc.dimension == .d3) 1 else desc.depth_or_layers, .dimension = desc.dimension,
        .layout = if (desc.initial_data != null) .general else .undefined };
    device.instance.nameObject(device.allocator, device.proxy, .image, @intFromEnum(image), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &texture_vtable };
}

pub fn createTextureView(ptr: *anyopaque, desc: resource.TextureViewDescriptor) !resource.TextureView {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const texture = try vkTexture.fromHandle(desc.texture);
    const levels = desc.mip_count orelse texture.mip_levels - desc.base_mip;
    const layers = desc.layer_count orelse texture.layers - desc.base_layer;
    if (levels == 0 or layers == 0 or desc.base_mip >= texture.mip_levels or desc.base_layer >= texture.layers) return error.InvalidTextureViewRange;
    const aspect = aspectMask(desc.aspect, texture.format);
    const handle = try device.proxy.createImageView(&.{ .image = texture.image,
        .view_type = viewType(desc.dimension orelse defaultViewDimension(texture.dimension, texture.layers)),
        .format = if (desc.format) |format| adapter_impl.toVkFormat(format) else texture.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{ .aspect_mask = aspect, .base_mip_level = desc.base_mip, .level_count = levels, .base_array_layer = desc.base_layer, .layer_count = layers },
    }, null);
    errdefer device.proxy.destroyImageView(handle, null);
    const self = try device.allocator.create(vkTextureView);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .view = handle, .image = texture.image, .format = texture.format,
        .extent = .{ .width = texture.extent.width, .height = texture.extent.height }, .aspect = aspect, .layout = texture.layout };
    device.instance.nameObject(device.allocator, device.proxy, .image_view, @intFromEnum(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &texture_view_vtable };
}

pub fn createSampler(ptr: *anyopaque, desc: resource.SamplerDescriptor) !resource.Sampler {
    if (desc.max_anisotropy == 0 or desc.lod_min > desc.lod_max) return error.InvalidSamplerDescriptor;
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const handle = try device.proxy.createSampler(&.{
        .mag_filter = filter(desc.mag_filter), .min_filter = filter(desc.min_filter), .mipmap_mode = if (desc.mipmap_filter == .linear) .linear else .nearest,
        .address_mode_u = address(desc.address_u), .address_mode_v = address(desc.address_v), .address_mode_w = address(desc.address_w),
        .anisotropy_enable = if (desc.max_anisotropy > 1) .true else .false, .max_anisotropy = @floatFromInt(desc.max_anisotropy),
        .compare_enable = if (desc.compare != null) .true else .false, .compare_op = compare(desc.compare orelse .always),
        .mip_lod_bias = 0, .min_lod = desc.lod_min, .max_lod = desc.lod_max, .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    }, null);
    errdefer device.proxy.destroySampler(handle, null);
    const self = try device.allocator.create(vkSampler);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = handle };
    device.instance.nameObject(device.allocator, device.proxy, .sampler, @intFromEnum(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &sampler_vtable };
}

fn destroyTexture(value: resource.Texture) void { const self = vkTexture.fromHandle(value) catch return; const a = self.allocator; self.device.destroyImage(self.image, null); self.device.freeMemory(self.memory, null); a.destroy(self); }
fn destroyTextureView(value: resource.TextureView) void { const self = vkTextureView.fromHandle(value) catch return; const a = self.allocator orelse return; self.device.?.destroyImageView(self.view, null); a.destroy(self); }
fn destroySampler(value: resource.Sampler) void { const self = vkSampler.fromHandle(value) catch return; const a = self.allocator; self.device.destroySampler(self.handle, null); a.destroy(self); }

fn uploadTexture(device: *vkDevice, image: vk.Image, format: vk.Format, desc: resource.TextureDescriptor, data: []const u8) !void {
    if (data.len == 0) return error.InvalidInitialData;
    const staging = try device.proxy.createBuffer(&.{ .size = data.len, .usage = .{ .transfer_src_bit = true }, .sharing_mode = .exclusive }, null);
    defer device.proxy.destroyBuffer(staging, null);
    const req = device.proxy.getBufferMemoryRequirements(staging);
    const memory_type = findMemoryType(device, req.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }) orelse return error.NoSuitableMemoryType;
    const memory = try device.proxy.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = memory_type }, null);
    defer device.proxy.freeMemory(memory, null);
    try device.proxy.bindBufferMemory(staging, memory, 0);
    const mapped = try device.proxy.mapMemory(memory, 0, data.len, .{}); @memcpy(@as([*]u8, @ptrCast(mapped))[0..data.len], data); device.proxy.unmapMemory(memory);
    const pool = try device.proxy.createCommandPool(&.{ .flags = .{ .transient_bit = true }, .queue_family_index = device.queues.graphics_family }, null);
    defer device.proxy.destroyCommandPool(pool, null);
    var cmd: vk.CommandBuffer = undefined;
    try device.proxy.allocateCommandBuffers(&.{ .command_pool = pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&cmd));
    try device.proxy.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
    const aspect = aspectMask(.all, format);
    const range: vk.ImageSubresourceRange = .{ .aspect_mask = aspect, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };
    device.proxy.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, null, null, &.{.{ .src_access_mask = .{}, .dst_access_mask = .{ .transfer_write_bit = true }, .old_layout = .undefined, .new_layout = .transfer_dst_optimal, .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .image = image, .subresource_range = range }});
    const block = formatBlock(desc.format);
    if (desc.bytes_per_row != 0 and desc.bytes_per_row % block.bytes != 0) return error.InvalidBytesPerRow;
    const row_length = if (desc.bytes_per_row == 0) 0 else desc.bytes_per_row / block.bytes * block.width;
    device.proxy.cmdCopyBufferToImage(cmd, staging, image, .transfer_dst_optimal, &.{.{ .buffer_offset = 0, .buffer_row_length = row_length, .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = aspect, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 }, .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = desc.width, .height = desc.height, .depth = if (desc.dimension == .d3) desc.depth_or_layers else 1 } }});
    device.proxy.cmdPipelineBarrier(cmd, .{ .transfer_bit = true }, .{ .all_commands_bit = true }, .{}, null, null, &.{.{ .src_access_mask = .{ .transfer_write_bit = true }, .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true }, .old_layout = .transfer_dst_optimal, .new_layout = .general, .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED, .image = image, .subresource_range = range }});
    try device.proxy.endCommandBuffer(cmd);
    const queue = device.proxy.getDeviceQueue(device.queues.graphics_family, 0);
    try device.proxy.queueSubmit(queue, &.{.{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd) }}, .null_handle);
    try device.proxy.queueWaitIdle(queue);
}

const FormatBlock = struct { width: u32 = 1, bytes: u32 };
fn formatBlock(format: resource.Format) FormatBlock { return switch (format) {
    .r8_unorm, .r8_snorm, .r8_uint, .r8_sint, .stencil8 => .{ .bytes = 1 },
    .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint, .r16_unorm, .r16_snorm, .r16_uint, .r16_sint, .r16_float, .d16_unorm => .{ .bytes = 2 },
    .rgba8_unorm, .rgba8_snorm, .rgba8_uint, .rgba8_sint, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb, .rg16_unorm, .rg16_snorm, .rg16_uint, .rg16_sint, .rg16_float, .r32_uint, .r32_sint, .r32_float, .rgb10a2_unorm, .rg11b10_float, .d24_unorm_s8_uint, .d32_float => .{ .bytes = 4 },
    .rgba16_unorm, .rgba16_snorm, .rgba16_uint, .rgba16_sint, .rgba16_float, .rg32_uint, .rg32_sint, .rg32_float, .d32_float_s8_uint => .{ .bytes = 8 },
    .rgb32_uint, .rgb32_sint, .rgb32_float => .{ .bytes = 12 }, .rgba32_uint, .rgba32_sint, .rgba32_float => .{ .bytes = 16 },
    .bc1_rgba_unorm, .bc1_rgba_unorm_srgb, .bc4_r_unorm, .bc4_r_snorm => .{ .width = 4, .bytes = 8 },
    .bc2_rgba_unorm, .bc2_rgba_unorm_srgb, .bc3_rgba_unorm, .bc3_rgba_unorm_srgb, .bc5_rg_unorm, .bc5_rg_snorm, .bc6h_rgb_ufloat, .bc6h_rgb_float, .bc7_rgba_unorm, .bc7_rgba_unorm_srgb => .{ .width = 4, .bytes = 16 },
    .undefined => .{ .bytes = 1 },
}; }
fn sampleCount(n: u32) vk.SampleCountFlags { return switch (n) { 1 => .{ .@"1_bit" = true }, 2 => .{ .@"2_bit" = true }, 4 => .{ .@"4_bit" = true }, 8 => .{ .@"8_bit" = true }, 16 => .{ .@"16_bit" = true }, 32 => .{ .@"32_bit" = true }, 64 => .{ .@"64_bit" = true }, else => .{} }; }
fn defaultViewDimension(d: resource.TextureDimension, layers: u32) resource.TextureViewDimension { return switch (d) { .d1 => if (layers > 1) .d1_array else .d1, .d2 => if (layers > 1) .d2_array else .d2, .d3 => .d3 }; }
fn viewType(d: resource.TextureViewDimension) vk.ImageViewType { return switch (d) { .d1 => .@"1d", .d1_array => .@"1d_array", .d2 => .@"2d", .d2_array => .@"2d_array", .cube => .cube, .cube_array => .cube_array, .d3 => .@"3d" }; }
fn aspectMask(a: resource.TextureAspect, format: vk.Format) vk.ImageAspectFlags { return switch (a) { .color => .{ .color_bit = true }, .depth => .{ .depth_bit = true }, .stencil => .{ .stencil_bit = true }, .all => switch (format) { .s8_uint => .{ .stencil_bit = true }, .d16_unorm, .d32_sfloat => .{ .depth_bit = true }, .d24_unorm_s8_uint, .d32_sfloat_s8_uint => .{ .depth_bit = true, .stencil_bit = true }, else => .{ .color_bit = true } } }; }
fn filter(v: resource.FilterMode) vk.Filter { return if (v == .linear) .linear else .nearest; }
fn address(v: resource.AddressMode) vk.SamplerAddressMode { return switch (v) { .repeat => .repeat, .mirror_repeat => .mirrored_repeat, .clamp_to_edge => .clamp_to_edge }; }
pub fn compare(v: resource.CompareOp) vk.CompareOp { return switch (v) { .never => .never, .less => .less, .equal => .equal, .less_equal => .less_or_equal, .greater => .greater, .not_equal => .not_equal, .greater_equal => .greater_or_equal, .always => .always }; }

fn deinitBorrowedTextureView(_: resource.TextureView) void {}
