//! Physical GPU discovery and backend selection.

const std = @import("std");
const options = @import("shader_options");
const settings_mod = @import("settings.zig");
const Backend = settings_mod.Backend;
const BackendType = settings_mod.BackendType;
const ValidationLevel = settings_mod.ValidationLevel;
const Instance = @import("instance.zig").Instance;
const Device = @import("device.zig").Device;
const DeviceDescriptor = @import("device.zig").DeviceDescriptor;
const Swapchain = @import("swapchain.zig").Swapchain;
const SwapchainDescriptor = @import("swapchain.zig").SwapchainDescriptor;
const swapchain = @import("swapchain.zig");
const resource = @import("resource.zig");
const Window = @import("../windowing/windowing.zig").Window;

pub const PowerPreference = enum { low_power, high_performance };
pub const AdapterDescriptor = struct {
    /// Optional name shown for the selected physical adapter in graphics debuggers.
    label: ?[]const u8 = null,
};
pub const FeatureSet = settings_mod.FeatureSet;
pub const Limits = struct {
    max_buffer_size: u64 = 0,
    max_texture_dimension_1d: u32 = 0,
    max_texture_dimension_2d: u32 = 0,
    max_texture_dimension_3d: u32 = 0,
    max_texture_array_layers: u32 = 0,
    max_bind_groups: u32 = 0,
    max_bindings_per_group: u32 = 0,
    max_uniform_buffer_binding_size: u64 = 0,
    max_storage_buffer_binding_size: u64 = 0,
    min_uniform_buffer_offset_alignment: u32 = 1,
    min_storage_buffer_offset_alignment: u32 = 1,
    max_vertex_buffers: u32 = 0,
    max_vertex_attributes: u32 = 0,
    max_vertex_stride: u32 = 0,
    max_color_attachments: u32 = 0,
    max_compute_workgroup_storage: u32 = 0,
    max_compute_invocations: u32 = 0,
    max_compute_workgroup_size: [3]u32 = .{ 0, 0, 0 },
    max_compute_workgroups: [3]u32 = .{ 0, 0, 0 },
    max_sampler_anisotropy: u16 = 1,
};
pub const AdapterCapabilities = struct { features: FeatureSet = .{}, limits: Limits = .{} };
pub const SampleCounts = packed struct(u8) { one: bool = true, two: bool = false, four: bool = false, eight: bool = false, _pad: u4 = 0 };
pub const FormatCapabilities = struct { usage: resource.TextureUsage = .{}, sample_counts: SampleCounts = .{} };
pub const SurfaceCapabilities = struct {
    allocator: std.mem.Allocator,
    formats: []swapchain.SwapchainFormat,
    present_modes: []swapchain.PresentMode,
    composite_alpha: []swapchain.CompositeAlpha,
    min_image_count: u32,
    max_image_count: u32,
    min_extent: swapchain.Extent2D,
    max_extent: swapchain.Extent2D,
    pub fn deinit(self: SurfaceCapabilities) void {
        self.allocator.free(self.formats);
        self.allocator.free(self.present_modes);
        self.allocator.free(self.composite_alpha);
    }
};

/// Recognised GPU vendor families.
pub const Vendor = enum { nvidia, amd, intel, apple, microsoft, unknown };

/// Broad adapter class used when ranking available devices.
pub const Kind = enum { discrete, integrated, software, unknown };

