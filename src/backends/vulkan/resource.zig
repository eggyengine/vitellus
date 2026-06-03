const std = @import("std");

const descriptor_set = @import("../../types/descriptor_set.zig");
const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const sampler = @import("../../types/sampler.zig");
const texture = @import("../../types/texture.zig");
const vk = @import("vulkan");
const vkDevice = @import("device.zig").vkDevice;
const debug = @import("debug.zig");
const utils = @import("utils.zig");

pub const vkBuffer = struct {
    device: *vkDevice,
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: def.Size64,
    mapped_ptr: ?[*]u8 = null,
    mapped_offset: def.Size64 = 0,
    mapped_size: def.Size64 = 0,

    is_staging: bool = false,

    pub const vtable = hal.Buffer.VTable{
        .destroy = destroy,
        .mapAsync = mapAsync,
        .getMappedRange = getMappedRange,
        .unmap = unmap,
    };

    pub fn init(device: *vkDevice, descriptor: buffer.Buffer.Descriptor) !hal.Buffer {
        const create_info = vk.BufferCreateInfo{
            .size = descriptor.size,
            .usage = bufferFlagsToVk(descriptor.usage),
            .sharing_mode = .exclusive,
        };
        const handle = try device.device.createBuffer(&create_info, null);
        errdefer device.device.destroyBuffer(handle, null);

        const requirements = device.device.getBufferMemoryRequirements(handle);
        const usage = buffer.Buffer.Usage.fromFlags(descriptor.usage);
        const allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = try findMemoryType(device, requirements.memory_type_bits, memoryFlagsForBuffer(usage, descriptor.mappedAtCreation)),
        };
        const memory = try device.device.allocateMemory(&allocate_info, null);
        errdefer device.device.freeMemory(memory, null);

        try device.device.bindBufferMemory(handle, memory, 0);

        const self = try device.adapter.gpu.allocator.create(vkBuffer);
        errdefer device.adapter.gpu.allocator.destroy(self);
        self.* = .{
            .device = device,
            .handle = handle,
            .memory = memory,
            .size = descriptor.size,
        };
        if (descriptor.mappedAtCreation) {
            const mapped = try device.device.mapMemory(memory, 0, descriptor.size, .{});
            self.mapped_ptr = @ptrCast(mapped);
            self.mapped_offset = 0;
            self.mapped_size = descriptor.size;
        }
        debug.setObjectName(device, .buffer, handle, descriptor.label);

        return .{ .ptr = self, .vtable = &vtable };
    }

    fn bufferFlagsToVk(flags: u32) vk.BufferUsageFlags {
        const usage = buffer.Buffer.Usage.fromFlags(flags);
        return .{
            .transfer_src_bit = usage.copy_src or usage.map_read,
            .transfer_dst_bit = usage.copy_dst or usage.map_write or usage.query_resolve,
            .index_buffer_bit = usage.index,
            .vertex_buffer_bit = usage.vertex,
            .uniform_buffer_bit = usage.uniform,
            .storage_buffer_bit = usage.storage,
            .indirect_buffer_bit = usage.indirect,
        };
    }

    fn memoryFlagsForBuffer(usage: buffer.Buffer.Usage, mapped_at_creation: bool) vk.MemoryPropertyFlags {
        if (mapped_at_creation or usage.map_read or usage.map_write) {
            return .{ .host_visible_bit = true, .host_coherent_bit = true };
        }
        return .{ .device_local_bit = true };
    }

    fn findMemoryType(device: *vkDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
        const memory_properties = device.adapter.gpu.instance.getPhysicalDeviceMemoryProperties(device.adapter.pdev);
        var i: u32 = 0;
        while (i < memory_properties.memory_type_count) : (i += 1) {
            const supported = (type_filter & (@as(u32, 1) << @intCast(i))) != 0;
            const flags = memory_properties.memory_types[i].property_flags;
            if (supported and flags.contains(properties)) return i;
        }
        return error.NoSuitableMemoryType;
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.device.device.deviceWaitIdle() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
        };
        typed.unmapInternal();
        if (typed.handle != .null_handle) {
            if (!typed.is_staging) std.log.debug("destroying vulkan buffer: handle=0x{x}", .{@intFromEnum(typed.handle)});
            typed.device.device.destroyBuffer(typed.handle, null);
            typed.handle = .null_handle;
        }
        if (typed.memory != .null_handle) {
            typed.device.device.freeMemory(typed.memory, null);
            typed.memory = .null_handle;
        }
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn mapAsync(
        ptr: *anyopaque,
        io: std.Io,
        mode: buffer.Buffer.MapMode,
        offset: ?def.Size64,
        size: def.Size64,
    ) std.Io.Future(anyerror!void) {
        return io.async(mapAsyncInternal, .{ ptr, mode, offset, size });
    }

    fn mapAsyncInternal(
        ptr: *anyopaque,
        mode: buffer.Buffer.MapMode,
        offset: ?def.Size64,
        size: def.Size64,
    ) anyerror!void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (!mode.read and !mode.write) return error.InvalidMapMode;
        if (typed.mapped_ptr != null) return;

        const resolved_offset = offset orelse 0;
        if (resolved_offset > typed.size or size > typed.size - resolved_offset) return error.MapRangeOutOfBounds;

        const mapped = try typed.device.device.mapMemory(typed.memory, resolved_offset, size, .{});
        typed.mapped_ptr = @ptrCast(mapped);
        typed.mapped_offset = resolved_offset;
        typed.mapped_size = size;
    }

    fn getMappedRange(ptr: *anyopaque, offset: ?def.Size64, size: ?def.Size64) anyerror!?def.ArrayBuffer {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const mapped = typed.mapped_ptr orelse return null;

        const resolved_offset = offset orelse typed.mapped_offset;
        if (resolved_offset < typed.mapped_offset) return error.MapRangeOutOfBounds;

        const relative_offset = resolved_offset - typed.mapped_offset;
        if (relative_offset > typed.mapped_size) return error.MapRangeOutOfBounds;

        const resolved_size = size orelse (typed.mapped_size - relative_offset);
        if (resolved_size > typed.mapped_size - relative_offset) return error.MapRangeOutOfBounds;

        return mapped[relative_offset .. relative_offset + resolved_size];
    }

    fn unmap(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.unmapInternal();
    }

    fn unmapInternal(self: *@This()) void {
        if (self.mapped_ptr) |_| {
            self.device.device.unmapMemory(self.memory);
            self.mapped_ptr = null;
            self.mapped_offset = 0;
            self.mapped_size = 0;
        }
    }
};

