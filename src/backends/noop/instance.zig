const std = @import("std");
const candler = @import("candler");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const adapter_backend = @import("adapter.zig");
const surface_backend = @import("surface.zig");

const log = std.log.scoped(.vitellus_noop);

pub const NoopInstance = struct {
    allocator: std.mem.Allocator,
    adapter: adapter_backend.NoopAdapter,

    pub const vtable = hal.Instance.VTable{
        .destroy = destroy,
        .enumerateAdapters = enumerateAdapters,
        .requestAdapter = requestAdapter,
        .createSurface = createSurface,
    };

    pub fn init(descriptor: gpu.Instance.Descriptor) !hal.Instance {
        const allocator = descriptor.allocator;
        const instance = try allocator.create(NoopInstance);
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
        const typed: *NoopInstance = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop instance", .{});
        typed.allocator.destroy(typed);
    }

    fn enumerateAdapters(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror![]const hal.Adapter {
        const typed: *NoopInstance = @ptrCast(@alignCast(ptr));
        _ = options;
        log.debug("enumerating noop adapters", .{});
        const adapters = try typed.allocator.alloc(hal.Adapter, 1);
        adapters[0] = .{ .ptr = &typed.adapter, .vtable = &adapter_backend.NoopAdapter.vtable };
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
        const typed: *NoopInstance = @ptrCast(@alignCast(ptr));
        _ = options;
        log.debug("returning noop adapter", .{});
        return .{ .ptr = &typed.adapter, .vtable = &adapter_backend.NoopAdapter.vtable };
    }

    fn createSurface(
        ptr: *anyopaque,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!hal.Surface {
        const typed: *NoopInstance = @ptrCast(@alignCast(ptr));
        log.debug("creating noop surface: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return surface_backend.NoopSurface.init(typed.allocator);
    }
};
