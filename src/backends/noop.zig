//! No-operation/null backend.
//!
//! This is useful for tests and examples that need object plumbing without a real Instance backend, as well be used as a template in your own implementation.

const std = @import("std");
const candler = @import("candler");

const bind_group = @import("../types/bind_group.zig");
const buffer = @import("../types/buffer.zig");
const command = @import("../types/command.zig");
const def = @import("../types/def.zig");
const gpu = @import("../types/gpu.zig");
const hal = @import("hal.zig");
const pipeline = @import("../types/pipeline.zig");
const sampler = @import("../types/sampler.zig");
const shader = @import("../types/shader.zig");
const texture = @import("../types/texture.zig");

const log = std.log.scoped(.vitellus_noop);

const NoopInstance = struct {
    const vtable = hal.Instance.VTable{
        .enumerateAdapters = enumerateAdapters,
        .requestAdapter = requestAdapter,
        .destroy = destroyGPU,
        .createSurface = createSurface,
    };

    fn destroyGPU(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying noop backend", .{});
    }

    const adapters = [_]hal.Adapter{
        .{
            .ptr = &adapter_state,
            .vtable = &NoopAdapter.vtable,
        },
    };

    fn enumerateAdapters(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror![]const hal.Adapter {
        _ = ptr;
        _ = options;
        log.debug("enumerating noop adapters", .{});
        return &adapters;
    }

    fn createSurface(
        ptr: *anyopaque,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!hal.Surface {
        _ = ptr;
        log.debug("creating noop surface: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return .{
            .ptr = &surface_state,
            .vtable = &NoopSurface.vtable,
        };
    }

    fn requestAdapter(
        ptr: *anyopaque,
        io: std.Io,
        options: gpu.Adapter.RequestOptions,
    ) std.Io.Future(anyerror!hal.Adapter) {
        log.debug("requesting noop adapter", .{});
        return io.async(requestAdapterInternal, .{ ptr, options });
    }

    fn requestAdapterInternal(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror!hal.Adapter {
        _ = ptr;
        _ = options;
        log.debug("returning noop adapter", .{});
        return .{
            .ptr = &adapter_state,
            .vtable = &NoopAdapter.vtable,
        };
    }
};

const NoopSurface = struct {
    const vtable = hal.Surface.VTable{
        .destroy = destroySurface,
        .getCapabilities = getSurfaceCapabilities,
        .configure = configureSurface,
        .unconfigure = unconfigureSurface,
        .getCurrentTexture = getCurrentSurfaceTexture,
    };

    const formats = [_]texture.Texture.Format{
        .bgra8unorm,
        .bgra8unorm_srgb,
        .rgba8unorm,
        .rgba8unorm_srgb,
    };
    const present_modes = [_]texture.Surface.PresentMode{.fifo};
    const alpha_modes = [_]texture.Surface.AlphaMode{.@"opaque"};

    fn destroySurface(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying noop surface", .{});
    }

    fn getSurfaceCapabilities(ptr: *anyopaque, adapter: hal.Adapter) texture.Surface.Capabilities {
        _ = ptr;
        _ = adapter;
        log.debug("getting noop surface capabilities", .{});
        return .{
            .formats = &formats,
            .present_modes = &present_modes,
            .alpha_modes = &alpha_modes,
        };
    }

    fn configureSurface(ptr: *anyopaque, device: hal.Device, configuration: texture.Surface.Configuration) void {
        _ = ptr;
        _ = device;
        _ = configuration;
        log.debug("configuring noop surface", .{});
    }

    fn unconfigureSurface(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("unconfiguring noop surface", .{});
    }

    fn getCurrentSurfaceTexture(ptr: *anyopaque) anyerror!texture.Surface.CurrentSurfaceTexture {
        _ = ptr;
        log.debug("noop surface current texture requested", .{});
        return error.NotImplemented;
    }
};

const NoopAdapter = struct {
    const vtable = hal.Adapter.VTable{
        .requestDevice = requestDevice,
        .getInfo = getAdapterInfo,
        .getDownlevelCapabilities = getDownlevelCapabilities,
        .getTextureFormatFeatures = getTextureFormatFeatures,
        .isSurfaceSupported = isSurfaceSupported,
    };

    fn requestDevice(
        ptr: *anyopaque,
        io: std.Io,
        options: gpu.Device.Descriptor,
    ) std.Io.Future(anyerror!struct { hal.Device, hal.Queue }) {
        log.debug("requesting noop device", .{});
        return io.async(requestDeviceInternal, .{ ptr, options });
    }

    fn requestDeviceInternal(ptr: *anyopaque, options: gpu.Device.Descriptor) anyerror!struct { hal.Device, hal.Queue } {
        _ = ptr;
        _ = options;
        log.debug("returning noop device", .{});
        const device = hal.Device{
            .ptr = &device_state,
            .vtable = &NoopDevice.vtable,
        };
        const queue = hal.Queue{
            .ptr = &queue_state,
            .vtable = &NoopQueue.vtable,
        };
        return .{ device, queue };
    }

    fn getAdapterInfo(ptr: *anyopaque) gpu.Adapter.Info {
        _ = ptr;
        log.debug("getting noop adapter info", .{});
        return .{
            .vendor = "",
            .architecture = "",
            .device = "",
            .description = "",
            .subgroupMinSize = 0,
            .subgroupMaxSize = 0,
            .isFallbackAdapter = false,
        };
    }

    fn getDownlevelCapabilities(ptr: *anyopaque) gpu.Adapter.DownlevelCapabilities {
        _ = ptr;
        log.debug("getting noop adapter downlevel capabilities", .{});
        return .{};
    }

    fn getTextureFormatFeatures(
        ptr: *anyopaque,
        format: texture.Texture.Format,
    ) gpu.Adapter.TextureFormatFeatures {
        _ = ptr;
        _ = format;
        log.debug("getting noop texture format features", .{});
        return .{};
    }

    fn isSurfaceSupported(ptr: *anyopaque, surface: hal.Surface) bool {
        _ = ptr;
        _ = surface;
        log.debug("checking noop surface support", .{});
        return true;
    }
};

const NoopDevice = struct {
    const vtable = hal.Device.VTable{
        .destroy = destroy,
        .createBuffer = createBuffer,
        .createTexture = createTexture,
        .createSampler = createSampler,
        .importExternalTexture = importExternalTexture,
        .createBindGroupLayout = createBindGroupLayout,
        .createPipelineLayout = createPipelineLayout,
        .createBindGroup = createBindGroup,
        .createShaderModule = createShaderModule,
        .createComputePipeline = createComputePipeline,
        .createRenderPipeline = createRenderPipeline,
        .createComputePipelineAsync = createComputePipelineAsync,
        .createRenderPipelineAsync = createRenderPipelineAsync,
        .createCommandEncoder = createCommandEncoder,
        .createRenderBundleEncoder = createRenderBundleEncoder,
        .createQuerySet = createQuerySet,
        .lost = lost,
        .popErrorScope = popErrorScope,
        .pushErrorScope = pushErrorScope,
        .getQueue = getQueue,
    };

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying noop device", .{});
    }

    fn createBuffer(ptr: *anyopaque, descriptor: buffer.Buffer.Descriptor) anyerror!hal.Buffer {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createTexture(ptr: *anyopaque, descriptor: texture.Texture.Descriptor) anyerror!hal.Texture {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createSampler(ptr: *anyopaque, descriptor: sampler.Sampler.Descriptor) anyerror!hal.Sampler {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn importExternalTexture(ptr: *anyopaque, descriptor: texture.ExternalTexture.Descriptor) anyerror!hal.ExternalTexture {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createBindGroupLayout(ptr: *anyopaque, descriptor: bind_group.BindGroupLayout.Descriptor) anyerror!hal.BindGroupLayout {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createPipelineLayout(ptr: *anyopaque, descriptor: pipeline.PipelineLayout.Descriptor) anyerror!hal.PipelineLayout {
        _ = ptr;
        _ = descriptor;
        return .{
            .ptr = &pipeline_layout_state,
            .vtable = &NoopPipelineLayout.vtable,
        };
    }

    fn createBindGroup(ptr: *anyopaque, descriptor: bind_group.BindGroup.Descriptor) anyerror!hal.BindGroup {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
        _ = ptr;
        _ = descriptor;
        return .{
            .ptr = &shader_module_state,
            .vtable = &NoopShaderModule.vtable,
        };
    }

    fn createComputePipeline(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createRenderPipeline(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
        _ = ptr;
        _ = descriptor;
        return .{
            .ptr = &render_pipeline_state,
            .vtable = &NoopRenderPipeline.vtable,
        };
    }

    fn createComputePipelineAsync(
        ptr: *anyopaque,
        io: std.Io,
        descriptor: pipeline.ComputePipeline.Descriptor,
    ) std.Io.Future(anyerror!hal.ComputePipeline) {
        return io.async(createComputePipelineAsyncInternal, .{ ptr, descriptor });
    }

    fn createComputePipelineAsyncInternal(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createRenderPipelineAsync(
        ptr: *anyopaque,
        io: std.Io,
        descriptor: pipeline.RenderPipeline.Descriptor,
    ) std.Io.Future(anyerror!hal.RenderPipeline) {
        return io.async(createRenderPipelineAsyncInternal, .{ ptr, descriptor });
    }

    fn createRenderPipelineAsyncInternal(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createCommandEncoder(ptr: *anyopaque, descriptor: ?command.CommandEncoder.Descriptor) anyerror!hal.CommandEncoder {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createRenderBundleEncoder(ptr: *anyopaque, descriptor: command.RenderBundleEncoder.Descriptor) anyerror!hal.RenderBundleEncoder {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn createQuerySet(ptr: *anyopaque, descriptor: gpu.QuerySet.Descriptor) anyerror!hal.QuerySet {
        _ = ptr;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn lost(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!gpu.Device.LostInfo) {
        return io.async(lostInternal, .{ptr});
    }

    fn lostInternal(ptr: *anyopaque) anyerror!gpu.Device.LostInfo {
        _ = ptr;
        return error.NotImplemented;
    }

    fn popErrorScope(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!?gpu.Device.Error) {
        return io.async(popErrorScopeInternal, .{ptr});
    }

    fn popErrorScopeInternal(ptr: *anyopaque) anyerror!?gpu.Device.Error {
        _ = ptr;
        return null;
    }

    fn pushErrorScope(ptr: *anyopaque, filter: gpu.Device.ErrorFilter) void {
        _ = ptr;
        _ = filter;
    }

    fn getQueue(ptr: *anyopaque) hal.Queue {
        _ = ptr;
        return .{
            .ptr = &queue_state,
            .vtable = &NoopQueue.vtable,
        };
    }
};

const NoopPipelineLayout = struct {
    const vtable = hal.PipelineLayout.VTable{
        .destroy = destroy,
    };

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying noop pipeline layout", .{});
    }
};

const NoopShaderModule = struct {
    const vtable = hal.ShaderModule.VTable{
        .destroy = destroy,
        .getCompilationInfo = getCompilationInfo,
    };

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying noop shader module", .{});
    }

    fn getCompilationInfo(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!shader.ShaderModule.CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{ptr});
    }

    fn getCompilationInfoInternal(ptr: *anyopaque) anyerror!shader.ShaderModule.CompilationInfo {
        _ = ptr;
        return .{};
    }
};

const NoopRenderPipeline = struct {
    const vtable = hal.RenderPipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        log.debug("destroying noop render pipeline", .{});
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: def.Index32) anyerror!hal.BindGroupLayout {
        _ = ptr;
        _ = index;
        return error.NotImplemented;
    }
};

const NoopQueue = struct {
    const vtable = hal.Queue.VTable{
        .submit = submit,
        .writeBuffer = writeBuffer,
        .writeTexture = writeTexture,
        .copyExternalImageToTexture = copyExternalImageToTexture,
        .onSubmittedWorkDone = onSubmittedWorkDone,
    };

    fn submit(ptr: *anyopaque, command_buffers: []const hal.CommandBuffer) void {
        _ = ptr;
        _ = command_buffers;
    }

    fn writeBuffer(
        ptr: *anyopaque,
        target: hal.Buffer,
        buffer_offset: def.Size64,
        data: def.AllowSharedBufferSource,
        data_offset: def.Size64,
        size: ?def.Size64,
    ) void {
        _ = ptr;
        _ = target;
        _ = buffer_offset;
        _ = data;
        _ = data_offset;
        _ = size;
    }

    fn writeTexture(
        ptr: *anyopaque,
        destination: texture.TexelCopyTextureInfo,
        data: def.AllowSharedBufferSource,
        data_layout: texture.TexelCopyBufferLayout,
        size: texture.Texture.Extent3D,
    ) void {
        _ = ptr;
        _ = destination;
        _ = data;
        _ = data_layout;
        _ = size;
    }

    fn copyExternalImageToTexture(
        ptr: *anyopaque,
        source: texture.CopyExternalImageSourceInfo,
        destination: texture.CopyExternalImageDestInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        _ = ptr;
        _ = source;
        _ = destination;
        _ = copy_size;
    }

    fn onSubmittedWorkDone(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!void) {
        return io.async(onSubmittedWorkDoneInternal, .{ptr});
    }

    fn onSubmittedWorkDoneInternal(ptr: *anyopaque) anyerror!void {
        _ = ptr;
    }
};

var instance_state: NoopInstance = .{};
var surface_state: NoopSurface = .{};
var adapter_state: NoopAdapter = .{};
var device_state: NoopDevice = .{};
var queue_state: NoopQueue = .{};
var shader_module_state: NoopShaderModule = .{};
var pipeline_layout_state: NoopPipelineLayout = .{};
var render_pipeline_state: NoopRenderPipeline = .{};

pub fn init() hal.Instance {
    log.debug("initializing noop backend", .{});
    return .{
        .ptr = &instance_state,
        .vtable = &NoopInstance.vtable,
    };
}
