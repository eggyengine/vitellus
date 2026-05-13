const std = @import("std");
const vk = @import("vulkan");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");
const instance_backend = @import("instance.zig");
const surface_backend = @import("surface.zig");
const device_backend = @import("device.zig");

const log = std.log.scoped(.vitellus_vulkan);

pub const QueueFamilyIndices = struct {
    graphics_family: ?u32 = null,
    present_family: ?u32 = null,

    pub fn isComplete(self: @This()) bool {
        return self.graphics_family != null and self.present_family != null;
    }
};

pub fn findQueueFamilies(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice, surface: hal.Surface) anyerror!QueueFamilyIndices {
    const vk_surface: *surface_backend.vkSurface = @ptrCast(@alignCast(surface.ptr));
    const queue_families = try instance.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
        pdev,
        std.heap.page_allocator,
    );
    defer std.heap.page_allocator.free(queue_families);

    var indices = QueueFamilyIndices{};
    for (queue_families, 0..) |queue_family, i| {
        if (queue_family.queue_count == 0) {
            continue;
        }

        if (queue_family.queue_count > 0 and queue_family.queue_flags.graphics_bit) {
            indices.graphics_family = @intCast(i);
        }

        const present_supported = instance.instance.getPhysicalDeviceSurfaceSupportKHR(
            pdev,
            @intCast(i),
            vk_surface.handle,
        ) catch .false;
        if (present_supported == .true) {
            indices.present_family = @intCast(i);
        }

        if (indices.isComplete()) {
            break;
        }
    }

    return indices;
}

pub fn isDeviceSuitable(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice, surface: hal.Surface) anyerror!bool {
    const indices = try findQueueFamilies(instance, pdev, surface);
    if (!indices.isComplete()) {
        return false;
    }

    return true;
}

pub fn isPhysicalDeviceSurfaceSupported(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice, surface: hal.Surface) bool {
    const indices = findQueueFamilies(instance, pdev, surface) catch return false;
    if (!indices.isComplete()) {
        return false;
    }

    return true;
}

