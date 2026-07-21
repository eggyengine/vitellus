const std = @import("std");
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
        enumerateAdaptersFn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!Adapters = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: VitellusConfig) !Instance {
        var last_error: ?anyerror = null;

        for (config.custom_backends) |factory| {
            var instance = factory.createInstanceFn(allocator, config) catch |err| {
                last_error = err;
                continue;
            };
            instance.config = config;
            instance.selected_backend = factory.backend();
            return instance;
        }

        const order = settings.backendFallbackOrder(config.backend);
        for (order.slice()) |candidate| {
            var instance = switch (candidate) {
                .dx12 => @import("../backends/dx12/instance.zig").Dx12Instance.init(allocator, config),
                .vulkan => @import("../backends/vulkan/instance.zig").vkInstance.init(allocator, config),
                .metal => error.MetalNotImplemented,
                .custom => unreachable, // custom backends never enter the built-in fallback order
            } catch |err| {
                last_error = err;
                continue;
            };
            instance.config = config;
            instance.selected_backend = candidate;
            return instance;
        }

        if (last_error) |err| return err;
        return error.NoSupportedBackend;
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
    pub fn enumerateAdapters(self: Instance) !Adapters {
        const enumerateFn = self.vtable.enumerateAdaptersFn orelse
            return error.EnumerationUnsupported;
        const adapters = try enumerateFn(self.ptr, self.allocator);
        for (adapters.inner) |*adapter| {
            adapter.validation = self.config.validation;
        }
        return adapters;
    }

    pub fn backend(self: Instance) Backend {
        return self.selected_backend;
    }
};

/// Storage for an array of adapters
pub const Adapters = struct {
    inner: []Adapter,
    alloc: std.mem.Allocator,

    /// Releases every enumerated adapter and the backing slice.
    pub fn deinit(self: @This()) void {
        for (self.inner) |adapter| adapter.deinit();
        self.alloc.free(self.inner);
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
    defer adapters.deinit();

    try std.testing.expect(adapters.inner.len > 0);
    try std.testing.expectEqual(settings.ValidationLevel.none, adapters.inner[0].validation);
}

test "custom backends are selected before built-in backends" {
    const Mock = struct {
        var live_instances: usize = 0;

        const vtable: Instance.VTable = .{
            .deinitFn = deinitImpl,
            .createAdapterFn = createAdapterImpl,
        };

        fn createInstance(allocator: std.mem.Allocator, config: settings.VitellusConfig) anyerror!Instance {
            _ = config;
            const self = try allocator.create(@This());
            live_instances += 1;
            return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
        }

        fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            live_instances -= 1;
            allocator.destroy(self);
        }

        fn createAdapterImpl(_: *anyopaque, _: std.mem.Allocator, _: AdapterDescriptor) anyerror!Adapter {
            return error.NotNeededForTest;
        }
    };

    const factory = settings.BackendFactory{
        .name = "mock",
        .createInstanceFn = Mock.createInstance,
    };
    try std.testing.expect(factory.backend().eql(.{ .custom = "mock" }));

    const instance = try Instance.init(std.testing.allocator, .{
        .backend = .{}, // no built-in backends
        .custom_backends = &.{factory},
        .validation = .extended,
    });
    try std.testing.expectEqual(@as(usize, 1), Mock.live_instances);
    try std.testing.expectEqual(settings.ValidationLevel.extended, instance.config.validation);
    try std.testing.expect(instance.backend().eql(.{ .custom = "mock" }));
    instance.deinit();
    try std.testing.expectEqual(@as(usize, 0), Mock.live_instances);
}

test "failing custom backends fall through to the built-in order" {
    const Failing = struct {
        fn createInstance(_: std.mem.Allocator, _: settings.VitellusConfig) anyerror!Instance {
            return error.MockBackendUnavailable;
        }
    };

    const result = Instance.init(std.testing.allocator, .{
        .backend = .{}, // no built-in backends to fall back to
        .custom_backends = &.{.{ .name = "failing", .createInstanceFn = Failing.createInstance }},
        .validation = .none,
    });
    try std.testing.expectError(error.MockBackendUnavailable, result);
}