fn imageTypeFromDimension(dimension: texture.Texture.Dimension) vk.ImageType {
    return switch (dimension) {
        .@"1d" => .@"1d",
        .@"2d" => .@"2d",
        .@"3d" => .@"3d",
    };
}

fn imageExtentFromDescriptor(descriptor: texture.Texture.Descriptor) vk.Extent3D {
    return switch (descriptor.dimension) {
        .@"1d" => .{
            .width = descriptor.size.width,
            .height = 1,
            .depth = 1,
        },
        .@"2d" => .{
            .width = descriptor.size.width,
            .height = descriptor.size.height,
            .depth = 1,
        },
        .@"3d" => .{
            .width = descriptor.size.width,
            .height = descriptor.size.height,
            .depth = descriptor.size.depthOrArrayLayers,
        },
    };
}

fn imageArrayLayersFromDescriptor(descriptor: texture.Texture.Descriptor) u32 {
    return switch (descriptor.dimension) {
        .@"1d", .@"2d" => descriptor.size.depthOrArrayLayers,
        .@"3d" => 1,
    };
}

fn imageCreateFlagsFromDescriptor(descriptor: texture.Texture.Descriptor) vk.ImageCreateFlags {
    const cube_compatible = if (descriptor.textureBindingViewDimension) |view_dimension|
        view_dimension == .cube or view_dimension == .@"cube-array"
    else
        false;

    return .{
        .cube_compatible_bit = cube_compatible,
        .mutable_format_bit = descriptor.viewFormats.len > 0,
    };
}

fn isDepthStencilFormat(format: texture.Texture.Format) bool {
    return switch (format) {
        .stencil8,
        .depth16unorm,
        .depth24plus,
        .depth24plus_stencil8,
        .depth32float,
        .depth32float_stencil8,
        => true,
        else => false,
    };
}

fn imageUsageFromTextureDescriptor(descriptor: texture.Texture.Descriptor) vk.ImageUsageFlags {
    const usage = texture.Texture.Usage.fromFlags(descriptor.usage);
    const is_depth_stencil = isDepthStencilFormat(descriptor.format);
    return .{
        .transfer_src_bit = usage.copy_src,
        .transfer_dst_bit = usage.copy_dst,
        .sampled_bit = usage.texture_binding,
        .storage_bit = usage.storage_binding,
        .color_attachment_bit = usage.render_attachment and !is_depth_stencil,
        .depth_stencil_attachment_bit = usage.render_attachment and is_depth_stencil,
        .transient_attachment_bit = usage.transient_attachment,
    };
}

