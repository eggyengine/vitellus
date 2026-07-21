pub const vk = @import("vulkan");

pub const instance = @import("vulkan/instance.zig");
pub const adapter = @import("vulkan/adapter.zig");
pub const debug = @import("vulkan/debug.zig");
pub const swapchain = @import("vulkan/swapchain.zig");
pub const queue = @import("vulkan/queue.zig");
pub const sync = @import("vulkan/sync.zig");
pub const device = @import("vulkan/device.zig");
pub const shader = @import("vulkan/shader.zig");
pub const resource = @import("vulkan/resource.zig");
pub const binding = @import("vulkan/binding.zig");
pub const pipeline = @import("vulkan/pipeline.zig");
pub const command = @import("vulkan/command.zig");

pub const spirv = @import("vulkan/spirv.zig");
pub const SPIRVShaderModule = spirv.SPIRVShaderModule;
