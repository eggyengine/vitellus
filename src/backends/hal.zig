//! vitellus hardware abstraction layer (vit.hal)
//!
//! in this module, it is a bridge between the higher level (vit.types) and the lower-level graphics APIs.

const std = @import("std");
const builtin = @import("builtin");
const candler = @import("candler");

const bind_group = @import("../types/bind_group.zig");
const buffer = @import("../types/buffer.zig");
const command = @import("../types/command.zig");
const def = @import("../types/def.zig");
const gpu = @import("../types/gpu.zig");
const pipeline = @import("../types/pipeline.zig");
const sampler = @import("../types/sampler.zig");
const shader = @import("../types/shader.zig");
const texture = @import("../types/texture.zig");

pub const noop = @import("noop.zig");
pub const vulkan = @import("vulkan.zig");

const log = std.log.scoped(.vitellus_hal);

pub const Backends = packed struct(u32) {
    /// No operation backend
    ///
    /// Typically used for testing
    noop: bool = false,
    /// Vulkan (specifically Vulkan 1.4)
    vulkan: bool = false,
    /// OpenGL/WebGL
    gl: bool = false,
    /// Metal (supported on Apple devices)
    metal: bool = false,
    /// DirectX12
    directx12: bool = false,
    /// Browser webgpu (navigator.gpu)
    browser_webgpu: bool = false,

    _: u26 = 0,

    /// No operation backend
    ///
    /// Typically used for testing
    pub const NOOP: u32 = 0x01;
    /// Vulkan (specifically Vulkan 1.4)
    pub const VULKAN: u32 = 0x02;
    /// OpenGL/WebGL
    pub const GL: u32 = 0x04;
    /// Metal (supported on Apple devices)
    pub const METAL: u32 = 0x08;
    /// DirectX12
    pub const DIRECTX12: u32 = 0x10;
    /// Browser webgpu (navigator.gpu)
    pub const BROWSER_WEBGPU: u32 = 0x20;

    pub const PRIMARY: u32 = VULKAN | METAL | DIRECTX12 | BROWSER_WEBGPU;
    pub const SECONDARY: u32 = GL;

    pub fn fromFlags(flags: u32) Backends {
        return @bitCast(flags);
    }

    pub fn toFlags(self: Backends) u32 {
        return @bitCast(self);
    }
};

pub const Instance = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (
            *anyopaque,
        ) void,
        enumerateAdapters: *const fn (
            *anyopaque,
            gpu.Adapter.RequestOptions,
        ) []const Adapter,
        requestAdapter: *const fn (
            *anyopaque,
            std.Io,
            gpu.Adapter.RequestOptions,
        ) std.Io.Future(anyerror!Adapter),
        createSurface: *const fn (
            *anyopaque,
            candler.WindowHandle,
            candler.DisplayHandle,
        ) anyerror!Surface,
    };

    pub const FromPotentialBackendsError = error{
        NotImplemented,
        NoBackendAvailable,
    };

    pub fn fromPotentialBackends(flags: Backends) FromPotentialBackendsError!type {
        switch (builtin.os.tag) {
            .windows => {
                // dx12 takes priority on windows
                if (flags.directx12) {
                    return error.NotImplemented;
                }

                if (flags.vulkan) {
                    return vulkan.vkInstance;
                }
            },

            .linux => {
                // vulkan only
                if (flags.vulkan) {
                    return vulkan.vkInstance;
                }
            },

            // vulkan can be supported through moltenvk
            .macos => {
                if (flags.metal) {
                    return error.NotImplemented;
                }
            },
            .ios => {
                if (flags.metal) {
                    return error.NotImplemented;
                }
            },
            .watchos => {
                if (flags.metal) {
                    return error.NotImplemented;
                }
            },
            .tvos => {
                if (flags.metal) {
                    return error.NotImplemented;
                }
            },
            .visionos => {
                if (flags.metal) {
                    return error.NotImplemented;
                }
            },

            // wasm uses `navigator.gpu` api
            .emscripten => {
                if (flags.browser_webgpu) {
                    return error.NotImplemented;
                }
            },
            .wasi => {
                if (flags.browser_webgpu) {
                    return error.NotImplemented;
                }
            },
            else => {},
        }

        // basically all platforms support some form of opengl
        if (flags.gl) {
            return error.NotImplemented;
        }

        if (flags.noop) {
            return noop;
        }

        return error.NoBackendAvailable;
    }

    pub fn requestAdapter(
        self: Instance,
        io: std.Io,
        options: gpu.Adapter.RequestOptions,
    ) std.Io.Future(anyerror!Adapter) {
        log.debug("instance.requestAdapter dispatch", .{});
        return self.vtable.requestAdapter(self.ptr, io, options);
    }

    pub fn enumerateAdapters(
        self: Instance,
        options: gpu.Adapter.RequestOptions,
    ) []const Adapter {
        log.debug("instance.enumerateAdapters dispatch", .{});
        return self.vtable.enumerateAdapters(self.ptr, options);
    }

    pub fn createSurface(
        self: Instance,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!Surface {
        log.debug("instance.createSurface dispatch: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return self.vtable.createSurface(self.ptr, window, display);
    }

    pub fn deinit(self: Instance) void {
        log.debug("instance.destroy dispatch", .{});
        return self.vtable.destroy(self.ptr);
    }
};

pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        requestDevice: *const fn (
            *anyopaque,
            std.Io,
            gpu.Device.Descriptor,
        ) std.Io.Future(anyerror!struct { Device, Queue }),
        getInfo: *const fn (*anyopaque) gpu.Adapter.Info,
        getDownlevelCapabilities: *const fn (*anyopaque) gpu.Adapter.DownlevelCapabilities,
        getTextureFormatFeatures: *const fn (
            *anyopaque,
            texture.Texture.Format,
        ) gpu.Adapter.TextureFormatFeatures,
    };

    pub fn requestDevice(
        self: Adapter,
        io: std.Io,
        options: gpu.Device.Descriptor,
    ) std.Io.Future(anyerror!struct { Device, Queue }) {
        log.debug("adapter.requestDevice dispatch", .{});
        return self.vtable.requestDevice(self.ptr, io, options);
    }

    pub fn getInfo(self: Adapter) gpu.Adapter.Info {
        log.debug("adapter.getInfo dispatch", .{});
        return self.vtable.getInfo(self.ptr);
    }

    pub fn getDownlevelCapabilities(self: Adapter) gpu.Adapter.DownlevelCapabilities {
        log.debug("adapter.getDownlevelCapabilities dispatch", .{});
        return self.vtable.getDownlevelCapabilities(self.ptr);
    }

    pub fn getTextureFormatFeatures(
        self: Adapter,
        format: texture.Texture.Format,
    ) gpu.Adapter.TextureFormatFeatures {
        log.debug("adapter.getTextureFormatFeatures dispatch", .{});
        return self.vtable.getTextureFormatFeatures(self.ptr, format);
    }
};

pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        createBuffer: *const fn (
            *anyopaque,
            buffer.Buffer.Descriptor,
        ) anyerror!Buffer,
        createTexture: *const fn (
            *anyopaque,
            texture.Texture.Descriptor,
        ) anyerror!Texture,
        createSampler: *const fn (
            *anyopaque,
            sampler.Sampler.Descriptor,
        ) anyerror!Sampler,
        importExternalTexture: *const fn (
            *anyopaque,
            texture.ExternalTexture.Descriptor,
        ) anyerror!ExternalTexture,
        createBindGroupLayout: *const fn (
            *anyopaque,
            bind_group.BindGroupLayout.Descriptor,
        ) anyerror!BindGroupLayout,
        createPipelineLayout: *const fn (
            *anyopaque,
            pipeline.PipelineLayout.Descriptor,
        ) anyerror!PipelineLayout,
        createBindGroup: *const fn (
            *anyopaque,
            bind_group.BindGroup.Descriptor,
        ) anyerror!BindGroup,
        createShaderModule: *const fn (
            *anyopaque,
            shader.ShaderModule.Descriptor,
        ) anyerror!ShaderModule,
        createComputePipeline: *const fn (
            *anyopaque,
            pipeline.ComputePipeline.Descriptor,
        ) anyerror!ComputePipeline,
        createRenderPipeline: *const fn (
            *anyopaque,
            pipeline.RenderPipeline.Descriptor,
        ) anyerror!RenderPipeline,
        createComputePipelineAsync: *const fn (
            *anyopaque,
            std.Io,
            pipeline.ComputePipeline.Descriptor,
        ) std.Io.Future(anyerror!ComputePipeline),
        createRenderPipelineAsync: *const fn (
            *anyopaque,
            std.Io,
            pipeline.RenderPipeline.Descriptor,
        ) std.Io.Future(anyerror!RenderPipeline),
        createCommandEncoder: *const fn (
            *anyopaque,
            ?command.CommandEncoder.Descriptor,
        ) anyerror!CommandEncoder,
        createRenderBundleEncoder: *const fn (
            *anyopaque,
            command.RenderBundleEncoder.Descriptor,
        ) anyerror!RenderBundleEncoder,
        createQuerySet: *const fn (
            *anyopaque,
            gpu.QuerySet.Descriptor,
        ) anyerror!QuerySet,
        lost: *const fn (*anyopaque, std.Io) std.Io.Future(anyerror!gpu.Device.LostInfo),
        popErrorScope: *const fn (*anyopaque, std.Io) std.Io.Future(anyerror!?gpu.Device.Error),
        pushErrorScope: *const fn (*anyopaque, gpu.Device.ErrorFilter) void,
        getQueue: *const fn (*anyopaque) Queue,
    };

    pub fn destroy(self: Device) void {
        log.debug("device.destroy dispatch", .{});
        return self.vtable.destroy(self.ptr);
    }

    pub fn createBuffer(
        self: Device,
        descriptor: buffer.Buffer.Descriptor,
    ) anyerror!Buffer {
        return self.vtable.createBuffer(self.ptr, descriptor);
    }

    pub fn createTexture(
        self: Device,
        descriptor: texture.Texture.Descriptor,
    ) anyerror!Texture {
        return self.vtable.createTexture(self.ptr, descriptor);
    }

    pub fn createSampler(
        self: Device,
        descriptor: sampler.Sampler.Descriptor,
    ) anyerror!Sampler {
        return self.vtable.createSampler(self.ptr, descriptor);
    }

    pub fn importExternalTexture(
        self: Device,
        descriptor: texture.ExternalTexture.Descriptor,
    ) anyerror!ExternalTexture {
        return self.vtable.importExternalTexture(self.ptr, descriptor);
    }

    pub fn createBindGroupLayout(
        self: Device,
        descriptor: bind_group.BindGroupLayout.Descriptor,
    ) anyerror!BindGroupLayout {
        return self.vtable.createBindGroupLayout(self.ptr, descriptor);
    }

    pub fn createPipelineLayout(
        self: Device,
        descriptor: pipeline.PipelineLayout.Descriptor,
    ) anyerror!PipelineLayout {
        return self.vtable.createPipelineLayout(self.ptr, descriptor);
    }

    pub fn createBindGroup(
        self: Device,
        descriptor: bind_group.BindGroup.Descriptor,
    ) anyerror!BindGroup {
        return self.vtable.createBindGroup(self.ptr, descriptor);
    }

    pub fn createShaderModule(
        self: Device,
        descriptor: shader.ShaderModule.Descriptor,
    ) anyerror!ShaderModule {
        return self.vtable.createShaderModule(self.ptr, descriptor);
    }

    pub fn createComputePipeline(
        self: Device,
        descriptor: pipeline.ComputePipeline.Descriptor,
    ) anyerror!ComputePipeline {
        return self.vtable.createComputePipeline(self.ptr, descriptor);
    }

    pub fn createRenderPipeline(
        self: Device,
        descriptor: pipeline.RenderPipeline.Descriptor,
    ) anyerror!RenderPipeline {
        return self.vtable.createRenderPipeline(self.ptr, descriptor);
    }

    pub fn createComputePipelineAsync(
        self: Device,
        io: std.Io,
        descriptor: pipeline.ComputePipeline.Descriptor,
    ) std.Io.Future(anyerror!ComputePipeline) {
        return self.vtable.createComputePipelineAsync(self.ptr, io, descriptor);
    }

    pub fn createRenderPipelineAsync(
        self: Device,
        io: std.Io,
        descriptor: pipeline.RenderPipeline.Descriptor,
    ) std.Io.Future(anyerror!RenderPipeline) {
        return self.vtable.createRenderPipelineAsync(self.ptr, io, descriptor);
    }

    pub fn createCommandEncoder(
        self: Device,
        descriptor: ?command.CommandEncoder.Descriptor,
    ) anyerror!CommandEncoder {
        return self.vtable.createCommandEncoder(self.ptr, descriptor);
    }

    pub fn createRenderBundleEncoder(
        self: Device,
        descriptor: command.RenderBundleEncoder.Descriptor,
    ) anyerror!RenderBundleEncoder {
        return self.vtable.createRenderBundleEncoder(self.ptr, descriptor);
    }

    pub fn createQuerySet(
        self: Device,
        descriptor: gpu.QuerySet.Descriptor,
    ) anyerror!QuerySet {
        return self.vtable.createQuerySet(self.ptr, descriptor);
    }

    pub fn lost(self: Device, io: std.Io) std.Io.Future(anyerror!gpu.Device.LostInfo) {
        return self.vtable.lost(self.ptr, io);
    }

    pub fn popErrorScope(self: Device, io: std.Io) std.Io.Future(anyerror!?gpu.Device.Error) {
        return self.vtable.popErrorScope(self.ptr, io);
    }

    pub fn pushErrorScope(self: Device, filter: gpu.Device.ErrorFilter) void {
        return self.vtable.pushErrorScope(self.ptr, filter);
    }

    pub fn getQueue(self: Device) Queue {
        log.debug("device.getQueue dispatch", .{});
        return self.vtable.getQueue(self.ptr);
    }
};

