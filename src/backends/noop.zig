//! No-operation/null backend.
//!
//! This is useful for tests and examples that need object plumbing without a
//! real GPU backend, and as a compact reference for backend implementors.

const std = @import("std");
const hal = @import("hal.zig");
const gpu = @import("../types/gpu.zig");

pub const instance = @import("noop/instance.zig");
pub const surface = @import("noop/surface.zig");
pub const adapter = @import("noop/adapter.zig");
pub const device = @import("noop/device.zig");
pub const resource = @import("noop/resource.zig");
pub const shader = @import("noop/shader.zig");
pub const pipeline = @import("noop/pipeline.zig");
pub const command = @import("noop/command.zig");

pub const NoopInstance = instance.NoopInstance;
pub const NoopSurface = surface.NoopSurface;
pub const NoopAdapter = adapter.NoopAdapter;
pub const NoopDevice = device.NoopDevice;
pub const NoopQueue = device.NoopQueue;

pub const NoopBuffer = resource.NoopBuffer;
pub const NoopTexture = resource.NoopTexture;
pub const NoopTextureView = resource.NoopTextureView;
pub const NoopSampler = resource.NoopSampler;
pub const NoopDescriptorSetLayout = resource.NoopDescriptorSetLayout;
pub const NoopDescriptorSet = resource.NoopDescriptorSet;
pub const NoopQuerySet = resource.NoopQuerySet;

pub const NoopShaderModule = shader.NoopShaderModule;

pub const NoopPipelineLayout = pipeline.NoopPipelineLayout;
pub const NoopComputePipeline = pipeline.NoopComputePipeline;
pub const NoopRenderPipeline = pipeline.NoopRenderPipeline;

pub const NoopCommandBuffer = command.NoopCommandBuffer;
pub const NoopCommandEncoder = command.NoopCommandEncoder;
pub const NoopComputePassEncoder = command.NoopComputePassEncoder;
pub const NoopRenderPassEncoder = command.NoopRenderPassEncoder;
pub const NoopRenderBundle = command.NoopRenderBundle;
pub const NoopRenderBundleEncoder = command.NoopRenderBundleEncoder;


pub fn init(descriptor: gpu.Instance.Descriptor) hal.Instance.FromPotentialBackendsError!hal.Instance {
    std.log.info("initializing noop backend", .{});
    return NoopInstance.init(descriptor) catch error.NoBackendAvailable;
}
