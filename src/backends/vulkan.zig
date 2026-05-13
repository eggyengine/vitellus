//! Vulkan backend, powered by [Snektron/vulkan-zig].
//!
//! This file is intentionally a small facade. Backend implementation is split
//! by Vulkan object lifetime in `backends/vulkan/`.

pub const vk = @import("vulkan");

pub const instance = @import("vulkan/instance.zig");
pub const surface = @import("vulkan/surface.zig");
pub const adapter = @import("vulkan/adapter.zig");
pub const device = @import("vulkan/device.zig");

pub const InstanceDescriptor = instance.InstanceDescriptor;
pub const vkInstance = instance.vkInstance;

pub const QueueFamilyIndices = adapter.QueueFamilyIndices;
pub const findQueueFamilies = adapter.findQueueFamilies;
pub const isDeviceSuitable = adapter.isDeviceSuitable;
pub const isPhysicalDeviceSurfaceSupported = adapter.isPhysicalDeviceSurfaceSupported;
pub const vkAdapter = adapter.vkAdapter;

pub const vkSurface = surface.vkSurface;

pub const vkDevice = device.vkDevice;
pub const vkQueue = device.vkQueue;
