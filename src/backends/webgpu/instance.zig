//! The WebGPU instance.

const std = @import("std");
const c = @import("webgpu_c");
const settings = @import("../../interface/settings.zig");
const instance_if = @import("../../interface/instance.zig");
const adapter_if = @import("../../interface/adapter.zig");
const log = @import("utils.zig").log;
const forever = @import("utils.zig").forever;
const slice = @import("utils.zig").slice;
const zeroInit = @import("utils.zig").zeroInit;
const waitFuture = @import("utils.zig").waitFuture;
const WgpuAdapter = @import("adapter.zig").WgpuAdapter;

pub const WgpuInstance = struct {
    handle: c.WGPUInstance,

    const vtable: instance_if.Instance.VTable = .{
        .deinitFn = deinit,
        .createAdapterFn = createAdapter,
    };

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuInstance = @ptrCast(@alignCast(ptr));
        c.wgpuInstanceRelease(self.handle);
        allocator.destroy(self);
    }

    fn createAdapter(ptr: *anyopaque, allocator: std.mem.Allocator, desc: adapter_if.AdapterDescriptor) anyerror!adapter_if.Adapter {
        _ = desc;
        const self: *WgpuInstance = @ptrCast(@alignCast(ptr));
        const Result = struct {
            adapter: c.WGPUAdapter = null,
            fn done(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.WGPUStringView, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const result: *@This() = @ptrCast(@alignCast(user));
                if (status == c.WGPURequestAdapterStatus_Success) {
                    result.adapter = adapter;
                } else log.err("no WebGPU adapter: {s}", .{slice(message)});
            }
        };
        var result: Result = .{};
        const options = zeroInit(c.WGPURequestAdapterOptions, .{ .powerPreference = c.WGPUPowerPreference_HighPerformance });
        const future = c.wgpuInstanceRequestAdapter(self.handle, &options, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_WaitAnyOnly,
            .callback = Result.done,
            .userdata1 = &result,
            .userdata2 = null,
        });
        _ = try waitFuture(self.handle, future, forever);
        const handle = result.adapter orelse return error.NoAdapter;
        errdefer c.wgpuAdapterRelease(handle);
        const adapter = try allocator.create(WgpuAdapter);
        adapter.* = .{ .instance = self.handle, .handle = handle };
        return .{ .ptr = adapter, .vtable = &WgpuAdapter.vtable, .allocator = allocator };
    }
};

pub fn createInstance(allocator: std.mem.Allocator, config: settings.VitellusConfig) anyerror!instance_if.Instance {
    _ = config;
    const features = [_]c.WGPUInstanceFeatureName{c.WGPUInstanceFeatureName_TimedWaitAny};
    const desc = zeroInit(c.WGPUInstanceDescriptor, .{ .requiredFeatureCount = features.len, .requiredFeatures = &features });
    const handle = c.wgpuCreateInstance(&desc) orelse return error.WebGpuUnavailable;
    const self = try allocator.create(WgpuInstance);
    self.* = .{ .handle = handle };
    return .{ .ptr = self, .vtable = &WgpuInstance.vtable, .allocator = allocator };
}
