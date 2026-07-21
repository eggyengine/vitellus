const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const adapter = @import("../../interface/adapter.zig");
const swapchain = @import("../../interface/swapchain.zig");
const Window = @import("../../windowing/windowing.zig").Window;
const vkInstance = @import("instance.zig").vkInstance;

pub fn create(instance: *vkInstance, window: Window) !vk.SurfaceKHR {
    const raw_window = (try window.window_handle.windowHandle()).asRaw();
    const raw_display = (try window.display_handle.displayHandle()).asRaw();

    return switch (builtin.target.os.tag) {
        .windows => switch (raw_window) {
            .win32 => |handle| instance.wrapper.createWin32SurfaceKHR(instance.instance, &.{
                .hinstance = intToOpaque(vk.HINSTANCE, handle.hinstance orelse return error.MissingWindowInstance),
                .hwnd = intToOpaque(vk.HWND, handle.hwnd),
            }, null),
            else => error.UnsupportedWindowHandle,
        },
        .linux => switch (raw_window) {
            .wayland => |window_handle| switch (raw_display) {
                .wayland => |display_handle| instance.wrapper.createWaylandSurfaceKHR(instance.instance, &.{
                    .display = @ptrCast(display_handle.display),
                    .surface = @ptrCast(window_handle.surface),
                }, null),
                else => error.MismatchedWindowDisplayHandles,
            },
            .xcb => |window_handle| switch (raw_display) {
                .xcb => |display_handle| instance.wrapper.createXcbSurfaceKHR(instance.instance, &.{
                    .connection = @ptrCast(display_handle.connection orelse return error.MissingDisplayConnection),
                    .window = window_handle.window,
                }, null),
                else => error.MismatchedWindowDisplayHandles,
            },
            .xlib => |window_handle| switch (raw_display) {
                .xlib => |display_handle| instance.wrapper.createXlibSurfaceKHR(instance.instance, &.{
                    .dpy = @ptrCast(display_handle.display orelse return error.MissingDisplayConnection),
                    .window = window_handle.window,
                }, null),
                else => error.MismatchedWindowDisplayHandles,
            },
            else => error.UnsupportedWindowHandle,
        },
        .macos => switch (raw_window) {
            .app_kit => |handle| instance.wrapper.createMetalSurfaceEXT(instance.instance, &.{
                .p_layer = @ptrCast(handle.ns_view),
            }, null),
            else => error.UnsupportedWindowHandle,
        },
        else => error.VulkanUnsupportedPlatform,
    };
}

