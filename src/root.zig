pub const hal = struct {
    pub const adapter = @import("interface/adapter.zig");
    pub const device = @import("interface/device.zig");
    pub const queue = @import("interface/queue.zig");
    pub const settings = @import("interface/settings.zig");
    pub const swapchain = @import("interface/swapchain.zig");
};

pub const candler = @import("candler");

pub const windowing = struct {
    pub const Window = @import("windowing/windowing.zig").Window;
    pub const sdl3 = @import("windowing/sdl3.zig");
};

pub const backends = struct {
    pub const dx12 = @import("backends/dx12.zig");
};

pub const Adapter = hal.adapter.Adapter;
pub const AdapterInfo = hal.adapter.AdapterInfo;
pub const Device = hal.device.Device;
pub const DeviceDescriptor = hal.device.DeviceDescriptor;
pub const Queue = hal.queue.Queue;
pub const QueueDescriptor = hal.queue.QueueDescriptor;
pub const Swapchain = hal.swapchain.Swapchain;
pub const SwapchainDescriptor = hal.swapchain.SwapchainDescriptor;
pub const SwapchainFormat = hal.swapchain.SwapchainFormat;
pub const SwapchainColorSpace = hal.swapchain.SwapchainColorSpace;
pub const PresentMode = hal.swapchain.PresentMode;
pub const CompositeAlpha = hal.swapchain.CompositeAlpha;
pub const ImageUsage = hal.swapchain.ImageUsage;
pub const Extent2D = hal.swapchain.Extent2D;
pub const Window = windowing.Window;
pub const Config = hal.settings.VitellusConfig;
