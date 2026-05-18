//! helper functions for creating a vulkan surface based on the `candler` library.

const std = @import("std");
const candler = @import("candler");
const vk = @import("vulkan");

const logz = @import("logz");

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
    logz.info().fmt("msg", "creating vulkan window surface: window={s} display={s}", .{ window_tag, display_tag }).log();

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
    logz.info().fmt("msg", "creating vulkan headless surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateHeadlessSurfaceEXT == null) {
        logz.info().fmt("msg", "vkCreateHeadlessSurfaceEXT is unavailable", .{}).log();
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

    logz.info().fmt("msg", "creating Android Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateAndroidSurfaceKHR == null) {
        logz.info().fmt("msg", "vkCreateAndroidSurfaceKHR is unavailable", .{}).log();
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

    logz.info().fmt("msg", "creating iOS Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateIOSSurfaceMVK == null) {
        logz.info().fmt("msg", "vkCreateIosSurfaceMVK is unavailable", .{}).log();
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

    logz.info().fmt("msg", "creating macOS Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateMacOSSurfaceMVK == null) {
        logz.info().fmt("msg", "vkCreateMacOsSurfaceMVK is unavailable", .{}).log();
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

    logz.info().fmt("msg", "creating OHOS Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateSurfaceOHOS == null) {
        logz.info().fmt("msg", "vkCreateSurfaceOHOS is unavailable", .{}).log();
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
    logz.info().fmt("msg", "creating Wayland Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateWaylandSurfaceKHR == null) {
        logz.info().fmt("msg", "vkCreateWaylandSurfaceKHR is unavailable", .{}).log();
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
        logz.info().fmt("msg", "win32 vulkan surface missing hinstance", .{}).log();
        return error.DisplayHandleMismatch;
    };
    logz.info().fmt("msg", "creating Win32 Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateWin32SurfaceKHR == null) {
        logz.info().fmt("msg", "vkCreateWin32SurfaceKHR is unavailable", .{}).log();
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
        logz.info().fmt("msg", "xlib vulkan surface missing display pointer", .{}).log();
        return error.DisplayHandleMismatch;
    };
    logz.info().fmt("msg", "creating Xlib Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateXlibSurfaceKHR == null) {
        logz.info().fmt("msg", "vkCreateXlibSurfaceKHR is unavailable", .{}).log();
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
        logz.info().fmt("msg", "xcb vulkan surface missing connection", .{}).log();
        return error.DisplayHandleMismatch;
    };
    logz.info().fmt("msg", "creating XCB Vulkan surface", .{}).log();
    if (instance.wrapper.dispatch.vkCreateXcbSurfaceKHR == null) {
        logz.info().fmt("msg", "vkCreateXcbSurfaceKHR is unavailable", .{}).log();
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
    logz.info().fmt("msg", "unsupported vulkan surface window handle: {s}", .{window_tag}).log();
    return error.UnsupportedSurface;
}

fn displayMismatch(comptime window_tag: []const u8, display: candler.RawDisplayHandle) error{DisplayHandleMismatch} {
    logz.info().fmt("msg", "vulkan surface display mismatch: window={s} display={s}", .{
        window_tag,
        @tagName(display),
    }).log();
    return error.DisplayHandleMismatch;
}
