const std = @import("std");
const candler = @import("candler");
const vk = @import("vulkan");

const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");
const vulkan_windowing = @import("../../windowing/vulkan.zig");
const adapter_backend = @import("adapter.zig");
const instance_backend = @import("instance.zig");
const vkDevice = @import("device.zig").vkDevice;

const log = std.log.scoped(.vitellus_vulkan);

pub const vkSurface = struct {
    pub const vtable = hal.Surface.VTable{
        .destroy = deinit,
        .getCapabilities = getCapabilities,
        .configure = configure,
        .unconfigure = unconfigure,
        .getCurrentTexture = getCurrentTexture,
    };

    const fallback_surface_formats = [_]texture.Texture.Format{
        .bgra8unorm,
        .bgra8unorm_srgb,
        .rgba8unorm,
        .rgba8unorm_srgb,
    };
    const fallback_present_modes = [_]texture.Surface.PresentMode{.fifo};
    const fallback_alpha_modes = [_]texture.Surface.AlphaMode{.@"opaque"};

    gpu: *instance_backend.vkInstance,
    handle: vk.SurfaceKHR,
    formats: ?[]texture.Texture.Format = null,
    present_modes: ?[]texture.Surface.PresentMode = null,
    alpha_modes: ?[]texture.Surface.AlphaMode = null,

    pub fn initRaw(instance: *instance_backend.vkInstance, window: candler.WindowHandle, display: candler.DisplayHandle) !@This() {
        log.debug("creating vulkan surface: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return .{
            .gpu = instance,
            .handle = try vulkan_windowing.createSurface(instance.instance, window, display),
        };
    }

    pub fn initHeadless(instance: *instance_backend.vkInstance) !@This() {
        log.debug("creating headless vulkan surface", .{});
        return .{
            .gpu = instance,
            .handle = try vulkan_windowing.createHeadlessSurface(instance.instance),
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.destroy();
    }

    pub fn destroy(self: *@This()) void {
        if (self.formats) |formats| {
            std.heap.page_allocator.free(formats);
            self.formats = null;
        }
        if (self.present_modes) |present_modes| {
            std.heap.page_allocator.free(present_modes);
            self.present_modes = null;
        }
        if (self.alpha_modes) |alpha_modes| {
            std.heap.page_allocator.free(alpha_modes);
            self.alpha_modes = null;
        }

        if (self.handle != .null_handle) {
            log.debug("destroying vulkan surface: handle=0x{x}", .{@intFromEnum(self.handle)});
            self.gpu.instance.destroySurfaceKHR(self.handle, null);
            self.handle = .null_handle;
        }
        std.heap.page_allocator.destroy(self);
    }

    fn getCapabilities(ptr: *anyopaque, adapter: hal.Adapter) texture.Surface.Capabilities {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        const vk_adapter: *adapter_backend.vkAdapter = @ptrCast(@alignCast(adapter.ptr));
        log.debug("vulkan surface capabilities requested", .{});

        typed.refreshCapabilities(vk_adapter) catch |err| {
            log.warn("failed to query vulkan surface capabilities: {s}; using fallback capabilities", .{@errorName(err)});
            return .{
                .formats = &fallback_surface_formats,
                .present_modes = &fallback_present_modes,
                .alpha_modes = &fallback_alpha_modes,
            };
        };

        return .{
            .formats = typed.formats orelse &fallback_surface_formats,
            .present_modes = typed.present_modes orelse &fallback_present_modes,
            .alpha_modes = typed.alpha_modes orelse &fallback_alpha_modes,
        };
    }

    fn refreshCapabilities(self: *@This(), adapter: *adapter_backend.vkAdapter) !void {
        const vk_formats = try self.gpu.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
            adapter.pdev,
            self.handle,
            std.heap.page_allocator,
        );
        defer std.heap.page_allocator.free(vk_formats);

        const vk_present_modes = try self.gpu.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
            adapter.pdev,
            self.handle,
            std.heap.page_allocator,
        );
        defer std.heap.page_allocator.free(vk_present_modes);

        const vk_caps = try self.gpu.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(adapter.pdev, self.handle);

        const formats = try std.heap.page_allocator.alloc(texture.Texture.Format, vk_formats.len);
        errdefer std.heap.page_allocator.free(formats);
        for (vk_formats, formats) |vk_format, *format| {
            format.* = textureFormatFromVulkan(vk_format.format) orelse .bgra8unorm;
        }

        const modes = try std.heap.page_allocator.alloc(texture.Surface.PresentMode, vk_present_modes.len);
        errdefer std.heap.page_allocator.free(modes);
        for (vk_present_modes, modes) |vk_mode, *mode| {
            mode.* = presentModeFromVulkan(vk_mode) orelse .fifo;
        }

        var alpha_buffer: [4]texture.Surface.AlphaMode = undefined;
        var alpha_count: usize = 0;
        if (vk_caps.supported_composite_alpha.opaque_bit_khr) {
            alpha_buffer[alpha_count] = .@"opaque";
            alpha_count += 1;
        }
        if (vk_caps.supported_composite_alpha.pre_multiplied_bit_khr or
            vk_caps.supported_composite_alpha.post_multiplied_bit_khr)
        {
            alpha_buffer[alpha_count] = .premultiplied;
            alpha_count += 1;
        }
        if (alpha_count == 0) {
            alpha_buffer[alpha_count] = .@"opaque";
            alpha_count += 1;
        }

        const alpha = try std.heap.page_allocator.alloc(texture.Surface.AlphaMode, alpha_count);
        errdefer std.heap.page_allocator.free(alpha);
        @memcpy(alpha, alpha_buffer[0..alpha_count]);

        if (self.formats) |old| std.heap.page_allocator.free(old);
        if (self.present_modes) |old| std.heap.page_allocator.free(old);
        if (self.alpha_modes) |old| std.heap.page_allocator.free(old);
        self.formats = formats;
        self.present_modes = modes;
        self.alpha_modes = alpha;
    }

    fn configure(ptr: *anyopaque, device: hal.Device, desc: texture.Surface.Configuration) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        // const dev: *vkDevice = @ptrCast(@alignCast(device.ptr));

        _ = typed;
        _ = device;
        _ = desc;
        log.debug("vulkan surface configure requested", .{});
    }

    fn unconfigure(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = typed;
        log.debug("vulkan surface unconfigure requested", .{});
    }

    fn getCurrentTexture(ptr: *anyopaque) !texture.Surface.CurrentSurfaceTexture {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = typed;
        log.debug("vulkan surface current texture requested", .{});
        return error.NotImplemented;
    }
};

fn textureFormatFromVulkan(format: vk.Format) ?texture.Texture.Format {
    return switch (format) {
        .b8g8r8a8_unorm => .bgra8unorm,
        .b8g8r8a8_srgb => .bgra8unorm_srgb,
        .r8g8b8a8_unorm => .rgba8unorm,
        .r8g8b8a8_srgb => .rgba8unorm_srgb,
        else => null,
    };
}

fn presentModeFromVulkan(mode: vk.PresentModeKHR) ?texture.Surface.PresentMode {
    return switch (mode) {
        .fifo_khr => .fifo,
        .fifo_relaxed_khr => .fifo_relaxed,
        .immediate_khr => .immediate,
        .mailbox_khr => .mailbox,
        else => null,
    };
}
