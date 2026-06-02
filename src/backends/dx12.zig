//! No-operation/null backend.
//!
//! This is useful for tests and examples that need object plumbing without a
//! real GPU backend, and as a compact reference for backend implementors.

const std = @import("std");
const hal = @import("hal.zig");
const gpu = @import("../types/gpu.zig");

pub const instance = @import("dx12/instance.zig");
pub const surface = @import("dx12/surface.zig");
pub const adapter = @import("dx12/adapter.zig");
pub const device = @import("dx12/device.zig");
pub const resource = @import("dx12/resource.zig");
pub const shader = @import("dx12/shader.zig");
pub const pipeline = @import("dx12/pipeline.zig");
pub const command = @import("dx12/command.zig");

pub const DX_Instance = instance.DX_Instance;
pub const DX_Surface = surface.DX_Surface;
pub const DX_Adapter = adapter.DX_Adapter;
pub const DX_Device = device.DX_Device;
pub const DX_Queue = device.DX_Queue;

pub const DX_Buffer = resource.DX_Buffer;
pub const DX_Texture = resource.DX_Texture;
pub const DX_TextureView = resource.DX_TextureView;
pub const DX_Sampler = resource.DX_Sampler;
pub const DX_DescriptorSetLayout = resource.DX_DescriptorSetLayout;
pub const DX_DescriptorSet = resource.DX_DescriptorSet;
pub const DX_QuerySet = resource.DX_QuerySet;

pub const DX_ShaderModule = shader.DX_ShaderModule;

pub const DX_PipelineLayout = pipeline.DX_PipelineLayout;
pub const DX_ComputePipeline = pipeline.DX_ComputePipeline;
pub const DX_RenderPipeline = pipeline.DX_RenderPipeline;

pub const DX_CommandBuffer = command.DX_CommandBuffer;
pub const DX_CommandEncoder = command.DX_CommandEncoder;
pub const DX_ComputePassEncoder = command.DX_ComputePassEncoder;
pub const DX_RenderPassEncoder = command.DX_RenderPassEncoder;
pub const DX_RenderBundle = command.DX_RenderBundle;
pub const DX_RenderBundleEncoder = command.DX_RenderBundleEncoder;

pub fn init(descriptor: gpu.Instance.Descriptor) hal.Instance.FromPotentialBackendsError!hal.Instance {
    std.log.info("initializing dx12 backend", .{});
    return DX_Instance.init(descriptor) catch error.NoBackendAvailable;
}