pub const Queue = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        submit: *const fn (*anyopaque, []const CommandBuffer) void,
        writeBuffer: *const fn (
            *anyopaque,
            Buffer,
            def.Size64,
            def.AllowSharedBufferSource,
            def.Size64,
            ?def.Size64,
        ) void,
        writeTexture: *const fn (
            *anyopaque,
            texture.TexelCopyTextureInfo,
            def.AllowSharedBufferSource,
            texture.TexelCopyBufferLayout,
            texture.Texture.Extent3D,
        ) void,
        copyExternalImageToTexture: *const fn (
            *anyopaque,
            texture.CopyExternalImageSourceInfo,
            texture.CopyExternalImageDestInfo,
            texture.Texture.Extent3D,
        ) void,
        onSubmittedWorkDone: *const fn (*anyopaque, std.Io) std.Io.Future(anyerror!void),
    };

    pub fn submit(self: Queue, command_buffers: []const CommandBuffer) void {
        return self.vtable.submit(self.ptr, command_buffers);
    }

    pub fn writeBuffer(
        self: Queue,
        target: Buffer,
        buffer_offset: def.Size64,
        data: def.AllowSharedBufferSource,
        data_offset: def.Size64,
        size: ?def.Size64,
    ) void {
        return self.vtable.writeBuffer(self.ptr, target, buffer_offset, data, data_offset, size);
    }

    pub fn writeTexture(
        self: Queue,
        destination: texture.TexelCopyTextureInfo,
        data: def.AllowSharedBufferSource,
        data_layout: texture.TexelCopyBufferLayout,
        size: texture.Texture.Extent3D,
    ) void {
        return self.vtable.writeTexture(self.ptr, destination, data, data_layout, size);
    }

    pub fn copyExternalImageToTexture(
        self: Queue,
        source: texture.CopyExternalImageSourceInfo,
        destination: texture.CopyExternalImageDestInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        return self.vtable.copyExternalImageToTexture(self.ptr, source, destination, copy_size);
    }

    pub fn onSubmittedWorkDone(self: Queue, io: std.Io) std.Io.Future(anyerror!void) {
        return self.vtable.onSubmittedWorkDone(self.ptr, io);
    }
};

