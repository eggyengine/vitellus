const std = @import("std");
const vk = @import("vulkan");
const adapter_interface = @import("../../interface/adapter.zig");
const Adapter = adapter_interface.Adapter;
const AdapterDescriptor = adapter_interface.AdapterDescriptor;
const AdapterInfo = adapter_interface.AdapterInfo;
const Device = @import("../../interface/device.zig").Device;
const DeviceDescriptor = @import("../../interface/device.zig").DeviceDescriptor;
const resource = @import("../../interface/resource.zig");
const Swapchain = @import("../../interface/swapchain.zig").Swapchain;
const SwapchainDescriptor = @import("../../interface/swapchain.zig").SwapchainDescriptor;
const Window = @import("../../windowing/windowing.zig").Window;
const vkInstance = @import("instance.zig").vkInstance;

const log = std.log.scoped(.vk_adapter);

pub const QueueAllocation = struct {
    graphics_family: u32,
    compute_family: ?u32,
    copy_family: u32,
};

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    memory_props: vk.PhysicalDeviceMemoryProperties,
    features: vk.PhysicalDeviceFeatures,
    queues: QueueAllocation,
};

pub const vkAdapter = struct {
    instance: *vkInstance,
    physical_device: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    memory_props: vk.PhysicalDeviceMemoryProperties,
    features: vk.PhysicalDeviceFeatures,
    queues: QueueAllocation,

    const vtable: Adapter.VTable = .{
        .deinitFn = deinitImpl,
        .infoFn = infoImpl,
        .createDeviceFn = createDeviceImpl,
        .createSwapchainFn = createSwapchainImpl,
        .capabilitiesFn = capabilitiesImpl,
        .formatCapabilitiesFn = formatCapabilitiesImpl,
        .surfaceCapabilitiesFn = surfaceCapabilitiesImpl,
    };

    pub fn init(instance_ptr: *anyopaque, allocator: std.mem.Allocator, _: AdapterDescriptor) !Adapter {
        const adapters = try enumerateSlice(instance_ptr, allocator);
        defer allocator.free(adapters);

        const selected = Adapter.pick(adapters, .high_performance) orelse adapters[0];
        for (adapters) |adapter| {
            if (adapter.ptr != selected.ptr) adapter.deinit();
        }
        return selected;
    }

    pub fn enumerate(instance_ptr: *anyopaque, allocator: std.mem.Allocator) !@import("../../interface/instance.zig").Adapters {
        return .{
            .inner = try enumerateSlice(instance_ptr, allocator),
            .alloc = allocator,
        };
    }

    pub fn enumerateStandalone(allocator: std.mem.Allocator) ![]Adapter {
        const instance = try vkInstance.init(allocator, .{ .backend = .{ .vulkan = true }, .validation = .none });
        const backend: *vkInstance = @ptrCast(@alignCast(instance.ptr));
        defer instance.deinit();
        return enumerateSlice(backend, allocator);
    }

    fn enumerateSlice(instance_ptr: *anyopaque, allocator: std.mem.Allocator) ![]Adapter {
        const instance: *vkInstance = @ptrCast(@alignCast(instance_ptr));
        const pdevs = try instance.wrapper.enumeratePhysicalDevicesAlloc(instance.instance, allocator);
        defer allocator.free(pdevs);

        if (pdevs.len == 0) return error.NoSuitableAdapter;
        const adapters = try allocator.alloc(Adapter, pdevs.len);
        errdefer allocator.free(adapters);

        var initialized: usize = 0;
        errdefer for (adapters[0..initialized]) |adapter| adapter.deinit();

        for (pdevs) |pdev| {
            const candidate = try checkSuitable(instance, pdev, allocator) orelse continue;
            const self = try allocator.create(vkAdapter);
            self.* = fromCandidate(instance, candidate);
            instance.retain();
            adapters[initialized] = .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
            initialized += 1;
        }

        if (initialized == 0) return error.NoSuitableAdapter;
        log.debug("enumerated {} suitable Vulkan adapter(s)", .{initialized});
        return allocator.realloc(adapters, initialized);
    }

    fn fromCandidate(instance: *vkInstance, candidate: DeviceCandidate) vkAdapter {
        return .{
            .instance = instance,
            .physical_device = candidate.pdev,
            .props = candidate.props,
            .memory_props = candidate.memory_props,
            .features = candidate.features,
            .queues = candidate.queues,
        };
    }

    fn checkSuitable(instance: *vkInstance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator) !?DeviceCandidate {
        if (!try supportsRequiredExtensions(instance, pdev, allocator)) return null;
        const queues = try allocateQueues(instance, pdev, allocator) orelse return null;

        return .{
            .pdev = pdev,
            .props = instance.wrapper.getPhysicalDeviceProperties(pdev),
            .memory_props = instance.wrapper.getPhysicalDeviceMemoryProperties(pdev),
            .features = instance.wrapper.getPhysicalDeviceFeatures(pdev),
            .queues = queues,
        };
    }

    fn supportsRequiredExtensions(instance: *vkInstance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator) !bool {
        const extensions = try instance.wrapper.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
        defer allocator.free(extensions);

        for (extensions) |*extension| {
            if (fixedStringEquals(extension.extension_name.len, &extension.extension_name, vk.extensions.khr_swapchain.name)) return true;
        }
        return false;
    }

    fn allocateQueues(instance: *vkInstance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator) !?QueueAllocation {
        const families = try instance.wrapper.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
        defer allocator.free(families);

        var graphics: ?u32 = null;
        var compute: ?u32 = null;
        var dedicated_compute: ?u32 = null;
        var copy: ?u32 = null;
        var dedicated_copy: ?u32 = null;
        for (families, 0..) |family, index| {
            if (family.queue_count == 0) continue;
            const family_index: u32 = @intCast(index);
            if (graphics == null and family.queue_flags.graphics_bit) graphics = family_index;
            if (compute == null and family.queue_flags.compute_bit) compute = family_index;
            if (dedicated_compute == null and family.queue_flags.compute_bit and !family.queue_flags.graphics_bit)
                dedicated_compute = family_index;
            if (copy == null and family.queue_flags.transfer_bit) copy = family_index;
            if (dedicated_copy == null and family.queue_flags.transfer_bit and
                !family.queue_flags.graphics_bit and !family.queue_flags.compute_bit)
                dedicated_copy = family_index;
        }
        const graphics_family = graphics orelse return null;
        return .{
            .graphics_family = graphics_family,
            .compute_family = dedicated_compute orelse compute,
            .copy_family = dedicated_copy orelse copy orelse graphics_family,
        };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *vkAdapter = @ptrCast(@alignCast(ptr));
        const instance = self.instance;
        allocator.destroy(self);
        instance.release(allocator);
        log.debug("destroyed Vulkan adapter", .{});
    }

    fn infoImpl(ptr: *anyopaque) AdapterInfo {
        const self: *vkAdapter = @ptrCast(@alignCast(ptr));
        var info: AdapterInfo = .{
            .vendor = vendorFromId(self.props.vendor_id),
            .kind = kindFromVk(self.props.device_type),
        };

        const name = std.mem.sliceTo(&self.props.device_name, 0);
        info.name_len = @min(name.len, info.name.len);
        @memcpy(info.name[0..info.name_len], name[0..info.name_len]);

        var device_memory: u64 = 0;
        for (self.memory_props.memory_heaps[0..self.memory_props.memory_heap_count]) |heap| {
            if (heap.flags.device_local_bit) device_memory +|= heap.size;
        }
        info.dedicated_vram = @intCast(@min(device_memory, std.math.maxInt(usize)));
        return info;
    }

    fn capabilitiesImpl(ptr: *anyopaque) adapter_interface.AdapterCapabilities {
        const self: *vkAdapter = @ptrCast(@alignCast(ptr));
        const limits = self.props.limits;
        const anisotropy = if (self.features.sampler_anisotropy == .true)
            @as(u16, @intFromFloat(@min(limits.max_sampler_anisotropy, @as(f32, std.math.maxInt(u16)))))
        else
            1;

        return .{
            .features = .{
                .timestamp_query = limits.timestamp_compute_and_graphics == .true,
                .occlusion_query = self.features.occlusion_query_precise == .true,
                .indirect_first_instance = self.features.draw_indirect_first_instance == .true,
                .depth_clip_control = self.features.depth_clamp == .true,
                .wireframe = self.features.fill_mode_non_solid == .true,
                .anisotropic_filtering = self.features.sampler_anisotropy == .true,
                .bc_compression = self.features.texture_compression_bc == .true,
            },
            .limits = .{
                .max_buffer_size = limits.max_storage_buffer_range,
                .max_texture_dimension_1d = limits.max_image_dimension_1d,
                .max_texture_dimension_2d = limits.max_image_dimension_2d,
                .max_texture_dimension_3d = limits.max_image_dimension_3d,
                .max_texture_array_layers = limits.max_image_array_layers,
                .max_bind_groups = limits.max_bound_descriptor_sets,
                .max_bindings_per_group = limits.max_per_stage_resources,
                .max_uniform_buffer_binding_size = limits.max_uniform_buffer_range,
                .max_storage_buffer_binding_size = limits.max_storage_buffer_range,
                .min_uniform_buffer_offset_alignment = @intCast(limits.min_uniform_buffer_offset_alignment),
                .min_storage_buffer_offset_alignment = @intCast(limits.min_storage_buffer_offset_alignment),
                .max_vertex_buffers = limits.max_vertex_input_bindings,
                .max_vertex_attributes = limits.max_vertex_input_attributes,
                .max_vertex_stride = limits.max_vertex_input_binding_stride,
                .max_color_attachments = limits.max_color_attachments,
                .max_compute_workgroup_storage = limits.max_compute_shared_memory_size,
                .max_compute_invocations = limits.max_compute_work_group_invocations,
                .max_compute_workgroup_size = limits.max_compute_work_group_size,
                .max_compute_workgroups = limits.max_compute_work_group_count,
                .max_sampler_anisotropy = anisotropy,
            },
        };
    }

    fn formatCapabilitiesImpl(ptr: *anyopaque, format: resource.Format) adapter_interface.FormatCapabilities {
        if (format == .undefined) return .{};
        const self: *vkAdapter = @ptrCast(@alignCast(ptr));
        const properties = self.instance.wrapper.getPhysicalDeviceFormatProperties(self.physical_device, toVkFormat(format));
        const features = properties.optimal_tiling_features;
        const counts = if (features.depth_stencil_attachment_bit)
            self.props.limits.framebuffer_depth_sample_counts
        else
            self.props.limits.framebuffer_color_sample_counts;

        return .{
            .usage = .{
                .sampled = features.sampled_image_bit,
                .storage = features.storage_image_bit,
                .color_attachment = features.color_attachment_bit,
                .depth_stencil_attachment = features.depth_stencil_attachment_bit,
                .transfer_src = features.transfer_src_bit,
                .transfer_dst = features.transfer_dst_bit,
            },
            .sample_counts = .{
                .one = counts.@"1_bit",
                .two = counts.@"2_bit",
                .four = counts.@"4_bit",
                .eight = counts.@"8_bit",
            },
        };
    }

    fn surfaceCapabilitiesImpl(ptr: *anyopaque, allocator: std.mem.Allocator, window: Window) !adapter_interface.SurfaceCapabilities {
        const self: *vkAdapter = @ptrCast(@alignCast(ptr));
        const surface_impl = @import("surface.zig");
        const surface = try surface_impl.create(self.instance, window);
        defer self.instance.wrapper.destroySurfaceKHR(self.instance.instance, surface, null);
        return surface_impl.query(self.instance, self.physical_device, allocator, surface);
    }

    fn createDeviceImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: DeviceDescriptor) anyerror!Device {
        return @import("device.zig").vkDevice.init(ptr, allocator, desc);
    }

    fn createSwapchainImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: SwapchainDescriptor) anyerror!Swapchain {
        return @import("swapchain.zig").vkSwapchain.init(ptr, allocator, desc);
    }
};

