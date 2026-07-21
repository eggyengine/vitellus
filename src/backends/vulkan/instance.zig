const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const DynLib = @import("../../utils/dynlib.zig").DynLib;

const Instance = @import("../../interface/instance.zig").Instance;
const Adapter = @import("../../interface/adapter.zig").Adapter;
const AdapterDescriptor = @import("../../interface/adapter.zig").AdapterDescriptor;
const VitellusConfig = @import("../../interface/settings.zig").VitellusConfig;
const ValidationLevel = @import("../../interface/settings.zig").ValidationLevel;

const vkAdapter = @import("adapter.zig").vkAdapter;

const log = std.log.scoped(.vk_instance);
const validation_layer_name: [:0]const u8 = "VK_LAYER_KHRONOS_validation";

pub const vkInstance = struct {
    loader: DynLib,
    base: vk.BaseWrapper,
    instance: vk.Instance,
    wrapper: vk.InstanceWrapper,
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    validation_level: ValidationLevel,
    validation_layer_enabled: bool,
    debug_utils_enabled: bool,
    ref_count: usize = 1,

    const vtable: Instance.VTable = .{
        .deinitFn = deinitImpl,
        .createAdapterFn = createAdapterImpl,
        .enumerateAdaptersFn = enumerateAdaptersImpl,
    };

    pub fn init(allocator: std.mem.Allocator, config: VitellusConfig) !Instance {
        const self = try allocator.create(vkInstance);
        errdefer allocator.destroy(self);

        var loader = try openVulkanLoader();
        errdefer loader.close();

        const get_instance_proc_addr = loader.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
            return error.VulkanLoaderMissingGetInstanceProcAddr;
        const base = vk.BaseWrapper.load(get_instance_proc_addr);
        if (base.dispatch.vkCreateInstance == null)
            return error.VulkanLoaderMissingCreateInstance;

        var enabled_layers: [1][*:0]const u8 = undefined;
        var enabled_layer_count: u32 = 0;
        var enabled_extensions: [8][*:0]const u8 = undefined;
        var enabled_extension_count: u32 = 0;

        const validation_enabled = config.validation != .none and
            try hasInstanceLayer(base, allocator, validation_layer_name);
        if (config.validation != .none and !validation_enabled) {
            log.warn("Vulkan validation requested, but {s} is unavailable", .{validation_layer_name});
        }
        if (validation_enabled) {
            enabled_layers[enabled_layer_count] = validation_layer_name.ptr;
            enabled_layer_count += 1;
        }

        // Debug utils is also used for object names, so enable it whenever the
        // application requests validation, even if the SDK validation layer is
        // not installed on the current machine.
        const debug_utils_enabled = config.validation != .none and
            try hasInstanceExtension(base, allocator, null, vk.extensions.ext_debug_utils.name);
        if (debug_utils_enabled) {
            enabled_extensions[enabled_extension_count] = vk.extensions.ext_debug_utils.name.ptr;
            enabled_extension_count += 1;
        } else if (config.validation != .none) {
            log.warn("Vulkan validation requested without {s}; messages and object names are unavailable", .{vk.extensions.ext_debug_utils.name});
        }

        if (!try hasInstanceExtension(base, allocator, null, vk.extensions.khr_surface.name))
            return error.VulkanSurfaceExtensionUnavailable;
        enabled_extensions[enabled_extension_count] = vk.extensions.khr_surface.name.ptr;
        enabled_extension_count += 1;

        switch (builtin.target.os.tag) {
            .windows => {
                if (!try hasInstanceExtension(base, allocator, null, vk.extensions.khr_win_32_surface.name))
                    return error.VulkanPlatformSurfaceExtensionUnavailable;
                enabled_extensions[enabled_extension_count] = vk.extensions.khr_win_32_surface.name.ptr;
                enabled_extension_count += 1;
            },
            .linux => {
                var platform_extension_count: u32 = 0;
                inline for (.{
                    vk.extensions.khr_wayland_surface.name,
                    vk.extensions.khr_xcb_surface.name,
                    vk.extensions.khr_xlib_surface.name,
                }) |extension| {
                    if (try hasInstanceExtension(base, allocator, null, extension)) {
                        enabled_extensions[enabled_extension_count] = extension.ptr;
                        enabled_extension_count += 1;
                        platform_extension_count += 1;
                    }
                }
                if (platform_extension_count == 0) return error.VulkanPlatformSurfaceExtensionUnavailable;
            },
            .macos => {
                if (!try hasInstanceExtension(base, allocator, null, vk.extensions.ext_metal_surface.name))
                    return error.VulkanPlatformSurfaceExtensionUnavailable;
                enabled_extensions[enabled_extension_count] = vk.extensions.ext_metal_surface.name.ptr;
                enabled_extension_count += 1;
            },
            else => return error.VulkanUnsupportedPlatform,
        }

        const portability_enabled = try hasInstanceExtension(
            base,
            allocator,
            null,
            vk.extensions.khr_portability_enumeration.name,
        );
        if (portability_enabled) {
            enabled_extensions[enabled_extension_count] = vk.extensions.khr_portability_enumeration.name.ptr;
            enabled_extension_count += 1;
        }

        var validation_feature_values: [4]vk.ValidationFeatureEnableEXT = undefined;
        const validation_feature_count = validationFeatures(config, &validation_feature_values);
        const validation_features_enabled = validation_enabled and validation_feature_count > 0 and
            (try hasInstanceExtension(base, allocator, validation_layer_name.ptr, vk.extensions.ext_validation_features.name) or
                try hasInstanceExtension(base, allocator, null, vk.extensions.ext_validation_features.name));
        if (validation_features_enabled) {
            enabled_extensions[enabled_extension_count] = vk.extensions.ext_validation_features.name.ptr;
            enabled_extension_count += 1;
        } else if (validation_enabled and validation_feature_count > 0) {
            log.warn("advanced Vulkan validation requested, but {s} is unavailable", .{vk.extensions.ext_validation_features.name});
        }

        var validation_features: vk.ValidationFeaturesEXT = .{
            .enabled_validation_feature_count = if (validation_features_enabled) validation_feature_count else 0,
            .p_enabled_validation_features = if (validation_features_enabled) &validation_feature_values else null,
        };
        var debug_create_info = debugMessengerCreateInfo();
        if (validation_features_enabled)
            debug_create_info.p_next = &validation_features;

        const app_info: vk.ApplicationInfo = .{
            .p_application_name = null,
            .application_version = vk.makeApiVersion(0, 0, 1, 0).toU32(),
            .p_engine_name = null,
            .engine_version = vk.makeApiVersion(0, 0, 1, 0).toU32(),
            .api_version = try supportedApiVersion(base),
        };
        const instance = try base.createInstance(&.{
            .p_next = if (debug_utils_enabled) &debug_create_info else if (validation_features_enabled) &validation_features else null,
            .flags = .{ .enumerate_portability_bit_khr = portability_enabled },
            .p_application_info = &app_info,
            .enabled_layer_count = enabled_layer_count,
            .pp_enabled_layer_names = if (enabled_layer_count > 0) &enabled_layers else null,
            .enabled_extension_count = enabled_extension_count,
            .pp_enabled_extension_names = if (enabled_extension_count > 0) &enabled_extensions else null,
        }, null);
        const wrapper = vk.InstanceWrapper.load(instance, get_instance_proc_addr);
        errdefer {
            if (wrapper.dispatch.vkDestroyInstance) |destroy_instance|
                destroy_instance(instance, null);
        }
        if (wrapper.dispatch.vkDestroyInstance == null)
            return error.VulkanLoaderMissingDestroyInstance;

        var debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle;
        if (debug_utils_enabled and
            wrapper.dispatch.vkCreateDebugUtilsMessengerEXT != null and
            wrapper.dispatch.vkDestroyDebugUtilsMessengerEXT != null)
        {
            debug_messenger = wrapper.createDebugUtilsMessengerEXT(instance, &debug_create_info, null) catch |err| blk: {
                log.warn("failed to create Vulkan debug messenger: {}", .{err});
                break :blk .null_handle;
            };
        }

        self.* = .{
            .loader = loader,
            .base = base,
            .instance = instance,
            .wrapper = wrapper,
            .debug_messenger = debug_messenger,
            .validation_level = config.validation,
            .validation_layer_enabled = validation_enabled,
            .debug_utils_enabled = debug_utils_enabled,
        };

        log.debug("initialised Vulkan instance", .{});
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    /// Names a device-owned Vulkan object when validation was requested and
    /// `VK_EXT_debug_utils` is available. Naming is diagnostic-only and never
    /// makes object creation fail.
    pub fn nameObject(
        self: *const vkInstance,
        allocator: std.mem.Allocator,
        device: vk.DeviceProxy,
        object_type: vk.ObjectType,
        object_handle: u64,
        label: ?[]const u8,
    ) void {
        if (self.validation_level == .none or !self.debug_utils_enabled) return;
        const value = label orelse return;
        const terminated = allocator.dupeZ(u8, value) catch |err| {
            log.warn("could not allocate Vulkan debug name: {}", .{err});
            return;
        };
        defer allocator.free(terminated);
        @import("debug.zig").nameVkObj(device, object_type, object_handle, terminated) catch |err| {
            log.warn("could not name Vulkan {s}: {}", .{ @tagName(object_type), err });
        };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *vkInstance = @ptrCast(@alignCast(ptr));

        self.release(allocator);
    }

    pub fn retain(self: *vkInstance) void { self.ref_count += 1; }
    pub fn release(self: *vkInstance, allocator: std.mem.Allocator) void {
        self.ref_count -= 1;
        if (self.ref_count != 0) return;

        if (self.debug_messenger != .null_handle)
            self.wrapper.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        self.wrapper.destroyInstance(self.instance, null);
        self.loader.close();
        log.debug("destroyed Vulkan instance", .{});
        allocator.destroy(self);
    }

    fn createAdapterImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: AdapterDescriptor) !Adapter {
        return vkAdapter.init(ptr, allocator, desc);
    }

    fn enumerateAdaptersImpl(ptr: *anyopaque, allocator: std.mem.Allocator) !@import("../../interface/instance.zig").Adapters {
        return vkAdapter.enumerate(ptr, allocator);
    }
};

