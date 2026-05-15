const std = @import("std");
const candler = @import("candler");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const adapter_backend = @import("adapter.zig");
const surface_backend = @import("surface.zig");

const allocator = std.heap.page_allocator;
const log = std.log.scoped(.vitellus_noop);

pub const NoopInstance = struct {
    pub const vtable = hal.Instance.VTable{
        .destroy = destroy,
        .enumerateAdapters = enumerateAdapters,
        .requestAdapter = requestAdapter,
        .createSurface = createSurface,
    };

    pub fn init(descriptor: gpu.Instance.Descriptor) !hal.Instance {
        const instance = try allocator.create(NoopInstance);
        instance.* = .{};
        _ = descriptor;
        return .{
            .ptr = instance,
            .vtable = &vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopInstance = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop instance", .{});
        allocator.destroy(typed);
    }

    fn enumerateAdapters(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror![]const hal.Adapter {
        _ = ptr;
        _ = options;
        log.debug("enumerating noop adapters", .{});
        const adapters = try allocator.alloc(hal.Adapter, 1);
        adapters[0] = try adapter_backend.NoopAdapter.init();
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
        _ = ptr;
        _ = options;
        log.debug("returning noop adapter", .{});
        return adapter_backend.NoopAdapter.init();
    }

    fn createSurface(
        ptr: *anyopaque,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!hal.Surface {
        _ = ptr;
        log.debug("creating noop surface: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return surface_backend.NoopSurface.init();
    }
};
