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

const SwapChainSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,

    fn deinit(self: @This()) void {
        std.heap.page_allocator.free(self.formats);
        std.heap.page_allocator.free(self.present_modes);
    }
};

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
    swapchain_device: ?*vkDevice = null,
    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_images: ?[]vk.Image = null,
    swapchain_image_format: vk.Format = .undefined,
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    swapchain_image_views: ?[]vk.ImageView = null,
    swapchain_framebuffers: ?[]vk.Framebuffer = null,
    swapchain_framebuffer_render_pass: vk.RenderPass = .null_handle,

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
        self.unconfigureSwapchain();

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
        const dev: *vkDevice = @ptrCast(@alignCast(device.ptr));

        log.debug("vulkan surface configure requested", .{});
        typed.configureSwapchain(dev, desc) catch |err| {
            log.err("failed to configure vulkan swapchain: {s}", .{@errorName(err)});
        };
    }

    fn unconfigure(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        log.debug("vulkan surface unconfigure requested", .{});
        typed.unconfigureSwapchain();
    }

    fn getCurrentTexture(ptr: *anyopaque) !texture.Surface.CurrentSurfaceTexture {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = typed;
        log.debug("vulkan surface current texture requested", .{});
        return error.NotImplemented;
    }

    fn configureSwapchain(self: *@This(), device: *vkDevice, desc: texture.Surface.Configuration) !void {
        self.unconfigureSwapchain();

        var support = try querySwapChainSupport(self.gpu, device.adapter.pdev, self.handle);
        defer support.deinit();
        if (support.formats.len == 0) {
            return error.NoSwapchainSurfaceFormats;
        }
        if (support.present_modes.len == 0) {
            return error.NoSwapchainPresentModes;
        }

        const surface_format = chooseSwapSurfaceFormat(support.formats, desc.format);
        const present_mode = chooseSwapPresentMode(support.present_modes, desc.presentMode);
        const extent = chooseSwapExtent(support.capabilities, desc.width, desc.height);

        var image_count = support.capabilities.min_image_count + 1;
        if (desc.desiredMaximumFrameLatency > image_count) {
            image_count = desc.desiredMaximumFrameLatency;
        }
        if (support.capabilities.max_image_count > 0 and image_count > support.capabilities.max_image_count) {
            image_count = support.capabilities.max_image_count;
        }

        var queue_family_indices = [_]u32{
            device.graphics_queue_family,
            device.present_queue_family,
        };
        const separate_queue_families = device.graphics_queue_family != device.present_queue_family;
        const image_usage = imageUsageFromSurfaceUsage(desc.usage);
        const composite_alpha = chooseCompositeAlpha(support.capabilities.supported_composite_alpha, desc.alphaMode);

        const sci = vk.SwapchainCreateInfoKHR{
            .surface = self.handle,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = image_usage,
            .image_sharing_mode = if (separate_queue_families) .concurrent else .exclusive,
            .queue_family_index_count = if (separate_queue_families) queue_family_indices.len else 0,
            .p_queue_family_indices = if (separate_queue_families) &queue_family_indices else null,
            .pre_transform = support.capabilities.current_transform,
            .composite_alpha = composite_alpha,
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = .null_handle,
        };

        const swapchain = try device.device.createSwapchainKHR(&sci, null);
        errdefer device.device.destroySwapchainKHR(swapchain, null);

        const swapchain_images = try device.device.getSwapchainImagesAllocKHR(
            swapchain,
            std.heap.page_allocator,
        );
        errdefer std.heap.page_allocator.free(swapchain_images);

        self.swapchain_device = device;
        self.swapchain = swapchain;
        self.swapchain_images = swapchain_images;
        self.swapchain_image_format = surface_format.format;
        self.swapchain_extent = extent;

        // create swapchain image views
        var views = std.ArrayList(vk.ImageView).empty;
        errdefer {
            for (views.items) |view| {
                device.device.destroyImageView(view, null);
            }
            views.deinit(std.heap.page_allocator);
        }
        try views.ensureTotalCapacity(std.heap.page_allocator, swapchain_images.len);

        for (0..swapchain_images.len) |i| {
            const ivci: vk.ImageViewCreateInfo = .{
                .image = swapchain_images[i],
                .view_type = .@"2d",
                .format = surface_format.format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            const image_view = try device.device.createImageView(&ivci, null);
            try views.append(std.heap.page_allocator, image_view);
        }
        self.swapchain_image_views = try views.toOwnedSlice(std.heap.page_allocator);

        log.debug("configured vulkan swapchain: images={} format={s} extent={}x{}", .{
            swapchain_images.len,
            @tagName(surface_format.format),
            extent.width,
            extent.height,
        });
    }

    pub fn ensureSwapchainFramebuffers(self: *@This(), render_pass: vk.RenderPass) ![]const vk.Framebuffer {
        if (self.swapchain == .null_handle) {
            return error.SurfaceNotConfigured;
        }
        if (render_pass == .null_handle) {
            return error.InvalidRenderPass;
        }
        if (self.swapchain_framebuffers) |framebuffers| {
            if (self.swapchain_framebuffer_render_pass == render_pass) {
                return framebuffers;
            }
            self.destroySwapchainFramebuffers();
        }

        const device = self.swapchain_device orelse return error.SurfaceNotConfigured;
        const image_views = self.swapchain_image_views orelse return error.SurfaceNotConfigured;

        var framebuffers = try std.heap.page_allocator.alloc(vk.Framebuffer, image_views.len);
        errdefer {
            for (framebuffers) |framebuffer| {
                if (framebuffer != .null_handle) {
                    device.device.destroyFramebuffer(framebuffer, null);
                }
            }
            std.heap.page_allocator.free(framebuffers);
        }
        @memset(framebuffers, .null_handle);

        for (image_views, 0..) |image_view, i| {
            const attachments = [_]vk.ImageView{image_view};
            const create_info = vk.FramebufferCreateInfo{
                .render_pass = render_pass,
                .attachment_count = attachments.len,
                .p_attachments = &attachments,
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };
            framebuffers[i] = try device.device.createFramebuffer(&create_info, null);
        }

        self.swapchain_framebuffers = framebuffers;
        self.swapchain_framebuffer_render_pass = render_pass;
        log.debug("created vulkan swapchain framebuffers: count={} render_pass=0x{x} extent={}x{}", .{
            framebuffers.len,
            @intFromEnum(render_pass),
            self.swapchain_extent.width,
            self.swapchain_extent.height,
        });
        return framebuffers;
    }

    fn unconfigureSwapchain(self: *@This()) void {
        self.destroySwapchainFramebuffers();

        if (self.swapchain_image_views) |views| {
            for (views) |view| {
                if (self.swapchain_device) |device| {
                    log.debug("destroying vulkan swapchain image view: handle=0x{x}", .{@intFromEnum(view)});
                    device.device.destroyImageView(view, null);
                }
            }

            std.heap.page_allocator.free(views);
            self.swapchain_image_views = null;
        }

        if (self.swapchain_images) |images| {
            std.heap.page_allocator.free(images);
            self.swapchain_images = null;
        }

        if (self.swapchain != .null_handle) {
            if (self.swapchain_device) |device| {
                log.debug("destroying vulkan swapchain: handle=0x{x}", .{@intFromEnum(self.swapchain)});
                device.device.destroySwapchainKHR(self.swapchain, null);
            }
            self.swapchain = .null_handle;
        }

        self.swapchain_device = null;
        self.swapchain_image_format = .undefined;
        self.swapchain_extent = .{ .width = 0, .height = 0 };
    }

    fn destroySwapchainFramebuffers(self: *@This()) void {
        if (self.swapchain_framebuffers) |framebuffers| {
            if (self.swapchain_device) |device| {
                for (framebuffers) |framebuffer| {
                    if (framebuffer != .null_handle) {
                        log.debug("destroying vulkan framebuffer: handle=0x{x}", .{@intFromEnum(framebuffer)});
                        device.device.destroyFramebuffer(framebuffer, null);
                    }
                }
            }

            std.heap.page_allocator.free(framebuffers);
            self.swapchain_framebuffers = null;
        }
        self.swapchain_framebuffer_render_pass = .null_handle;
    }
};