fn fixedStringEquals(comptime len: usize, value: *const [len]u8, expected: []const u8) bool {
    const value_len = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
    return std.mem.eql(u8, value[0..value_len], expected);
}

fn vendorFromId(vendor_id: u32) adapter_interface.Vendor {
    return switch (vendor_id) {
        0x10DE => .nvidia,
        0x1002, 0x1022 => .amd,
        0x8086 => .intel,
        0x106B => .apple,
        0x1414 => .microsoft,
        else => .unknown,
    };
}

fn kindFromVk(device_type: vk.PhysicalDeviceType) adapter_interface.Kind {
    return switch (device_type) {
        .discrete_gpu => .discrete,
        .integrated_gpu => .integrated,
        .cpu => .software,
        else => .unknown,
    };
}

pub fn toVkFormat(format: resource.Format) vk.Format {
    return switch (format) {
        .undefined => .undefined,
        .r8_unorm => .r8_unorm,
        .r8_snorm => .r8_snorm,
        .r8_uint => .r8_uint,
        .r8_sint => .r8_sint,
        .rg8_unorm => .r8g8_unorm,
        .rg8_snorm => .r8g8_snorm,
        .rg8_uint => .r8g8_uint,
        .rg8_sint => .r8g8_sint,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .rgba8_snorm => .r8g8b8a8_snorm,
        .rgba8_uint => .r8g8b8a8_uint,
        .rgba8_sint => .r8g8b8a8_sint,
        .rgba8_unorm_srgb => .r8g8b8a8_srgb,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .bgra8_unorm_srgb => .b8g8r8a8_srgb,
        .r16_unorm => .r16_unorm,
        .r16_snorm => .r16_snorm,
        .r16_uint => .r16_uint,
        .r16_sint => .r16_sint,
        .r16_float => .r16_sfloat,
        .rg16_unorm => .r16g16_unorm,
        .rg16_snorm => .r16g16_snorm,
        .rg16_uint => .r16g16_uint,
        .rg16_sint => .r16g16_sint,
        .rg16_float => .r16g16_sfloat,
        .rgba16_unorm => .r16g16b16a16_unorm,
        .rgba16_snorm => .r16g16b16a16_snorm,
        .rgba16_uint => .r16g16b16a16_uint,
        .rgba16_sint => .r16g16b16a16_sint,
        .rgba16_float => .r16g16b16a16_sfloat,
        .r32_uint => .r32_uint,
        .r32_sint => .r32_sint,
        .r32_float => .r32_sfloat,
        .rg32_uint => .r32g32_uint,
        .rg32_sint => .r32g32_sint,
        .rg32_float => .r32g32_sfloat,
        .rgb32_uint => .r32g32b32_uint,
        .rgb32_sint => .r32g32b32_sint,
        .rgb32_float => .r32g32b32_sfloat,
        .rgba32_uint => .r32g32b32a32_uint,
        .rgba32_sint => .r32g32b32a32_sint,
        .rgba32_float => .r32g32b32a32_sfloat,
        .rgb10a2_unorm => .a2b10g10r10_unorm_pack32,
        .rg11b10_float => .b10g11r11_ufloat_pack32,
        .bc1_rgba_unorm => .bc1_rgba_unorm_block,
        .bc1_rgba_unorm_srgb => .bc1_rgba_srgb_block,
        .bc2_rgba_unorm => .bc2_unorm_block,
        .bc2_rgba_unorm_srgb => .bc2_srgb_block,
        .bc3_rgba_unorm => .bc3_unorm_block,
        .bc3_rgba_unorm_srgb => .bc3_srgb_block,
        .bc4_r_unorm => .bc4_unorm_block,
        .bc4_r_snorm => .bc4_snorm_block,
        .bc5_rg_unorm => .bc5_unorm_block,
        .bc5_rg_snorm => .bc5_snorm_block,
        .bc6h_rgb_ufloat => .bc6h_ufloat_block,
        .bc6h_rgb_float => .bc6h_sfloat_block,
        .bc7_rgba_unorm => .bc7_unorm_block,
        .bc7_rgba_unorm_srgb => .bc7_srgb_block,
        .stencil8 => .s8_uint,
        .d16_unorm => .d16_unorm,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        .d32_float => .d32_sfloat,
        .d32_float_s8_uint => .d32_sfloat_s8_uint,
    };
}

test "Vulkan instance enumerates and describes adapters" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .windows and
        builtin.target.os.tag != .linux and
        builtin.target.os.tag != .macos)
    {
        return error.SkipZigTest;
    }

    const instance = vkInstance.init(std.testing.allocator, .{
        .backend = .{ .vulkan = true },
        .validation = .none,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer instance.deinit();

    const adapters = try instance.enumerateAdapters();
    defer adapters.deinit();

    try std.testing.expect(adapters.inner.len > 0);
    const info = adapters.inner[0].info();
    try std.testing.expect(info.nameSlice().len > 0);
    try std.testing.expect(adapters.inner[0].capabilities().limits.max_texture_dimension_2d > 0);
    try std.testing.expect(adapters.inner[0].formatCapabilities(.rgba8_unorm).usage.sampled);
}