fn sampleCountToVk(count: u32) vk.SampleCountFlags {
    return switch (count) {
        1 => .{ .@"1_bit" = true },
        2 => .{ .@"2_bit" = true },
        4 => .{ .@"4_bit" = true },
        8 => .{ .@"8_bit" = true },
        16 => .{ .@"16_bit" = true },
        32 => .{ .@"32_bit" = true },
        64 => .{ .@"64_bit" = true },
        else => .{ .@"1_bit" = true },
    };
}

fn findImageMemoryType(device: *vkDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const memory_properties = device.adapter.gpu.instance.getPhysicalDeviceMemoryProperties(device.adapter.pdev);
    var i: u32 = 0;
    while (i < memory_properties.memory_type_count) : (i += 1) {
        const supported = (type_filter & (@as(u32, 1) << @intCast(i))) != 0;
        const flags = memory_properties.memory_types[i].property_flags;
        if (supported and flags.contains(properties)) return i;
    }
    return error.NoSuitableMemoryType;
}

pub const vkTexture = struct {
    device: *vkDevice,
    memory: vk.DeviceMemory = undefined,
    handle: vk.Image,
    format: vk.Format,
    extent: vk.Extent3D,
    dimension: texture.Texture.Dimension,
    mip_level_count: u32,
    array_layers: u32,
    layout: vk.ImageLayout = .undefined,
    owns_image: bool = false,
    label: ?[*:0]const u8 = null,
    present_surface: ?*anyopaque = null,
    present_image_index: u32 = 0,
    present_image_view: ?*vkTextureView = null,

    pub const vtable = hal.Texture.VTable{
        .destroy = destroy,
        .createView = createView,
    };

    pub fn init(device: *vkDevice, descriptor: texture.Texture.Descriptor) !hal.Texture {
        const format = utils.formatToVk(descriptor.format) orelse return error.UnsupportedTextureFormat;
        const extent = imageExtentFromDescriptor(descriptor);
        const array_layers = imageArrayLayersFromDescriptor(descriptor);

        const image_create = vk.ImageCreateInfo{
            .flags = imageCreateFlagsFromDescriptor(descriptor),
            .image_type = imageTypeFromDimension(descriptor.dimension),
            .format = format,
            .extent = extent,
            .mip_levels = descriptor.mipLevelCount,
            .array_layers = array_layers,
            .samples = sampleCountToVk(descriptor.sampleCount),
            .tiling = .optimal,
            .usage = imageUsageFromTextureDescriptor(descriptor),
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };

        const handle = try device.device.createImage(&image_create, null);
        errdefer device.device.destroyImage(handle, null);

        const requirements = device.device.getImageMemoryRequirements(handle);
        const allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = try findImageMemoryType(device, requirements.memory_type_bits, .{ .device_local_bit = true }),
        };
        const memory = try device.device.allocateMemory(&allocate_info, null);
        errdefer device.device.freeMemory(memory, null);

        try device.device.bindImageMemory(handle, memory, 0);
        debug.setObjectName(device, .image, handle, descriptor.label);

        const self = try device.adapter.gpu.allocator.create(vkTexture);
        self.* = .{
            .label = descriptor.label,
            .device = device,
            .memory = memory,
            .handle = handle,
            .format = format,
            .extent = extent,
            .dimension = descriptor.dimension,
            .mip_level_count = descriptor.mipLevelCount,
            .array_layers = array_layers,
            .layout = .undefined,
            .owns_image = true,
        };

        return hal.Texture{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn initSwapchainImage(device: *vkDevice, image: vk.Image, format: vk.Format, extent: vk.Extent2D) @This() {
        return .{
            .device = device,
            .handle = image,
            .format = format,
            .extent = .{
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },
            .dimension = .@"2d",
            .mip_level_count = 1,
            .array_layers = 1,
            .layout = .present_src_khr,
            .owns_image = false,
        };
    }

    pub fn createDefaultView(self: *@This()) !vkTextureView {
        return self.createViewFromDescriptor(.{});
    }

    pub fn deinit(self: *@This()) void {
        self.device.device.deviceWaitIdle() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
        };
        if (self.owns_image and self.handle != .null_handle) {
            std.log.debug("destroying vulkan image: handle=0x{x}", .{@intFromEnum(self.handle)});
            self.device.device.destroyImage(self.handle, null);
        }
        self.handle = .null_handle;

        if (self.owns_image and self.memory != .null_handle) {
            self.device.device.freeMemory(self.memory, null);
            self.memory = .null_handle;
        }
    }

    fn destroy(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.device.adapter.gpu.allocator.destroy(self);
    }

    fn createView(ptr: *anyopaque, descriptor: texture.Texture.View.Descriptor) anyerror!hal.TextureView {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const view = try typed.device.adapter.gpu.allocator.create(vkTextureView);
        errdefer typed.device.adapter.gpu.allocator.destroy(view);
        if (typed.present_image_view) |present_image_view| {
            if (!isDefaultViewDescriptor(descriptor)) return error.InvalidSwapchainViewDescriptor;
            view.* = present_image_view.*;
            view.owns_view = false;
        } else {
            view.* = try typed.createViewFromDescriptor(descriptor);
        }
        view.present_surface = typed.present_surface;
        view.present_image_index = typed.present_image_index;
        return .{ .ptr = view, .vtable = &vkTextureView.vtable };
    }

    fn createViewFromDescriptor(self: *@This(), descriptor: texture.Texture.View.Descriptor) !vkTextureView {
        const format = if (descriptor.format) |format|
            utils.formatToVk(format) orelse return error.UnsupportedTextureFormat
        else
            self.format;

        const view_dimension = descriptor.dimension orelse defaultViewDimension(self.dimension, self.array_layers);
        const base_mip_level = descriptor.baseMipLevel;
        if (base_mip_level >= self.mip_level_count) return error.TextureViewMipRangeOutOfBounds;
        const level_count = descriptor.mipLevelCount orelse (self.mip_level_count - base_mip_level);
        if (level_count == 0 or level_count > self.mip_level_count - base_mip_level) return error.TextureViewMipRangeOutOfBounds;

        const base_array_layer = descriptor.baseArrayLayer;
        if (base_array_layer >= self.array_layers) return error.TextureViewArrayRangeOutOfBounds;
        const layer_count = descriptor.arrayLayerCount orelse defaultViewLayerCount(view_dimension, self.array_layers - base_array_layer);
        if (layer_count == 0 or layer_count > self.array_layers - base_array_layer) return error.TextureViewArrayRangeOutOfBounds;
        try validateViewDimension(self.dimension, view_dimension, layer_count);

        return vkTextureView.init(self.device, .{
            .image = self.handle,
            .view_type = viewDimensionToVk(view_dimension),
            .format = format,
            .aspect_mask = aspectMaskForView(descriptor.aspect, format),
            .base_mip_level = base_mip_level,
            .level_count = level_count,
            .base_array_layer = base_array_layer,
            .layer_count = layer_count,
            .components = try componentMappingFromSwizzle(descriptor.swizzle),
            .label = descriptor.label orelse self.label,
        });
    }
};

