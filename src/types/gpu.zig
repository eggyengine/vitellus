const std = @import("std");

const features = @import("features.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const sampler = @import("sampler.zig");
const bind_group = @import("bind_group.zig");
const command = @import("command.zig");
const def = @import("def.zig");
const pipeline = @import("pipeline.zig");
const shader = @import("shader.zig");
const hal = @import("../backends/hal.zig");

pub const GPU = struct {
    backend: hal.GPU,
    wgslLanguageFeatures: []const []const u8 = &.{},

    pub const Descriptor = struct {
        wgslLanguageFeatures: []const []const u8 = &.{},
    };

    pub fn requestAdapter(self: *@This(), io: std.Io, options: Adapter.RequestOptions) std.Io.Future(Adapter.RequestAdapterError!Adapter) {
        return io.async(requestAdapterInternal, .{ self, io, options });
    }

    pub fn init(comptime Backend: type, descriptor: Descriptor) GPU {
        return .{
            .backend = Backend.init(),
            .wgslLanguageFeatures = descriptor.wgslLanguageFeatures,
        };
    }

    pub fn initFromBackend(backend: hal.GPU, descriptor: Descriptor) GPU {
        return .{
            .backend = backend,
            .wgslLanguageFeatures = descriptor.wgslLanguageFeatures,
        };
    }

    pub fn initFromPotentialBackends(comptime flags: hal.Backends, descriptor: Descriptor) hal.GPU.FromPotentialBackendsError!GPU {
        const Backend = try hal.GPU.fromPotentialBackends(flags);
        return init(Backend, descriptor);
    }

    pub fn getPreferredCanvasFormat() texture.Texture.Format {
        return .bgra8unorm;
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    fn requestAdapterInternal(
        self: *@This(),
        io: std.Io,
        options: Adapter.RequestOptions,
    ) Adapter.RequestAdapterError!Adapter {
        var future = self.backend.requestAdapter(io, options);
        defer _ = future.cancel(io) catch {};

        const backend_adapter = future.await(io) catch return error.NoAdapter;
        return .{
            .backend = backend_adapter,
            .features = &.{},
            .limits = &.{},
            .info = .{
                .vendor = "",
                .architecture = "",
                .device = "",
                .description = "",
                .subgroupMinSize = 0,
                .subgroupMaxSize = 0,
                .isFallbackAdapter = false,
            },
            .gpu = self,
        };
    }
};

pub const Adapter = struct {
    backend: hal.Adapter,
    features: []const features.FeatureName,
    limits: []const features.SupportedLimitNumber,
    info: Info,
    gpu: *GPU,

    pub const RequestOptions = struct {
        label: ?[*:0]const u8 = null,
        feature_level: FeatureLevel = .core,
        power_preference: ?PowerPreference = null,
        force_fallback_adapter: bool = false,
        xr_compatible: bool = false,
    };

    pub const Info = struct {
        vendor: [*:0]const u8,
        architecture: [*:0]const u8,
        device: [*:0]const u8,
        description: [*:0]const u8,
        subgroupMinSize: u32,
        subgroupMaxSize: u32,
        isFallbackAdapter: bool,
    };

    pub const RequestAdapterError = error{NoAdapter};

    pub const FeatureLevel = enum { core, compatibility };

    pub const PowerPreference = enum {
        lowPower,
        highPerformance,
    };

    pub fn requestDevice(self: *@This(), io: std.Io, options: Device.Descriptor) std.Io.Future(Device.RequestDeviceError!Device) {
        return io.async(requestDeviceInternal, .{ self, io, options });
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    fn requestDeviceInternal(
        self: *@This(),
        io: std.Io,
        options: Device.Descriptor,
    ) Device.RequestDeviceError!Device {
        var future = self.backend.requestDevice(io, options);
        defer _ = future.cancel(io) catch {};

        const backend_device = future.await(io) catch return error.UnsupportedFeature;
        return .{
            .backend = backend_device,
            .adapter = self.*,
            .queue = .{
                .backend = backend_device.getQueue(),
            },
        };
    }
};

pub const Device = struct {
    backend: hal.Device,
    adapter: Adapter,

    queue: Queue,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        required_features: []const features.FeatureName = &.{},
        required_limits: []const features.SupportedLimitNumber = &.{},
        default_queue: Queue.Descriptor = .{},
    };

    pub const RequestDeviceError = error{
        UnsupportedFeature,
        UnsupportedLimit,
    };
    pub const CreatePipelineAsyncError = pipeline.PipelineError.Error;
    pub const LostError = error{NotImplemented};
    pub const PopErrorScopeError = error{NotImplemented};

    pub const LostInfo = struct {
        reason: LostReason,
        message: [*:0]const u8 = "",
    };

    pub const LostReason = enum {
        unknown,
        destroyed,
    };

    pub const Error = union(enum) {
        validation: ValidationError,
        out_of_memory: OutOfMemoryError,
        internal: InternalError,
    };

    pub const ErrorFilter = enum {
        validation,
        out_of_memory,
        internal,
    };

    pub const UncapturedErrorEvent = struct {
        type: []const u8,
        @"error": Error,
    };

    pub const ValidationError = struct {
        message: [*:0]const u8,
    };

    pub const OutOfMemoryError = struct {
        message: [*:0]const u8,
    };

    pub const InternalError = struct {
        message: [*:0]const u8,
    };

    pub fn destroy(self: *@This()) void {
        _ = self;
    }

    pub fn createBuffer(self: *@This(), descriptor: buffer.Buffer.Descriptor) buffer.Buffer {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createTexture(self: *@This(), descriptor: texture.Texture.Descriptor) texture.Texture {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createSampler(self: *@This(), descriptor: ?sampler.Sampler.Descriptor) sampler.Sampler {
        _ = self;
        return sampler.Sampler.init(descriptor orelse .{});
    }

    pub fn importExternalTexture(self: *@This(), descriptor: texture.ExternalTexture.Descriptor) texture.ExternalTexture {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createBindGroupLayout(self: *@This(), descriptor: BindGroupLayout.Descriptor) BindGroupLayout {
        _ = self;
        return BindGroupLayout.init(descriptor);
    }

    pub fn createPipelineLayout(self: *@This(), descriptor: PipelineLayout.Descriptor) PipelineLayout {
        _ = self;
        return PipelineLayout.init(descriptor);
    }

    pub fn createBindGroup(self: *@This(), descriptor: BindGroup.Descriptor) BindGroup {
        _ = self;
        return BindGroup.init(descriptor);
    }

    pub fn createShaderModule(self: *@This(), descriptor: shader.ShaderModule.Descriptor) shader.ShaderModule {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createComputePipeline(self: *@This(), descriptor: ComputePipeline.Descriptor) ComputePipeline {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createRenderPipeline(self: *@This(), descriptor: RenderPipeline.Descriptor) RenderPipeline {
        _ = self;
        _ = descriptor;
        return .{};
    }

    fn createComputePipelineAsyncInternal(
        self: *@This(),
        descriptor: ComputePipeline.Descriptor,
    ) CreatePipelineAsyncError!ComputePipeline {
        _ = self;
        _ = descriptor;
        return error.Internal;
    }

    fn createRenderPipelineAsyncInternal(
        self: *@This(),
        descriptor: RenderPipeline.Descriptor,
    ) CreatePipelineAsyncError!RenderPipeline {
        _ = self;
        _ = descriptor;
        return error.Internal;
    }

    pub fn createComputePipelineAsync(
        self: *@This(),
        io: std.Io,
        descriptor: ComputePipeline.Descriptor,
    ) std.Io.Future(CreatePipelineAsyncError!ComputePipeline) {
        return io.async(createComputePipelineAsyncInternal, .{ self, descriptor });
    }

    pub fn createRenderPipelineAsync(
        self: *@This(),
        io: std.Io,
        descriptor: RenderPipeline.Descriptor,
    ) std.Io.Future(CreatePipelineAsyncError!RenderPipeline) {
        return io.async(createRenderPipelineAsyncInternal, .{ self, descriptor });
    }

    pub fn createCommandEncoder(self: *@This(), descriptor: ?CommandEncoder.Descriptor) CommandEncoder {
        _ = self;
        return .{ .label = if (descriptor) |d| d.label else null };
    }

    pub fn createRenderBundleEncoder(self: *@This(), descriptor: RenderBundleEncoder.Descriptor) RenderBundleEncoder {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createQuerySet(self: *@This(), descriptor: QuerySet.Descriptor) QuerySet {
        _ = self;
        return .{
            .label = descriptor.label,
            .type = descriptor.type,
            .count = descriptor.count,
        };
    }

    fn lostInternal(self: *@This()) LostError!LostInfo {
        _ = self;
        return error.NotImplemented;
    }

    pub fn lost(self: *@This(), io: std.Io) std.Io.Future(LostError!LostInfo) {
        return io.async(lostInternal, .{self});
    }

    fn popErrorScopeInternal(self: *@This()) PopErrorScopeError!?Error {
        _ = self;
        return error.NotImplemented;
    }

    pub fn popErrorScope(self: *@This(), io: std.Io) std.Io.Future(PopErrorScopeError!?Error) {
        return io.async(popErrorScopeInternal, .{self});
    }

    pub fn pushErrorScope(self: *@This(), filter: ErrorFilter) void {
        _ = self;
        _ = filter;
    }
};

pub const Queue = struct {
    backend: hal.Queue,

    pub const OnSubmittedWorkDoneError = error{NotImplemented};

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub fn submit(self: *@This(), commandBuffers: []const command.CommandBuffer) void {
        _ = self;
        _ = commandBuffers;
    }

    pub fn writeBuffer(
        self: *@This(),
        target: *buffer.Buffer,
        bufferOffset: def.Size64,
        data: def.AllowSharedBufferSource,
        dataOffset: def.Size64,
        size: ?def.Size64,
    ) void {
        _ = self;
        _ = target;
        _ = bufferOffset;
        _ = data;
        _ = dataOffset;
        _ = size;
    }

    pub fn writeTexture(
        self: *@This(),
        destination: texture.TexelCopyTextureInfo,
        data: def.AllowSharedBufferSource,
        dataLayout: texture.TexelCopyBufferLayout,
        size: texture.Texture.Extent3D,
    ) void {
        _ = self;
        _ = destination;
        _ = data;
        _ = dataLayout;
        _ = size;
    }

    pub fn copyExternalImageToTexture(
        self: *@This(),
        source: texture.CopyExternalImageSourceInfo,
        destination: texture.CopyExternalImageDestInfo,
        copySize: texture.Texture.Extent3D,
    ) void {
        _ = self;
        _ = source;
        _ = destination;
        _ = copySize;
    }

    fn onSubmittedWorkDoneInternal(self: *@This()) OnSubmittedWorkDoneError!void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn onSubmittedWorkDone(self: *@This(), io: std.Io) std.Io.Future(OnSubmittedWorkDoneError!void) {
        return io.async(onSubmittedWorkDoneInternal, .{self});
    }
};

pub const BindGroupLayout = bind_group.BindGroupLayout;

pub const PipelineLayout = pipeline.PipelineLayout;

pub const BindGroup = bind_group.BindGroup;

pub const PipelineError = pipeline.PipelineError;

pub const ComputePipeline = pipeline.ComputePipeline;

pub const RenderPipeline = pipeline.RenderPipeline;

pub const CommandBuffer = command.CommandBuffer;

pub const CommandEncoder = command.CommandEncoder;

pub const ComputePassEncoder = command.ComputePassEncoder;

pub const RenderPassEncoder = command.RenderPassEncoder;

pub const RenderBundle = command.RenderBundle;

pub const RenderBundleEncoder = command.RenderBundleEncoder;

pub const QuerySet = struct {
    label: ?[*:0]const u8 = null,
    type: Type,
    count: def.Size32Out,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        type: Type,
        count: def.Size32,
    };

    pub const Type = enum {
        occlusion,
        timestamp,
    };

    pub fn destroy(self: *@This()) void {
        _ = self;
    }
};
