//! The canvas swapchain.

const std = @import("std");
const c = @import("webgpu_c");
const swapchain_if = @import("../../interface/swapchain.zig");
const resource = @import("../../interface/resource.zig");
const sync = @import("../../interface/sync.zig");
const zeroInit = @import("utils.zig").zeroInit;
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
    config: c.WGPUSurfaceConfiguration,
    /// sRGB formats render through a view of the (never sRGB) canvas texture.
    view_format: c.WGPUTextureFormat,
    swapchain_format: swapchain_if.SwapchainFormat,
    image_count: u32,
    current: ?struct { texture: c.WGPUTexture, view: resource.TextureView } = null,

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
        const self = try allocator.create(WgpuSwapchain);
        self.* = .{
            .allocator = allocator,
            .device = device,
            .surface = surface,
            .view_format = view_format,
            .swapchain_format = desc.format,
            .image_count = desc.image_count,
            .config = zeroInit(c.WGPUSurfaceConfiguration, .{
                .device = device,
                .format = canvas_format,
                .usage = usage,
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

    fn releaseCurrent(self: *WgpuSwapchain) void {
        const current = self.current orelse return;
        current.view.deinit();
        c.wgpuTextureRelease(current.texture);
        self.current = null;
    }

    fn acquire(ptr: *anyopaque, _: ?sync.Semaphore) anyerror!swapchain_if.AcquireResult {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        self.releaseCurrent();
        var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        const status: swapchain_if.AcquireStatus = switch (surface_texture.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal => .optimal,
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal => .suboptimal,
            c.WGPUSurfaceGetCurrentTextureStatus_Timeout, c.WGPUSurfaceGetCurrentTextureStatus_Outdated, c.WGPUSurfaceGetCurrentTextureStatus_Lost => return error.OutOfDate,
            else => return error.AcquireFailed,
        };
        const texture = surface_texture.texture orelse return error.AcquireFailed;
        errdefer c.wgpuTextureRelease(texture);
        const raw_view = c.wgpuTextureCreateView(texture, &zeroInit(c.WGPUTextureViewDescriptor, .{
            .format = self.view_format,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .arrayLayerCount = 1,
            .aspect = c.WGPUTextureAspect_All,
        })) orelse return error.AcquireFailed;
        const view = try WgpuView.wrap(self.allocator, raw_view, self.view_format);
        self.current = .{ .texture = texture, .view = view };
        return .{ .index = 0, .view = view, .status = status };
    }

    fn present(ptr: *anyopaque, _: []const sync.Semaphore) anyerror!swapchain_if.PresentStatus {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        // The browser presents the canvas when this frame's callback returns.
        self.releaseCurrent();
        return .optimal;
    }

    fn resize(ptr: *anyopaque, extent: swapchain_if.Extent2D) anyerror!void {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        self.releaseCurrent();
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
        self.releaseCurrent();
        c.wgpuSurfaceUnconfigure(self.surface);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuDeviceRelease(self.device);
        allocator.destroy(self);
    }
};
