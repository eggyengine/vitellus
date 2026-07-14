pub const hal = struct {
    pub const adapter = @import("interface/adapter.zig");
    pub const device = @import("interface/device.zig");
    pub const queue = @import("interface/queue.zig");
    pub const settings = @import("interface/settings.zig");
    pub const swapchain = @import("interface/swapchain.zig");
    pub const shader = @import("interface/shader.zig");
    pub const resource = @import("interface/resource.zig");
    pub const pipeline = @import("interface/pipeline.zig");
    pub const command = @import("interface/command.zig");
    pub const sync = @import("interface/sync.zig");
};

pub const candler = @import("candler");

pub const windowing = struct {
    pub const Window = @import("windowing/windowing.zig").Window;
    pub const sdl3 = @import("windowing/sdl3.zig");
};

pub const backends = struct {
    pub const dx12 = @import("backends/dx12.zig");
};

pub const Adapter = hal.adapter.Adapter;
pub const AdapterInfo = hal.adapter.AdapterInfo;
pub const Device = hal.device.Device;
pub const DeviceDescriptor = hal.device.DeviceDescriptor;
pub const Queue = hal.queue.Queue;
pub const QueueDescriptor = hal.queue.QueueDescriptor;
pub const Swapchain = hal.swapchain.Swapchain;
pub const SwapchainDescriptor = hal.swapchain.SwapchainDescriptor;
pub const SwapchainFormat = hal.swapchain.SwapchainFormat;
pub const SwapchainColorSpace = hal.swapchain.SwapchainColorSpace;
pub const PresentMode = hal.swapchain.PresentMode;
pub const CompositeAlpha = hal.swapchain.CompositeAlpha;
pub const ImageUsage = hal.swapchain.ImageUsage;
pub const Extent2D = hal.swapchain.Extent2D;
pub const Window = windowing.Window;
pub const Config = hal.settings.VitellusConfig;
pub const Shader = hal.shader.Shader;
pub const ShaderModule = hal.shader.ShaderModule;
pub const HLSLShaderModule = @import("backends/dx12/hlsl_shader_module.zig").HLSLShaderModule;
pub const HLSLProfile = @import("backends/dx12/hlsl_shader_module.zig").HLSLProfile;
pub const BinaryShaderModule = hal.shader.BinaryShaderModule;
pub const CompiledShader = hal.shader.CompiledShader;
pub const ShaderCompileRequest = hal.shader.ShaderCompileRequest;
pub const ShaderBinaryFormat = hal.shader.ShaderBinaryFormat;
pub const ShaderDescriptor = hal.shader.ShaderDescriptor;
pub const ShaderStage = hal.shader.ShaderStage;
pub const Buffer = hal.resource.Buffer;
pub const BufferDescriptor = hal.resource.BufferDescriptor;
pub const Texture = hal.resource.Texture;
pub const TextureView = hal.resource.TextureView;
pub const TextureDescriptor = hal.resource.TextureDescriptor;
pub const Format = hal.resource.Format;
pub const GraphicsPipeline = hal.pipeline.GraphicsPipeline;
pub const GraphicsPipelineDescriptor = hal.pipeline.GraphicsPipelineDescriptor;
pub const CommandPool = hal.command.CommandPool;
pub const CommandBuffer = hal.command.CommandBuffer;
pub const RenderPassDescriptor = hal.command.RenderPassDescriptor;
pub const SubmitDescriptor = hal.sync.SubmitDescriptor;

test {
    _ = @import("backends/dx12/hlsl_shader_module.zig");
    _ = @import("backends/dx12/shader.zig");
}