/// Stable, backend-independent information about a physical adapter.
pub const AdapterInfo = struct {
    /// GPU name encoded as UTF-8. Use `nameSlice()` to read it.
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,
    /// Reported dedicated video memory in bytes.
    dedicated_vram: usize = 0,
    /// Vendor inferred from the backend's device identifier.
    vendor: Vendor = .unknown,
    /// Hardware class reported or inferred by the backend.
    kind: Kind = .unknown,

    /// Returns the initialised portion of the UTF-8 adapter name.
    pub fn nameSlice(self: *const AdapterInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Owning handle to a selected physical GPU and backend.
///
/// Destroy dependent devices and swapchains before calling `deinit`. Do not
/// deinitialise copied handles more than once.
pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,
    validation: ValidationLevel = .none,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        infoFn: *const fn (ptr: *anyopaque) AdapterInfo,
        createDeviceFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, desc: DeviceDescriptor) anyerror!Device,
        createSwapchainFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, desc: SwapchainDescriptor) anyerror!Swapchain,
        capabilitiesFn: *const fn (ptr: *anyopaque) AdapterCapabilities,
        formatCapabilitiesFn: *const fn (ptr: *anyopaque, format: resource.Format) FormatCapabilities,
        surfaceCapabilitiesFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, window: Window) anyerror!SurfaceCapabilities,
    };

    pub fn init(instance: Instance, desc: AdapterDescriptor) !Adapter {
        var adapter = try instance.createAdapter(desc);
        adapter.validation = instance.config.validation;
        return adapter;
    }

    /// Enumerates adapters from the first requested backend that succeeds.
    ///
    /// The caller owns the returned slice and every adapter in it. Call
    /// `deinit` on each adapter, then free the slice with `allocator`.
    pub fn enumerate(allocator: std.mem.Allocator, backend: BackendType) ![]Adapter {
        const preferred_backend = try settings_mod.environmentBackend(allocator);
        const order = settings_mod.backendFallbackOrderWithPreference(backend, preferred_backend);
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

    /// Enumerates adapters from a user-implemented backend. Fails with
    /// `error.EnumerationUnsupported` when the factory does not implement
    /// adapter enumeration.
    ///
    /// The caller owns the returned slice and every adapter in it, as with
    /// `enumerate`.
    pub fn enumerateCustom(allocator: std.mem.Allocator, factory: settings_mod.BackendFactory) ![]Adapter {
        const enumerateFn = factory.enumerateAdaptersFn orelse return error.EnumerationUnsupported;
        return enumerateFn(allocator);
    }

    fn enumerateBackend(backend: Backend, allocator: std.mem.Allocator) ![]Adapter {
        return switch (backend) {
            .dx12 => if (comptime options.enable_dx12)
                @import("../backends/dx12/adapter.zig").Dx12Adapter.enumerate(allocator)
            else
                error.Dx12Unavailable,
            .vulkan => if (comptime options.enable_vk)
                @import("../backends/vulkan/adapter.zig").vkAdapter.enumerateStandalone(allocator)
            else
                error.VulkanUnavailable,
            .metal => error.MetalNotImplemented,
            .custom => unreachable, // custom backends never enter the built-in fallback order
        };
    }

    /// Picks the strongest non-software adapter, preferring discrete GPUs and
    /// then greater dedicated video memory. The returned handle is borrowed
    /// from `adapters` and must not be deinitialised separately.
    pub fn pick(adapters: []const Adapter, preference: PowerPreference) ?Adapter {
        var best: ?Adapter = null;
        var best_info: ?AdapterInfo = null;

        for (adapters) |adapter| {
            const i = adapter.info();
            if (i.kind == .software) continue;

            const choose = if (best_info) |bi| blk: {
                const preferred = if (preference == .high_performance) Kind.discrete else Kind.integrated;
                const gains_discrete = i.kind == preferred and bi.kind != preferred;
                const same_kind_more_vram = i.kind == bi.kind and i.dedicated_vram > bi.dedicated_vram;
                break :blk gains_discrete or same_kind_more_vram;
            } else true;

            if (choose) {
                best = adapter;
                best_info = i;
            }
        }

        return best;
    }

    /// Queries backend-independent adapter properties.
    pub fn info(self: Adapter) AdapterInfo {
        return self.vtable.infoFn(self.ptr);
    }

    pub fn capabilities(self: Adapter) AdapterCapabilities {
        return self.vtable.capabilitiesFn(self.ptr);
    }
    pub fn formatCapabilities(self: Adapter, format: resource.Format) FormatCapabilities {
        return self.vtable.formatCapabilitiesFn(self.ptr, format);
    }
    pub fn surfaceCapabilities(self: Adapter, allocator: std.mem.Allocator, window: Window) !SurfaceCapabilities {
        return self.vtable.surfaceCapabilitiesFn(self.ptr, allocator, window);
    }

    /// Releases the backend adapter and its native resources.
    pub fn deinit(self: Adapter) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};
