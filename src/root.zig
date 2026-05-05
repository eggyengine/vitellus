//! vitellus - webgpu implementation in pure zig
//!
//! start off at `vit.GPU`.

// only place re-exports in this file.

// only keep lower-level types in here. do not export.
pub const hal = struct {
    const gpu = @import("gpu.zig");
    const buffer = @import("buffer.zig");
    const texture = @import("texture.zig");
    const sampler = @import("sampler.zig");
    const bind_group_layout = @import("bind_group_layout.zig");
    const bind_group = @import("bind_group.zig");
    const pipeline_layout = @import("pipeline_layout.zig");
};

// re-export types
pub const GPU = hal.gpu.GPU;
pub const Adapter = hal.gpu.Adapter;
pub const Device = hal.gpu.Device;
pub const Queue = hal.gpu.Queue;

pub const Buffer = hal.buffer.Buffer;
pub const Texture = hal.texture.Texture;
pub const ExternalTexture = hal.texture.ExternalTexture;
pub const Sampler = hal.sampler.Sampler;
pub const BindGroupLayout = hal.bind_group_layout.BindGroupLayout;
pub const BindGroup = hal.bind_group.BindGroup;
pub const PipelineLayout = hal.pipeline_layout.PipelineLayout;

pub const TextureFormat = Texture.Format;
