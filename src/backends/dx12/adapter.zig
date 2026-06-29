const std = @import("std");
const Adapter = @import("../../interface/adapter.zig").Adapter;
const AdapterInfo = @import("../../interface/adapter.zig").AdapterInfo;
const Vendor = @import("../../interface/adapter.zig").Vendor;
const Device = @import("../../interface/device.zig").Device;
const DeviceDescriptor = @import("../../interface/device.zig").DeviceDescriptor;
const Swapchain = @import("../../interface/swapchain.zig").Swapchain;
const SwapchainDescriptor = @import("../../interface/swapchain.zig").SwapchainDescriptor;
const VitellusConfig = @import("../../interface/settings.zig").VitellusConfig;
const Dx12Device = @import("device.zig").Dx12Device;
const Dx12Swapchain = @import("swapchain.zig").Dx12Swapchain;
const debug = @import("debug.zig");

const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

const log = std.log.scoped(.dx12_adapter);

pub const Dx12Adapter = struct {
    debug_ctrl: debug.Dx12DebugController = .{},
    factory: ComPtr(dx.IDXGIFactory4) = .{},
    adapter: ComPtr(dx.IDXGIAdapter1) = .{},

    const vtable: Adapter.VTable = .{
        .deinitFn = deinitImpl,
        .infoFn = infoImpl,
        .createDeviceFn = createDeviceImpl,
        .createSwapchainFn = createSwapchainImpl,
    };

    pub fn init(allocator: std.mem.Allocator, config: VitellusConfig) !Adapter {
        const self = try allocator.create(Dx12Adapter);
        self.* = .{};

        var hr: c_long = 0;
        errdefer {
            self.adapter.deinit();
            self.factory.deinit();
            self.debug_ctrl.deinit();
            allocator.destroy(self);
        }

        // create debug layer
        switch (config.validation) {
            .core, .extended, .gpu_based => {
                self.debug_ctrl = debug.Dx12DebugController.init();
            },
            .none => {},
        }

        // create factory
        var raw_factory: ?*anyopaque = null;
        hr = dx.CreateDXGIFactory1(&dx.IID_IDXGIFactory4, &raw_factory);
        if (hr < 0) {
            log.err("initialisation of IDXGIFactory4 failed? {}", .{hr});
            return error.HrFailed;
        }
        if (raw_factory) |raw| {
            const p: *dx.IDXGIFactory4 = @ptrCast(@alignCast(raw));
            self.factory = .attach(p);
        }
        log.debug("IDXGIFactory4 successfully initialised", .{});

        // adapter init
        log.debug("selecting DX12 hardware adapter", .{});
        self.adapter = getHardwareAdapter(self.factory.get()) catch |err| fallback: {
            log.warn("hardware adapter unavailable ({}); falling back to WARP", .{err});
            break :fallback try getWarpAdapter(self.factory.get());
        };

        return Adapter{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    /// Returns hardware adapters, or WARP if no compatible hardware adapter exists.
    pub fn enumerate(allocator: std.mem.Allocator) ![]Adapter {
        log.debug("enumerating DX12 adapters", .{});

        var factory = try createFactory();
        defer factory.deinit();

        const adapter_count = try countHardwareAdapters(factory.get());
        log.debug("found {} compatible DX12 hardware adapter(s)", .{adapter_count});
        if (adapter_count == 0) {
            log.warn("no compatible DX12 hardware adapters found; enumerating WARP fallback", .{});
            return enumerateWarpFallback(allocator, factory);
        }

        const adapters = try allocator.alloc(Adapter, adapter_count);
        errdefer allocator.free(adapters);

        var initialized: usize = 0;
        errdefer {
            for (adapters[0..initialized]) |adapter| {
                adapter.deinit();
            }
        }

        var adapter_index: dx.UINT = 0;
        while (true) : (adapter_index += 1) {
            var adapter: ComPtr(dx.IDXGIAdapter1) = .{};
            const enum_hr = factory.unwrap().lpVtbl.*.EnumAdapters1.?(factory.get(), adapter_index, @ptrCast(adapter.put()));
            if (enum_hr == dx.DXGI_ERROR_NOT_FOUND) break;
            try checkHr(enum_hr);

            const supported = isHardwareAdapterSupported(adapter.unwrap()) catch |err| {
                adapter.deinit();
                return err;
            };
            if (!supported) {
                log.debug("skipping DX12 adapter {}: software or D3D12 unsupported", .{adapter_index});
                adapter.deinit();
                continue;
            }
            if (initialized == adapters.len) {
                log.warn("DX12 adapter enumeration found more compatible adapters than counted", .{});
                adapter.deinit();
                continue;
            }

            const self = allocator.create(Dx12Adapter) catch |err| {
                adapter.deinit();
                return err;
            };
            self.* = .{
                .factory = factory.clone(),
                .adapter = adapter,
            };

            adapters[initialized] = Adapter{ .ptr = self, .vtable = &vtable, .allocator = allocator };
            log.debug("added DX12 hardware adapter {} to enumeration result", .{adapter_index});
            initialized += 1;
        }

        if (initialized != adapters.len) {
            log.err("DX12 adapter enumeration count mismatch: expected {}, initialized {}", .{ adapters.len, initialized });
            return error.HrFailed;
        }
        return adapters;
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Adapter = @ptrCast(@alignCast(ptr));

        self.adapter.deinit();
        self.factory.deinit();
        self.debug_ctrl.deinit();

        allocator.destroy(self);
    }

    fn infoImpl(ptr: *anyopaque) AdapterInfo {
        const self: *Dx12Adapter = @ptrCast(@alignCast(ptr));
        var info: AdapterInfo = .{};

        const adapter = self.adapter.get() orelse {
            log.warn("DX12 adapter info requested before adapter initialisation", .{});
            return info;
        };
        var desc: dx.DXGI_ADAPTER_DESC1 = .{};
        checkHr(adapter.lpVtbl.*.GetDesc1.?(adapter, &desc)) catch |err| {
            log.warn("failed to query DX12 adapter description: {}", .{err});
            return info;
        };

        info.dedicated_vram = desc.DedicatedVideoMemory;
        info.vendor = vendorFromId(desc.VendorId);
        info.kind = if ((desc.Flags & dx.DXGI_ADAPTER_FLAG_SOFTWARE) != 0)
            .software
        else if (desc.DedicatedVideoMemory > 0)
            .discrete
        else
            .integrated;

        for (desc.Description) |wc| {
            if (wc == 0 or info.name_len == info.name.len) break;
            info.name[info.name_len] = if (wc < 0x80) @intCast(wc) else '?';
            info.name_len += 1;
        }

        return info;
    }

    fn createDeviceImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: DeviceDescriptor) anyerror!Device {
        return Dx12Device.init(ptr, allocator, desc);
    }

    fn createSwapchainImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: SwapchainDescriptor) anyerror!Swapchain {
        return Dx12Swapchain.init(ptr, allocator, desc);
    }
};

