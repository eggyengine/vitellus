const std = @import("std");
const candler = @import("candler");
const vk = @import("vulkan");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const vulkan_windowing = @import("../../windowing/vulkan.zig");
const DynLib = @import("../../utils/dynamic_lib.zig").DynLib;

const adapter_backend = @import("adapter.zig");
const surface_backend = @import("surface.zig");

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const Instance = vk.InstanceProxy;

const allocator = std.heap.page_allocator;
const log = std.log.scoped(.vitellus_vulkan);

pub const default_validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

pub const InstanceDescriptor = struct {
    getInstanceProcAddr: ?vk.PfnGetInstanceProcAddr = null,
    required_extensions: []const [*:0]const u8 = &.{},
    requested_validation_layers: []const [*:0]const u8 = &default_validation_layers,
    enable_validation: bool = false,
    application_name: [*:0]const u8 = "vitellus",
    application_version: u32 = vk.makeApiVersion(0, 1, 0, 0).toU32(),
    engine_name: [*:0]const u8 = "vitellus",
    engine_version: u32 = vk.makeApiVersion(0, 1, 0, 0).toU32(),
    api_version: u32 = vk.API_VERSION_1_4.toU32(),
};

pub const vkInstance = struct {
    vkb: BaseWrapper = undefined,
    vki: InstanceWrapper = undefined,
    instance: Instance = undefined,
    instance_handle: vk.Instance = .null_handle,
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    validation_layers_enabled: bool = false,
    validation_layers: []const [*:0]const u8 = &.{},
    debug_utils_enabled: bool = false,
    headless_surface: ?*surface_backend.vkSurface = null,
    loader: ?DynLib = null,

    pub const vtable = hal.Instance.VTable{
        .enumerateAdapters = enumerateAdapters,
        .requestAdapter = requestAdapter,
        .destroy = destroyGPU,
        .createSurface = createSurface,
    };

    pub fn init(descriptor: gpu.Instance.Descriptor) hal.Instance.FromPotentialBackendsError!hal.Instance {
        log.debug("initializing vulkan backend with default descriptor", .{});
        return initWithDescriptor(.{
            .enable_validation = descriptor.flags.validation,
        }) catch error.NoBackendAvailable;
    }

    pub fn initWithDescriptor(descriptor: InstanceDescriptor) !hal.Instance {
        log.debug("initializing vulkan backend: required_extensions={} api_version=0x{x}", .{
            descriptor.required_extensions.len,
            descriptor.api_version,
        });

        const self = try allocator.create(vkInstance);
        self.* = .{};
        errdefer destroyGPU(self);

        const get_instance_proc_addr = descriptor.getInstanceProcAddr orelse try loadDefaultGetInstanceProcAddr(self);
        log.debug("loaded vkGetInstanceProcAddr", .{});
        self.vkb = BaseWrapper.load(get_instance_proc_addr);

        const extension_properties = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
        defer allocator.free(extension_properties);
        const validation_layers_enabled = descriptor.enable_validation and
            validationLayersAvailable(self.vkb, descriptor.requested_validation_layers);
        if (descriptor.enable_validation and !validation_layers_enabled) {
            log.warn("vulkan validation requested, but required validation layers are unavailable; continuing without validation", .{});
        }

        var enabled_extensions: [64][*:0]const u8 = undefined;
        var enabled_extension_count: usize = 0;
        try addRequiredInstanceExtensions(
            &enabled_extensions,
            &enabled_extension_count,
            extension_properties,
            descriptor.required_extensions,
        );
        addSupportedInstanceExtensions(
            &enabled_extensions,
            &enabled_extension_count,
            extension_properties,
            vulkan_windowing.default_instance_extensions,
        );
        const debug_utils_enabled = validation_layers_enabled and
            hasInstanceExtension(extension_properties, vk.extensions.ext_debug_utils.name);
        if (validation_layers_enabled) {
            if (debug_utils_enabled) {
                try addInstanceExtension(
                    &enabled_extensions,
                    &enabled_extension_count,
                    vk.extensions.ext_debug_utils.name.ptr,
                    false,
                );
            } else {
                log.warn("vulkan validation enabled, but {s} is unavailable; continuing without debug messenger callback", .{
                    vk.extensions.ext_debug_utils.name,
                });
            }
        }
        log.debug("enabled vulkan instance extensions: count={}", .{enabled_extension_count});

        const app_info = vk.ApplicationInfo{
            .p_application_name = descriptor.application_name,
            .application_version = descriptor.application_version,
            .p_engine_name = descriptor.engine_name,
            .engine_version = descriptor.engine_version,
            .api_version = descriptor.api_version,
        };

        var debug_create_info = populateDebugMessengerCreateInfo();
        const enabled_validation_layers = if (validation_layers_enabled) descriptor.requested_validation_layers else &.{};
        const create_info = vk.InstanceCreateInfo{
            .p_next = if (debug_utils_enabled) @ptrCast(&debug_create_info) else null,
            .p_application_info = &app_info,
            .enabled_layer_count = @intCast(enabled_validation_layers.len),
            .pp_enabled_layer_names = if (enabled_validation_layers.len == 0) null else enabled_validation_layers.ptr,
            .enabled_extension_count = @intCast(enabled_extension_count),
            .pp_enabled_extension_names = if (enabled_extension_count == 0) null else enabled_extensions[0..enabled_extension_count].ptr,
        };

        const instance_handle = try self.vkb.createInstance(&create_info, null);
        errdefer self.vkb.destroyInstance(instance_handle, null);
        log.debug("created vulkan instance: handle=0x{x}", .{@intFromEnum(instance_handle)});

        self.vki = InstanceWrapper.load(instance_handle, get_instance_proc_addr);
        self.instance = Instance.init(instance_handle, &self.vki);
        self.instance_handle = instance_handle;
        self.validation_layers_enabled = validation_layers_enabled;
        self.validation_layers = enabled_validation_layers;
        self.debug_utils_enabled = debug_utils_enabled;

        if (debug_utils_enabled) {
            self.debug_messenger = self.instance.createDebugUtilsMessengerEXT(&debug_create_info, null) catch |err| blk: {
                log.warn("failed to set up vulkan debug messenger: {s}; continuing without callback", .{@errorName(err)});
                self.debug_utils_enabled = false;
                break :blk .null_handle;
            };
        }

        return .{
            .ptr = self,
            .vtable = &vkInstance.vtable,
        };
    }

    fn destroyGPU(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.debug_messenger != .null_handle) {
            log.debug("destroying vulkan debug messenger: handle=0x{x}", .{@intFromEnum(typed.debug_messenger)});
            typed.instance.destroyDebugUtilsMessengerEXT(typed.debug_messenger, null);
            typed.debug_messenger = .null_handle;
        }

        if (typed.headless_surface) |surface| {
            log.debug("destroying cached vulkan headless surface", .{});
            surface.destroy();
            typed.headless_surface = null;
        }

        if (typed.instance_handle != .null_handle) {
            log.debug("destroying vulkan instance: handle=0x{x}", .{@intFromEnum(typed.instance_handle)});
            typed.instance.destroyInstance(null);
            typed.instance_handle = .null_handle;
            typed.instance.handle = .null_handle;
        }

        typed.validation_layers_enabled = false;
        typed.validation_layers = &.{};
        typed.debug_utils_enabled = false;

        if (typed.loader) |*loader| {
            log.debug("closing vulkan loader", .{});
            loader.close();
            typed.loader = null;
        }

        allocator.destroy(typed);
    }

    fn enumerateAdapters(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror![]const hal.Adapter {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const selection_surface = try typed.selectionSurface(options);

        log.debug("enumerating vulkan adapters", .{});

        const pdevs = try typed.instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(pdevs);

        var adapters = std.ArrayList(hal.Adapter).empty;
        errdefer adapters.deinit(allocator);

        for (pdevs) |pdev| {
            if (!(try adapter_backend.isDeviceSuitable(typed, pdev, selection_surface))) {
                continue;
            }

            const adapter = try allocator.create(adapter_backend.vkAdapter);
            errdefer allocator.destroy(adapter);
            adapter.* = try adapter_backend.vkAdapter.init(typed, pdev, selection_surface);
            try adapters.append(allocator, .{
                .ptr = adapter,
                .vtable = &adapter_backend.vkAdapter.vtable,
            });
        }

        return try adapters.toOwnedSlice(allocator);
    }

    fn createSurface(
        ptr: *anyopaque,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!hal.Surface {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        log.debug("allocating vulkan surface wrapper", .{});
        const surface = try allocator.create(surface_backend.vkSurface);
        errdefer allocator.destroy(surface);

        surface.* = try surface_backend.vkSurface.initRaw(typed, window, display);
        log.debug("created vulkan surface wrapper: handle=0x{x}", .{@intFromEnum(surface.handle)});
        return .{
            .ptr = surface,
            .vtable = &surface_backend.vkSurface.vtable,
        };
    }

    fn requestAdapter(
        ptr: *anyopaque,
        io: std.Io,
        options: gpu.Adapter.RequestOptions,
    ) std.Io.Future(anyerror!hal.Adapter) {
        log.debug("requesting vulkan adapter", .{});
        return io.async(requestAdapterInternal, .{ ptr, options });
    }

    fn requestAdapterInternal(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror!hal.Adapter {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const selection_surface = try typed.selectionSurface(options);

        log.debug("picking vulkan physical device", .{});
        const pdev = try pickPhysicalDevice(typed, selection_surface);
        const adapter = try allocator.create(adapter_backend.vkAdapter);
        errdefer allocator.destroy(adapter);
        adapter.* = try adapter_backend.vkAdapter.init(typed, pdev, selection_surface);
        return .{
            .ptr = adapter,
            .vtable = &adapter_backend.vkAdapter.vtable,
        };
    }

    fn pickPhysicalDevice(instance: *vkInstance, selection_surface: hal.Surface) anyerror!vk.PhysicalDevice {
        const pdevs = try instance.instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(pdevs);

        for (pdevs) |pdev| {
            if (try adapter_backend.isDeviceSuitable(instance, pdev, selection_surface)) {
                return pdev;
            }
        }

        return error.NoAdapter;
    }

    fn selectionSurface(instance: *@This(), options: gpu.Adapter.RequestOptions) anyerror!hal.Surface {
        if (options.surface) |surface| {
            return surface.backend;
        }

        return instance.getOrCreateHeadlessSurface();
    }

    fn getOrCreateHeadlessSurface(instance: *@This()) anyerror!hal.Surface {
        if (instance.headless_surface == null) {
            log.debug("creating cached vulkan headless surface for adapter selection", .{});
            const surface = try allocator.create(surface_backend.vkSurface);
            errdefer allocator.destroy(surface);
            surface.* = try surface_backend.vkSurface.initHeadless(instance);
            instance.headless_surface = surface;
        }

        return .{
            .ptr = instance.headless_surface.?,
            .vtable = &surface_backend.vkSurface.vtable,
        };
    }
};

fn validationLayersAvailable(vkb: BaseWrapper, requested_layers: []const [*:0]const u8) bool {
    if (requested_layers.len == 0) {
        return true;
    }

    const available_layers = vkb.enumerateInstanceLayerPropertiesAlloc(allocator) catch |err| {
        log.warn("failed to enumerate vulkan validation layers: {s}", .{@errorName(err)});
        return false;
    };
    defer allocator.free(available_layers);

    for (requested_layers) |requested_layer| {
        if (!hasInstanceLayer(available_layers, std.mem.span(requested_layer))) {
            log.warn("vulkan validation layer unavailable: {s}", .{requested_layer});
            return false;
        }
    }

    return true;
}

fn hasInstanceLayer(available_layers: []const vk.LayerProperties, requested_layer: []const u8) bool {
    for (available_layers) |available_layer| {
        const layer_name = std.mem.sliceTo(&available_layer.layer_name, 0);
        if (std.mem.eql(u8, layer_name, requested_layer)) {
            return true;
        }
    }

    return false;
}

fn populateDebugMessengerCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .message_severity = .{
            .verbose_bit_ext = true,
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
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    const debugLog = std.log.scoped(.vitellus_validation);

    _ = message_types;
    _ = p_user_data;

    const message = if (p_callback_data) |data|
        data.p_message orelse "(missing validation message)"
    else
        "(missing validation callback data)";

    if (message_severity.error_bit_ext) {
        debugLog.err("{s}", .{message});
    } else if (message_severity.warning_bit_ext) {
        debugLog.warn("{s}", .{message});
    } else {
        debugLog.debug("{s}", .{message});
    }

    return .false;
}

fn loadDefaultGetInstanceProcAddr(instance: *vkInstance) !vk.PfnGetInstanceProcAddr {
    if (instance.loader == null) {
        log.debug("opening vulkan loader: {s}", .{defaultVulkanLoaderName()});
        instance.loader = try DynLib.open(defaultVulkanLoaderName());
    }

    return instance.loader.?.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse error.MissingVkGetInstanceProcAddr;
}

fn defaultVulkanLoaderName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "vulkan-1.dll",
        .macos, .ios, .tvos, .watchos, .visionos => "libvulkan.1.dylib",
        else => "libvulkan.so.1",
    };
}

