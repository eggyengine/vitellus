const std = @import("std");
const candler = @import("candler");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const adapter_backend = @import("adapter.zig");
const surface_backend = @import("surface.zig");
const windows = std.os.windows;
const hr = @import("utils.zig").hr;

const c = @cImport({
    @cDefine("COBJMACROS", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");

    @cInclude("windows.h");
    @cInclude("d3d12.h");
    @cInclude("dxgi.h");
});

const logz = @import("logz");

pub const DX_Instance = struct {
    allocator: std.mem.Allocator,
    adapter: adapter_backend.DX_Adapter,

    pub const vtable = hal.Instance.VTable{
        .destroy = destroy,
        .enumerateAdapters = enumerateAdapters,
        .requestAdapter = requestAdapter,
        .createSurface = createSurface,
    };

    pub fn init(descriptor: gpu.Instance.Descriptor) !hal.Instance {
        const allocator = descriptor.allocator;
        const instance = try allocator.create(DX_Instance);

        var factory: ?*c.IDXGIFactory = null;

        try hr(c.CreateDXGIFactory(
            &IID_IDXGIFactory,
            @ptrCast(&factory),
        ), @src());

        instance.* = .{
            .allocator = allocator,
            .adapter = .{ .allocator = allocator },
        };
        return .{
            .ptr = instance,
            .vtable = &vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_Instance = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "destroying DX_ instance", .{}).log();
        typed.allocator.destroy(typed);
    }

    fn enumerateAdapters(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror![]const hal.Adapter {
        const typed: *DX_Instance = @ptrCast(@alignCast(ptr));
        _ = options;
        logz.info().fmt("msg", "enumerating DX_ adapters", .{}).log();
        const adapters = try typed.allocator.alloc(hal.Adapter, 1);
        adapters[0] = .{ .ptr = &typed.adapter, .vtable = &adapter_backend.DX_Adapter.vtable };
        return adapters;
    }

    fn requestAdapter(
        ptr: *anyopaque,
        io: std.Io,
        options: gpu.Adapter.RequestOptions,
    ) std.Io.Future(anyerror!hal.Adapter) {
        return io.async(requestAdapterInternal, .{ ptr, options });
    }

    fn requestAdapterInternal(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror!hal.Adapter {
        const typed: *DX_Instance = @ptrCast(@alignCast(ptr));
        _ = options;
        logz.info().fmt("msg", "returning DX_ adapter", .{}).log();
        return .{ .ptr = &typed.adapter, .vtable = &adapter_backend.DX_Adapter.vtable };
    }

    fn createSurface(
        ptr: *anyopaque,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!hal.Surface {
        const typed: *DX_Instance = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "creating DX_ surface: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        }).log();
        return surface_backend.DX_Surface.init(typed.allocator);
    }
};
