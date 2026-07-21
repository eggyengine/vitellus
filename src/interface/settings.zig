//! Backend selection and validation configuration.

const std = @import("std");
const builtin = @import("builtin");
const Instance = @import("instance.zig").Instance;
const Adapter = @import("adapter.zig").Adapter;

/// Top-level configuration used while selecting an adapter.
pub const VitellusConfig = struct {
    /// Optional name shown for the backend instance in graphics debuggers.
    label: ?[]const u8 = null,
    /// Optional set of built-in backends the caller is willing to use.
    ///
    /// If null, Vitellus uses the current platform's preferred fallback chain:
    /// - Windows: DX12 → Vulkan
    /// - Apple platforms: Metal → Vulkan
    /// - Android: Vulkan
    /// - Linux: Vulkan
    ///
    /// Pass an empty set (`.{}`) together with `custom_backends` to disable
    /// every built-in backend.
    backend: ?BackendType,
    /// User-implemented backends tried, in listed order, before any built-in
    /// backend. See `BackendFactory`.
    custom_backends: []const BackendFactory = &.{},
    /// Validation features requested from the selected backend.
    validation: ValidationLevel,
};

/// Rendering backend implemented by Vitellus, or a user-implemented one.
pub const Backend = union(enum) {
    dx12,
    vulkan,
    metal,
    /// User-implemented backend identified by a stable, unique name
    /// (e.g. "webgpu"). The name is borrowed and must outlive this value.
    custom: []const u8,

    /// Returns whether two backend identities are the same. Custom backends
    /// compare by name.
    pub fn eql(self: Backend, other: Backend) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .custom => |name_| std.mem.eql(u8, name_, other.custom),
            else => true,
        };
    }

    /// Returns a stable, human-readable backend name.
    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .custom => |n| n,
            else => @tagName(self),
        };
    }
};

/// Entry point for a user-implemented rendering backend.
///
/// A backend implements the type-erased vtables from `interface/` (`Instance`,
/// `Adapter`, `Device`, `Queue`, ...) and exposes itself with a factory:
///
/// ```zig
/// pub const factory = vitellus.BackendFactory{
///     .name = "webgpu",
///     .createInstanceFn = WebGpuInstance.create,
/// };
/// ```
///
/// Callers opt in through `VitellusConfig.custom_backends`:
///
/// ```zig
/// const instance = try vitellus.Instance.init(allocator, .{
///     .backend = .{}, // or a built-in set to fall back to
///     .custom_backends = &.{webgpu.factory},
///     .validation = .none,
/// });
/// ```
pub const BackendFactory = struct {
    /// Stable, unique backend name (e.g. "webgpu"). This is the identity the
    /// backend should use as `Backend{ .custom = name }` in shader compile
    /// requests.
    name: []const u8,
    /// Creates the backend's `Instance`. Return an error to let selection
    /// fall through to the next candidate backend.
    createInstanceFn: *const fn (allocator: std.mem.Allocator, config: VitellusConfig) anyerror!Instance,
    /// Optionally enumerates every adapter exposed by the backend. Used by
    /// `Adapter.enumerateCustom`.
    enumerateAdaptersFn: ?*const fn (allocator: std.mem.Allocator) anyerror![]Adapter = null,

    /// Returns this backend's identity.
    pub fn backend(self: BackendFactory) Backend {
        return .{ .custom = self.name };
    }
};

/// Set of backends a caller is willing to use.
pub const BackendType = packed struct(u32) {
    vulkan: bool = false,
    dx12: bool = false,
    metal: bool = false,
    _pad: u29 = 0,

    /// Returns a set containing every known backend.
    ///
    /// Currently the rules are:
    /// - Windows:
    ///     - DirectX 12
    ///     - Vulkan
    /// - Linux:
    ///     - Vulkan
    /// - macOS:
    ///     - Metal
    ///     - Vulkan
    pub fn all() BackendType {
        return .{ .vulkan = true, .dx12 = true, .metal = true };
    }

    /// Returns whether this set contains `backend`. Custom backends are
    /// selected through `VitellusConfig.custom_backends`, never this set.
    pub fn contains(self: BackendType, backend: Backend) bool {
        return switch (backend) {
            .dx12 => self.dx12,
            .vulkan => self.vulkan,
            .metal => self.metal,
            .custom => false,
        };
    }

    /// Returns whether no backend is enabled.
    pub fn isEmpty(self: BackendType) bool {
        return !self.dx12 and !self.vulkan and !self.metal;
    }
};

/// Fixed-capacity backend preference list.
pub const BackendFallbackOrder = struct {
    items: [3]Backend = undefined,
    len: usize = 0,

    /// Returns the initialised entries in preference order.
    pub fn slice(self: *const BackendFallbackOrder) []const Backend {
        return self.items[0..self.len];
    }
};

/// Returns the backends normally considered on the target platform.
pub fn platformDefaultBackends() BackendType {
    return switch (builtin.target.os.tag) {
        .windows => .{ .dx12 = true, .vulkan = true },
        // Zig models Android as a Linux OS with an Android ABI.
        .linux => .{ .vulkan = true },
        else => if (builtin.target.os.tag.isDarwin())
            .{ .metal = true, .vulkan = true }
        else
            .{ .vulkan = true },
    };
}

/// Returns platform backends from most to least preferred.
pub fn platformBackendOrder() []const Backend {
    return switch (builtin.target.os.tag) {
        .windows => &.{ .dx12, .vulkan },
        // Zig models Android as a Linux OS with an Android ABI.
        .linux => &.{.vulkan},
        else => if (builtin.target.os.tag.isDarwin())
            &.{ .metal, .vulkan }
        else
            &.{.vulkan},
    };
}

/// Returns the ordered backends to try for this platform, filtered by the
/// caller's requested backend set. If `requested` is null, the platform default
/// fallback set is used.
pub fn backendFallbackOrder(requested: ?BackendType) BackendFallbackOrder {
    const allowed = requested orelse platformDefaultBackends();
    var order = BackendFallbackOrder{};

    if (allowed.isEmpty()) return order;

    for (platformBackendOrder()) |backend| {
        if (allowed.contains(backend)) {
            order.items[order.len] = backend;
            order.len += 1;
        }
    }

    return order;
}

/// Amount of backend and API validation requested by the application.
pub const ValidationLevel = enum { none, core, extended, gpu_based };

/// Optional capabilities that must be checked before device creation.
pub const FeatureSet = packed struct(u32) {
    timestamp_query: bool = false,
    occlusion_query: bool = false,
    indirect_first_instance: bool = false,
    depth_clip_control: bool = false,
    wireframe: bool = false,
    anisotropic_filtering: bool = false,
    bc_compression: bool = false,
    _pad: u25 = 0,
};
