//! vitellus - webgpu implementation in pure zig
//!
//! start off at `vit.GPU`.

// only place re-exports in this file.

// only keep lower-level types in here. do not export.
pub const types = struct {
    const gpu = @import("types/gpu.zig");
    const buffer = @import("types/buffer.zig");
    const texture = @import("types/texture.zig");
    const sampler = @import("types/sampler.zig");
    const bind_group = @import("types/bind_group.zig");
    const pipeline = @import("types/pipeline.zig");
    const shader = @import("types/shader.zig");
};

// re-export types
pub const GPU = types.gpu.GPU;
pub const Adapter = types.gpu.Adapter;
pub const Device = types.gpu.Device;
pub const Queue = types.gpu.Queue;

pub const Buffer = types.buffer.Buffer;
pub const Texture = types.texture.Texture;
pub const ExternalTexture = types.texture.ExternalTexture;
pub const Sampler = types.sampler.Sampler;
pub const BindGroupLayout = types.bind_group.BindGroupLayout;
pub const BindGroup = types.bind_group.BindGroup;
pub const PipelineLayout = types.pipeline.PipelineLayout;
pub const PipelineError = types.pipeline.PipelineError;
pub const ComputePipeline = types.pipeline.ComputePipeline;
pub const RenderPipeline = types.pipeline.RenderPipeline;
pub const ShaderModule = types.shader.ShaderModule;

pub const TextureFormat = Texture.Format;