pub const Buffer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        mapAsync: *const fn (
            *anyopaque,
            std.Io,
            buffer.Buffer.MapMode,
            ?def.Size64,
            def.Size64,
        ) std.Io.Future(anyerror!void),
        getMappedRange: *const fn (*anyopaque, ?def.Size64, ?def.Size64) ?def.ArrayBuffer,
        unmap: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: Buffer) void {
        return self.vtable.destroy(self.ptr);
    }

    pub fn mapAsync(
        self: Buffer,
        io: std.Io,
        mode: buffer.Buffer.MapMode,
        offset: ?def.Size64,
        size: def.Size64,
    ) std.Io.Future(anyerror!void) {
        return self.vtable.mapAsync(self.ptr, io, mode, offset, size);
    }

    pub fn getMappedRange(self: Buffer, offset: ?def.Size64, size: ?def.Size64) ?def.ArrayBuffer {
        return self.vtable.getMappedRange(self.ptr, offset, size);
    }

    pub fn unmap(self: Buffer) void {
        return self.vtable.unmap(self.ptr);
    }
};

pub const Texture = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        createView: *const fn (
            *anyopaque,
            texture.Texture.View.Descriptor,
        ) anyerror!TextureView,
    };

    pub fn destroy(self: Texture) void {
        return self.vtable.destroy(self.ptr);
    }

    pub fn createView(
        self: Texture,
        descriptor: texture.Texture.View.Descriptor,
    ) anyerror!TextureView {
        return self.vtable.createView(self.ptr, descriptor);
    }
};

pub const TextureView = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: TextureView) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const ExternalTexture = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: ExternalTexture) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const Sampler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: Sampler) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const BindGroupLayout = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: BindGroupLayout) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const PipelineLayout = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: PipelineLayout) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const BindGroup = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: BindGroup) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const ShaderModule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        getCompilationInfo: *const fn (
            *anyopaque,
            std.Io,
        ) std.Io.Future(anyerror!shader.ShaderModule.CompilationInfo),
    };

    pub fn destroy(self: ShaderModule) void {
        return self.vtable.destroy(self.ptr);
    }

    pub fn getCompilationInfo(self: ShaderModule, io: std.Io) std.Io.Future(anyerror!shader.ShaderModule.CompilationInfo) {
        return self.vtable.getCompilationInfo(self.ptr, io);
    }
};

pub const ComputePipeline = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        getBindGroupLayout: *const fn (
            *anyopaque,
            def.Index32,
        ) anyerror!BindGroupLayout,
    };

    pub fn destroy(self: ComputePipeline) void {
        return self.vtable.destroy(self.ptr);
    }

    pub fn getBindGroupLayout(
        self: ComputePipeline,
        index: def.Index32,
    ) anyerror!BindGroupLayout {
        return self.vtable.getBindGroupLayout(self.ptr, index);
    }
};

pub const RenderPipeline = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        getBindGroupLayout: *const fn (
            *anyopaque,
            def.Index32,
        ) anyerror!BindGroupLayout,
    };

    pub fn destroy(self: RenderPipeline) void {
        return self.vtable.destroy(self.ptr);
    }

    pub fn getBindGroupLayout(
        self: RenderPipeline,
        index: def.Index32,
    ) anyerror!BindGroupLayout {
        return self.vtable.getBindGroupLayout(self.ptr, index);
    }
};

