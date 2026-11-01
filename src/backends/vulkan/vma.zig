//! Sub-allocates Vulkan buffer and image memory from large blocks with the Vulkan Memory Allocator (`vma.cpp`).
const vk = @import("vulkan");

pub const Allocator = *opaque {};
pub const Allocation = *opaque {};

/// How the CPU uses a buffer's memory; matches `VitHostAccess` in `vma.cpp`.
pub const HostAccess = enum(c_int) { none = 0, write = 1, read = 2 };

/// A buffer and its memory. `mapped` is the whole buffer when `HostAccess` isn't `.none`.
pub const Buffer = struct {
    buffer: vk.Buffer,
    allocation: Allocation,
    mapped: ?[*]u8,
};

/// An image and its memory.
pub const Image = struct {
    image: vk.Image,
    allocation: Allocation,
};

/// The allocator for `device`; destroy it before the device, after every buffer and image it made.
pub fn createAllocator(
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    api_version: u32,
    get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    get_device_proc_addr: vk.PfnGetDeviceProcAddr,
) !Allocator {
    var allocator: ?Allocator = null;
    try check(vit_vma_create_allocator(instance, physical_device, device, api_version, get_instance_proc_addr, get_device_proc_addr, &allocator));
    return allocator orelse error.InitializationFailed;
}

pub fn destroyAllocator(allocator: Allocator) void {
    vit_vma_destroy_allocator(allocator);
}

pub fn createBuffer(allocator: Allocator, info: *const vk.BufferCreateInfo, host_access: HostAccess) !Buffer {
    var buffer: vk.Buffer = .null;
    var allocation: ?Allocation = null;
    var mapped: ?*anyopaque = null;
    try check(vit_vma_create_buffer(allocator, info, host_access, &buffer, &allocation, &mapped));
    return .{ .buffer = buffer, .allocation = allocation.?, .mapped = @ptrCast(mapped) };
}

pub fn destroyBuffer(allocator: Allocator, buffer: vk.Buffer, allocation: Allocation) void {
    vit_vma_destroy_buffer(allocator, buffer, allocation);
}

pub fn createImage(allocator: Allocator, info: *const vk.ImageCreateInfo) !Image {
    var image: vk.Image = .null;
    var allocation: ?Allocation = null;
    try check(vit_vma_create_image(allocator, info, &image, &allocation));
    return .{ .image = image, .allocation = allocation.? };
}

pub fn destroyImage(allocator: Allocator, image: vk.Image, allocation: Allocation) void {
    vit_vma_destroy_image(allocator, image, allocation);
}

fn check(result: vk.Result) !void {
    return switch (result) {
        .success => {},
        .error_out_of_host_memory => error.OutOfHostMemory,
        .error_out_of_device_memory => error.OutOfDeviceMemory,
        .error_feature_not_present => error.FeatureNotPresent,
        .error_initialization_failed => error.InitializationFailed,
        else => error.Unknown,
    };
}

extern fn vit_vma_create_allocator(vk.Instance, vk.PhysicalDevice, vk.Device, u32, vk.PfnGetInstanceProcAddr, vk.PfnGetDeviceProcAddr, *?Allocator) vk.Result;
extern fn vit_vma_destroy_allocator(Allocator) void;
extern fn vit_vma_create_buffer(Allocator, *const vk.BufferCreateInfo, HostAccess, *vk.Buffer, *?Allocation, *?*anyopaque) vk.Result;
extern fn vit_vma_destroy_buffer(Allocator, vk.Buffer, Allocation) void;
extern fn vit_vma_create_image(Allocator, *const vk.ImageCreateInfo, *vk.Image, *?Allocation) vk.Result;
extern fn vit_vma_destroy_image(Allocator, vk.Image, Allocation) void;
