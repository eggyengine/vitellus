//! Window presentation and swapchain-image acquisition.

const std = @import("std");
const Queue = @import("queue.zig").Queue;
const Window = @import("../windowing/windowing.zig").Window;
const resource = @import("resource.zig");
const sync = @import("sync.zig");

/// Two-dimensional pixel extent.
pub const Extent2D = struct {
    width: u32 = 0,
    height: u32 = 0,
};

/// Formats supported by presentation swapchains.
pub const SwapchainFormat = enum {
    bgra8_unorm,
    bgra8_unorm_srgb,
    rgba8_unorm,
    rgba8_unorm_srgb,
    rgba16_float,
};

/// Colour-space encoding used when presenting.
pub const SwapchainColorSpace = enum {
    srgb_nonlinear,
};

/// Scheduling policy for displaying completed images.
pub const PresentMode = enum {
    immediate,
    mailbox,
    fifo,
    fifo_relaxed,
};

/// How swapchain alpha combines with other window-system content.
pub const CompositeAlpha = enum {
    opaque_alpha,
    premultiplied,
    postmultiplied,
    inherit,
};

/// Operations permitted on swapchain images.
pub const ImageUsage = packed struct(u32) {
    render_target: bool = true,
    sampled: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _pad: u28 = 0,
};

/// Window, queue, format, and scheduling used to create a swapchain.
pub const SwapchainDescriptor = struct {
    window: Window,
    queue: Queue,
    extent: Extent2D = .{},
    format: SwapchainFormat = .bgra8_unorm,
    color_space: SwapchainColorSpace = .srgb_nonlinear,
    present_mode: PresentMode = .fifo,
    composite_alpha: CompositeAlpha = .opaque_alpha,
    usage: ImageUsage = .{},
    image_count: u32 = 2,
};
pub const AcquireStatus = enum { optimal, suboptimal, occluded };
pub const PresentStatus = enum { optimal, suboptimal, occluded };
pub const AcquireResult = struct { index: u32, view: resource.TextureView, status: AcquireStatus = .optimal };
pub const SwapchainInfo = struct { extent: Extent2D, format: SwapchainFormat, image_count: u32 };

/// Owning handle to a window presentation chain.
///
/// Destroy all work using its images before calling `deinit`.
pub const Swapchain = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        acquireNextImageFn: ?*const fn (*anyopaque, ?sync.Semaphore) anyerror!AcquireResult = null,
        presentFn: ?*const fn (*anyopaque, []const sync.Semaphore) anyerror!PresentStatus = null,
        resizeFn: ?*const fn (*anyopaque, Extent2D) anyerror!void = null,
        infoFn: ?*const fn (*anyopaque) SwapchainInfo = null,
    };

    pub fn init(adapter: anytype, desc: SwapchainDescriptor) !Swapchain {
        return adapter.vtable.createSwapchainFn(adapter.ptr, adapter.allocator, desc);
    }

    /// Releases the swapchain and its images.
    pub fn deinit(self: Swapchain) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
    /// Acquires the image that should receive the next rendered frame.
    /// Optionally signals `signal` when that image is available.
    pub fn acquireNextImage(self: Swapchain, signal: ?sync.Semaphore) !AcquireResult {
        return if (self.vtable.acquireNextImageFn) |f| f(self.ptr, signal) else error.Unsupported;
    }
    /// Presents the current image after all synchronisation objects in `waits`.
    pub fn present(self: Swapchain, waits: []const sync.Semaphore) !PresentStatus {
        return if (self.vtable.presentFn) |f| f(self.ptr, waits) else error.Unsupported;
    }
    pub fn resize(self: Swapchain, extent: Extent2D) !void {
        return if (self.vtable.resizeFn) |f| f(self.ptr, extent) else error.Unsupported;
    }
    pub fn info(self: Swapchain) SwapchainInfo {
        return if (self.vtable.infoFn) |f| f(self.ptr) else .{ .extent = .{}, .format = .bgra8_unorm, .image_count = 0 };
    }
};