fn querySwapChainSupport(
    instance: *instance_backend.vkInstance,
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !SwapChainSupportDetails {
    const capabilities = try instance.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(pdev, surface);
    const formats = try instance.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        pdev,
        surface,
        std.heap.page_allocator,
    );
    errdefer std.heap.page_allocator.free(formats);

    const present_modes = try instance.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        pdev,
        surface,
        std.heap.page_allocator,
    );
    errdefer std.heap.page_allocator.free(present_modes);

    return .{
        .capabilities = capabilities,
        .formats = formats,
        .present_modes = present_modes,
    };
}

fn chooseSwapSurfaceFormat(
    available_formats: []const vk.SurfaceFormatKHR,
    preferred_format: texture.Texture.Format,
) vk.SurfaceFormatKHR {
    const preferred_vk_format = textureFormatToVulkan(preferred_format) orelse .b8g8r8a8_srgb;
    for (available_formats) |available_format| {
        if (available_format.format == preferred_vk_format and
            available_format.color_space == .srgb_nonlinear_khr)
        {
            return available_format;
        }
    }

    for (available_formats) |available_format| {
        if (available_format.format == .b8g8r8a8_srgb and
            available_format.color_space == .srgb_nonlinear_khr)
        {
            return available_format;
        }
    }

    return available_formats[0];
}

