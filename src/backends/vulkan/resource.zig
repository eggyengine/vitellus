const std = @import("std");

const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const sampler = @import("../../types/sampler.zig");
const texture = @import("../../types/texture.zig");
const vkDevice = @import("device.zig").vkDevice;

const log = std.log.scoped(.vitellus_vulkan);

pub const vkBuffer = struct {
    pub const vtable = hal.Buffer.VTable{
        .destroy = destroy,
        .mapAsync = mapAsync,
        .getMappedRange = getMappedRange,
        .unmap = unmap,
    };

    pub fn init(device: *vkDevice, descriptor: buffer.Buffer.Descriptor) !hal.Buffer {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan buffer", .{});
    }

    fn mapAsync(
        ptr: *anyopaque,
        io: std.Io,
        mode: buffer.Buffer.MapMode,
        offset: ?def.Size64,
        size: def.Size64,
    ) std.Io.Future(anyerror!void) {
        return io.async(mapAsyncInternal, .{ ptr, mode, offset, size });
    }

    fn mapAsyncInternal(
        ptr: *anyopaque,
        mode: buffer.Buffer.MapMode,
        offset: ?def.Size64,
        size: def.Size64,
    ) anyerror!void {
        _ = ptr;
        _ = mode;
        _ = offset;
        _ = size;
        return error.NotImplemented;
    }

    fn getMappedRange(ptr: *anyopaque, offset: ?def.Size64, size: ?def.Size64) ?def.ArrayBuffer {
        _ = ptr;
        _ = offset;
        _ = size;
        return null;
    }

    fn unmap(ptr: *anyopaque) void {
        _ = ptr;
    }
};

pub const vkTexture = struct {
    pub const vtable = hal.Texture.VTable{
        .destroy = destroy,
        .createView = createView,
    };

    pub fn init(device: *vkDevice, descriptor: texture.Texture.Descriptor) !hal.Texture {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan texture", .{});
    }

    fn createView(ptr: *anyopaque, descriptor: texture.Texture.View.Descriptor) anyerror!hal.TextureView {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }
};

pub const vkTextureView = struct {
    pub const vtable = hal.TextureView.VTable{
        .destroy = destroy,
    };

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan texture view", .{});
    }
};

pub const vkExternalTexture = struct {
    pub const vtable = hal.ExternalTexture.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: texture.ExternalTexture.Descriptor) !hal.ExternalTexture {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan external texture", .{});
    }
};

pub const vkSampler = struct {
    pub const vtable = hal.Sampler.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: sampler.Sampler.Descriptor) !hal.Sampler {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan sampler", .{});
    }
};

pub const vkBindGroupLayout = struct {
    pub const vtable = hal.BindGroupLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: @import("../../types/bind_group.zig").BindGroupLayout.Descriptor) !hal.BindGroupLayout {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan bind group layout", .{});
    }
};

pub const vkBindGroup = struct {
    pub const vtable = hal.BindGroup.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: @import("../../types/bind_group.zig").BindGroup.Descriptor) !hal.BindGroup {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan bind group", .{});
    }
};

pub const vkQuerySet = struct {
    pub const vtable = hal.QuerySet.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: gpu.QuerySet.Descriptor) !hal.QuerySet {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying vulkan query set", .{});
    }
};
