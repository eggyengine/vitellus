const std = @import("std");
const adapter_interface = @import("../../interface/adapter.zig");
const Adapter = adapter_interface.Adapter;
const AdapterDescriptor = adapter_interface.AdapterDescriptor;
const AdapterInfo = adapter_interface.AdapterInfo;
const Device = @import("../../interface/device.zig").Device;
const DeviceDescriptor = @import("../../interface/device.zig").DeviceDescriptor;
const resource = @import("../../interface/resource.zig");
const Swapchain = @import("../../interface/swapchain.zig").Swapchain;
const SwapchainDescriptor = @import("../../interface/swapchain.zig").SwapchainDescriptor;
const Window = @import("../../windowing/windowing.zig").Window;
const vkInstance = @import("instance.zig").vkInstance;

const log = std.log.scoped(.vk_adapter);

pub const vkAdapter = struct {
    instance: *vkInstance,

    const vtable: Adapter.VTable = .{
        .deinitFn = deinitImpl,
        .infoFn = infoImpl,
        .createDeviceFn = createDeviceImpl,
        .createSwapchainFn = createSwapchainImpl,
        .capabilitiesFn = capabilitiesImpl,
        .formatCapabilitiesFn = formatCapabilitiesImpl,
        .surfaceCapabilitiesFn = surfaceCapabilitiesImpl,
    };

    pub fn init(instance_ptr: *anyopaque, allocator: std.mem.Allocator, _: AdapterDescriptor) !Adapter {
        const instance: *vkInstance = @ptrCast(@alignCast(instance_ptr));
        const self = try allocator.create(vkAdapter);
        self.* = .{ .instance = instance };

        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *vkAdapter = @ptrCast(@alignCast(ptr));

        log.debug("destroyed vulkan adapter", .{});
        allocator.destroy(self);
    }

    fn infoImpl(_: *anyopaque) AdapterInfo {
        return .{};
    }

    fn capabilitiesImpl(_: *anyopaque) adapter_interface.AdapterCapabilities {
        return .{};
    }

    fn formatCapabilitiesImpl(_: *anyopaque, _: resource.Format) adapter_interface.FormatCapabilities {
        return .{};
    }

    fn surfaceCapabilitiesImpl(_: *anyopaque, _: std.mem.Allocator, _: Window) !adapter_interface.SurfaceCapabilities {
        return error.VulkanSurfaceCapabilitiesNotImplemented;
    }

    fn createDeviceImpl(_: *anyopaque, _: std.mem.Allocator, _: DeviceDescriptor) anyerror!Device {
        return error.VulkanDeviceNotImplemented;
    }

    fn createSwapchainImpl(_: *anyopaque, _: std.mem.Allocator, _: SwapchainDescriptor) anyerror!Swapchain {
        return error.VulkanSwapchainNotImplemented;
    }
};
