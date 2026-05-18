const std = @import("std");

const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const gpu = @import("../../types/gpu.zig");
const hal = @import("../hal.zig");
const sampler = @import("../../types/sampler.zig");
const texture = @import("../../types/texture.zig");
const vk = @import("vulkan");
const vkDevice = @import("device.zig").vkDevice;
const debug = @import("debug.zig");

const logz = @import("logz");

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
        logz.info().fmt("msg", "destroying vulkan buffer", .{}).log();
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
    device: *vkDevice,
    handle: vk.Image,
    format: vk.Format,
    extent: vk.Extent3D,
    owns_image: bool = false,
    label: ?[*:0]const u8 = null,
    present_surface: ?*anyopaque = null,
    present_image_index: u32 = 0,
    present_image_view: ?*vkTextureView = null,

    pub const vtable = hal.Texture.VTable{
        .destroy = destroy,
        .createView = createView,
    };

    pub fn init(device: *vkDevice, descriptor: texture.Texture.Descriptor) !hal.Texture {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    pub fn initSwapchainImage(device: *vkDevice, image: vk.Image, format: vk.Format, extent: vk.Extent2D) @This() {
        return .{
            .device = device,
            .handle = image,
            .format = format,
            .extent = .{
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },
            .owns_image = false,
        };
    }

    pub fn createDefaultView(self: *@This()) !vkTextureView {
        return vkTextureView.init(self.device, self.handle, self.format, .{ .color_bit = true }, self.label);
    }

    pub fn deinit(self: *@This()) void {
        if (self.owns_image and self.handle != .null_handle) {
            logz.info().fmt("msg", "destroying vulkan image: handle=0x{x}", .{@intFromEnum(self.handle)}).log();
            self.device.device.destroyImage(self.handle, null);
        }
        self.handle = .null_handle;
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.deinit();
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn createView(ptr: *anyopaque, descriptor: texture.Texture.View.Descriptor) anyerror!hal.TextureView {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        const view = try typed.device.adapter.gpu.allocator.create(vkTextureView);
        errdefer typed.device.adapter.gpu.allocator.destroy(view);
        if (typed.present_image_view) |present_image_view| {
            view.* = present_image_view.*;
            view.owns_view = false;
        } else {
            view.* = try typed.createDefaultView();
        }
        view.present_surface = typed.present_surface;
        view.present_image_index = typed.present_image_index;
        return .{ .ptr = view, .vtable = &vkTextureView.vtable };
    }
};

pub const vkTextureView = struct {
    device: *vkDevice,
    handle: vk.ImageView,
    image: vk.Image,
    format: vk.Format,
    label: ?[*:0]const u8 = null,
    owns_view: bool = true,
    present_surface: ?*anyopaque = null,
    present_image_index: u32 = 0,

    pub const vtable = hal.TextureView.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, image: vk.Image, format: vk.Format, aspect_mask: vk.ImageAspectFlags, label: ?[*:0]const u8) !@This() {
        const create_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const handle = try device.device.createImageView(&create_info, null);
        errdefer device.device.destroyImageView(handle, null);
        debug.setObjectName(device, .image_view, handle, label);
        return .{
            .device = device,
            .handle = handle,
            .image = image,
            .format = format,
            .label = label,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.handle != .null_handle) {
            if (self.owns_view) {
                logz.info().fmt("msg", "destroying vulkan texture view: handle=0x{x}", .{@intFromEnum(self.handle)}).log();
                self.device.device.destroyImageView(self.handle, null);
            }
            self.handle = .null_handle;
        }
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.deinit();
        typed.device.adapter.gpu.allocator.destroy(typed);
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
        logz.info().fmt("msg", "destroying vulkan external texture", .{}).log();
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
        logz.info().fmt("msg", "destroying vulkan sampler", .{}).log();
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
        logz.info().fmt("msg", "destroying vulkan bind group layout", .{}).log();
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
        logz.info().fmt("msg", "destroying vulkan bind group", .{}).log();
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
        logz.info().fmt("msg", "destroying vulkan query set", .{}).log();
    }
};
