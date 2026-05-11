pub const sdl = @import("sdl3");
const std = @import("std");
const candler = @import("candler");
const win = @import("windowing.zig");

const log = std.log.scoped(.vitellus_sdl3_windowing);

pub const Sdl3Window = struct {
    window: sdl.video.Window,
    metal_view: ?sdl.MetalView = null,

    pub fn init(window: sdl.video.Window) Sdl3Window {
        return .{ .window = window };
    }

    pub fn initWithMetalView(window: sdl.video.Window, metal_view: sdl.MetalView) Sdl3Window {
        return .{
            .window = window,
            .metal_view = metal_view,
        };
    }

    pub fn asWindow(self: *const @This()) !win.Window {
        return .{
            .display_handle = candler.HasDisplayHandle.init(self),
            .window_handle = candler.HasWindowHandle.init(self),
        };
    }

    pub fn windowHandle(self: *const Sdl3Window) candler.HandleError!candler.WindowHandle {
        const props = self.properties() catch return error.Unavailable;

        if (props.android_window) |window| {
            if (window.value) |ptr| {
                log.debug("resolved SDL3 Android window handle", .{});
                return borrowedWindowHandle(candler.AndroidNdkWindowHandle.new(ptr).intoRaw());
            }
        }

        if (props.ui_kit_window != null) {
            if (self.metal_view) |view| {
                log.debug("resolved SDL3 UIKit window handle", .{});
                return borrowedWindowHandle(candler.UiKitWindowHandle.new(view.value).intoRaw());
            }
        }

        if (props.cocoa_window != null) {
            if (self.metal_view) |view| {
                log.debug("resolved SDL3 AppKit window handle", .{});
                return borrowedWindowHandle(candler.AppKitWindowHandle.new(view.value).intoRaw());
            }
        }

        if (props.win32_hwnd) |window| {
            if (window.value) |ptr| {
                var handle = candler.Win32WindowHandle.new(@as(isize, @intCast(@intFromPtr(ptr))));
                if (props.win32_instance) |instance| {
                    if (instance.value) |instance_ptr| {
                        handle.hinstance = @as(isize, @intCast(@intFromPtr(instance_ptr)));
                    }
                }
                log.debug("resolved SDL3 Win32 window handle: hinstance={}", .{handle.hinstance != null});
                return borrowedWindowHandle(handle.intoRaw());
            }
        }

        if (props.wayland_surface) |surface| {
            if (surface.value) |ptr| {
                log.debug("resolved SDL3 Wayland window handle", .{});
                return borrowedWindowHandle(candler.WaylandWindowHandle.new(ptr).intoRaw());
            }
        }

        if (props.x11_window) |window| {
            if (window > 0) {
                log.debug("resolved SDL3 Xlib window handle", .{});
                return borrowedWindowHandle(candler.XlibWindowHandle.new(@as(c_ulong, @intCast(window))).intoRaw());
            }
        }

        log.debug("SDL3 window handle not supported by available properties", .{});
        return error.NotSupported;
    }

    pub fn displayHandle(self: *const Sdl3Window) candler.HandleError!candler.DisplayHandle {
        const props = self.properties() catch return error.Unavailable;

        if (props.android_window != null or props.android_surface != null) {
            log.debug("resolved SDL3 Android display handle", .{});
            return borrowedDisplayHandle(candler.AndroidDisplayHandle.new().intoRaw());
        }

        if (props.ui_kit_window != null) {
            log.debug("resolved SDL3 UIKit display handle", .{});
            return borrowedDisplayHandle(candler.UiKitDisplayHandle.new().intoRaw());
        }

        if (props.cocoa_window != null) {
            log.debug("resolved SDL3 AppKit display handle", .{});
            return borrowedDisplayHandle(candler.AppKitDisplayHandle.new().intoRaw());
        }

        if (props.win32_hwnd != null or props.win32_hdc != null or props.win32_instance != null) {
            log.debug("resolved SDL3 Windows display handle", .{});
            return borrowedDisplayHandle(candler.WindowsDisplayHandle.new().intoRaw());
        }

        if (props.wayland_display) |display| {
            if (display.value) |ptr| {
                log.debug("resolved SDL3 Wayland display handle", .{});
                return borrowedDisplayHandle(candler.WaylandDisplayHandle.new(ptr).intoRaw());
            }
        }

        if (props.x11_display) |display| {
            const screen = if (props.x11_screen) |screen| @as(c_int, @intCast(screen)) else 0;
            log.debug("resolved SDL3 Xlib display handle: screen={}", .{screen});
            return borrowedDisplayHandle(candler.XlibDisplayHandle.new(display.value, screen).intoRaw());
        }

        if (props.kmsdrm_gbm_device) |device| {
            if (device.value) |ptr| {
                log.debug("resolved SDL3 GBM display handle", .{});
                return borrowedDisplayHandle(candler.GbmDisplayHandle.new(ptr).intoRaw());
            }
        }

        if (props.kmsdrm_drm_fd) |fd| {
            log.debug("resolved SDL3 DRM display handle", .{});
            return borrowedDisplayHandle(candler.DrmDisplayHandle.new(@as(i32, @intCast(fd))).intoRaw());
        }

        if (props.emscripten_canvas_id != null) {
            log.debug("resolved SDL3 wasm display handle", .{});
            return borrowedDisplayHandle(candler.WasmBindgenDisplay.new().intoRaw());
        }

        log.debug("SDL3 display handle not supported by available properties", .{});
        return error.NotSupported;
    }

    fn properties(self: *const Sdl3Window) !sdl.video.Window.Properties {
        return self.window.getProperties();
    }
};

fn borrowedWindowHandle(raw: candler.RawWindowHandle) candler.WindowHandle {
    return candler.WindowHandle.borrowRaw(raw);
}

fn borrowedDisplayHandle(raw: candler.RawDisplayHandle) candler.DisplayHandle {
    return candler.DisplayHandle.borrowRaw(raw);
}