fn addRequiredInstanceExtensions(
    enabled_extensions: *[64][*:0]const u8,
    enabled_extension_count: *usize,
    extension_properties: []const vk.ExtensionProperties,
    required_extensions: []const [*:0]const u8,
) !void {
    if (required_extensions.len == 0) {
        log.debug("no vulkan instance extensions requested", .{});
        return;
    }

    for (required_extensions) |required_extension| {
        if (!hasInstanceExtension(extension_properties, std.mem.span(required_extension))) {
            log.debug("missing vulkan instance extension: {s}", .{required_extension});
            return error.RequiredInstanceExtensionNotSupported;
        }
        try addInstanceExtension(enabled_extensions, enabled_extension_count, required_extension, true);
    }
}

fn addSupportedInstanceExtensions(
    enabled_extensions: *[64][*:0]const u8,
    enabled_extension_count: *usize,
    extension_properties: []const vk.ExtensionProperties,
    candidate_extensions: []const [*:0]const u8,
) void {
    for (candidate_extensions) |candidate_extension| {
        if (!hasInstanceExtension(extension_properties, std.mem.span(candidate_extension))) {
            log.debug("skipping unsupported default vulkan instance extension: {s}", .{candidate_extension});
            continue;
        }
        addInstanceExtension(enabled_extensions, enabled_extension_count, candidate_extension, false) catch |err| {
            log.debug("skipping default vulkan instance extension {s}: {s}", .{ candidate_extension, @errorName(err) });
        };
    }
}

