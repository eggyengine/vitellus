const std = @import("std");
const vk = @import("vulkan");
const swapchain_interface = @import("../../interface/swapchain.zig");
const Swapchain = swapchain_interface.Swapchain;
const SwapchainDescriptor = swapchain_interface.SwapchainDescriptor;
const resource = @import("../../interface/resource.zig");
const resource_impl = @import("resource.zig");
const sync = @import("../../interface/sync.zig");
const sync_impl = @import("sync.zig");
const vkAdapter = @import("adapter.zig").vkAdapter;
const vkQueue = @import("queue.zig").vkQueue;
const surface_impl = @import("surface.zig");

const log = std.log.scoped(.vk_swapchain);

pub const vkSwapchain = struct {
    allocator: std.mem.Allocator,
    adapter: *vkAdapter,
    queue: *vkQueue,
    surface: vk.SurfaceKHR,
    handle: vk.SwapchainKHR = .null_handle,
    images: []vk.Image = &.{},
    image_views: []vk.ImageView = &.{},
    view_impls: []resource_impl.vkTextureView = &.{},
    views: []resource.TextureView = &.{},
    acquire_fence: vk.Fence = .null_handle,
    current_image: ?u32 = null,
    extent: swapchain_interface.Extent2D,
    format: swapchain_interface.SwapchainFormat,
    color_space: swapchain_interface.SwapchainColorSpace,
    present_mode: swapchain_interface.PresentMode,
    composite_alpha: swapchain_interface.CompositeAlpha,
    usage: swapchain_interface.ImageUsage,
    requested_image_count: u32,
    label: ?[]u8 = null,

    const vtable: Swapchain.VTable = .{
        .deinitFn = deinitImpl,
        .acquireNextImageFn = acquireNextImageImpl,
        .presentFn = presentImpl,
        .resizeFn = resizeImpl,
        .infoFn = infoImpl,
    };
    pub fn init(adapter_ptr: *anyopaque, allocator: std.mem.Allocator, desc: SwapchainDescriptor) !Swapchain {
        const adapter: *vkAdapter = @ptrCast(@alignCast(adapter_ptr));
        const queue: *vkQueue = @ptrCast(@alignCast(desc.queue.ptr));
        const surface = try surface_impl.create(adapter.instance, desc.window);
        errdefer adapter.instance.wrapper.destroySurfaceKHR(adapter.instance.instance, surface, null);
        if (try adapter.instance.wrapper.getPhysicalDeviceSurfaceSupportKHR(
            adapter.physical_device,
            queue.family_index,
            surface,
        ) == .false) return error.QueueCannotPresent;

        const self = try allocator.create(vkSwapchain);
        self.* = .{
            .allocator = allocator,
            .adapter = adapter,
            .queue = queue,
            .surface = surface,
            .extent = desc.extent,
            .format = desc.format,
            .color_space = desc.color_space,
            .present_mode = desc.present_mode,
            .composite_alpha = desc.composite_alpha,
            .usage = desc.usage,
            .requested_image_count = desc.image_count,
        };
        errdefer {
            if (self.label) |label| allocator.free(label);
            allocator.destroy(self);
        }
        self.label = if (desc.label) |label| try allocator.dupe(u8, label) else null;
        self.acquire_fence = try queue.device.createFence(&.{}, null);
        errdefer queue.device.destroyFence(self.acquire_fence, null);
        try self.recreate(desc.extent);

        log.debug("created Vulkan swapchain with {} images at {}x{}", .{ self.images.len, self.extent.width, self.extent.height });
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *vkSwapchain = @ptrCast(@alignCast(ptr));
        _ = self.queue.device.deviceWaitIdle() catch {};
        self.releaseImages();
        if (self.handle != .null_handle) self.queue.device.destroySwapchainKHR(self.handle, null);
        if (self.acquire_fence != .null_handle) self.queue.device.destroyFence(self.acquire_fence, null);
        self.adapter.instance.wrapper.destroySurfaceKHR(self.adapter.instance.instance, self.surface, null);
        if (self.label) |label| allocator.free(label);
        allocator.destroy(self);
        log.debug("destroyed Vulkan swapchain", .{});
    }

    fn acquireNextImageImpl(ptr: *anyopaque, signal: ?sync.Semaphore) anyerror!swapchain_interface.AcquireResult {
        const self: *vkSwapchain = @ptrCast(@alignCast(ptr));
        const semaphore: vk.Semaphore = if (signal) |value| try sync_impl.rawSemaphore(value) else .null_handle;
        const fence: vk.Fence = if (signal == null) self.acquire_fence else .null_handle;
        const acquired = while (true) {
            break self.queue.device.acquireNextImageKHR(self.handle, std.math.maxInt(u64), semaphore, fence) catch |err| switch (err) {
                error.OutOfDateKHR => {
                    try resizeImpl(ptr, self.extent);
                    continue;
                },
                else => return err,
            };
        };
        if (signal == null) {
            _ = try self.queue.device.waitForFences(&.{self.acquire_fence}, .true, std.math.maxInt(u64));
            try self.queue.device.resetFences(&.{self.acquire_fence});
        }
        if (acquired.image_index >= self.views.len) return error.InvalidSwapchainImageIndex;
        self.current_image = acquired.image_index;
        return .{
            .index = acquired.image_index,
            .view = self.views[acquired.image_index],
            .status = if (acquired.result == .suboptimal_khr) .suboptimal else .optimal,
        };
    }

    fn presentImpl(ptr: *anyopaque, waits: []const sync.Semaphore) anyerror!swapchain_interface.PresentStatus {
        const self: *vkSwapchain = @ptrCast(@alignCast(ptr));
        const image_index = self.current_image orelse return error.NoAcquiredImage;
        const semaphores = try self.allocator.alloc(vk.Semaphore, waits.len);
        defer self.allocator.free(semaphores);
        for (waits, semaphores) |wait, *semaphore| semaphore.* = try sync_impl.rawSemaphore(wait);
        // ponytail: main currently presents without a binary render-finished semaphore.
        // Serialize that compatibility path until the public API supplies one.
        if (waits.len == 0) try self.queue.device.queueWaitIdle(self.queue.queue);
        const swapchains = [_]vk.SwapchainKHR{self.handle};
        const indices = [_]u32{image_index};

        const result = self.queue.device.queuePresentKHR(self.queue.queue, &.{
            .wait_semaphore_count = @intCast(semaphores.len),
            .p_wait_semaphores = if (semaphores.len == 0) null else semaphores.ptr,
            .swapchain_count = 1,
            .p_swapchains = &swapchains,
            .p_image_indices = &indices,
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.current_image = null;
                try resizeImpl(ptr, self.extent);
                return .suboptimal;
            },
            else => return err,
        };
        self.current_image = null;
        if (result == .suboptimal_khr) {
            try resizeImpl(ptr, self.extent);
            return .suboptimal;
        }
        return .optimal;
    }

    fn resizeImpl(ptr: *anyopaque, extent: swapchain_interface.Extent2D) anyerror!void {
        const self: *vkSwapchain = @ptrCast(@alignCast(ptr));
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        try self.queue.device.deviceWaitIdle();
        try self.recreate(extent);
        self.current_image = null;
    }

    fn infoImpl(ptr: *anyopaque) swapchain_interface.SwapchainInfo {
        const self: *vkSwapchain = @ptrCast(@alignCast(ptr));
        return .{ .extent = self.extent, .format = self.format, .image_count = @intCast(self.images.len) };
    }

    fn recreate(self: *vkSwapchain, requested_extent: swapchain_interface.Extent2D) !void {
        const instance = self.adapter.instance;
        const caps = try instance.wrapper.getPhysicalDeviceSurfaceCapabilitiesKHR(self.adapter.physical_device, self.surface);
        const supported = try surface_impl.query(instance, self.adapter.physical_device, self.allocator, self.surface);
        defer supported.deinit();
        if (!containsFormat(supported.formats, self.format)) return error.UnsupportedSwapchainFormat;
        if (!containsPresentMode(supported.present_modes, self.present_mode)) return error.UnsupportedPresentMode;
        if (!containsCompositeAlpha(supported.composite_alpha, self.composite_alpha)) return error.UnsupportedCompositeAlpha;

        const usage = toVkUsage(self.usage);
        if (!caps.supported_usage_flags.contains(usage)) return error.UnsupportedImageUsage;
        const extent = chooseExtent(caps, requested_extent);
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        var image_count = @max(self.requested_image_count, caps.min_image_count);
        if (caps.max_image_count != 0) image_count = @min(image_count, caps.max_image_count);

        const new_handle = try self.queue.device.createSwapchainKHR(&.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = surface_impl.toVkFormat(self.format),
            .image_color_space = .srgb_nonlinear_khr,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = usage,
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = surface_impl.toVkCompositeAlpha(self.composite_alpha),
            .present_mode = surface_impl.toVkPresentMode(self.present_mode),
            .clipped = .true,
            .old_swapchain = self.handle,
        }, null);
        errdefer self.queue.device.destroySwapchainKHR(new_handle, null);

        const new_images = try self.queue.device.getSwapchainImagesAllocKHR(new_handle, self.allocator);
        errdefer self.allocator.free(new_images);
        const new_image_views = try self.allocator.alloc(vk.ImageView, new_images.len);
        errdefer self.allocator.free(new_image_views);
        var created_views: usize = 0;
        errdefer for (new_image_views[0..created_views]) |view| self.queue.device.destroyImageView(view, null);
        const new_views = try self.allocator.alloc(resource.TextureView, new_images.len);
        errdefer self.allocator.free(new_views);
        const new_view_impls = try self.allocator.alloc(resource_impl.vkTextureView, new_images.len);
        errdefer self.allocator.free(new_view_impls);

        for (new_images, 0..) |image, index| {
            const view = try self.queue.device.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = surface_impl.toVkFormat(self.format),
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
            new_image_views[index] = view;
            new_view_impls[index] = .{
                .view = view,
                .image = image,
                .format = surface_impl.toVkFormat(self.format),
                .extent = extent,
            };
            new_views[index] = .{
                .handle = @intCast(@intFromPtr(&new_view_impls[index])),
                .vtable = &resource_impl.borrowed_texture_view_vtable,
            };
            created_views += 1;
        }

        self.releaseImages();
        if (self.handle != .null_handle) self.queue.device.destroySwapchainKHR(self.handle, null);
        self.handle = new_handle;
        self.images = new_images;
        self.image_views = new_image_views;
        self.view_impls = new_view_impls;
        self.views = new_views;
        self.extent = .{ .width = extent.width, .height = extent.height };
        self.adapter.instance.nameObject(
            self.allocator,
            self.queue.device,
            .swapchain_khr,
            @intFromEnum(self.handle),
            self.label,
        );
    }

    fn releaseImages(self: *vkSwapchain) void {
        for (self.image_views) |view| self.queue.device.destroyImageView(view, null);
        if (self.image_views.len != 0) self.allocator.free(self.image_views);
        if (self.images.len != 0) self.allocator.free(self.images);
        if (self.view_impls.len != 0) self.allocator.free(self.view_impls);
        if (self.views.len != 0) self.allocator.free(self.views);
        self.image_views = &.{};
        self.images = &.{};
        self.view_impls = &.{};
        self.views = &.{};
    }
};

fn toVkUsage(usage: swapchain_interface.ImageUsage) vk.ImageUsageFlags {
    return .{
        .color_attachment_bit = usage.render_target,
        .sampled_bit = usage.sampled,
        .transfer_src_bit = usage.transfer_src,
        .transfer_dst_bit = usage.transfer_dst,
    };
}

fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR, requested: swapchain_interface.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    return .{
        .width = std.math.clamp(requested.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(requested.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn containsFormat(values: []const swapchain_interface.SwapchainFormat, value: swapchain_interface.SwapchainFormat) bool {
    for (values) |candidate| if (candidate == value) return true;
    return false;
}

fn containsPresentMode(values: []const swapchain_interface.PresentMode, value: swapchain_interface.PresentMode) bool {
    for (values) |candidate| if (candidate == value) return true;
    return false;
}

fn containsCompositeAlpha(values: []const swapchain_interface.CompositeAlpha, value: swapchain_interface.CompositeAlpha) bool {
    for (values) |candidate| if (candidate == value) return true;
    return false;
}
