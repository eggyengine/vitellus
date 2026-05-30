const std = @import("std");
const vk = @import("vulkan");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");
const instance_backend = @import("instance.zig");
const surface_backend = @import("surface.zig");
const device_backend = @import("device.zig");
const debug = @import("debug.zig");


pub const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name.ptr,
};

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
        instance.allocator,
    );
    defer instance.allocator.free(queue_families);

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

pub fn isPhysicalDeviceSurfaceSupported(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice, surface: hal.Surface) bool {
    const indices = findQueueFamilies(instance, pdev, surface) catch |err| {
        std.log.debug("failed to query vulkan queue families: {s}", .{@errorName(err)});
        return false;
    };

    const extensions_supported = checkDeviceExtensionSupport(instance, pdev);
    const swapchain_adequate = if (extensions_supported)
        hasAdequateSwapchainSupport(instance, pdev, surface)
    else
        false;

    return indices.isComplete() and extensions_supported and swapchain_adequate and supportsRequiredDeviceFeatures(instance, pdev);
}

pub fn isDeviceSuitable(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice, surface: hal.Surface) anyerror!bool {
    const indices = try findQueueFamilies(instance, pdev, surface);
    const extensions_supported = checkDeviceExtensionSupport(instance, pdev);
    const swapchain_adequate = if (extensions_supported)
        hasAdequateSwapchainSupport(instance, pdev, surface)
    else
        false;

    return indices.isComplete() and extensions_supported and swapchain_adequate and supportsRequiredDeviceFeatures(instance, pdev);
}

pub fn checkDeviceExtensionSupport(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice) bool {
    const available_extensions = instance.instance.enumerateDeviceExtensionPropertiesAlloc(
        pdev,
        null,
        instance.allocator,
    ) catch |err| {
        std.log.debug("failed to enumerate vulkan device extensions: {s}", .{@errorName(err)});
        return false;
    };
    defer instance.allocator.free(available_extensions);

    for (required_device_extensions) |required_extension| {
        if (!hasDeviceExtension(available_extensions, std.mem.span(required_extension))) {
            std.log.debug("missing vulkan device extension: {s}", .{required_extension});
            return false;
        }
    }

    return true;
}

fn supportsRequiredDeviceFeatures(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice) bool {
    var vulkan_11_features = vk.PhysicalDeviceVulkan11Features{};
    var features = vk.PhysicalDeviceFeatures2{
        .p_next = @ptrCast(&vulkan_11_features),
        .features = .{},
    };
    instance.instance.getPhysicalDeviceFeatures2(pdev, &features);

    if (vulkan_11_features.shader_draw_parameters != .true) {
        std.log.debug("missing required vulkan device feature: shaderDrawParameters", .{});
        return false;
    }

    return true;
}

fn hasAdequateSwapchainSupport(instance: *instance_backend.vkInstance, pdev: vk.PhysicalDevice, surface: hal.Surface) bool {
    const vk_surface: *surface_backend.vkSurface = @ptrCast(@alignCast(surface.ptr));

    const formats = instance.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        pdev,
        vk_surface.handle,
        instance.allocator,
    ) catch |err| {
        std.log.debug("failed to query vulkan surface formats: {s}", .{@errorName(err)});
        return false;
    };
    defer instance.allocator.free(formats);

    const present_modes = instance.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        pdev,
        vk_surface.handle,
        instance.allocator,
    ) catch |err| {
        std.log.debug("failed to query vulkan present modes: {s}", .{@errorName(err)});
        return false;
    };
    defer instance.allocator.free(present_modes);

    return formats.len != 0 and present_modes.len != 0;
}

fn hasDeviceExtension(available_extensions: []const vk.ExtensionProperties, required_extension: []const u8) bool {
    for (available_extensions) |available_extension| {
        const extension_name = std.mem.sliceTo(&available_extension.extension_name, 0);
        if (std.mem.eql(u8, extension_name, required_extension)) {
            return true;
        }
    }

    return false;
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
        std.log.debug("requesting vulkan device", .{});
        return io.async(requestDeviceInternal, .{ ptr, options });
    }

    fn requestDeviceInternal(ptr: *anyopaque, options: gpu.Device.Descriptor) anyerror!struct { hal.Device, hal.Queue } {
        const adapter: *@This() = @ptrCast(@alignCast(ptr));

        // locate queue
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

        // TOOO: implement webgpu-specific features
        var vulkan_13_features = vk.PhysicalDeviceVulkan13Features{
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
        };
        const vulkan_11_features = vk.PhysicalDeviceVulkan11Features{
            .p_next = @ptrCast(&vulkan_13_features),
            .shader_draw_parameters = .true,
        };
        const create_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&vulkan_11_features),
            .queue_create_info_count = @intCast(queue_family_count),
            .p_queue_create_infos = @ptrCast(&queue_create_infos),
            .pp_enabled_layer_names = null,
            .enabled_extension_count = @intCast(required_device_extensions.len),
            .pp_enabled_extension_names = &required_device_extensions,
            .p_enabled_features = &device_features,
        };
        const get_device_proc_addr = adapter.gpu.vki.dispatch.vkGetDeviceProcAddr orelse return error.MissingVkGetDeviceProcAddr;

        std.log.debug("creating vulkan logical device: graphics_queue_family={}", .{graphics_queue_family});
        const device_handle = try adapter.gpu.instance.createDevice(adapter.pdev, &create_info, null);

        const device = try adapter.gpu.allocator.create(device_backend.vkDevice);
        errdefer adapter.gpu.allocator.destroy(device);
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

        debug.setObjectName(device, .device, device.device_handle, options.label);
        debug.setObjectName(device, .queue, device.graphics_queue, options.default_queue.label);

        std.log.debug("created vulkan logical device: handle=0x{x} graphics_queue=0x{x}", .{
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
        std.log.debug("getting vulkan adapter info", .{});
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

    fn getDownlevelCapabilities(ptr: *anyopaque) anyerror!gpu.Adapter.DownlevelCapabilities {
        _ = ptr;
        std.log.debug("getting vulkan adapter downlevel capabilities", .{});
        return error.NotImplemented;
    }

    fn getTextureFormatFeatures(
        ptr: *anyopaque,
        format: texture.Texture.Format,
    ) anyerror!gpu.Adapter.TextureFormatFeatures {
        _ = ptr;
        _ = format;
        std.log.debug("getting vulkan texture format features", .{});
        return error.NotImplemented;
    }

    fn isSurfaceSupported(ptr: *anyopaque, surface: hal.Surface) bool {
        const adapter: *@This() = @ptrCast(@alignCast(ptr));
        return isPhysicalDeviceSurfaceSupported(adapter.gpu, adapter.pdev, surface);
    }
};