fn createFactory() !ComPtr(dx.IDXGIFactory4) {
    log.debug("creating IDXGIFactory4", .{});

    var raw_factory: ?*anyopaque = null;
    try checkHr(dx.CreateDXGIFactory1(&dx.IID_IDXGIFactory4, &raw_factory));

    if (raw_factory) |raw| {
        const factory: *dx.IDXGIFactory4 = @ptrCast(@alignCast(raw));
        log.debug("IDXGIFactory4 created", .{});
        return .attach(factory);
    }

    log.err("CreateDXGIFactory1 succeeded but returned null IDXGIFactory4", .{});
    return error.HrFailed;
}

fn countHardwareAdapters(factory: ?*dx.IDXGIFactory4) !usize {
    const f = factory orelse return error.HrFailed;

    log.debug("counting compatible DX12 hardware adapters", .{});

    var count: usize = 0;
    var adapter_index: dx.UINT = 0;
    while (true) : (adapter_index += 1) {
        var adapter: ComPtr(dx.IDXGIAdapter1) = .{};
        const enum_hr = f.lpVtbl.*.EnumAdapters1.?(f, adapter_index, @ptrCast(adapter.put()));
        if (enum_hr == dx.DXGI_ERROR_NOT_FOUND) break;
        try checkHr(enum_hr);

        const supported = isHardwareAdapterSupported(adapter.unwrap()) catch |err| {
            adapter.deinit();
            return err;
        };
        adapter.deinit();

        if (supported) {
            log.debug("DX12 adapter {} is hardware and D3D12-capable", .{adapter_index});
            count += 1;
        } else {
            log.debug("DX12 adapter {} is not a compatible hardware adapter", .{adapter_index});
        }
    }

    return count;
}