fn chooseSwapPresentMode(
    available_present_modes: []const vk.PresentModeKHR,
    preferred_mode: texture.Surface.PresentMode,
) vk.PresentModeKHR {
    const preferred_vk_mode = presentModeToVulkan(preferred_mode);
    for (available_present_modes) |available_present_mode| {
        if (available_present_mode == preferred_vk_mode) {
            return available_present_mode;
        }
    }

    for (available_present_modes) |available_present_mode| {
        if (available_present_mode == .mailbox_khr) {
            return available_present_mode;
        }
    }

    return .fifo_khr;
}

fn chooseSwapExtent(
    capabilities: vk.SurfaceCapabilitiesKHR,
    desired_width: u32,
    desired_height: u32,
) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) {
        return capabilities.current_extent;
    }

    return .{
        .width = std.math.clamp(
            desired_width,
            capabilities.min_image_extent.width,
            capabilities.max_image_extent.width,
        ),
        .height = std.math.clamp(
            desired_height,
            capabilities.min_image_extent.height,
            capabilities.max_image_extent.height,
        ),
    };
}

fn chooseCompositeAlpha(
    supported: vk.CompositeAlphaFlagsKHR,
    preferred_mode: texture.Surface.AlphaMode,
) vk.CompositeAlphaFlagsKHR {
    switch (preferred_mode) {
        .@"opaque" => if (supported.opaque_bit_khr) return .{ .opaque_bit_khr = true },
        .premultiplied => if (supported.pre_multiplied_bit_khr) return .{ .pre_multiplied_bit_khr = true },
    }

    if (supported.opaque_bit_khr) return .{ .opaque_bit_khr = true };
    if (supported.pre_multiplied_bit_khr) return .{ .pre_multiplied_bit_khr = true };
    if (supported.post_multiplied_bit_khr) return .{ .post_multiplied_bit_khr = true };
    return .{ .inherit_bit_khr = true };
}

fn imageUsageFromSurfaceUsage(usage: texture.Texture.UsageFlags) vk.ImageUsageFlags {
    const typed = texture.Texture.Usage.fromFlags(usage);
    return .{
        .transfer_src_bit = typed.copy_src,
        .transfer_dst_bit = typed.copy_dst,
        .sampled_bit = typed.texture_binding,
        .storage_bit = typed.storage_binding,
        .color_attachment_bit = typed.render_attachment,
        .transient_attachment_bit = typed.transient_attachment,
    };
}

fn textureFormatFromVulkan(format: vk.Format) ?texture.Texture.Format {
    return switch (format) {
        .b8g8r8a8_unorm => .bgra8unorm,
        .b8g8r8a8_srgb => .bgra8unorm_srgb,
        .r8g8b8a8_unorm => .rgba8unorm,
        .r8g8b8a8_srgb => .rgba8unorm_srgb,
        else => null,
    };
}

fn textureFormatToVulkan(format: texture.Texture.Format) ?vk.Format {
    return switch (format) {
        .bgra8unorm => .b8g8r8a8_unorm,
        .bgra8unorm_srgb => .b8g8r8a8_srgb,
        .rgba8unorm => .r8g8b8a8_unorm,
        .rgba8unorm_srgb => .r8g8b8a8_srgb,
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

fn presentModeToVulkan(mode: texture.Surface.PresentMode) vk.PresentModeKHR {
    return switch (mode) {
        .fifo => .fifo_khr,
        .fifo_relaxed => .fifo_relaxed_khr,
        .immediate => .immediate_khr,
        .mailbox => .mailbox_khr,
    };
}