pub const vkAdapter = struct {
    gpu: *instance_backend.vkInstance,
    pdev: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    features: vk.PhysicalDeviceFeatures,
    queue_family_indices: QueueFamilyIndices,
    selection_surface: hal.Surface,

    pub const vtable = hal.Adapter.VTable{
        .requestDevice = requestDevice,
        .getInfo = getAdapterInfo,
        .getDownlevelCapabilities = getDownlevelCapabilities,
        .getTextureFormatFeatures = getTextureFormatFeatures,
        .isSurfaceSupported = isSurfaceSupported,
    };

    pub fn init(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice, selection_surface: hal.Surface) !@This() {
        return .{
            .gpu = instance,
            .pdev = pdev,
            .properties = instance.instance.getPhysicalDeviceProperties(pdev),
            .features = instance.instance.getPhysicalDeviceFeatures(pdev),
            .queue_family_indices = try findQueueFamilies(instance, pdev, selection_surface),
            .selection_surface = selection_surface,
        };
    }

    fn requestDevice(
        ptr: *anyopaque,
        io: std.Io,
        options: gpu.Device.Descriptor,
    ) std.Io.Future(anyerror!struct { hal.Device, hal.Queue }) {
        log.debug("requesting vulkan device", .{});
        return io.async(requestDeviceInternal, .{ ptr, options });
    }

    fn requestDeviceInternal(ptr: *anyopaque, options: gpu.Device.Descriptor) anyerror!struct { hal.Device, hal.Queue } {
        const adapter: *@This() = @ptrCast(@alignCast(ptr));
        _ = options;

        const graphics_queue_family = adapter.queue_family_indices.graphics_family orelse return error.NoGraphicsQueueFamily;
        const present_queue_family = adapter.queue_family_indices.present_family orelse return error.NoPresentQueueFamily;
        var queue_families: [2]u32 = undefined;
        queue_families[0] = graphics_queue_family;
        var queue_family_count: usize = 1;
        if (graphics_queue_family != present_queue_family) {
            queue_families[queue_family_count] = present_queue_family;
            queue_family_count += 1;
        }

        const queue_priority = [_]f32{1.0};
        var queue_create_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        for (queue_families[0..queue_family_count], 0..) |queue_family, i| {
            queue_create_infos[i] = .{
                .queue_family_index = queue_family,
                .queue_count = 1,
                .p_queue_priorities = &queue_priority,
            };
        }

        const device_features = vk.PhysicalDeviceFeatures{};
        const create_info = vk.DeviceCreateInfo{
            .queue_create_info_count = @intCast(queue_family_count),
            .p_queue_create_infos = @ptrCast(&queue_create_infos),
            .enabled_layer_count = if (adapter.gpu.validation_layers_enabled) @intCast(adapter.gpu.validation_layers.len) else 0,
            .pp_enabled_layer_names = if (adapter.gpu.validation_layers_enabled) adapter.gpu.validation_layers.ptr else null,
            .enabled_extension_count = 0,
            .p_enabled_features = &device_features,
        };
        const get_device_proc_addr = adapter.gpu.vki.dispatch.vkGetDeviceProcAddr orelse return error.MissingVkGetDeviceProcAddr;

        log.debug("creating vulkan logical device: graphics_queue_family={}", .{graphics_queue_family});
        const device_handle = try adapter.gpu.instance.createDevice(adapter.pdev, &create_info, null);

        const device = try std.heap.page_allocator.create(device_backend.vkDevice);
        errdefer std.heap.page_allocator.destroy(device);
        device.* = .{
            .adapter = adapter,
            .vkd = undefined,
            .device = undefined,
            .device_handle = device_handle,
            .graphics_queue_family = graphics_queue_family,
            .present_queue_family = present_queue_family,
            .graphics_queue = .null_handle,
            .present_queue = .null_handle,
            .queue = undefined,
        };
        device.vkd = vk.DeviceWrapper.load(device_handle, get_device_proc_addr);
        device.device = vk.DeviceProxy.init(device_handle, &device.vkd);
        errdefer device.device.destroyDevice(null);
        device.graphics_queue = device.device.getDeviceQueue(graphics_queue_family, 0);
        device.present_queue = device.device.getDeviceQueue(present_queue_family, 0);
        device.queue = .{
            .device = device,
            .handle = device.graphics_queue,
        };

        log.debug("created vulkan logical device: handle=0x{x} graphics_queue=0x{x}", .{
            @intFromEnum(device.device_handle),
            @intFromEnum(device.graphics_queue),
        });
        return .{
            .{
                .ptr = device,
                .vtable = &device_backend.vkDevice.vtable,
            },
            .{
                .ptr = &device.queue,
                .vtable = &device_backend.vkQueue.vtable,
            },
        };
    }

    fn getAdapterInfo(ptr: *anyopaque) gpu.Adapter.Info {
        const adapter: *@This() = @ptrCast(@alignCast(ptr));
        log.debug("getting vulkan adapter info", .{});
        return .{
            .vendor = "",
            .architecture = "",
            .device = @ptrCast(&adapter.properties.device_name),
            .description = @ptrCast(&adapter.properties.device_name),
            .subgroupMinSize = 0,
            .subgroupMaxSize = 0,
            .isFallbackAdapter = adapter.properties.device_type == .cpu,
        };
    }

    fn getDownlevelCapabilities(ptr: *anyopaque) gpu.Adapter.DownlevelCapabilities {
        _ = ptr;
        log.debug("getting vulkan adapter downlevel capabilities", .{});
        return .{};
    }

    fn getTextureFormatFeatures(
        ptr: *anyopaque,
        format: texture.Texture.Format,
    ) gpu.Adapter.TextureFormatFeatures {
        _ = ptr;
        _ = format;
        log.debug("getting vulkan texture format features", .{});
        return .{};
    }

    fn isSurfaceSupported(ptr: *anyopaque, surface: hal.Surface) bool {
        const adapter: *@This() = @ptrCast(@alignCast(ptr));
        return isPhysicalDeviceSurfaceSupported(adapter.gpu, adapter.pdev, surface);
    }
};
