const std = @import("std");
const Queue = @import("queue.zig").Queue;
const Window = @import("../windowing/windowing.zig").Window;

pub const Extent2D = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const SwapchainFormat = enum {
    bgra8_unorm,
    bgra8_unorm_srgb,
    rgba8_unorm,
    rgba8_unorm_srgb,
    rgba16_float,
};

pub const SwapchainColorSpace = enum {
    srgb_nonlinear,
};

pub const PresentMode = enum {
    immediate,
    mailbox,
    fifo,
    fifo_relaxed,
};

pub const CompositeAlpha = enum {
    opaque_alpha,
    premultiplied,
    postmultiplied,
    inherit,
};

pub const ImageUsage = packed struct(u32) {
    render_target: bool = true,
    sampled: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _pad: u28 = 0,
};

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

pub const Swapchain = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn deinit(self: Swapchain) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};
