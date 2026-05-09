pub const sdl = @import("sdl3");
const candler = @import("candler");

pub const Sdl3Window = struct {
    window: sdl.video.Window,
    metal_view: ?sdl.metal.View = null,

    pub fn init(window: sdl.video.Window) Sdl3Window {
        return .{ .window = window };
    }

    pub fn initWithMetalView(window: sdl.video.Window, metal_view: sdl.metal.View) Sdl3Window {
        return .{
            .window = window,
            .metal_view = metal_view,
        };
    }

    pub fn windowHandle(self: *const Sdl3Window) candler.HandleError!candler.WindowHandle {
        const props = self.properties() catch return error.Unavailable;

        if (props.android_window) |window| {
            if (window.value) |ptr| {
                return borrowedWindowHandle(candler.AndroidNdkWindowHandle.new(ptr).intoRaw());
            }
        }

        if (props.ui_kit_window != null) {
            if (self.metal_view) |view| {
                return borrowedWindowHandle(candler.UiKitWindowHandle.new(view.value).intoRaw());
            }
        }

        if (props.cocoa_window != null) {
            if (self.metal_view) |view| {
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
                return borrowedWindowHandle(handle.intoRaw());
            }
        }

        if (props.wayland_surface) |surface| {
            if (surface.value) |ptr| {
                return borrowedWindowHandle(candler.WaylandWindowHandle.new(ptr).intoRaw());
            }
        }

        if (props.x11_window) |window| {
            if (window > 0) {
                return borrowedWindowHandle(candler.XlibWindowHandle.new(@as(c_ulong, @intCast(window))).intoRaw());
            }
        }

        return error.NotSupported;
    }

    pub fn displayHandle(self: *const Sdl3Window) candler.HandleError!candler.DisplayHandle {
        const props = self.properties() catch return error.Unavailable;

        if (props.android_window != null or props.android_surface != null) {
            return borrowedDisplayHandle(candler.AndroidDisplayHandle.new().intoRaw());
        }

        if (props.ui_kit_window != null) {
            return borrowedDisplayHandle(candler.UiKitDisplayHandle.new().intoRaw());
        }

        if (props.cocoa_window != null) {
            return borrowedDisplayHandle(candler.AppKitDisplayHandle.new().intoRaw());
        }

        if (props.win32_hwnd != null or props.win32_hdc != null or props.win32_instance != null) {
            return borrowedDisplayHandle(candler.WindowsDisplayHandle.new().intoRaw());
        }

        if (props.wayland_display) |display| {
            if (display.value) |ptr| {
                return borrowedDisplayHandle(candler.WaylandDisplayHandle.new(ptr).intoRaw());
            }
        }

        if (props.x11_display) |display| {
            const screen = if (props.x11_screen) |screen| @as(c_int, @intCast(screen)) else 0;
            return borrowedDisplayHandle(candler.XlibDisplayHandle.new(display.value, screen).intoRaw());
        }

        if (props.kmsdrm_gbm_device) |device| {
            if (device.value) |ptr| {
                return borrowedDisplayHandle(candler.GbmDisplayHandle.new(ptr).intoRaw());
            }
        }

        if (props.kmsdrm_drm_fd) |fd| {
            return borrowedDisplayHandle(candler.DrmDisplayHandle.new(@as(i32, @intCast(fd))).intoRaw());
        }

        if (props.emscripten_canvas_id != null) {
            return borrowedDisplayHandle(candler.WasmBindgenDisplay.new().intoRaw());
        }

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
