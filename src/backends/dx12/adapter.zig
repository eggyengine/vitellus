const std = @import("std");
const Adapter = @import("../../interface/adapter.zig").Adapter;
const AdapterDescriptor = @import("../../interface/adapter.zig").AdapterDescriptor;
const AdapterInfo = @import("../../interface/adapter.zig").AdapterInfo;
const Vendor = @import("../../interface/adapter.zig").Vendor;
const Device = @import("../../interface/device.zig").Device;
const DeviceDescriptor = @import("../../interface/device.zig").DeviceDescriptor;
const Swapchain = @import("../../interface/swapchain.zig").Swapchain;
const SwapchainDescriptor = @import("../../interface/swapchain.zig").SwapchainDescriptor;
const adapter_interface = @import("../../interface/adapter.zig");
const resource = @import("../../interface/resource.zig");
const swapchain_interface = @import("../../interface/swapchain.zig");
const Window = @import("../../windowing/windowing.zig").Window;
const Dx12Instance = @import("instance.zig").Dx12Instance;
const Dx12Device = @import("device.zig").Dx12Device;
const Dx12Swapchain = @import("swapchain.zig").Dx12Swapchain;
const dx_resource = @import("resource.zig");

const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

const log = std.log.scoped(.dx12_adapter);

pub const Dx12Adapter = struct {
    instance: ?*Dx12Instance = null,
    factory: ComPtr(dx.IDXGIFactory4) = .{},
    adapter: ComPtr(dx.IDXGIAdapter1) = .{},
    /// Lazily created D3D12 device used only for capability queries.
    /// D3D12 devices are singletons per adapter, so this aliases any device
    /// later created for rendering rather than duplicating GPU state.
    query_device: ComPtr(dx.ID3D12Device) = .{},

    const vtable: Adapter.VTable = .{
        .deinitFn = deinitImpl,
        .infoFn = infoImpl,
        .createDeviceFn = createDeviceImpl,
        .createSwapchainFn = createSwapchainImpl,
        .capabilitiesFn = capabilitiesImpl,
        .formatCapabilitiesFn = formatCapabilitiesImpl,
        .surfaceCapabilitiesFn = surfaceCapabilitiesImpl,
    };

    pub fn init(instance_ptr: *anyopaque, allocator: std.mem.Allocator, desc: AdapterDescriptor) !Adapter {
        const instance: *Dx12Instance = @ptrCast(@alignCast(instance_ptr));
        const self = try allocator.create(Dx12Adapter);
        self.* = .{ .instance = instance, .factory = instance.factory.clone() };

        errdefer {
            self.adapter.deinit();
            self.factory.deinit();
            allocator.destroy(self);
        }

        log.debug("selecting DX12 hardware adapter", .{});
        self.adapter = getHardwareAdapter(self.factory.get()) catch |err| fallback: {
            log.warn("hardware adapter unavailable ({}); falling back to WARP", .{err});
            break :fallback try getWarpAdapter(self.factory.get());
        };

        utils.setDxgiName(self.adapter.unwrap(), desc.label);
        return Adapter{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn capabilitiesImpl(ptr: *anyopaque) adapter_interface.AdapterCapabilities {
        const self: *Dx12Adapter = @ptrCast(@alignCast(ptr));
        const device = self.queryDevice() catch |err| {
            log.warn("failed to create D3D12 capability query device ({}); reporting guaranteed FL 11_0 capabilities", .{err});
            return featureLevel11Capabilities();
        };

        var caps = featureLevel11Capabilities();

        var options = std.mem.zeroes(dx.D3D12_FEATURE_DATA_D3D12_OPTIONS);
        if (checkFeature(device, dx.D3D12_FEATURE_D3D12_OPTIONS, &options)) {
            // Tier 1 hardware bounds descriptors visible to a single shader
            // stage; higher tiers only bound them by descriptor heap size.
            caps.limits.max_bindings_per_group = switch (options.ResourceBindingTier) {
                dx.D3D12_RESOURCE_BINDING_TIER_1 => 64,
                dx.D3D12_RESOURCE_BINDING_TIER_2 => 256,
                else => 1024,
            };
        }

        var va = std.mem.zeroes(dx.D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT);
        if (checkFeature(device, dx.D3D12_FEATURE_GPU_VIRTUAL_ADDRESS_SUPPORT, &va) and
            va.MaxGPUVirtualAddressBitsPerResource > 0)
        {
            const bits: u6 = @intCast(@min(va.MaxGPUVirtualAddressBitsPerResource, 63));
            caps.limits.max_buffer_size = (@as(u64, 1) << bits) - 1;
            caps.limits.max_storage_buffer_binding_size = @min(
                caps.limits.max_buffer_size,
                std.math.maxInt(u32),
            );
        }

        caps.features.bc_compression = blk: {
            var support = std.mem.zeroes(dx.D3D12_FEATURE_DATA_FORMAT_SUPPORT);
            support.Format = dx.DXGI_FORMAT_BC7_UNORM;
            if (!checkFeature(device, dx.D3D12_FEATURE_FORMAT_SUPPORT, &support)) break :blk false;
            break :blk (support.Support1 & dx.D3D12_FORMAT_SUPPORT1_TEXTURE2D) != 0;
        };

        return caps;
    }

    /// Capabilities every D3D12 feature-level 11_0 device must provide. The
    /// fixed limits come from the D3D12 constants in `d3d12.h`; hardware-
    /// dependent values are refined by `capabilitiesImpl`.
    fn featureLevel11Capabilities() adapter_interface.AdapterCapabilities {
        return .{
            .features = .{
                // Guaranteed by D3D12 at feature level 11_0.
                .timestamp_query = true,
                .occlusion_query = true,
                .indirect_first_instance = true,
                .depth_clip_control = true,
                .wireframe = true,
                .anisotropic_filtering = true,
                .bc_compression = true,
            },
            .limits = .{
                .max_buffer_size = std.math.maxInt(u32),
                .max_texture_dimension_1d = dx.D3D12_REQ_TEXTURE1D_U_DIMENSION,
                .max_texture_dimension_2d = dx.D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION,
                .max_texture_dimension_3d = dx.D3D12_REQ_TEXTURE3D_U_V_OR_W_DIMENSION,
                .max_texture_array_layers = dx.D3D12_REQ_TEXTURE2D_ARRAY_AXIS_DIMENSION,
                .max_bind_groups = 8,
                .max_bindings_per_group = 64,
                .max_uniform_buffer_binding_size = dx.D3D12_REQ_CONSTANT_BUFFER_ELEMENT_COUNT * 16,
                .max_storage_buffer_binding_size = std.math.maxInt(u32),
                .min_uniform_buffer_offset_alignment = dx.D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT,
                .min_storage_buffer_offset_alignment = dx.D3D12_RAW_UAV_SRV_BYTE_ALIGNMENT,
                .max_vertex_buffers = dx.D3D12_IA_VERTEX_INPUT_RESOURCE_SLOT_COUNT,
                .max_vertex_attributes = dx.D3D12_IA_VERTEX_INPUT_STRUCTURE_ELEMENT_COUNT,
                .max_vertex_stride = 2048,
                .max_color_attachments = dx.D3D12_SIMULTANEOUS_RENDER_TARGET_COUNT,
                .max_compute_workgroup_storage = dx.D3D12_CS_TGSM_REGISTER_COUNT * 4,
                .max_compute_invocations = dx.D3D12_CS_THREAD_GROUP_MAX_THREADS_PER_GROUP,
                .max_compute_workgroup_size = .{
                    dx.D3D12_CS_THREAD_GROUP_MAX_X,
                    dx.D3D12_CS_THREAD_GROUP_MAX_Y,
                    dx.D3D12_CS_THREAD_GROUP_MAX_Z,
                },
                .max_compute_workgroups = .{
                    dx.D3D12_CS_DISPATCH_MAX_THREAD_GROUPS_PER_DIMENSION,
                    dx.D3D12_CS_DISPATCH_MAX_THREAD_GROUPS_PER_DIMENSION,
                    dx.D3D12_CS_DISPATCH_MAX_THREAD_GROUPS_PER_DIMENSION,
                },
                .max_sampler_anisotropy = dx.D3D12_MAX_MAXANISOTROPY,
            },
        };
    }

    fn formatCapabilitiesImpl(ptr: *anyopaque, format: resource.Format) adapter_interface.FormatCapabilities {
        const self: *Dx12Adapter = @ptrCast(@alignCast(ptr));
        if (format == .undefined) return .{};
        const dxgi_format = dx_resource.toDxFormat(format);
        if (dxgi_format == dx.DXGI_FORMAT_UNKNOWN) return .{};
        const device = self.queryDevice() catch |err| {
            log.warn("failed to create D3D12 capability query device: {}", .{err});
            return .{};
        };

        var support = std.mem.zeroes(dx.D3D12_FEATURE_DATA_FORMAT_SUPPORT);
        support.Format = dxgi_format;
        if (!checkFeature(device, dx.D3D12_FEATURE_FORMAT_SUPPORT, &support)) return .{};

        const s1 = support.Support1;
        const texture = (s1 & (dx.D3D12_FORMAT_SUPPORT1_TEXTURE1D |
            dx.D3D12_FORMAT_SUPPORT1_TEXTURE2D |
            dx.D3D12_FORMAT_SUPPORT1_TEXTURE3D)) != 0;
        if (!texture) return .{};

        const renderable = (s1 & dx.D3D12_FORMAT_SUPPORT1_RENDER_TARGET) != 0;
        return .{
            .usage = .{
                .sampled = (s1 & (dx.D3D12_FORMAT_SUPPORT1_SHADER_LOAD |
                    dx.D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE)) != 0,
                .storage = (s1 & dx.D3D12_FORMAT_SUPPORT1_TYPED_UNORDERED_ACCESS_VIEW) != 0,
                .color_attachment = renderable,
                .depth_stencil_attachment = (s1 & dx.D3D12_FORMAT_SUPPORT1_DEPTH_STENCIL) != 0,
                .transfer_src = true,
                .transfer_dst = true,
            },
            .sample_counts = .{
                .one = true,
                .two = multisampleSupported(device, dxgi_format, 2),
                .four = multisampleSupported(device, dxgi_format, 4),
                .eight = multisampleSupported(device, dxgi_format, 8),
            },
        };
    }

    fn multisampleSupported(device: *dx.ID3D12Device, format: dx.DXGI_FORMAT, count: dx.UINT) bool {
        var levels = std.mem.zeroes(dx.D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS);
        levels.Format = format;
        levels.SampleCount = count;
        if (!checkFeature(device, dx.D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS, &levels)) return false;
        return levels.NumQualityLevels > 0;
    }

    fn checkFeature(device: *dx.ID3D12Device, feature: dx.D3D12_FEATURE, data: anytype) bool {
        const hr = device.lpVtbl.*.CheckFeatureSupport.?(
            device,
            feature,
            @ptrCast(data),
            @sizeOf(@TypeOf(data.*)),
        );
        if (hr < 0) log.warn("CheckFeatureSupport({}) failed with 0x{X:0>8}", .{ feature, @as(u32, @bitCast(hr)) });
        return hr >= 0;
    }

    /// Lazily creates the D3D12 device used for capability queries. D3D12
    /// devices are per-adapter singletons, so this shares state with any
    /// device later created for rendering.
    fn queryDevice(self: *Dx12Adapter) !*dx.ID3D12Device {
        if (self.query_device.get()) |device| return device;
        const adapter = self.adapter.get() orelse return error.HrFailed;
        var raw: ?*anyopaque = null;
        try checkHr(dx.D3D12CreateDevice(
            @ptrCast(adapter),
            dx.D3D_FEATURE_LEVEL_11_0,
            &dx.IID_ID3D12Device,
            &raw,
        ));
        self.query_device = .attach(@ptrCast(@alignCast(raw orelse return error.HrFailed)));
        return self.query_device.unwrap();
    }

    fn surfaceCapabilitiesImpl(ptr: *anyopaque, allocator: std.mem.Allocator, _: Window) !adapter_interface.SurfaceCapabilities {
        const self: *Dx12Adapter = @ptrCast(@alignCast(ptr));

        const candidates = [_]swapchain_interface.SwapchainFormat{
            .bgra8_unorm, .bgra8_unorm_srgb, .rgba8_unorm, .rgba8_unorm_srgb, .rgba16_float,
        };
        var supported: [candidates.len]swapchain_interface.SwapchainFormat = undefined;
        var supported_len: usize = 0;
        const device = try self.queryDevice();
        for (candidates) |candidate| {
            var support = std.mem.zeroes(dx.D3D12_FEATURE_DATA_FORMAT_SUPPORT);
            support.Format = @import("swapchain.zig").toDxFormat(candidate);
            if (!checkFeature(device, dx.D3D12_FEATURE_FORMAT_SUPPORT, &support)) continue;
            if ((support.Support1 & dx.D3D12_FORMAT_SUPPORT1_DISPLAY) == 0) continue;
            supported[supported_len] = candidate;
            supported_len += 1;
        }
        const formats = try allocator.dupe(swapchain_interface.SwapchainFormat, supported[0..supported_len]);
        errdefer allocator.free(formats);

        // Sync-interval-0 presents need DXGI tearing support from the factory.
        const present_modes = if (self.allowsTearing())
            try allocator.dupe(swapchain_interface.PresentMode, &.{ .fifo, .immediate, .mailbox })
        else
            try allocator.dupe(swapchain_interface.PresentMode, &.{.fifo});
        errdefer allocator.free(present_modes);

        // HWND flip-model swapchains always composite opaquely.
        const composite_alpha = try allocator.dupe(swapchain_interface.CompositeAlpha, &.{.opaque_alpha});

        return .{
            .allocator = allocator,
            .formats = formats,
            .present_modes = present_modes,
            .composite_alpha = composite_alpha,
            .min_image_count = 2,
            .max_image_count = dx.DXGI_MAX_SWAP_CHAIN_BUFFERS,
            .min_extent = .{ .width = 1, .height = 1 },
            .max_extent = .{
                .width = dx.D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION,
                .height = dx.D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION,
            },
        };
    }

    fn allowsTearing(self: *Dx12Adapter) bool {
        var factory5 = self.factory.as(dx.IDXGIFactory5, &dx.IID_IDXGIFactory5) catch return false;
        defer factory5.deinit();
        var allow: dx.BOOL = dx.FALSE;
        const hr = factory5.unwrap().lpVtbl.*.CheckFeatureSupport.?(
            factory5.unwrap(),
            dx.DXGI_FEATURE_PRESENT_ALLOW_TEARING,
            &allow,
            @sizeOf(dx.BOOL),
        );
        return hr >= 0 and allow != dx.FALSE;
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
            log.err("DX12 adapter enumeration count mismatch: expected {}, initialised {}", .{ adapters.len, initialized });
            return error.HrFailed;
        }
        return adapters;
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Adapter = @ptrCast(@alignCast(ptr));

        self.query_device.deinit();
        self.adapter.deinit();
        self.factory.deinit();

        log.debug("destroyed DX12 adapter", .{});
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