fn isDefaultViewDescriptor(descriptor: texture.Texture.View.Descriptor) bool {
    return descriptor.format == null and
        descriptor.dimension == null and
        descriptor.usage == 0 and
        descriptor.aspect == .all and
        descriptor.baseMipLevel == 0 and
        descriptor.mipLevelCount == null and
        descriptor.baseArrayLayer == 0 and
        descriptor.arrayLayerCount == null and
        std.mem.eql(u8, descriptor.swizzle, "rgba");
}

fn defaultViewDimension(dimension: texture.Texture.Dimension, array_layers: u32) texture.Texture.View.Dimension {
    return switch (dimension) {
        .@"1d" => .@"1d",
        .@"2d" => if (array_layers > 1) .@"2d-array" else .@"2d",
        .@"3d" => .@"3d",
    };
}

fn defaultViewLayerCount(view_dimension: texture.Texture.View.Dimension, available_layers: u32) u32 {
    return switch (view_dimension) {
        .@"1d", .@"2d", .@"3d" => 1,
        .cube => 6,
        .@"2d-array", .@"cube-array" => available_layers,
    };
}

fn validateViewDimension(texture_dimension: texture.Texture.Dimension, view_dimension: texture.Texture.View.Dimension, layer_count: u32) !void {
    switch (view_dimension) {
        .@"1d" => if (texture_dimension != .@"1d" or layer_count != 1) return error.InvalidTextureViewDimension,
        .@"2d" => if (texture_dimension != .@"2d" or layer_count != 1) return error.InvalidTextureViewDimension,
        .@"2d-array" => if (texture_dimension != .@"2d") return error.InvalidTextureViewDimension,
        .cube => if (texture_dimension != .@"2d" or layer_count != 6) return error.InvalidTextureViewDimension,
        .@"cube-array" => if (texture_dimension != .@"2d" or layer_count < 6 or layer_count % 6 != 0) return error.InvalidTextureViewDimension,
        .@"3d" => if (texture_dimension != .@"3d" or layer_count != 1) return error.InvalidTextureViewDimension,
    }
}