fn addInstanceExtension(
    enabled_extensions: *[64][*:0]const u8,
    enabled_extension_count: *usize,
    extension: [*:0]const u8,
    required: bool,
) !void {
    if (hasEnabledInstanceExtension(enabled_extensions[0..enabled_extension_count.*], std.mem.span(extension))) {
        return;
    }

    if (enabled_extension_count.* == enabled_extensions.len) {
        return error.TooManyVulkanInstanceExtensions;
    }

    enabled_extensions[enabled_extension_count.*] = extension;
    enabled_extension_count.* += 1;
    log.debug("{s} vulkan instance extension: {s}", .{ if (required) "required" else "default", extension });
}

fn hasEnabledInstanceExtension(enabled_extensions: []const [*:0]const u8, extension: []const u8) bool {
    for (enabled_extensions) |enabled_extension| {
        if (std.mem.eql(u8, std.mem.span(enabled_extension), extension)) {
            return true;
        }
    }

    return false;
}

fn hasInstanceExtension(extension_properties: []const vk.ExtensionProperties, required_extension: []const u8) bool {
    for (extension_properties) |extension_property| {
        const extension_name = std.mem.sliceTo(&extension_property.extension_name, 0);
        if (std.mem.eql(u8, extension_name, required_extension)) {
            return true;
        }
    }

    return false;
}
