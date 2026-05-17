const std = @import("std");

const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");
const device_backend = @import("device.zig");

const log = std.log.scoped(.vitellus_noop);

pub const NoopAdapter = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Adapter.VTable{
        .requestDevice = requestDevice,
        .getInfo = getInfo,
        .getDownlevelCapabilities = getDownlevelCapabilities,
        .getTextureFormatFeatures = getTextureFormatFeatures,
        .isSurfaceSupported = isSurfaceSupported,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.Adapter {
        const adapter = try allocator.create(NoopAdapter);
        adapter.* = .{ .allocator = allocator };
        return .{
            .ptr = adapter,
            .vtable = &vtable,
        };
    }

    fn requestDevice(
        ptr: *anyopaque,
        io: std.Io,
        options: gpu.Device.Descriptor,
    ) std.Io.Future(anyerror!struct { hal.Device, hal.Queue }) {
        return io.async(requestDeviceInternal, .{ ptr, options });
    }

    fn requestDeviceInternal(ptr: *anyopaque, options: gpu.Device.Descriptor) anyerror!struct { hal.Device, hal.Queue } {
        const typed: *NoopAdapter = @ptrCast(@alignCast(ptr));
        _ = options;
        log.debug("returning noop device", .{});
        return try device_backend.NoopDevice.init(typed.allocator);
    }

    fn getInfo(ptr: *anyopaque) gpu.Adapter.Info {
        _ = ptr;
        return .{
            .vendor = "vitellus",
            .architecture = "noop",
            .device = "noop",
            .description = "vitellus noop backend",
            .subgroupMinSize = 0,
            .subgroupMaxSize = 0,
            .isFallbackAdapter = true,
        };
    }

    fn getDownlevelCapabilities(ptr: *anyopaque) gpu.Adapter.DownlevelCapabilities {
        _ = ptr;
        return .{};
    }

    fn getTextureFormatFeatures(
        ptr: *anyopaque,
        format: texture.Texture.Format,
    ) gpu.Adapter.TextureFormatFeatures {
        _ = ptr;
        _ = format;
        return .{
            .allowedUsages = texture.Texture.Usage.COPY_SRC |
                texture.Texture.Usage.COPY_DST |
                texture.Texture.Usage.TEXTURE_BINDING |
                texture.Texture.Usage.STORAGE_BINDING |
                texture.Texture.Usage.RENDER_ATTACHMENT,
            .flags = .{
                .filterable = true,
                .blendable = true,
                .multisample_x2 = true,
                .multisample_x4 = true,
            },
        };
    }

    fn isSurfaceSupported(ptr: *anyopaque, surface: hal.Surface) bool {
        _ = ptr;
        _ = surface;
        return true;
    }
};