fn viewDimensionToVk(dimension: texture.Texture.View.Dimension) vk.ImageViewType {
    return switch (dimension) {
        .@"1d" => .@"1d",
        .@"2d" => .@"2d",
        .@"2d-array" => .@"2d_array",
        .cube => .cube,
        .@"cube-array" => .cube_array,
        .@"3d" => .@"3d",
    };
}

fn aspectMaskForView(aspect: texture.Texture.Aspect, format: vk.Format) vk.ImageAspectFlags {
    return switch (aspect) {
        .depth_only => .{ .depth_bit = true },
        .stencil_only => .{ .stencil_bit = true },
        .all => switch (format) {
            .s8_uint => .{ .stencil_bit = true },
            .d16_unorm, .d32_sfloat => .{ .depth_bit = true },
            .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint => .{ .depth_bit = true, .stencil_bit = true },
            else => .{ .color_bit = true },
        },
    };
}

fn componentMappingFromSwizzle(swizzle: []const u8) !vk.ComponentMapping {
    if (swizzle.len != 4) return error.InvalidTextureViewSwizzle;
    return .{
        .r = try componentSwizzleFromByte(swizzle[0]),
        .g = try componentSwizzleFromByte(swizzle[1]),
        .b = try componentSwizzleFromByte(swizzle[2]),
        .a = try componentSwizzleFromByte(swizzle[3]),
    };
}

fn componentSwizzleFromByte(byte: u8) !vk.ComponentSwizzle {
    return switch (byte) {
        'r' => .r,
        'g' => .g,
        'b' => .b,
        'a' => .a,
        '0' => .zero,
        '1' => .one,
        'i' => .identity,
        else => error.InvalidTextureViewSwizzle,
    };
}

pub const vkTextureView = struct {
    device: *vkDevice,
    handle: vk.ImageView,
    image: vk.Image,
    format: vk.Format,
    label: ?[*:0]const u8 = null,
    owns_view: bool = true,
    present_surface: ?*anyopaque = null,
    present_image_index: u32 = 0,

    pub const Descriptor = struct {
        image: vk.Image,
        view_type: vk.ImageViewType,
        format: vk.Format,
        aspect_mask: vk.ImageAspectFlags,
        base_mip_level: u32,
        level_count: u32,
        base_array_layer: u32,
        layer_count: u32,
        components: vk.ComponentMapping,
        label: ?[*:0]const u8 = null,
    };

    pub const vtable = hal.TextureView.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: Descriptor) !@This() {
        const create_info = vk.ImageViewCreateInfo{
            .image = descriptor.image,
            .view_type = descriptor.view_type,
            .format = descriptor.format,
            .components = descriptor.components,
            .subresource_range = .{
                .aspect_mask = descriptor.aspect_mask,
                .base_mip_level = descriptor.base_mip_level,
                .level_count = descriptor.level_count,
                .base_array_layer = descriptor.base_array_layer,
                .layer_count = descriptor.layer_count,
            },
        };
        const handle = try device.device.createImageView(&create_info, null);
        errdefer device.device.destroyImageView(handle, null);
        debug.setObjectName(device, .image_view, handle, descriptor.label);
        return .{
            .device = device,
            .handle = handle,
            .image = descriptor.image,
            .format = descriptor.format,
            .label = descriptor.label,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.device.device.deviceWaitIdle() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
        };
        if (self.handle != .null_handle) {
            if (self.owns_view) {
                std.log.debug("destroying vulkan texture view: handle=0x{x}", .{@intFromEnum(self.handle)});
                self.device.device.destroyImageView(self.handle, null);
            }
            self.handle = .null_handle;
        }
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.deinit();
        typed.device.adapter.gpu.allocator.destroy(typed);
    }
};

fn addressModeToVk(address_mode: sampler.Sampler.AddressMode) vk.SamplerAddressMode {
    return switch (address_mode) {
        .clamp_to_edge => .clamp_to_edge,
        .mirror_repeat => .mirrored_repeat,
        .repeat => .repeat,
    };
}

