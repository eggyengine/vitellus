const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");
const Backend = settings_mod.Backend;
const BackendType = settings_mod.BackendType;
const VitellusConfig = settings_mod.VitellusConfig;
const Device = @import("device.zig").Device;
const DeviceDescriptor = @import("device.zig").DeviceDescriptor;
const Swapchain = @import("swapchain.zig").Swapchain;
const SwapchainDescriptor = @import("swapchain.zig").SwapchainDescriptor;

pub const Vendor = enum { nvidia, amd, intel, apple, microsoft, unknown };

pub const Kind = enum { discrete, integrated, software, unknown };

pub const AdapterInfo = struct {
    /// GPU name encoded as UTF-8. Use `nameSlice()` to read it.
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,
    dedicated_vram: usize = 0,
    vendor: Vendor = .unknown,
    kind: Kind = .unknown,

    pub fn nameSlice(self: *const AdapterInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    config: VitellusConfig = undefined,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        infoFn: *const fn (ptr: *anyopaque) AdapterInfo,
        createDeviceFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, desc: DeviceDescriptor) anyerror!Device,
        createSwapchainFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, desc: SwapchainDescriptor) anyerror!Swapchain,
    };

    pub fn init(allocator: std.mem.Allocator, config: VitellusConfig) !Adapter {
        const order = settings_mod.backendFallbackOrder(config.backend);
        var last_error: ?anyerror = null;

        for (order.slice()) |backend| {
            var adapter = initBackend(backend, allocator, config) catch |err| {
                last_error = err;
                continue;
            };
            adapter.config = config;
            return adapter;
        }

        if (last_error) |err| return err;
        return error.NoSupportedBackend;
    }

    pub fn enumerate(allocator: std.mem.Allocator, backend: BackendType) ![]Adapter {
        const order = settings_mod.backendFallbackOrder(backend);
        var last_error: ?anyerror = null;

        for (order.slice()) |candidate| {
            return enumerateBackend(candidate, allocator) catch |err| {
                last_error = err;
                continue;
            };
        }

        if (last_error) |err| return err;
        return error.NoSupportedBackend;
    }

    fn initBackend(backend: Backend, allocator: std.mem.Allocator, config: VitellusConfig) !Adapter {
        return switch (backend) {
            .dx12 => {
                return @import("../backends/dx12/adapter.zig").Dx12Adapter.init(allocator, config);
            },
            .vulkan => error.VulkanNotImplemented,
            .metal => error.MetalNotImplemented,
        };
    }

    fn enumerateBackend(backend: Backend, allocator: std.mem.Allocator) ![]Adapter {
        return switch (backend) {
            .dx12 => @import("../backends/dx12/adapter.zig").Dx12Adapter.enumerate(allocator),
            .vulkan => error.VulkanNotImplemented,
            .metal => error.MetalNotImplemented,
        };
    }

    pub fn pickBest(adapters: []const Adapter) ?Adapter {
        var best: ?Adapter = null;
        var best_info: ?AdapterInfo = null;

        for (adapters) |adapter| {
            const i = adapter.info();
            if (i.kind == .software) continue;

            const pick = if (best_info) |bi| blk: {
                const gains_discrete = i.kind == .discrete and bi.kind != .discrete;
                const same_kind_more_vram = i.kind == bi.kind and i.dedicated_vram > bi.dedicated_vram;
                break :blk gains_discrete or same_kind_more_vram;
            } else true;

            if (pick) {
                best = adapter;
                best_info = i;
            }
        }

        return best;
    }

    pub fn info(self: Adapter) AdapterInfo {
        return self.vtable.infoFn(self.ptr);
    }

    pub fn createDevice(self: Adapter) !Device {
        return self.vtable.createDeviceFn(self.ptr, self.allocator, .{
            .validation = self.config.validation,
        });
    }

    pub fn createSwapchain(self: Adapter, desc: SwapchainDescriptor) !Swapchain {
        return self.vtable.createSwapchainFn(self.ptr, self.allocator, desc);
    }

    pub fn deinit(self: Adapter) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};
