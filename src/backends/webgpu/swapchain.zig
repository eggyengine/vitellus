//! The canvas swapchain. Frames draw into an image of our own, copied onto the canvas at
//! present: the canvas's texture expires whenever the frame yields to the browser, which any
//! GPU wait mid-frame does.

const std = @import("std");
const c = @import("webgpu_c");
const swapchain_if = @import("../../interface/swapchain.zig");
const resource = @import("../../interface/resource.zig");
const sync = @import("../../interface/sync.zig");
const zeroInit = @import("utils.zig").zeroInit;
const str = @import("utils.zig").str;
const swapchainTextureFormat = @import("utils.zig").swapchainTextureFormat;
const aspect = @import("utils.zig").aspect;
const WgpuAdapter = @import("adapter.zig").WgpuAdapter;
const createSurface = @import("adapter.zig").createSurface;
const WgpuView = @import("resource.zig").WgpuView;
const WgpuQueue = @import("queue.zig").WgpuQueue;

pub const WgpuSwapchain = struct {
    allocator: std.mem.Allocator,
    device: c.WGPUDevice,
    surface: c.WGPUSurface,
    queue: c.WGPUQueue,
    config: c.WGPUSurfaceConfiguration,
    /// The usage asked for, given to the image frames draw into.
    image_usage: c.WGPUTextureUsage,
    /// sRGB formats render through a view of the (never sRGB) canvas texture.
    view_format: c.WGPUTextureFormat,
    swapchain_format: swapchain_if.SwapchainFormat,
    image_count: u32,
    image: ?struct { texture: c.WGPUTexture, view: resource.TextureView } = null,

    const vtable: swapchain_if.Swapchain.VTable = .{
        .deinitFn = deinit,
        .acquireNextImageFn = acquire,
        .presentFn = present,
        .resizeFn = resize,
        .infoFn = info,
    };

    pub fn create(ptr: *anyopaque, allocator: std.mem.Allocator, desc: swapchain_if.SwapchainDescriptor) anyerror!swapchain_if.Swapchain {
        const adapter: *WgpuAdapter = @ptrCast(@alignCast(ptr));
        const queue: *WgpuQueue = @ptrCast(@alignCast(desc.queue.ptr));
        const device = queue.device;
        c.wgpuDeviceAddRef(device);
        errdefer c.wgpuDeviceRelease(device);
        const surface = try createSurface(adapter.instance);
        errdefer c.wgpuSurfaceRelease(surface);
        const view_format = swapchainTextureFormat(desc.format);
        const canvas_format: c.WGPUTextureFormat = switch (desc.format) {
            .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8Unorm,
            .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8Unorm,
            else => view_format,
        };
        var usage: c.WGPUTextureUsage = c.WGPUTextureUsage_None;
        if (desc.usage.render_target) usage |= c.WGPUTextureUsage_RenderAttachment;
        if (desc.usage.sampled) usage |= c.WGPUTextureUsage_TextureBinding;
        if (desc.usage.transfer_src) usage |= c.WGPUTextureUsage_CopySrc;
        if (desc.usage.transfer_dst) usage |= c.WGPUTextureUsage_CopyDst;
        c.wgpuQueueAddRef(queue.handle);
        errdefer c.wgpuQueueRelease(queue.handle);
        const self = try allocator.create(WgpuSwapchain);
        self.* = .{
            .allocator = allocator,
            .device = device,
            .surface = surface,
            .queue = queue.handle,
            .image_usage = usage | c.WGPUTextureUsage_CopySrc,
            .view_format = view_format,
            .swapchain_format = desc.format,
            .image_count = desc.image_count,
            .config = zeroInit(c.WGPUSurfaceConfiguration, .{
                .device = device,
                .format = canvas_format,
                .usage = c.WGPUTextureUsage_CopyDst,
                .width = desc.extent.width,
                .height = desc.extent.height,
                .alphaMode = switch (desc.composite_alpha) {
                    .opaque_alpha => c.WGPUCompositeAlphaMode_Opaque,
                    .premultiplied => c.WGPUCompositeAlphaMode_Premultiplied,
                    .postmultiplied, .inherit => c.WGPUCompositeAlphaMode_Auto,
                },
                .presentMode = c.WGPUPresentMode_Fifo, // the only mode a canvas has
            }),
        };
        if (view_format != canvas_format) {
            self.config.viewFormatCount = 1;
            self.config.viewFormats = &self.view_format;
        }
        c.wgpuSurfaceConfigure(surface, &self.config);
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn releaseImage(self: *WgpuSwapchain) void {
        const image = self.image orelse return;
        image.view.deinit();
        c.wgpuTextureRelease(image.texture);
        self.image = null;
    }

    fn acquire(ptr: *anyopaque, _: ?sync.Semaphore) anyerror!swapchain_if.AcquireResult {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        if (self.image) |image| return .{ .index = 0, .view = image.view, .status = .optimal };
        // Made at the canvas's size on first use after a resize, and kept until the next one.
        const texture = c.wgpuDeviceCreateTexture(self.device, &zeroInit(c.WGPUTextureDescriptor, .{
            .usage = self.image_usage,
            .dimension = c.WGPUTextureDimension_2D,
            .size = c.WGPUExtent3D{ .width = self.config.width, .height = self.config.height, .depthOrArrayLayers = 1 },
            .format = self.config.format,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = self.config.viewFormatCount,
            .viewFormats = self.config.viewFormats,
        })) orelse return error.AcquireFailed;
        errdefer c.wgpuTextureRelease(texture);
        const raw_view = c.wgpuTextureCreateView(texture, &zeroInit(c.WGPUTextureViewDescriptor, .{
            .format = self.view_format,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .arrayLayerCount = 1,
            .aspect = c.WGPUTextureAspect_All,
        })) orelse return error.AcquireFailed;
        const view = try WgpuView.wrap(self.allocator, raw_view, self.view_format);
        self.image = .{ .texture = texture, .view = view };
        return .{ .index = 0, .view = view, .status = .optimal };
    }

    fn present(ptr: *anyopaque, _: []const sync.Semaphore) anyerror!swapchain_if.PresentStatus {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        const image = self.image orelse return .optimal;
        var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        switch (surface_texture.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal, c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal => {},
            c.WGPUSurfaceGetCurrentTextureStatus_Timeout, c.WGPUSurfaceGetCurrentTextureStatus_Outdated, c.WGPUSurfaceGetCurrentTextureStatus_Lost => {
                // This frame is dropped; the canvas is reconfigured for the next.
                c.wgpuSurfaceConfigure(self.surface, &self.config);
                return .suboptimal;
            },
            else => return error.PresentFailed,
        }
        const canvas = surface_texture.texture orelse return error.PresentFailed;
        defer c.wgpuTextureRelease(canvas);
        // Queued after the frame's own submit, so it copies the finished image; the browser
        // shows the canvas when this frame's callback returns.
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &.{ .nextInChain = null, .label = str(null) }) orelse return error.PresentFailed;
        defer c.wgpuCommandEncoderRelease(encoder);
        c.wgpuCommandEncoderCopyTextureToTexture(
            encoder,
            &zeroInit(c.WGPUTexelCopyTextureInfo, .{ .texture = image.texture, .aspect = c.WGPUTextureAspect_All }),
            &zeroInit(c.WGPUTexelCopyTextureInfo, .{ .texture = canvas, .aspect = c.WGPUTextureAspect_All }),
            &.{ .width = self.config.width, .height = self.config.height, .depthOrArrayLayers = 1 },
        );
        const commands = c.wgpuCommandEncoderFinish(encoder, &.{ .nextInChain = null, .label = str(null) }) orelse return error.PresentFailed;
        defer c.wgpuCommandBufferRelease(commands);
        c.wgpuQueueSubmit(self.queue, 1, &commands);
        return .optimal;
    }

    fn resize(ptr: *anyopaque, extent: swapchain_if.Extent2D) anyerror!void {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        self.releaseImage();
        self.config.width = extent.width;
        self.config.height = extent.height;
        c.wgpuSurfaceConfigure(self.surface, &self.config);
    }

    fn info(ptr: *anyopaque) swapchain_if.SwapchainInfo {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        return .{
            .extent = .{ .width = self.config.width, .height = self.config.height },
            .format = self.swapchain_format,
            .image_count = self.image_count,
        };
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        self.releaseImage();
        c.wgpuQueueRelease(self.queue);
        c.wgpuSurfaceUnconfigure(self.surface);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuDeviceRelease(self.device);
        allocator.destroy(self);
    }
};
