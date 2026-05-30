const std = @import("std");

const bind_group = @import("../../types/bind_group.zig");
const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const sampler = @import("../../types/sampler.zig");
const texture = @import("../../types/texture.zig");
const vk = @import("vulkan");
const vkDevice = @import("device.zig").vkDevice;
const debug = @import("debug.zig");


pub const vkBuffer = struct {
    device: *vkDevice,
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: def.Size64,
    mapped_ptr: ?[*]u8 = null,
    mapped_offset: def.Size64 = 0,
    mapped_size: def.Size64 = 0,

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
        typed.unmapInternal();
        if (typed.handle != .null_handle) {
            std.log.debug("destroying vulkan buffer: handle=0x{x}", .{@intFromEnum(typed.handle)});
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

pub const vkTexture = struct {
    device: *vkDevice,
    handle: vk.Image,
    format: vk.Format,
    extent: vk.Extent3D,
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
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
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
            .owns_image = false,
        };
    }

    pub fn createDefaultView(self: *@This()) !vkTextureView {
        return vkTextureView.init(self.device, self.handle, self.format, .{ .color_bit = true }, self.label);
    }

    pub fn deinit(self: *@This()) void {
        if (self.owns_image and self.handle != .null_handle) {
            std.log.debug("destroying vulkan image: handle=0x{x}", .{@intFromEnum(self.handle)});
            self.device.device.destroyImage(self.handle, null);
        }
        self.handle = .null_handle;
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.deinit();
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn createView(ptr: *anyopaque, descriptor: texture.Texture.View.Descriptor) anyerror!hal.TextureView {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        const view = try typed.device.adapter.gpu.allocator.create(vkTextureView);
        errdefer typed.device.adapter.gpu.allocator.destroy(view);
        if (typed.present_image_view) |present_image_view| {
            view.* = present_image_view.*;
            view.owns_view = false;
        } else {
            view.* = try typed.createDefaultView();
        }
        view.present_surface = typed.present_surface;
        view.present_image_index = typed.present_image_index;
        return .{ .ptr = view, .vtable = &vkTextureView.vtable };
    }
};

pub const vkTextureView = struct {
    device: *vkDevice,
    handle: vk.ImageView,
    image: vk.Image,
    format: vk.Format,
    label: ?[*:0]const u8 = null,
    owns_view: bool = true,
    present_surface: ?*anyopaque = null,
    present_image_index: u32 = 0,

    pub const vtable = hal.TextureView.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, image: vk.Image, format: vk.Format, aspect_mask: vk.ImageAspectFlags, label: ?[*:0]const u8) !@This() {
        const create_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const handle = try device.device.createImageView(&create_info, null);
        errdefer device.device.destroyImageView(handle, null);
        debug.setObjectName(device, .image_view, handle, label);
        return .{
            .device = device,
            .handle = handle,
            .image = image,
            .format = format,
            .label = label,
        };
    }

    pub fn deinit(self: *@This()) void {
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

pub const vkSampler = struct {
    pub const vtable = hal.Sampler.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: sampler.Sampler.Descriptor) !hal.Sampler {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        std.log.debug("destroying vulkan sampler", .{});
    }
};

pub const vkBindGroupLayout = struct {
    device: *vkDevice,
    handle: vk.DescriptorSetLayout,
    bindings: []vk.DescriptorSetLayoutBinding,
    label: ?[*:0]const u8,

    pub const vtable = hal.BindGroupLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: bind_group.BindGroupLayout.Descriptor) !hal.BindGroupLayout {
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

        const self = try allocator.create(vkBindGroupLayout);
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
            std.log.debug("destroying vulkan bind group layout: handle=0x{x}", .{@intFromEnum(typed.handle)});
            typed.device.device.destroyDescriptorSetLayout(typed.handle, null);
            typed.handle = .null_handle;
        }
        typed.device.adapter.gpu.allocator.free(typed.bindings);
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn descriptorTypeForLayoutEntry(entry: bind_group.BindGroupLayout.Entry) !vk.DescriptorType {
        if (entry.buffer) |buffer_binding| {
            return switch (buffer_binding.type) {
                .uniform => if (buffer_binding.hasDynamicOffset) .uniform_buffer_dynamic else .uniform_buffer,
                .storage, .read_only_storage => if (buffer_binding.hasDynamicOffset) .storage_buffer_dynamic else .storage_buffer,
            };
        }
        if (entry.sampler != null) return .sampler;
        if (entry.texture != null) return .sampled_image;
        if (entry.storageTexture != null) return .storage_image;
        return error.InvalidBindGroupLayoutEntry;
    }

    fn shaderStageFlagsToVulkan(flags: bind_group.BindGroupLayout.ShaderStageFlags) vk.ShaderStageFlags {
        const stages = bind_group.BindGroupLayout.ShaderStage.fromFlags(flags);
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
        return error.MissingBindGroupLayoutBinding;
    }
};

pub const vkBindGroup = struct {
    device: *vkDevice,
    layout: *vkBindGroupLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    label: ?[*:0]const u8,

    pub const vtable = hal.BindGroup.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: bind_group.BindGroup.Descriptor) !hal.BindGroup {
        const allocator = device.adapter.gpu.allocator;
        const layout_backend = descriptor.layout.backend orelse return error.InvalidBindGroupLayout;
        const layout: *vkBindGroupLayout = @ptrCast(@alignCast(layout_backend.ptr));

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
        const writes = try allocator.alloc(vk.WriteDescriptorSet, descriptor.entries.len);
        defer allocator.free(writes);

        for (descriptor.entries, 0..) |entry, i| {
            const descriptor_type = try layout.descriptorTypeForBinding(entry.binding);
            switch (entry.resource) {
                .buffer => |target| {
                    const vk_buffer: *vkBuffer = @ptrCast(@alignCast((target.backend orelse return error.InvalidBuffer).ptr));
                    buffer_infos[i] = .{
                        .buffer = vk_buffer.handle,
                        .offset = 0,
                        .range = vk_buffer.size,
                    };
                },
                .bufferBinding => |binding| {
                    const vk_buffer: *vkBuffer = @ptrCast(@alignCast((binding.buffer.backend orelse return error.InvalidBuffer).ptr));
                    if (binding.offset > vk_buffer.size) return error.BindGroupBufferRangeOutOfBounds;
                    buffer_infos[i] = .{
                        .buffer = vk_buffer.handle,
                        .offset = binding.offset,
                        .range = binding.size orelse (vk_buffer.size - binding.offset),
                    };
                },
                .sampler, .texture, .textureView => return error.NotImplemented,
            }
            writes[i] = .{
                .dst_set = descriptor_sets[0],
                .dst_binding = entry.binding,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = descriptor_type,
                .p_image_info = undefined,
                .p_buffer_info = @as([*]const vk.DescriptorBufferInfo, @ptrCast(&buffer_infos[i])),
                .p_texel_buffer_view = undefined,
            };
        }
        device.device.updateDescriptorSets(writes, null);

        const self = try allocator.create(vkBindGroup);
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
    }
};
