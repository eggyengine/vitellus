//! helper functions for creating a vulkan surface based on the `candler` library.

const std = @import("std");
const candler = @import("candler");
const vk = @import("vulkan");


pub const default_instance_extensions: []const [*:0]const u8 = &.{
    vk.extensions.khr_surface.name.ptr,
    vk.extensions.khr_android_surface.name.ptr,
    vk.extensions.khr_wayland_surface.name.ptr,
    vk.extensions.khr_win_32_surface.name.ptr,
    vk.extensions.khr_xlib_surface.name.ptr,
    vk.extensions.khr_xcb_surface.name.ptr,
    vk.extensions.mvk_ios_surface.name.ptr,
    vk.extensions.mvk_macos_surface.name.ptr,
    vk.extensions.ohos_surface.name.ptr,
    vk.extensions.ext_headless_surface.name.ptr,
};

pub fn createSurface(
    instance: vk.InstanceProxy,
    window: candler.WindowHandle,
    display: candler.DisplayHandle,
) !vk.SurfaceKHR {
    const raw_display = display.asRaw();
    const window_tag = @tagName(window.asRaw());
    const display_tag = @tagName(raw_display);
    std.log.debug("creating vulkan window surface: window={s} display={s}", .{ window_tag, display_tag });

    return switch (window.asRaw()) {
        .ui_kit => |ui_kit| createIosSurface(instance, ui_kit, raw_display),
        .app_kit => |app_kit| createMacOsSurface(instance, app_kit, raw_display),
        .orbital => unsupportedSurface("orbital"),
        .ohos_ndk => |ohos| createOhosSurface(instance, ohos, raw_display),
        .xlib => |xlib| createXlibSurface(instance, xlib, raw_display),
        .xcb => |xcb| createXcbSurface(instance, xcb, raw_display),
        .wayland => |wayland| createWaylandSurface(instance, wayland, raw_display),
        .drm => unsupportedSurface("drm"),
        .gbm => unsupportedSurface("gbm"),
        .win32 => |win32| createWin32Surface(instance, win32, raw_display),
        .win_rt => unsupportedSurface("win_rt"),
        .wasm_bindgen_canvas => unsupportedSurface("wasm_bindgen_canvas"),
        .wasm_bindgen_offscreen_canvas => unsupportedSurface("wasm_bindgen_offscreen_canvas"),
        .android_ndk => |android| createAndroidSurface(instance, android, raw_display),
        .haiku => unsupportedSurface("haiku"),
    };
}

