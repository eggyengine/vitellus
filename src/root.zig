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
    const command = @import("types/command.zig");
    const features = @import("types/features.zig");
    const def = @import("types/def.zig");
};

// re-export types
pub const GPU = types.gpu.GPU;
pub const Adapter = types.gpu.Adapter;
pub const Device = types.gpu.Device;
pub const Queue = types.gpu.Queue;
pub const QuerySet = types.gpu.QuerySet;

pub const Buffer = types.buffer.Buffer;
pub const Texture = types.texture.Texture;
pub const ExternalTexture = types.texture.ExternalTexture;
pub const CanvasContext = types.texture.CanvasContext;
pub const TexelCopyBufferLayout = types.texture.TexelCopyBufferLayout;
pub const TexelCopyBufferInfo = types.texture.TexelCopyBufferInfo;
pub const TexelCopyTextureInfo = types.texture.TexelCopyTextureInfo;
pub const CopyExternalImageSourceInfo = types.texture.CopyExternalImageSourceInfo;
pub const CopyExternalImageDestInfo = types.texture.CopyExternalImageDestInfo;
pub const Sampler = types.sampler.Sampler;
pub const BindGroupLayout = types.bind_group.BindGroupLayout;
pub const BindGroup = types.bind_group.BindGroup;
pub const PipelineLayout = types.pipeline.PipelineLayout;
pub const PipelineError = types.pipeline.PipelineError;
pub const ComputePipeline = types.pipeline.ComputePipeline;
pub const RenderPipeline = types.pipeline.RenderPipeline;
pub const PrimitiveState = types.pipeline.PrimitiveState;
pub const PrimitiveTopology = types.pipeline.PrimitiveTopology;
pub const FrontFace = types.pipeline.FrontFace;
pub const CullMode = types.pipeline.CullMode;
pub const MultisampleState = types.pipeline.MultisampleState;
pub const FragmentState = types.pipeline.FragmentState;
pub const ColorTargetState = types.pipeline.ColorTargetState;
pub const BlendState = types.pipeline.BlendState;
pub const BlendComponent = types.pipeline.BlendComponent;
pub const BlendFactor = types.pipeline.BlendFactor;
pub const BlendOperation = types.pipeline.BlendOperation;
pub const ColorWrite = types.pipeline.ColorWrite;
pub const DepthStencilState = types.pipeline.DepthStencilState;
pub const StencilFaceState = types.pipeline.StencilFaceState;
pub const StencilOperation = types.pipeline.StencilOperation;
pub const IndexFormat = types.pipeline.IndexFormat;
pub const VertexFormat = types.pipeline.VertexFormat;
pub const VertexStepMode = types.pipeline.VertexStepMode;
pub const VertexState = types.pipeline.VertexState;
pub const VertexBufferLayout = types.pipeline.VertexBufferLayout;
pub const VertexAttribute = types.pipeline.VertexAttribute;
pub const ShaderModule = types.shader.ShaderModule;
pub const CommandBuffer = types.command.CommandBuffer;
pub const CommandEncoder = types.command.CommandEncoder;
pub const ComputePassEncoder = types.command.ComputePassEncoder;
pub const RenderPassEncoder = types.command.RenderPassEncoder;
pub const RenderBundle = types.command.RenderBundle;
pub const RenderBundleEncoder = types.command.RenderBundleEncoder;

pub const TextureFormat = Texture.Format;
pub const FeatureName = types.features.FeatureName;
pub const SupportedFeatures = types.features.SupportedFeatures;
pub const SupportedLimits = types.features.SupportedLimits;
pub const SupportedLimitName = types.features.SupportedLimitName;
pub const SupportedLimitNumber = types.features.SupportedLimitNumber;
pub const WGSLLanguageFeatures = types.features.WGSLLanguageFeatures;

pub const BufferDynamicOffset = types.def.BufferDynamicOffset;
pub const StencilValue = types.def.StencilValue;
pub const SampleMask = types.def.SampleMask;
pub const DepthBias = types.def.DepthBias;
pub const Size64 = types.def.Size64;
pub const IntegerCoordinate = types.def.IntegerCoordinate;
pub const Index32 = types.def.Index32;
pub const Size32 = types.def.Size32;
pub const SignedOffset32 = types.def.SignedOffset32;
pub const Size64Out = types.def.Size64Out;
pub const IntegerCoordinateOut = types.def.IntegerCoordinateOut;
pub const Size32Out = types.def.Size32Out;
pub const FlagsConstant = types.def.FlagsConstant;
pub const Color = types.def.Color;
pub const ColorDict = types.def.ColorDict;
pub const Origin2D = types.def.Origin2D;
pub const Origin3D = types.def.Origin3D;
pub const PredefinedColorSpace = types.def.PredefinedColorSpace;
pub const ExternalImageSource = types.def.ExternalImageSource;