pub const CommandBuffer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: CommandBuffer) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const CommandEncoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginRenderPass: *const fn (
            *anyopaque,
            command.RenderPassEncoder.Descriptor,
        ) anyerror!RenderPassEncoder,
        beginComputePass: *const fn (
            *anyopaque,
            ?command.ComputePassEncoder.Descriptor,
        ) anyerror!ComputePassEncoder,
        copyBufferToBuffer: *const fn (*anyopaque, Buffer, Buffer, ?def.Size64) void,
        copyBufferToBufferWithOffsets: *const fn (
            *anyopaque,
            Buffer,
            def.Size64,
            Buffer,
            def.Size64,
            ?def.Size64,
        ) void,
        copyBufferToTexture: *const fn (
            *anyopaque,
            texture.TexelCopyBufferInfo,
            texture.TexelCopyTextureInfo,
            texture.Texture.Extent3D,
        ) void,
        copyTextureToBuffer: *const fn (
            *anyopaque,
            texture.TexelCopyTextureInfo,
            texture.TexelCopyBufferInfo,
            texture.Texture.Extent3D,
        ) void,
        copyTextureToTexture: *const fn (
            *anyopaque,
            texture.TexelCopyTextureInfo,
            texture.TexelCopyTextureInfo,
            texture.Texture.Extent3D,
        ) void,
        clearBuffer: *const fn (*anyopaque, Buffer, ?def.Size64, ?def.Size64) void,
        resolveQuerySet: *const fn (*anyopaque, QuerySet, def.Size32, def.Size32, Buffer, def.Size64) void,
        finish: *const fn (
            *anyopaque,
            ?command.CommandBuffer.Descriptor,
        ) anyerror!CommandBuffer,
        pushDebugGroup: *const fn (*anyopaque, []const u8) void,
        popDebugGroup: *const fn (*anyopaque) void,
        insertDebugMarker: *const fn (*anyopaque, []const u8) void,
    };

    pub fn beginRenderPass(
        self: CommandEncoder,
        descriptor: command.RenderPassEncoder.Descriptor,
    ) anyerror!RenderPassEncoder {
        return self.vtable.beginRenderPass(self.ptr, descriptor);
    }

    pub fn beginComputePass(
        self: CommandEncoder,
        descriptor: ?command.ComputePassEncoder.Descriptor,
    ) anyerror!ComputePassEncoder {
        return self.vtable.beginComputePass(self.ptr, descriptor);
    }

    pub fn copyBufferToBuffer(self: CommandEncoder, source: Buffer, destination: Buffer, size: ?def.Size64) void {
        return self.vtable.copyBufferToBuffer(self.ptr, source, destination, size);
    }

    pub fn copyBufferToBufferWithOffsets(
        self: CommandEncoder,
        source: Buffer,
        source_offset: def.Size64,
        destination: Buffer,
        destination_offset: def.Size64,
        size: ?def.Size64,
    ) void {
        return self.vtable.copyBufferToBufferWithOffsets(self.ptr, source, source_offset, destination, destination_offset, size);
    }

    pub fn copyBufferToTexture(
        self: CommandEncoder,
        source: texture.TexelCopyBufferInfo,
        destination: texture.TexelCopyTextureInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        return self.vtable.copyBufferToTexture(self.ptr, source, destination, copy_size);
    }

    pub fn copyTextureToBuffer(
        self: CommandEncoder,
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyBufferInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        return self.vtable.copyTextureToBuffer(self.ptr, source, destination, copy_size);
    }

    pub fn copyTextureToTexture(
        self: CommandEncoder,
        source: texture.TexelCopyTextureInfo,
        destination: texture.TexelCopyTextureInfo,
        copy_size: texture.Texture.Extent3D,
    ) void {
        return self.vtable.copyTextureToTexture(self.ptr, source, destination, copy_size);
    }

    pub fn clearBuffer(self: CommandEncoder, target: Buffer, offset: ?def.Size64, size: ?def.Size64) void {
        return self.vtable.clearBuffer(self.ptr, target, offset, size);
    }

    pub fn resolveQuerySet(
        self: CommandEncoder,
        query_set: QuerySet,
        first_query: def.Size32,
        query_count: def.Size32,
        destination: Buffer,
        destination_offset: def.Size64,
    ) void {
        return self.vtable.resolveQuerySet(self.ptr, query_set, first_query, query_count, destination, destination_offset);
    }

    pub fn finish(
        self: CommandEncoder,
        descriptor: ?command.CommandBuffer.Descriptor,
    ) anyerror!CommandBuffer {
        return self.vtable.finish(self.ptr, descriptor);
    }

    pub fn pushDebugGroup(self: CommandEncoder, group_label: []const u8) void {
        return self.vtable.pushDebugGroup(self.ptr, group_label);
    }

    pub fn popDebugGroup(self: CommandEncoder) void {
        return self.vtable.popDebugGroup(self.ptr);
    }

    pub fn insertDebugMarker(self: CommandEncoder, marker_label: []const u8) void {
        return self.vtable.insertDebugMarker(self.ptr, marker_label);
    }
};

