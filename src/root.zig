const options = @import("shader_options");

pub const candler = @import("candler");
/// `std.DynLib`, plus Windows.
pub const DynLib = @import("utils/dynlib.zig").DynLib;

pub const windowing = struct {
    pub const Window = @import("windowing/windowing.zig").Window;
};

pub const backends = struct {
    pub const dx12 = if (options.enable_dx12) @import("backends/dx12.zig") else struct {};
    pub const vk = if (options.enable_vk) @import("backends/vulkan.zig") else struct {};
    pub const webgpu = if (options.enable_webgpu) @import("backends/webgpu.zig") else struct {};
};

pub const hal = struct {
    pub const adapter = @import("interface/adapter.zig");
    pub const binding = @import("interface/binding.zig");
    pub const command = @import("interface/command.zig");
    pub const device = @import("interface/device.zig");
    pub const pipeline = @import("interface/pipeline.zig");
    pub const queue = @import("interface/queue.zig");
    pub const resource = @import("interface/resource.zig");
    pub const settings = @import("interface/settings.zig");
    pub const shader = @import("interface/shader.zig");
    pub const swapchain = @import("interface/swapchain.zig");
    pub const sync = @import("interface/sync.zig");
    pub const instance = @import("interface/instance.zig");
};

pub const Instance = hal.instance.Instance;
pub const Adapter = hal.adapter.Adapter;
pub const AdapterDescriptor = hal.adapter.AdapterDescriptor;
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
pub const Backend = hal.settings.Backend;
pub const BackendType = hal.settings.BackendType;
pub const ValidationLevel = hal.settings.ValidationLevel;
pub const VitellusConfig = hal.settings.VitellusConfig;
pub const Shader = hal.shader.Shader;
pub const ShaderModule = hal.shader.ShaderModule;
pub const BinaryShaderModule = hal.shader.BinaryShaderModule;
/// Browser console logging and panics for Emscripten builds.
pub const web = @import("web.zig");
pub const CompiledShader = hal.shader.CompiledShader;
pub const ShaderCompileRequest = hal.shader.ShaderCompileRequest;
pub const ShaderBinaryFormat = hal.shader.ShaderBinaryFormat;
pub const ShaderDescriptor = hal.shader.ShaderDescriptor;
pub const ShaderStage = hal.shader.ShaderStage;
pub const Buffer = hal.resource.Buffer;
pub const BufferDescriptor = hal.resource.BufferDescriptor;
pub const Texture = hal.resource.Texture;
pub const TextureView = hal.resource.TextureView;
pub const Sampler = hal.resource.Sampler;
pub const TextureDescriptor = hal.resource.TextureDescriptor;
pub const TextureViewDescriptor = hal.resource.TextureViewDescriptor;
pub const SamplerDescriptor = hal.resource.SamplerDescriptor;
pub const Format = hal.resource.Format;
pub const GraphicsPipeline = hal.pipeline.GraphicsPipeline;
pub const ComputePipeline = hal.pipeline.ComputePipeline;
pub const PipelineLayout = hal.pipeline.PipelineLayout;
pub const GraphicsPipelineDescriptor = hal.pipeline.GraphicsPipelineDescriptor;
pub const ComputePipelineDescriptor = hal.pipeline.ComputePipelineDescriptor;
pub const PipelineLayoutDescriptor = hal.pipeline.PipelineLayoutDescriptor;
pub const CommandPool = hal.command.CommandPool;
pub const CommandBuffer = hal.command.CommandBuffer;
pub const CommandPoolDescriptor = hal.command.CommandPoolDescriptor;
pub const CommandBufferDescriptor = hal.command.CommandBufferDescriptor;
pub const QuerySet = hal.command.QuerySet;
pub const QuerySetDescriptor = hal.command.QuerySetDescriptor;
pub const BindGroupLayout = hal.binding.BindGroupLayout;
pub const BindGroup = hal.binding.BindGroup;
pub const BindGroupLayoutDescriptor = hal.binding.BindGroupLayoutDescriptor;
pub const BindGroupDescriptor = hal.binding.BindGroupDescriptor;
pub const Fence = hal.sync.Fence;
pub const Semaphore = hal.sync.Semaphore;
pub const FenceDescriptor = hal.sync.FenceDescriptor;
pub const SemaphoreDescriptor = hal.sync.SemaphoreDescriptor;
pub const RenderPassDescriptor = hal.command.RenderPassDescriptor;
pub const SubmitDescriptor = hal.sync.SubmitDescriptor;

test {
    _ = @import("interface/instance.zig");
    _ = @import("interface/shader.zig");
    _ = @import("interface/settings.zig");
    if (comptime options.enable_dx12) {
        _ = @import("backends/dx12/resource.zig");
        _ = @import("backends/dx12/shader.zig");
        _ = @import("backends/dx12/pipeline.zig");
        _ = @import("backends/dx12/command.zig");
        _ = @import("backends/dx12/tests.zig");
    }
    _ = @import("backends/spirv_reflect.zig");
    if (comptime options.enable_vk) {
        _ = @import("backends/vulkan/instance.zig");
        _ = @import("backends/vulkan/adapter.zig");
        _ = @import("backends/vulkan/device.zig");
        _ = @import("backends/vulkan/shader.zig");
        _ = @import("backends/vulkan/command.zig");
    }
}