fn filterModeToVk(filter_mode: sampler.Sampler.FilterMode) vk.Filter {
    return switch (filter_mode) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn mipmapFilterModeToVk(filter_mode: sampler.Sampler.MipmapFilterMode) vk.SamplerMipmapMode {
    return switch (filter_mode) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn compareFunctionToVk(compare: sampler.Sampler.CompareFunction) vk.CompareOp {
    return switch (compare) {
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

pub const vkSampler = struct {
    device: *vkDevice,
    handle: vk.Sampler,

    pub const vtable = hal.Sampler.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: sampler.Sampler.Descriptor) !hal.Sampler {
        const sampler_create = vk.SamplerCreateInfo{
            .mag_filter = filterModeToVk(descriptor.magFilter),
            .min_filter = filterModeToVk(descriptor.minFilter),
            .mipmap_mode = mipmapFilterModeToVk(descriptor.mipmapFilter),
            .address_mode_u = addressModeToVk(descriptor.addressModeU),
            .address_mode_v = addressModeToVk(descriptor.addressModeV),
            .address_mode_w = addressModeToVk(descriptor.addressModeW),
            .mip_lod_bias = 0,
            .anisotropy_enable = if (descriptor.maxAnisotropy > 1) .true else .false,
            .max_anisotropy = @floatFromInt(@max(descriptor.maxAnisotropy, 1)),
            .compare_enable = if (descriptor.compare != null) .true else .false,
            .compare_op = if (descriptor.compare) |compare| compareFunctionToVk(compare) else .always,
            .min_lod = descriptor.lodMinClamp,
            .max_lod = descriptor.lodMaxClamp,
            .border_color = .float_transparent_black,
            .unnormalized_coordinates = .false,
        };

        const handle = try device.device.createSampler(&sampler_create, null);
        errdefer device.device.destroySampler(handle, null);
        debug.setObjectName(device, .sampler, handle, descriptor.label);

        const self = try device.adapter.gpu.allocator.create(vkSampler);
        self.* = .{
            .device = device,
            .handle = handle,
        };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.device.device.deviceWaitIdle() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
        };
        if (typed.handle != .null_handle) {
            std.log.debug("destroying vulkan sampler: handle=0x{x}", .{@intFromEnum(typed.handle)});
            typed.device.device.destroySampler(typed.handle, null);
            typed.handle = .null_handle;
        }
        typed.device.adapter.gpu.allocator.destroy(typed);
    }
};

pub const vkDescriptorSetLayout = struct {
    device: *vkDevice,
    handle: vk.DescriptorSetLayout,
    bindings: []vk.DescriptorSetLayoutBinding,
    label: ?[*:0]const u8,

    pub const vtable = hal.DescriptorSetLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: descriptor_set.DescriptorSetLayout.Descriptor) !hal.DescriptorSetLayout {
        const allocator = device.adapter.gpu.allocator;
        const bindings = try allocator.alloc(vk.DescriptorSetLayoutBinding, descriptor.entries.len);
        errdefer allocator.free(bindings);

        for (descriptor.entries, bindings) |entry_ptr, *binding| {
            const entry = entry_ptr.*;
            binding.* = .{
                .binding = entry.binding,
                .descriptor_type = try descriptorTypeForLayoutEntry(entry),
                .descriptor_count = 1,
                .stage_flags = shaderStageFlagsToVulkan(entry.visibility),
            };
        }

        const create_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = @intCast(bindings.len),
            .p_bindings = if (bindings.len == 0) null else bindings.ptr,
        };
        const handle = try device.device.createDescriptorSetLayout(&create_info, null);
        errdefer device.device.destroyDescriptorSetLayout(handle, null);

        const self = try allocator.create(vkDescriptorSetLayout);
        errdefer allocator.destroy(self);
        self.* = .{
            .device = device,
            .handle = handle,
            .bindings = bindings,
            .label = descriptor.label,
        };
        debug.setObjectName(device, .descriptor_set_layout, handle, descriptor.label);

        return .{ .ptr = self, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.device.device.deviceWaitIdle() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
        };
        if (typed.handle != .null_handle) {
            std.log.debug("destroying vulkan descriptor set layout: handle=0x{x}", .{@intFromEnum(typed.handle)});
            typed.device.device.destroyDescriptorSetLayout(typed.handle, null);
            typed.handle = .null_handle;
        }
        typed.device.adapter.gpu.allocator.free(typed.bindings);
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn descriptorTypeForLayoutEntry(entry: descriptor_set.DescriptorSetLayout.Entry) !vk.DescriptorType {
        if (entry.buffer) |buffer_binding| {
            return switch (buffer_binding.type) {
                .uniform => if (buffer_binding.hasDynamicOffset) .uniform_buffer_dynamic else .uniform_buffer,
                .storage, .read_only_storage => if (buffer_binding.hasDynamicOffset) .storage_buffer_dynamic else .storage_buffer,
            };
        }
        if (entry.sampler != null) return .sampler;
        if (entry.texture != null) return .sampled_image;
        if (entry.storageTexture != null) return .storage_image;
        if (entry.combinedImageSampler != null) return .combined_image_sampler;
        return error.InvalidDescriptorSetLayoutEntry;
    }

    fn shaderStageFlagsToVulkan(flags: descriptor_set.DescriptorSetLayout.ShaderStageFlags) vk.ShaderStageFlags {
        const stages = descriptor_set.DescriptorSetLayout.ShaderStage.fromFlags(flags);
        return .{
            .vertex_bit = stages.vertex,
            .fragment_bit = stages.fragment,
            .compute_bit = stages.compute,
        };
    }

    pub fn descriptorTypeForBinding(self: *const @This(), binding: def.Index32) !vk.DescriptorType {
        for (self.bindings) |layout_binding| {
            if (layout_binding.binding == binding) return layout_binding.descriptor_type;
        }
        return error.MissingDescriptorSetLayoutBinding;
    }
};

fn isBufferDescriptor(descriptor_type: vk.DescriptorType) bool {
    return switch (descriptor_type) {
        .uniform_buffer, .uniform_buffer_dynamic, .storage_buffer, .storage_buffer_dynamic => true,
        else => false,
    };
}

fn isImageDescriptor(descriptor_type: vk.DescriptorType) bool {
    return switch (descriptor_type) {
        .sampled_image, .storage_image => true,
        else => false,
    };
}

fn isCombinedImageSamplerDescriptor(descriptor_type: vk.DescriptorType) bool {
    return descriptor_type == .combined_image_sampler;
}

fn imageLayoutForDescriptorType(descriptor_type: vk.DescriptorType) vk.ImageLayout {
    return switch (descriptor_type) {
        .storage_image => .general,
        else => .shader_read_only_optimal,
    };
}

pub const vkDescriptorSet = struct {
    device: *vkDevice,
    layout: *vkDescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    label: ?[*:0]const u8,

    pub const vtable = hal.DescriptorSet.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: descriptor_set.DescriptorSet.Descriptor) !hal.DescriptorSet {
        const allocator = device.adapter.gpu.allocator;
        const layout_backend = descriptor.layout.backend orelse return error.InvalidDescriptorSetLayout;
        const layout: *vkDescriptorSetLayout = @ptrCast(@alignCast(layout_backend.ptr));

        var pool_sizes = std.ArrayList(vk.DescriptorPoolSize).empty;
        defer pool_sizes.deinit(allocator);
        for (layout.bindings) |layout_binding| {
            try addPoolSize(&pool_sizes, allocator, layout_binding.descriptor_type, layout_binding.descriptor_count);
        }

        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{ .free_descriptor_set_bit = true },
            .max_sets = 1,
            .pool_size_count = @intCast(pool_sizes.items.len),
            .p_pool_sizes = if (pool_sizes.items.len == 0) null else pool_sizes.items.ptr,
        };
        const descriptor_pool = try device.device.createDescriptorPool(&pool_info, null);
        errdefer device.device.destroyDescriptorPool(descriptor_pool, null);

        const set_layouts = [_]vk.DescriptorSetLayout{layout.handle};
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &set_layouts,
        };
        var descriptor_sets: [1]vk.DescriptorSet = undefined;
        try device.device.allocateDescriptorSets(&alloc_info, &descriptor_sets);

        const buffer_infos = try allocator.alloc(vk.DescriptorBufferInfo, descriptor.entries.len);
        defer allocator.free(buffer_infos);
        const image_infos = try allocator.alloc(vk.DescriptorImageInfo, descriptor.entries.len);
        defer allocator.free(image_infos);
        const writes = try allocator.alloc(vk.WriteDescriptorSet, descriptor.entries.len);
        defer allocator.free(writes);

        for (descriptor.entries, 0..) |entry, i| {
            const descriptor_type = try layout.descriptorTypeForBinding(entry.binding);
            var buffer_info: ?*const vk.DescriptorBufferInfo = null;
            var image_info: ?*const vk.DescriptorImageInfo = null;

            switch (entry.resource) {
                .buffer => |target| {
                    if (!isBufferDescriptor(descriptor_type)) return error.InvalidDescriptorSetBufferBinding;
                    const vk_buffer: *vkBuffer = @ptrCast(@alignCast((target.backend orelse return error.InvalidBuffer).ptr));
                    buffer_infos[i] = .{
                        .buffer = vk_buffer.handle,
                        .offset = 0,
                        .range = vk_buffer.size,
                    };
                    buffer_info = &buffer_infos[i];
                },
                .bufferBinding => |binding| {
                    if (!isBufferDescriptor(descriptor_type)) return error.InvalidDescriptorSetBufferBinding;
                    const vk_buffer: *vkBuffer = @ptrCast(@alignCast((binding.buffer.backend orelse return error.InvalidBuffer).ptr));
                    if (binding.offset > vk_buffer.size) return error.DescriptorSetBufferRangeOutOfBounds;
                    const range = binding.size orelse (vk_buffer.size - binding.offset);
                    if (range > vk_buffer.size - binding.offset) return error.DescriptorSetBufferRangeOutOfBounds;
                    buffer_infos[i] = .{
                        .buffer = vk_buffer.handle,
                        .offset = binding.offset,
                        .range = range,
                    };
                    buffer_info = &buffer_infos[i];
                },
                .sampler => |s| {
                    if (descriptor_type != .sampler) return error.InvalidDescriptorSetSamplerBinding;
                    const vk_sampler: *vkSampler = @ptrCast(@alignCast((s.backend orelse return error.InvalidSampler).ptr));
                    image_infos[i] = .{
                        .sampler = vk_sampler.handle,
                        .image_view = .null_handle,
                        .image_layout = .undefined,
                    };
                    image_info = &image_infos[i];
                },
                .textureView => |view| {
                    if (!isImageDescriptor(descriptor_type)) return error.InvalidDescriptorSetTextureBinding;
                    const vk_view: *vkTextureView = @ptrCast(@alignCast((view.backend orelse return error.InvalidTextureView).ptr));
                    image_infos[i] = .{
                        .sampler = .null_handle,
                        .image_view = vk_view.handle,
                        .image_layout = imageLayoutForDescriptorType(descriptor_type),
                    };
                    image_info = &image_infos[i];
                },
                .combinedImageSampler => |binding| {
                    if (!isCombinedImageSamplerDescriptor(descriptor_type)) return error.InvalidDescriptorSetCombinedImageSamplerBinding;
                    const vk_view: *vkTextureView = @ptrCast(@alignCast((binding.view.backend orelse return error.InvalidTextureView).ptr));
                    const vk_sampler: *vkSampler = @ptrCast(@alignCast((binding.sampler.backend orelse return error.InvalidSampler).ptr));
                    image_infos[i] = .{
                        .sampler = vk_sampler.handle,
                        .image_view = vk_view.handle,
                        .image_layout = .shader_read_only_optimal,
                    };
                    image_info = &image_infos[i];
                },
            }
            writes[i] = .{
                .dst_set = descriptor_sets[0],
                .dst_binding = entry.binding,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = descriptor_type,
                .p_image_info = if (image_info) |info| @as([*]const vk.DescriptorImageInfo, @ptrCast(info)) else undefined,
                .p_buffer_info = if (buffer_info) |info| @as([*]const vk.DescriptorBufferInfo, @ptrCast(info)) else undefined,
                .p_texel_buffer_view = undefined,
            };
        }
        device.device.updateDescriptorSets(writes, null);

        const self = try allocator.create(vkDescriptorSet);
        errdefer allocator.destroy(self);
        self.* = .{
            .device = device,
            .layout = layout,
            .descriptor_pool = descriptor_pool,
            .descriptor_set = descriptor_sets[0],
            .label = descriptor.label,
        };
        debug.setObjectName(device, .descriptor_pool, descriptor_pool, descriptor.label);
        debug.setObjectName(device, .descriptor_set, descriptor_sets[0], descriptor.label);

        return .{ .ptr = self, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.device.device.deviceWaitIdle() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
        };
        if (typed.descriptor_pool != .null_handle) {
            std.log.debug("destroying vulkan descriptor pool: handle=0x{x}", .{@intFromEnum(typed.descriptor_pool)});
            typed.device.device.destroyDescriptorPool(typed.descriptor_pool, null);
            typed.descriptor_pool = .null_handle;
            typed.descriptor_set = .null_handle;
        }
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn addPoolSize(pool_sizes: *std.ArrayList(vk.DescriptorPoolSize), allocator: std.mem.Allocator, descriptor_type: vk.DescriptorType, count: u32) !void {
        for (pool_sizes.items) |*pool_size| {
            if (pool_size.type == descriptor_type) {
                pool_size.descriptor_count += count;
                return;
            }
        }
        try pool_sizes.append(allocator, .{
            .type = descriptor_type,
            .descriptor_count = count,
        });
    }
};

pub const vkQuerySet = struct {
    pub const vtable = hal.QuerySet.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: gpu.QuerySet.Descriptor) !hal.QuerySet {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        std.log.debug("destroying vulkan query set", .{});
        // typed.device.device.deviceWaitIdle() catch |err| {
        //     std.log.err("{s}", .{@errorName(err)});
        // };
    }
};
