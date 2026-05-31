const std = @import("std");
const candler = @import("candler");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const adapter_backend = @import("adapter.zig");
const surface_backend = @import("surface.zig");
const windows = std.os.windows;
const utils = @import("utils.zig");
const hr = utils.hr;
const ComPtr = utils.ComPtr;

const c = @cImport({
    @cDefine("COBJMACROS", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");

    @cInclude("windows.h");
    @cInclude("d3d12.h");
    @cInclude("dxgi.h");
});

pub const DX_Descriptor = struct {
    useWarpDevice: bool = true,
};

pub const DX_Instance = struct {
    allocator: std.mem.Allocator,
    adapter: ?adapter_backend.DX_Adapter = null,

    factory: ComPtr(c.IDXGIFactory),
    debug_controller: ?ComPtr(c.ID3D12Debug) = null,

    pub const vtable = hal.Instance.VTable{
        .destroy = destroy,
        .enumerateAdapters = enumerateAdapters,
        .requestAdapter = requestAdapter,
        .createSurface = createSurface,
    };

    pub fn init(descriptor: gpu.Instance.Descriptor) hal.Instance.FromPotentialBackendsError!hal.Instance {
        return initInternal(descriptor) catch error.NoBackendAvailable;
    }

    fn initInternal(descriptor: gpu.Instance.Descriptor) !hal.Instance {
        const allocator = descriptor.allocator;
        const instance = try allocator.create(DX_Instance);
        errdefer allocator.destroy(instance);

        var debug_controller: ?ComPtr(c.ID3D12Debug) = null;
        errdefer if (debug_controller) |*controller| controller.deinit();

        if (descriptor.flags.validation) {
            var controller: ComPtr(c.ID3D12Debug) = .adopt(null);
            const result = c.D3D12GetDebugInterface(&c.IID_ID3D12Debug, @ptrCast(controller.outPtr()));
            if (result == 0) {
                const debug = controller.unwrap();
                debug.lpVtbl.*.EnableDebugLayer.?(debug);
                std.log.debug("enabled validation layers for dx12", .{});
                debug_controller = controller;
            } else {
                // non-crucial error
                std.log.err("unable to enable validation: hresult={}", .{result});
            }
        }

        var factory: ComPtr(c.IDXGIFactory) = .adopt(null);

        try hr(c.CreateDXGIFactory(
            &c.IID_IDXGIFactory,
            @ptrCast(factory.outPtr()),
        ), @src());

        std.log.debug("successfully created DXGIFactory", .{});

        instance.* = .{
            .allocator = allocator,
            .adapter = null,
            .debug_controller = debug_controller,
            .factory = factory,
        };
        return .{
            .ptr = instance,
            .vtable = &vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_Instance = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 instance", .{});
        if (typed.adapter) |*adapter| adapter.deinit();
        if (typed.debug_controller) |*controller| controller.deinit();
        typed.factory.deinit();
        typed.allocator.destroy(typed);
    }

    fn enumerateAdapters(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror![]const hal.Adapter {
        const typed: *DX_Instance = @ptrCast(@alignCast(ptr));
        _ = options;
        std.log.debug("enumerating dx12 adapters", .{});
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
        std.log.debug("returning dx12 adapter", .{});
        return .{ .ptr = &typed.adapter, .vtable = &adapter_backend.DX_Adapter.vtable };
    }

    fn createSurface(
        ptr: *anyopaque,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!hal.Surface {
        const typed: *DX_Instance = @ptrCast(@alignCast(ptr));
        std.log.debug("creating dx12 surface: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return surface_backend.DX_Surface.init(typed.allocator);
    }
};