pub const ComputePassEncoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setPipeline: *const fn (*anyopaque, ComputePipeline) void,
        dispatchWorkgroups: *const fn (*anyopaque, def.Size32, def.Size32, def.Size32) void,
        dispatchWorkgroupsIndirect: *const fn (*anyopaque, Buffer, def.Size64) void,
        end: *const fn (*anyopaque) void,
        setBindGroup: *const fn (*anyopaque, def.Index32, ?BindGroup, []const def.BufferDynamicOffset) void,
        setBindGroupFromData: *const fn (*anyopaque, def.Index32, ?BindGroup, []const u32, def.Size64, def.Size32) void,
        pushDebugGroup: *const fn (*anyopaque, []const u8) void,
        popDebugGroup: *const fn (*anyopaque) void,
        insertDebugMarker: *const fn (*anyopaque, []const u8) void,
    };

    pub fn setPipeline(self: ComputePassEncoder, target: ComputePipeline) void {
        return self.vtable.setPipeline(self.ptr, target);
    }

    pub fn dispatchWorkgroups(
        self: ComputePassEncoder,
        workgroup_count_x: def.Size32,
        workgroup_count_y: def.Size32,
        workgroup_count_z: def.Size32,
    ) void {
        return self.vtable.dispatchWorkgroups(self.ptr, workgroup_count_x, workgroup_count_y, workgroup_count_z);
    }

    pub fn dispatchWorkgroupsIndirect(self: ComputePassEncoder, indirect_buffer: Buffer, indirect_offset: def.Size64) void {
        return self.vtable.dispatchWorkgroupsIndirect(self.ptr, indirect_buffer, indirect_offset);
    }

    pub fn end(self: ComputePassEncoder) void {
        return self.vtable.end(self.ptr);
    }

    pub fn setBindGroup(
        self: ComputePassEncoder,
        index: def.Index32,
        group: ?BindGroup,
        dynamic_offsets: []const def.BufferDynamicOffset,
    ) void {
        return self.vtable.setBindGroup(self.ptr, index, group, dynamic_offsets);
    }

    pub fn setBindGroupFromData(
        self: ComputePassEncoder,
        index: def.Index32,
        group: ?BindGroup,
        dynamic_offsets_data: []const u32,
        dynamic_offsets_data_start: def.Size64,
        dynamic_offsets_data_length: def.Size32,
    ) void {
        return self.vtable.setBindGroupFromData(
            self.ptr,
            index,
            group,
            dynamic_offsets_data,
            dynamic_offsets_data_start,
            dynamic_offsets_data_length,
        );
    }

    pub fn pushDebugGroup(self: ComputePassEncoder, group_label: []const u8) void {
        return self.vtable.pushDebugGroup(self.ptr, group_label);
    }

    pub fn popDebugGroup(self: ComputePassEncoder) void {
        return self.vtable.popDebugGroup(self.ptr);
    }

    pub fn insertDebugMarker(self: ComputePassEncoder, marker_label: []const u8) void {
        return self.vtable.insertDebugMarker(self.ptr, marker_label);
    }
};