fn enumerateWarpFallback(allocator: std.mem.Allocator, factory: ComPtr(dx.IDXGIFactory4)) ![]Adapter {
    log.debug("creating WARP adapter enumeration result", .{});

    const adapters = try allocator.alloc(Adapter, 1);
    errdefer allocator.free(adapters);

    var warp_adapter = try getWarpAdapter(factory.get());
    errdefer warp_adapter.deinit();

    if (!isAdapterD3D12Supported(warp_adapter.unwrap())) {
        log.err("WARP adapter does not support requested D3D12 feature level", .{});
        return error.HrFailed;
    }

    const self = try allocator.create(Dx12Adapter);
    self.* = .{
        .factory = factory.clone(),
        .adapter = warp_adapter,
    };

    adapters[0] = Adapter{ .ptr = self, .vtable = &Dx12Adapter.vtable, .allocator = allocator };
    log.debug("added WARP adapter to enumeration result", .{});
    return adapters;
}

fn getHardwareAdapter(factory: ?*dx.IDXGIFactory4) !ComPtr(dx.IDXGIAdapter1) {
    const f = factory orelse return error.HrFailed;

    var adapter_index: dx.UINT = 0;
    while (true) : (adapter_index += 1) {
        var adapter: ComPtr(dx.IDXGIAdapter1) = .{};
        const enum_hr = f.lpVtbl.*.EnumAdapters1.?(f, adapter_index, @ptrCast(adapter.put()));
        if (enum_hr == dx.DXGI_ERROR_NOT_FOUND) break;
        try checkHr(enum_hr);

        const supported = isHardwareAdapterSupported(adapter.unwrap()) catch |err| {
            adapter.deinit();
            return err;
        };
        if (supported) {
            log.debug("selected DX12 hardware adapter {}", .{adapter_index});
            return adapter;
        }

        log.debug("rejected DX12 adapter {} during hardware selection", .{adapter_index});
        adapter.deinit();
    }

    return error.HrFailed;
}

fn getWarpAdapter(factory: ?*dx.IDXGIFactory4) !ComPtr(dx.IDXGIAdapter1) {
    const f = factory orelse return error.HrFailed;

    log.debug("requesting DXGI WARP adapter", .{});

    var adapter: ComPtr(dx.IDXGIAdapter1) = .{};
    try checkHr(f.lpVtbl.*.EnumWarpAdapter.?(f, &dx.IID_IDXGIAdapter1, @ptrCast(adapter.put())));
    log.debug("DXGI WARP adapter acquired", .{});
    return adapter;
}

fn isHardwareAdapterSupported(adapter: *dx.IDXGIAdapter1) !bool {
    var desc: dx.DXGI_ADAPTER_DESC1 = .{};
    try checkHr(adapter.lpVtbl.*.GetDesc1.?(adapter, &desc));

    if ((desc.Flags & dx.DXGI_ADAPTER_FLAG_SOFTWARE) != 0) return false;

    return isAdapterD3D12Supported(adapter);
}

fn isAdapterD3D12Supported(adapter: *dx.IDXGIAdapter1) bool {
    const hr = dx.D3D12CreateDevice(
        @ptrCast(adapter),
        dx.D3D_FEATURE_LEVEL_11_0,
        &dx.IID_ID3D12Device,
        null,
    );
    return hr >= 0;
}

fn vendorFromId(vendor_id: dx.UINT) Vendor {
    return switch (vendor_id) {
        0x10DE => .nvidia,
        0x1002, 0x1022 => .amd,
        0x8086 => .intel,
        0x106B => .apple,
        0x1414 => .microsoft,
        else => .unknown,
    };
}