pub fn createHeadlessSurface(instance: vk.InstanceProxy) !vk.SurfaceKHR {
    std.log.debug("creating vulkan headless surface", .{});
    if (instance.wrapper.dispatch.vkCreateHeadlessSurfaceEXT == null) {
        std.log.debug("vkCreateHeadlessSurfaceEXT is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.HeadlessSurfaceCreateInfoEXT{};
    return instance.createHeadlessSurfaceEXT(&create_info, null);
}

fn createAndroidSurface(
    instance: vk.InstanceProxy,
    window: candler.AndroidNdkWindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    switch (display) {
        .android => {},
        else => return displayMismatch("android_ndk", display),
    }

    std.log.debug("creating Android Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateAndroidSurfaceKHR == null) {
        std.log.debug("vkCreateAndroidSurfaceKHR is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.AndroidSurfaceCreateInfoKHR{
        .window = @ptrCast(@alignCast(window.a_native_window)),
    };
    return instance.createAndroidSurfaceKHR(&create_info, null);
}

fn createIosSurface(
    instance: vk.InstanceProxy,
    window: candler.UiKitWindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    switch (display) {
        .ui_kit => {},
        else => return displayMismatch("ui_kit", display),
    }

    std.log.debug("creating iOS Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateIOSSurfaceMVK == null) {
        std.log.debug("vkCreateIosSurfaceMVK is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.IOSSurfaceCreateInfoMVK{
        .p_view = window.ui_view,
    };
    return instance.createIosSurfaceMVK(&create_info, null);
}

fn createMacOsSurface(
    instance: vk.InstanceProxy,
    window: candler.AppKitWindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    switch (display) {
        .app_kit => {},
        else => return displayMismatch("app_kit", display),
    }

    std.log.debug("creating macOS Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateMacOSSurfaceMVK == null) {
        std.log.debug("vkCreateMacOsSurfaceMVK is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.MacOSSurfaceCreateInfoMVK{
        .p_view = window.ns_view,
    };
    return instance.createMacOsSurfaceMVK(&create_info, null);
}

fn createOhosSurface(
    instance: vk.InstanceProxy,
    window: candler.OhosNdkWindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    switch (display) {
        .ohos => {},
        else => return displayMismatch("ohos_ndk", display),
    }

    std.log.debug("creating OHOS Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateSurfaceOHOS == null) {
        std.log.debug("vkCreateSurfaceOHOS is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.SurfaceCreateInfoOHOS{
        .window = @ptrCast(@alignCast(window.native_window)),
    };
    return instance.createSurfaceOHOS(&create_info, null);
}

fn createWaylandSurface(
    instance: vk.InstanceProxy,
    window: candler.WaylandWindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    const wayland_display = switch (display) {
        .wayland => |wl| wl,
        else => return displayMismatch("wayland", display),
    };
    std.log.debug("creating Wayland Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateWaylandSurfaceKHR == null) {
        std.log.debug("vkCreateWaylandSurfaceKHR is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.WaylandSurfaceCreateInfoKHR{
        .display = @ptrCast(@alignCast(wayland_display.display)),
        .surface = @ptrCast(@alignCast(window.surface)),
    };
    return instance.createWaylandSurfaceKHR(&create_info, null);
}

fn createWin32Surface(
    instance: vk.InstanceProxy,
    window: candler.Win32WindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    switch (display) {
        .windows => {},
        else => return displayMismatch("win32", display),
    }

    const hinstance = window.hinstance orelse {
        std.log.debug("win32 vulkan surface missing hinstance", .{});
        return error.DisplayHandleMismatch;
    };
    std.log.debug("creating Win32 Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateWin32SurfaceKHR == null) {
        std.log.debug("vkCreateWin32SurfaceKHR is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.Win32SurfaceCreateInfoKHR{
        .hinstance = intToPtr(vk.HINSTANCE, hinstance),
        .hwnd = intToPtr(vk.HWND, window.hwnd),
    };
    return instance.createWin32SurfaceKHR(&create_info, null);
}

fn createXlibSurface(
    instance: vk.InstanceProxy,
    window: candler.XlibWindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    const xlib_display = switch (display) {
        .xlib => |xlib| xlib,
        else => return displayMismatch("xlib", display),
    };
    const dpy = xlib_display.display orelse {
        std.log.debug("xlib vulkan surface missing display pointer", .{});
        return error.DisplayHandleMismatch;
    };
    std.log.debug("creating Xlib Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateXlibSurfaceKHR == null) {
        std.log.debug("vkCreateXlibSurfaceKHR is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.XlibSurfaceCreateInfoKHR{
        .dpy = @ptrCast(@alignCast(dpy)),
        .window = @intCast(window.window),
    };
    return instance.createXlibSurfaceKHR(&create_info, null);
}

fn createXcbSurface(
    instance: vk.InstanceProxy,
    window: candler.XcbWindowHandle,
    display: candler.RawDisplayHandle,
) !vk.SurfaceKHR {
    const xcb_display = switch (display) {
        .xcb => |xcb| xcb,
        else => return displayMismatch("xcb", display),
    };
    const connection = xcb_display.connection orelse {
        std.log.debug("xcb vulkan surface missing connection", .{});
        return error.DisplayHandleMismatch;
    };
    std.log.debug("creating XCB Vulkan surface", .{});
    if (instance.wrapper.dispatch.vkCreateXcbSurfaceKHR == null) {
        std.log.debug("vkCreateXcbSurfaceKHR is unavailable", .{});
        return error.MissingVulkanSurfaceExtension;
    }
    const create_info = vk.XcbSurfaceCreateInfoKHR{
        .connection = @ptrCast(@alignCast(connection)),
        .window = @intCast(window.window),
    };
    return instance.createXcbSurfaceKHR(&create_info, null);
}

fn intToPtr(comptime Ptr: type, value: isize) Ptr {
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn unsupportedSurface(comptime window_tag: []const u8) error{UnsupportedSurface} {
    std.log.debug("unsupported vulkan surface window handle: {s}", .{window_tag});
    return error.UnsupportedSurface;
}

fn displayMismatch(comptime window_tag: []const u8, display: candler.RawDisplayHandle) error{DisplayHandleMismatch} {
    std.log.debug("vulkan surface display mismatch: window={s} display={s}", .{
        window_tag,
        @tagName(display),
    });
    return error.DisplayHandleMismatch;
}
