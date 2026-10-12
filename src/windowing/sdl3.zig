pub const sdl = @import("sdl3");
const builtin = @import("builtin");
const std = @import("std");
const vitellus = @import("vitellus");
const candler = vitellus.candler;

// todo: move this to its own library or open a PR in 7Games/zig-sdl

const log = std.log.scoped(.sdl3_ext);

pub const Sdl3Window = struct {
    window: sdl.video.Window,
    metal_view: ?sdl.MetalView = null,

    pub fn init(window: sdl.video.Window) Sdl3Window {
        return .{
            .window = window,
            .metal_view = if (builtin.os.tag == .macos) sdl.MetalView.init(window) else null,
        };
    }

    pub fn deinit(self: *Sdl3Window) void {
        if (self.metal_view) |view| view.deinit();
        self.window.deinit();
    }

    pub fn initWithMetalView(window: sdl.video.Window, metal_view: sdl.MetalView) Sdl3Window {
        return .{
            .window = window,
            .metal_view = metal_view,
        };
    }

    pub fn asWindow(self: *const @This()) !vitellus.Window {
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
                return borrowedWindowHandle(candler.AppKitWindowHandle.new(view.getLayer() orelse view.value).intoRaw());
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

/// zig-sdl3's `main_callbacks`, also for Emscripten. Reference it from the root file with
/// `comptime { _ = vitellus_sdl3.main_callbacks; }` and write the same `init`, `iterate`, `event`
/// and `quit` functions. zig-sdl3's version builds a `std.Io.Threaded`, which Zig 0.16 cannot
/// compile for Emscripten, so on the web `Init.io` is `std.Io.failing` and `Init.gpa` is libc's.
pub const main_callbacks = if (builtin.os.tag == .emscripten) WebMainCallbacks else sdl.main_callbacks;

const WebMainCallbacks = struct {
    const c = sdl.c;
    const root = @import("root");
    const AppState = @typeInfo(@typeInfo(@typeInfo(@TypeOf(root.init)).@"fn".return_type.?).error_union.payload).@"struct".fields[0].type;
    const State = struct { arena: std.heap.ArenaAllocator, app: AppState };
    const gpa = std.heap.c_allocator;

    // SDL drives frames from requestAnimationFrame once `main` hands it the callbacks.
    export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
        return c.SDL_EnterAppMainCallbacks(argc, argv, appInit, appIterate, appEvent, appQuit);
    }

    fn appInit(app_state: [*c]?*anyopaque, argc: c_int, argv: [*c][*c]u8) callconv(.c) c.SDL_AppResult {
        const state = gpa.create(State) catch return c.SDL_APP_FAILURE;
        state.arena = .init(gpa);
        state.app, const result = root.init(.{
            .arena = &state.arena,
            .gpa = gpa,
            .io = std.Io.failing,
            .args = @ptrCast(argv[0..@intCast(argc)]),
        }) catch |err| {
            log.err("init: {s}", .{@errorName(err)});
            state.arena.deinit();
            gpa.destroy(state);
            return c.SDL_APP_FAILURE;
        };
        app_state.* = state;
        return @intFromEnum(result);
    }

    fn appIterate(app_state: ?*anyopaque) callconv(.c) c.SDL_AppResult {
        if (!@hasDecl(root, "iterate")) return c.SDL_APP_CONTINUE;
        const state: *State = @ptrCast(@alignCast(app_state));
        return @intFromEnum(root.iterate(&state.app) catch |err| {
            log.err("iterate: {s}", .{@errorName(err)});
            return c.SDL_APP_FAILURE;
        });
    }

    fn appEvent(app_state: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) c.SDL_AppResult {
        if (!@hasDecl(root, "event")) return c.SDL_APP_CONTINUE;
        const state: *State = @ptrCast(@alignCast(app_state));
        return @intFromEnum(root.event(&state.app, sdl.events.Event.fromSdl(event.*)) catch |err| {
            log.err("event: {s}", .{@errorName(err)});
            return c.SDL_APP_FAILURE;
        });
    }

    fn appQuit(app_state: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
        const state: ?*State = @ptrCast(@alignCast(app_state));
        if (@hasDecl(root, "quit")) root.quit(if (state) |s| &s.app else null, @enumFromInt(result));
        if (state) |s| {
            s.arena.deinit();
            gpa.destroy(s);
        }
    }
};