pub const RenderPassEncoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setViewport: *const fn (*anyopaque, f32, f32, f32, f32, f32, f32) void,
        setScissorRect: *const fn (
            *anyopaque,
            def.IntegerCoordinate,
            def.IntegerCoordinate,
            def.IntegerCoordinate,
            def.IntegerCoordinate,
        ) void,
        setBlendConstant: *const fn (*anyopaque, def.Color) void,
        setStencilReference: *const fn (*anyopaque, def.StencilValue) void,
        beginOcclusionQuery: *const fn (*anyopaque, def.Size32) void,
        endOcclusionQuery: *const fn (*anyopaque) void,
        executeBundles: *const fn (*anyopaque, []const RenderBundle) void,
        end: *const fn (*anyopaque) void,
        setPipeline: *const fn (*anyopaque, RenderPipeline) void,
        setIndexBuffer: *const fn (*anyopaque, Buffer, pipeline.IndexFormat, def.Size64, ?def.Size64) void,
        setVertexBuffer: *const fn (*anyopaque, def.Index32, ?Buffer, def.Size64, ?def.Size64) void,
        draw: *const fn (*anyopaque, def.Size32, def.Size32, def.Size32, def.Size32) void,
        drawIndexed: *const fn (*anyopaque, def.Size32, def.Size32, def.Size32, def.SignedOffset32, def.Size32) void,
        drawIndirect: *const fn (*anyopaque, Buffer, def.Size64) void,
        drawIndexedIndirect: *const fn (*anyopaque, Buffer, def.Size64) void,
        setBindGroup: *const fn (*anyopaque, def.Index32, ?BindGroup, []const def.BufferDynamicOffset) void,
        setBindGroupFromData: *const fn (*anyopaque, def.Index32, ?BindGroup, []const u32, def.Size64, def.Size32) void,
        pushDebugGroup: *const fn (*anyopaque, []const u8) void,
        popDebugGroup: *const fn (*anyopaque) void,
        insertDebugMarker: *const fn (*anyopaque, []const u8) void,
    };

    pub fn setViewport(self: RenderPassEncoder, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void {
        return self.vtable.setViewport(self.ptr, x, y, width, height, min_depth, max_depth);
    }

    pub fn setScissorRect(
        self: RenderPassEncoder,
        x: def.IntegerCoordinate,
        y: def.IntegerCoordinate,
        width: def.IntegerCoordinate,
        height: def.IntegerCoordinate,
    ) void {
        return self.vtable.setScissorRect(self.ptr, x, y, width, height);
    }

    pub fn setBlendConstant(self: RenderPassEncoder, color: def.Color) void {
        return self.vtable.setBlendConstant(self.ptr, color);
    }

    pub fn setStencilReference(self: RenderPassEncoder, reference: def.StencilValue) void {
        return self.vtable.setStencilReference(self.ptr, reference);
    }

    pub fn beginOcclusionQuery(self: RenderPassEncoder, query_index: def.Size32) void {
        return self.vtable.beginOcclusionQuery(self.ptr, query_index);
    }

    pub fn endOcclusionQuery(self: RenderPassEncoder) void {
        return self.vtable.endOcclusionQuery(self.ptr);
    }

    pub fn executeBundles(self: RenderPassEncoder, bundles: []const RenderBundle) void {
        return self.vtable.executeBundles(self.ptr, bundles);
    }

    pub fn end(self: RenderPassEncoder) void {
        return self.vtable.end(self.ptr);
    }

    pub fn setPipeline(self: RenderPassEncoder, target: RenderPipeline) void {
        return self.vtable.setPipeline(self.ptr, target);
    }

    pub fn setIndexBuffer(
        self: RenderPassEncoder,
        target: Buffer,
        index_format: pipeline.IndexFormat,
        offset: def.Size64,
        size: ?def.Size64,
    ) void {
        return self.vtable.setIndexBuffer(self.ptr, target, index_format, offset, size);
    }

    pub fn setVertexBuffer(
        self: RenderPassEncoder,
        slot: def.Index32,
        target: ?Buffer,
        offset: def.Size64,
        size: ?def.Size64,
    ) void {
        return self.vtable.setVertexBuffer(self.ptr, slot, target, offset, size);
    }

    pub fn draw(
        self: RenderPassEncoder,
        vertex_count: def.Size32,
        instance_count: def.Size32,
        first_vertex: def.Size32,
        first_instance: def.Size32,
    ) void {
        return self.vtable.draw(self.ptr, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(
        self: RenderPassEncoder,
        index_count: def.Size32,
        instance_count: def.Size32,
        first_index: def.Size32,
        base_vertex: def.SignedOffset32,
        first_instance: def.Size32,
    ) void {
        return self.vtable.drawIndexed(self.ptr, index_count, instance_count, first_index, base_vertex, first_instance);
    }

    pub fn drawIndirect(self: RenderPassEncoder, indirect_buffer: Buffer, indirect_offset: def.Size64) void {
        return self.vtable.drawIndirect(self.ptr, indirect_buffer, indirect_offset);
    }

    pub fn drawIndexedIndirect(self: RenderPassEncoder, indirect_buffer: Buffer, indirect_offset: def.Size64) void {
        return self.vtable.drawIndexedIndirect(self.ptr, indirect_buffer, indirect_offset);
    }

    pub fn setBindGroup(
        self: RenderPassEncoder,
        index: def.Index32,
        group: ?BindGroup,
        dynamic_offsets: []const def.BufferDynamicOffset,
    ) void {
        return self.vtable.setBindGroup(self.ptr, index, group, dynamic_offsets);
    }

    pub fn setBindGroupFromData(
        self: RenderPassEncoder,
        index: def.Index32,
        group: ?BindGroup,
        dynamic_offsets_data: []const u32,
        dynamic_offsets_data_start: def.Size64,
        dynamic_offsets_data_length: def.Size32,
    ) void {
        return self.vtable.setBindGroupFromData(
            self.ptr,
            index,
            group,
            dynamic_offsets_data,
            dynamic_offsets_data_start,
            dynamic_offsets_data_length,
        );
    }

    pub fn pushDebugGroup(self: RenderPassEncoder, group_label: []const u8) void {
        return self.vtable.pushDebugGroup(self.ptr, group_label);
    }

    pub fn popDebugGroup(self: RenderPassEncoder) void {
        return self.vtable.popDebugGroup(self.ptr);
    }

    pub fn insertDebugMarker(self: RenderPassEncoder, marker_label: []const u8) void {
        return self.vtable.insertDebugMarker(self.ptr, marker_label);
    }
};

pub const RenderBundle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: RenderBundle) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const RenderBundleEncoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        finish: *const fn (
            *anyopaque,
            ?command.RenderBundle.Descriptor,
        ) anyerror!RenderBundle,
        setPipeline: *const fn (*anyopaque, RenderPipeline) void,
        setIndexBuffer: *const fn (*anyopaque, Buffer, pipeline.IndexFormat, def.Size64, ?def.Size64) void,
        setVertexBuffer: *const fn (*anyopaque, def.Index32, ?Buffer, def.Size64, ?def.Size64) void,
        draw: *const fn (*anyopaque, def.Size32, def.Size32, def.Size32, def.Size32) void,
        drawIndexed: *const fn (*anyopaque, def.Size32, def.Size32, def.Size32, def.SignedOffset32, def.Size32) void,
        drawIndirect: *const fn (*anyopaque, Buffer, def.Size64) void,
        drawIndexedIndirect: *const fn (*anyopaque, Buffer, def.Size64) void,
        setBindGroup: *const fn (*anyopaque, def.Index32, ?BindGroup, []const def.BufferDynamicOffset) void,
        setBindGroupFromData: *const fn (*anyopaque, def.Index32, ?BindGroup, []const u32, def.Size64, def.Size32) void,
        pushDebugGroup: *const fn (*anyopaque, []const u8) void,
        popDebugGroup: *const fn (*anyopaque) void,
        insertDebugMarker: *const fn (*anyopaque, []const u8) void,
    };

    pub fn finish(
        self: RenderBundleEncoder,
        descriptor: ?command.RenderBundle.Descriptor,
    ) anyerror!RenderBundle {
        return self.vtable.finish(self.ptr, descriptor);
    }

    pub fn setPipeline(self: RenderBundleEncoder, target: RenderPipeline) void {
        return self.vtable.setPipeline(self.ptr, target);
    }

    pub fn setIndexBuffer(
        self: RenderBundleEncoder,
        target: Buffer,
        index_format: pipeline.IndexFormat,
        offset: def.Size64,
        size: ?def.Size64,
    ) void {
        return self.vtable.setIndexBuffer(self.ptr, target, index_format, offset, size);
    }

    pub fn setVertexBuffer(
        self: RenderBundleEncoder,
        slot: def.Index32,
        target: ?Buffer,
        offset: def.Size64,
        size: ?def.Size64,
    ) void {
        return self.vtable.setVertexBuffer(self.ptr, slot, target, offset, size);
    }

    pub fn draw(
        self: RenderBundleEncoder,
        vertex_count: def.Size32,
        instance_count: def.Size32,
        first_vertex: def.Size32,
        first_instance: def.Size32,
    ) void {
        return self.vtable.draw(self.ptr, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(
        self: RenderBundleEncoder,
        index_count: def.Size32,
        instance_count: def.Size32,
        first_index: def.Size32,
        base_vertex: def.SignedOffset32,
        first_instance: def.Size32,
    ) void {
        return self.vtable.drawIndexed(self.ptr, index_count, instance_count, first_index, base_vertex, first_instance);
    }

    pub fn drawIndirect(self: RenderBundleEncoder, indirect_buffer: Buffer, indirect_offset: def.Size64) void {
        return self.vtable.drawIndirect(self.ptr, indirect_buffer, indirect_offset);
    }

    pub fn drawIndexedIndirect(self: RenderBundleEncoder, indirect_buffer: Buffer, indirect_offset: def.Size64) void {
        return self.vtable.drawIndexedIndirect(self.ptr, indirect_buffer, indirect_offset);
    }

    pub fn setBindGroup(
        self: RenderBundleEncoder,
        index: def.Index32,
        group: ?BindGroup,
        dynamic_offsets: []const def.BufferDynamicOffset,
    ) void {
        return self.vtable.setBindGroup(self.ptr, index, group, dynamic_offsets);
    }

    pub fn setBindGroupFromData(
        self: RenderBundleEncoder,
        index: def.Index32,
        group: ?BindGroup,
        dynamic_offsets_data: []const u32,
        dynamic_offsets_data_start: def.Size64,
        dynamic_offsets_data_length: def.Size32,
    ) void {
        return self.vtable.setBindGroupFromData(
            self.ptr,
            index,
            group,
            dynamic_offsets_data,
            dynamic_offsets_data_start,
            dynamic_offsets_data_length,
        );
    }

    pub fn pushDebugGroup(self: RenderBundleEncoder, group_label: []const u8) void {
        return self.vtable.pushDebugGroup(self.ptr, group_label);
    }

    pub fn popDebugGroup(self: RenderBundleEncoder) void {
        return self.vtable.popDebugGroup(self.ptr);
    }

    pub fn insertDebugMarker(self: RenderBundleEncoder, marker_label: []const u8) void {
        return self.vtable.insertDebugMarker(self.ptr, marker_label);
    }
};

pub const QuerySet = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
    };

    pub fn destroy(self: QuerySet) void {
        return self.vtable.destroy(self.ptr);
    }
};

