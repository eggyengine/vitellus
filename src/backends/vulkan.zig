//! Vulkan backend, powered by [Snektron/vulkan-zig].

pub const vk = @import("vulkan");

const gpu = @import("../types/gpu.zig");
const hal = @import("hal.zig");

pub const instance = @import("vulkan/instance.zig");
pub const surface = @import("vulkan/surface.zig");
pub const adapter = @import("vulkan/adapter.zig");
pub const device = @import("vulkan/device.zig");
pub const resource = @import("vulkan/resource.zig");
pub const shader = @import("vulkan/shader.zig");
pub const pipeline = @import("vulkan/pipeline.zig");
pub const command = @import("vulkan/command.zig");
pub const debug = @import("vulkan/debug.zig");

pub const InstanceDescriptor = instance.InstanceDescriptor;
pub const vkInstance = instance.vkInstance;

pub const vkAdapter = adapter.vkAdapter;

pub const vkSurface = surface.vkSurface;

pub const vkDevice = device.vkDevice;
pub const vkQueue = device.vkQueue;

pub const vkBuffer = resource.vkBuffer;
pub const vkTexture = resource.vkTexture;
pub const vkTextureView = resource.vkTextureView;
pub const vkExternalTexture = resource.vkExternalTexture;
pub const vkSampler = resource.vkSampler;
pub const vkBindGroupLayout = resource.vkBindGroupLayout;
pub const vkBindGroup = resource.vkBindGroup;
pub const vkQuerySet = resource.vkQuerySet;

pub const vkShader = shader.vkShader;
pub const vkShaderModule = shader.vkShaderModule;

pub const vkPipelineLayout = pipeline.vkPipelineLayout;
pub const vkComputePipeline = pipeline.vkComputePipeline;
pub const vkRenderPipeline = pipeline.vkRenderPipeline;

pub const vkCommandBuffer = command.vkCommandBuffer;
pub const vkCommandEncoder = command.vkCommandEncoder;
pub const vkComputePassEncoder = command.vkComputePassEncoder;
pub const vkRenderPassEncoder = command.vkRenderPassEncoder;
pub const vkRenderBundle = command.vkRenderBundle;
pub const vkRenderBundleEncoder = command.vkRenderBundleEncoder;

pub fn init(descriptor: gpu.Instance.Descriptor) hal.Instance.FromPotentialBackendsError!hal.Instance {
    return vkInstance.initWithDescriptor(descriptor.allocator, .{
        .enable_validation = descriptor.flags.validation,
    }) catch error.NoBackendAvailable;
}
