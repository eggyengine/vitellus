const builtin = @import("builtin");

pub const VitellusConfig = struct {
    /// Optional set of backends the caller is willing to use.
    ///
    /// If null, Vitellus uses the current platform's preferred fallback chain:
    /// - Windows: DX12 → Vulkan
    /// - Apple platforms: Metal → Vulkan
    /// - Android: Vulkan
    /// - Linux: Vulkan
    backend: ?BackendType,
    validation: ValidationLevel,
};

pub const Backend = enum {
    dx12,
    vulkan,
    metal,
};

pub const BackendType = packed struct(u32) {
    vulkan: bool = false,
    dx12: bool = false,
    metal: bool = false,
    _pad: u29 = 0,

    pub fn all() BackendType {
        return .{ .vulkan = true, .dx12 = true, .metal = true };
    }

    pub fn contains(self: BackendType, backend: Backend) bool {
        return switch (backend) {
            .dx12 => self.dx12,
            .vulkan => self.vulkan,
            .metal => self.metal,
        };
    }

    pub fn isEmpty(self: BackendType) bool {
        return !self.dx12 and !self.vulkan and !self.metal;
    }
};

pub const BackendFallbackOrder = struct {
    items: [3]Backend = undefined,
    len: usize = 0,

    pub fn slice(self: *const BackendFallbackOrder) []const Backend {
        return self.items[0..self.len];
    }
};

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

pub const ValidationLevel = enum { none, core, extended, gpu_based };