fn supportedApiVersion(base: vk.BaseWrapper) !u32 {
    if (base.dispatch.vkEnumerateInstanceVersion == null)
        return vk.API_VERSION_1_0.toU32();
    return @min(try base.enumerateInstanceVersion(), vk.API_VERSION_1_4.toU32());
}

fn hasInstanceLayer(base: vk.BaseWrapper, allocator: std.mem.Allocator, name: []const u8) !bool {
    const properties = try base.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(properties);

    for (properties) |*property| {
        if (fixedStringEquals(property.layer_name.len, &property.layer_name, name)) return true;
    }
    return false;
}

fn hasInstanceExtension(
    base: vk.BaseWrapper,
    allocator: std.mem.Allocator,
    layer_name: ?[*:0]const u8,
    name: []const u8,
) !bool {
    const properties = try base.enumerateInstanceExtensionPropertiesAlloc(layer_name, allocator);
    defer allocator.free(properties);

    for (properties) |*property| {
        if (fixedStringEquals(property.extension_name.len, &property.extension_name, name)) return true;
    }
    return false;
}

fn fixedStringEquals(comptime len: usize, value: *const [len]u8, expected: []const u8) bool {
    const value_len = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
    return std.mem.eql(u8, value[0..value_len], expected);
}

fn validationFeatures(config: VitellusConfig, features: *[4]vk.ValidationFeatureEnableEXT) u32 {
    return switch (config.validation) {
        .none, .core => 0,
        .extended => blk: {
            features[0] = .best_practices_ext;
            features[1] = .synchronization_validation_ext;
            break :blk 2;
        },
        .gpu_based => blk: {
            features[0] = .best_practices_ext;
            features[1] = .synchronization_validation_ext;
            features[2] = .gpu_assisted_ext;
            features[3] = .gpu_assisted_reserve_binding_slot_ext;
            break :blk 4;
        },
    };
}