pub fn query(
    instance: *vkInstance,
    physical_device: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !adapter.SurfaceCapabilities {
    const native_caps = try instance.wrapper.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);
    const native_formats = try instance.wrapper.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, allocator);
    defer allocator.free(native_formats);
    const native_modes = try instance.wrapper.getPhysicalDeviceSurfacePresentModesAllocKHR(physical_device, surface, allocator);
    defer allocator.free(native_modes);

    const all_formats = [_]swapchain.SwapchainFormat{
        .bgra8_unorm,
        .bgra8_unorm_srgb,
        .rgba8_unorm,
        .rgba8_unorm_srgb,
        .rgba16_float,
    };
    const accepts_any_format = native_formats.len == 1 and native_formats[0].format == .undefined and
        native_formats[0].color_space == .srgb_nonlinear_khr;
    var format_count: usize = if (accepts_any_format) all_formats.len else 0;
    if (!accepts_any_format) for (native_formats) |value| {
        if (fromVkFormat(value.format) != null and value.color_space == .srgb_nonlinear_khr) format_count += 1;
    };
    const formats = try allocator.alloc(swapchain.SwapchainFormat, format_count);
    errdefer allocator.free(formats);
    var format_index: usize = 0;
    if (accepts_any_format) {
        @memcpy(formats, &all_formats);
    } else {
        for (native_formats) |value| {
            if (value.color_space != .srgb_nonlinear_khr) continue;
            if (fromVkFormat(value.format)) |format| {
                formats[format_index] = format;
                format_index += 1;
            }
        }
    }

    var mode_count: usize = 0;
    for (native_modes) |value| if (fromVkPresentMode(value) != null) {
        mode_count += 1;
    };
    const modes = try allocator.alloc(swapchain.PresentMode, mode_count);
    errdefer allocator.free(modes);
    var mode_index: usize = 0;
    for (native_modes) |value| if (fromVkPresentMode(value)) |mode| {
        modes[mode_index] = mode;
        mode_index += 1;
    };

    const alpha_count: usize = @intFromBool(native_caps.supported_composite_alpha.opaque_bit_khr) +
        @intFromBool(native_caps.supported_composite_alpha.pre_multiplied_bit_khr) +
        @intFromBool(native_caps.supported_composite_alpha.post_multiplied_bit_khr) +
        @intFromBool(native_caps.supported_composite_alpha.inherit_bit_khr);
    const alpha = try allocator.alloc(swapchain.CompositeAlpha, alpha_count);
    errdefer allocator.free(alpha);
    var alpha_index: usize = 0;
    if (native_caps.supported_composite_alpha.opaque_bit_khr) appendAlpha(alpha, &alpha_index, .opaque_alpha);
    if (native_caps.supported_composite_alpha.pre_multiplied_bit_khr) appendAlpha(alpha, &alpha_index, .premultiplied);
    if (native_caps.supported_composite_alpha.post_multiplied_bit_khr) appendAlpha(alpha, &alpha_index, .postmultiplied);
    if (native_caps.supported_composite_alpha.inherit_bit_khr) appendAlpha(alpha, &alpha_index, .inherit);

    return .{
        .allocator = allocator,
        .formats = formats,
        .present_modes = modes,
        .composite_alpha = alpha,
        .min_image_count = native_caps.min_image_count,
        .max_image_count = native_caps.max_image_count,
        .min_extent = .{ .width = native_caps.min_image_extent.width, .height = native_caps.min_image_extent.height },
        .max_extent = .{ .width = native_caps.max_image_extent.width, .height = native_caps.max_image_extent.height },
    };
}

pub fn toVkFormat(format: swapchain.SwapchainFormat) vk.Format {
    return switch (format) {
        .bgra8_unorm => .b8g8r8a8_unorm,
        .bgra8_unorm_srgb => .b8g8r8a8_srgb,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .rgba8_unorm_srgb => .r8g8b8a8_srgb,
        .rgba16_float => .r16g16b16a16_sfloat,
    };
}

pub fn fromVkFormat(format: vk.Format) ?swapchain.SwapchainFormat {
    return switch (format) {
        .b8g8r8a8_unorm => .bgra8_unorm,
        .b8g8r8a8_srgb => .bgra8_unorm_srgb,
        .r8g8b8a8_unorm => .rgba8_unorm,
        .r8g8b8a8_srgb => .rgba8_unorm_srgb,
        .r16g16b16a16_sfloat => .rgba16_float,
        else => null,
    };
}

pub fn toVkPresentMode(mode: swapchain.PresentMode) vk.PresentModeKHR {
    return switch (mode) {
        .immediate => .immediate_khr,
        .mailbox => .mailbox_khr,
        .fifo => .fifo_khr,
        .fifo_relaxed => .fifo_relaxed_khr,
    };
}

fn fromVkPresentMode(mode: vk.PresentModeKHR) ?swapchain.PresentMode {
    return switch (mode) {
        .immediate_khr => .immediate,
        .mailbox_khr => .mailbox,
        .fifo_khr => .fifo,
        .fifo_relaxed_khr => .fifo_relaxed,
        else => null,
    };
}

pub fn toVkCompositeAlpha(alpha: swapchain.CompositeAlpha) vk.CompositeAlphaFlagsKHR {
    return switch (alpha) {
        .opaque_alpha => .{ .opaque_bit_khr = true },
        .premultiplied => .{ .pre_multiplied_bit_khr = true },
        .postmultiplied => .{ .post_multiplied_bit_khr = true },
        .inherit => .{ .inherit_bit_khr = true },
    };
}

fn appendAlpha(values: []swapchain.CompositeAlpha, index: *usize, value: swapchain.CompositeAlpha) void {
    values[index.*] = value;
    index.* += 1;
}

fn intToOpaque(comptime T: type, value: isize) T {
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, @bitCast(value)));
}
