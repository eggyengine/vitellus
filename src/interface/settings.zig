//! Backend selection and validation configuration.

const std = @import("std");
const builtin = @import("builtin");

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
    /// - Web (Emscripten): WebGPU
    ///
    /// The `VITELLUS_BACKEND` environment variable (`vulkan`, `dx12`, `metal`
    /// or `webgpu`) moves that backend to the front when the platform has it
    /// and this set allows it.
    backend: ?BackendType = null,
    /// Validation features requested from the selected backend.
    validation: ValidationLevel,
};

/// Rendering backend implemented by Vitellus.
pub const Backend = enum {
    dx12,
    vulkan,
    metal,
    /// WebGPU in the browser, through Emscripten.
    webgpu,
};

/// Set of backends a caller is willing to use, e.g. `.{ .vulkan = true, .webgpu = true }`.
pub const BackendType = std.enums.EnumFieldStruct(Backend, bool, false);

/// The platform's backends, most preferred first.
pub const platform_backends: []const Backend = switch (builtin.target.os.tag) {
    .windows => &.{ .dx12, .vulkan },
    .emscripten => &.{.webgpu},
    .macos, .ios, .tvos, .visionos, .watchos => &.{ .metal, .vulkan },
    // Zig models Android as Linux with an Android ABI.
    else => &.{.vulkan},
};

/// The backends to try, most preferred first: the platform's backends that `requested` allows (all of
/// them when null), with `preferred` moved to the front.
pub fn backendOrder(buffer: *[platform_backends.len]Backend, requested: ?BackendType, preferred: ?Backend) []Backend {
    var len: usize = 0;
    for (platform_backends) |backend| {
        if (requested) |set| switch (backend) {
            inline else => |tag| if (!@field(set, @tagName(tag))) continue,
        };
        buffer[len] = backend;
        len += 1;
    }
    const order = buffer[0..len];
    if (preferred) |backend| if (std.mem.indexOfScalar(Backend, order, backend)) |i| std.mem.rotate(Backend, order[0 .. i + 1], i);
    return order;
}

fn processEnviron() std.process.Environ {
    const Block = std.process.Environ.Block;
    if (comptime @hasField(Block, "use_global")) {
        return .{ .block = .global };
    }
    if (!builtin.link_libc) return .empty;
    const raw = std.c.environ;
    var env_count: usize = 0;
    while (raw[env_count] != null) : (env_count += 1) {}
    return .{ .block = .{ .slice = raw[0..env_count :null] } };
}

/// Returns the backend requested through `VITELLUS_BACKEND`, if any.
pub fn environmentBackend(allocator: std.mem.Allocator) !?Backend {
    const value = processEnviron().getAlloc(allocator, "VITELLUS_BACKEND") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer allocator.free(value);
    return std.meta.stringToEnum(Backend, value) orelse {
        std.log.warn("ignoring unknown VITELLUS_BACKEND value '{s}'", .{value});
        return null;
    };
}

test "backend order filters the platform list and promotes the preferred backend" {
    var buffer: [platform_backends.len]Backend = undefined;
    try std.testing.expectEqualSlices(Backend, platform_backends, backendOrder(&buffer, null, null));
    try std.testing.expectEqual(@as(usize, 0), backendOrder(&buffer, .{}, null).len);
    const last = platform_backends[platform_backends.len - 1];
    try std.testing.expectEqual(last, backendOrder(&buffer, null, last)[0]);
    // A preferred backend the platform doesn't have changes nothing.
    try std.testing.expectEqualSlices(Backend, platform_backends, backendOrder(&buffer, null, if (last == .webgpu) .dx12 else .webgpu));
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