fn debugMessengerCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .message_severity = .{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = debugCallback,
    };
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    const data = callback_data orelse return .false;
    const message = if (data.p_message) |value| std.mem.span(value) else "Vulkan validation message";
    const debug_callback_log = std.log.scoped(.vk_debug);
    if (severity.error_bit_ext) {
        debug_callback_log.err("{s}", .{message});
    } else if (severity.warning_bit_ext) {
        debug_callback_log.warn("{s}", .{message});
    } else if (severity.info_bit_ext) {
        debug_callback_log.info("{s}", .{message});
    } else {
        debug_callback_log.debug("{s}", .{message});
    }
    return .false;
}

fn openVulkanLoader() !DynLib {
    return switch (builtin.target.os.tag) {
        .windows => DynLib.open("vulkan-1.dll"),
        .linux => DynLib.open("libvulkan.so.1") catch DynLib.open("libvulkan.so"),
        .macos => DynLib.open("libvulkan.1.dylib") catch
            DynLib.open("libvulkan.dylib") catch
            DynLib.open("libMoltenVK.dylib"),
        else => error.VulkanUnsupportedPlatform,
    };
}

test "Vulkan instance lifecycle" {
    if (builtin.target.os.tag != .windows and
        builtin.target.os.tag != .linux and
        builtin.target.os.tag != .macos)
    {
        return error.SkipZigTest;
    }

    const instance = vkInstance.init(std.testing.allocator, .{
        .backend = .{ .vulkan = true },
        .validation = .extended,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const backend: *vkInstance = @ptrCast(@alignCast(instance.ptr));
    try std.testing.expectEqual(ValidationLevel.extended, backend.validation_level);
    if (!backend.debug_utils_enabled) {
        try std.testing.expectEqual(vk.DebugUtilsMessengerEXT.null_handle, backend.debug_messenger);
    }
    instance.deinit();
}

test "Vulkan validation none disables diagnostics" {
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

    const backend: *vkInstance = @ptrCast(@alignCast(instance.ptr));
    try std.testing.expectEqual(ValidationLevel.none, backend.validation_level);
    try std.testing.expect(!backend.validation_layer_enabled);
    try std.testing.expect(!backend.debug_utils_enabled);
    try std.testing.expectEqual(vk.DebugUtilsMessengerEXT.null_handle, backend.debug_messenger);
}