pub const CanvasContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        configure: *const fn (*anyopaque, texture.CanvasContext.Configuration) void,
        unconfigure: *const fn (*anyopaque) void,
        getConfiguration: *const fn (*anyopaque) ?texture.CanvasContext.Configuration,
        getCurrentTexture: *const fn (
            *anyopaque,
        ) anyerror!Texture,
    };

    pub fn configure(self: CanvasContext, configuration: texture.CanvasContext.Configuration) void {
        return self.vtable.configure(self.ptr, configuration);
    }

    pub fn unconfigure(self: CanvasContext) void {
        return self.vtable.unconfigure(self.ptr);
    }

    pub fn getConfiguration(self: CanvasContext) ?texture.CanvasContext.Configuration {
        return self.vtable.getConfiguration(self.ptr);
    }

    pub fn getCurrentTexture(
        self: CanvasContext,
    ) anyerror!Texture {
        return self.vtable.getCurrentTexture(self.ptr);
    }
};

pub const Surface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        getCapabilities: *const fn (*anyopaque, Adapter) texture.Surface.Capabilities,
        configure: *const fn (*anyopaque, Device, texture.Surface.Configuration) void,
        unconfigure: *const fn (*anyopaque) void,
        getCurrentTexture: *const fn (*anyopaque) anyerror!texture.Surface.CurrentSurfaceTexture,
    };

    pub fn destroy(self: Surface) void {
        log.debug("surface.destroy dispatch", .{});
        return self.vtable.destroy(self.ptr);
    }

    pub fn getCapabilities(self: Surface, adapter: Adapter) texture.Surface.Capabilities {
        log.debug("surface.getCapabilities dispatch", .{});
        return self.vtable.getCapabilities(self.ptr, adapter);
    }

    pub fn configure(self: Surface, device: Device, configuration: texture.Surface.Configuration) void {
        log.debug("surface.configure dispatch", .{});
        return self.vtable.configure(self.ptr, device, configuration);
    }

    pub fn unconfigure(self: Surface) void {
        log.debug("surface.unconfigure dispatch", .{});
        return self.vtable.unconfigure(self.ptr);
    }

    pub fn getCurrentTexture(self: Surface) anyerror!texture.Surface.CurrentSurfaceTexture {
        log.debug("surface.getCurrentTexture dispatch", .{});
        return self.vtable.getCurrentTexture(self.ptr);
    }
};
