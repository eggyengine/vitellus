const std = @import("std");
const options = @import("shader_options");
const settings = @import("settings.zig");
const Backend = settings.Backend;
const VitellusConfig = settings.VitellusConfig;
const Adapter = @import("adapter.zig").Adapter;
const AdapterDescriptor = @import("adapter.zig").AdapterDescriptor;

pub const Instance = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,
    config: VitellusConfig = undefined,
    selected_backend: Backend = undefined,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        createAdapterFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, desc: AdapterDescriptor) anyerror!Adapter,
        enumerateAdaptersFn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Adapter = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: VitellusConfig) !Instance {
        var last_error: anyerror = error.NoSupportedBackend;
        var buffer: [settings.platform_backends.len]Backend = undefined;
        for (settings.backendOrder(&buffer, config.backend, try settings.environmentBackend(allocator))) |candidate| {
            // Typed so the catch still compiles when every built-in backend is disabled.
            var instance = @as(anyerror!Instance, switch (candidate) {
                .dx12 => if (comptime options.enable_dx12)
                    @import("../backends/dx12/instance.zig").Dx12Instance.init(allocator, config)
                else
                    error.Dx12Unavailable,
                .vulkan => if (comptime options.enable_vk)
                    @import("../backends/vulkan/instance.zig").vkInstance.init(allocator, config)
                else
                    error.VulkanUnavailable,
                .metal => error.MetalNotImplemented,
                .webgpu => if (comptime options.enable_webgpu)
                    @import("../backends/webgpu.zig").createInstance(allocator, config)
                else
                    error.WebGpuUnavailable,
            }) catch |err| {
                last_error = err;
                continue;
            };
            instance.config = config;
            instance.selected_backend = candidate;
            return instance;
        }
        return last_error;
    }

    pub fn deinit(self: Instance) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }

    pub fn createAdapter(self: Instance, desc: AdapterDescriptor) !Adapter {
        return self.vtable.createAdapterFn(self.ptr, self.allocator, desc);
    }

    /// Enumerates every adapter exposed by this instance's selected backend.
    ///
    /// The caller owns the returned slice and every adapter in it. Destroy
    /// dependent objects first, call `deinit` on each adapter, then free the
    /// slice with the instance allocator before deinitialising the instance.
    pub fn enumerateAdapters(self: Instance) ![]Adapter {
        const enumerateFn = self.vtable.enumerateAdaptersFn orelse
            return error.EnumerationUnsupported;
        const adapters = try enumerateFn(self.ptr, self.allocator);
        for (adapters) |*adapter| {
            adapter.validation = self.config.validation;
        }
        return adapters;
    }

    pub fn backend(self: Instance) Backend {
        return self.selected_backend;
    }
};

test "DX12 instance owns a factory" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const instance = try Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try instance.createAdapter(.{});
    adapter.deinit();
}

test "DX12 instance enumerates selectable adapters" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const instance = try Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();

    const adapters = try instance.enumerateAdapters();
    defer {
        for (adapters) |adapter| adapter.deinit();
        std.testing.allocator.free(adapters);
    }

    try std.testing.expect(adapters.len > 0);
    try std.testing.expectEqual(settings.ValidationLevel.none, adapters[0].validation);
}

test "an empty backend set selects nothing" {
    try std.testing.expectError(error.NoSupportedBackend, Instance.init(std.testing.allocator, .{ .backend = .{}, .validation = .none }));
}
