const std = @import("std");

const features = @import("features.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const sampler = @import("sampler.zig");
const bind_group_layout = @import("bind_group_layout.zig");
const bind_group = @import("bind_group.zig");
const pipeline_layout = @import("pipeline_layout.zig");

pub const GPU = struct {
    fn requestAdapterInternal(options: Adapter.RequestOptions) Adapter.RequestAdapterError!Adapter {
        _ = options;
        return error.NotImplemented;
    }

    pub fn requestAdapter(io: std.Io, options: Adapter.RequestOptions) std.Io.Future(Adapter.RequestAdapterError!Adapter) {
        return io.async(requestAdapterInternal, .{options});
    }

    pub fn requestAdapterAsync(io: std.Io, options: Adapter.RequestOptions) std.Io.Future(Adapter.RequestAdapterError!Adapter) {
        return requestAdapter(io, options);
    }

    pub fn getPreferredCanvasFormat() texture.Texture.Format {
        return .bgra8unorm;
    }
};

pub const Adapter = struct {
    features: []features.FeatureName,
    limits: []features.SupportedLimitNumber,
    info: Info,

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

    pub const RequestAdapterError = error{NotImplemented};

    pub const FeatureLevel = enum { core, compatibility };

    pub const PowerPreference = enum {
        lowPower,
        highPerformance,
    };

    pub fn requestDevice(self: *@This(), io: std.Io, options: Device.Descriptor) std.Io.Future(Device.RequestDeviceError!Device) {
        _ = self;
        return io.async(requestDeviceInternal, .{options});
    }

    fn requestDeviceInternal(options: Device.Descriptor) Device.RequestDeviceError!Device {
        _ = options;
        return error.NotImplemented;
    }
};

pub const Device = struct {
    features: []features.FeatureName,
    limits: []features.SupportedLimitNumber,
    adapter_info: Adapter.Info,

    queue: Queue,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        required_features: []const features.FeatureName = &.{},
        required_limits: []const features.SupportedLimitNumber = &.{},
        default_queue: Queue.Descriptor = .{},
    };

    pub const RequestDeviceError = error{NotImplemented};
    pub const CreatePipelineAsyncError = error{NotImplemented};
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

    pub fn createShaderModule(self: *@This(), descriptor: ShaderModule.Descriptor) ShaderModule {
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
        return error.NotImplemented;
    }

    fn createRenderPipelineAsyncInternal(
        self: *@This(),
        descriptor: RenderPipeline.Descriptor,
    ) CreatePipelineAsyncError!RenderPipeline {
        _ = self;
        _ = descriptor;
        return error.NotImplemented;
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
        _ = descriptor;
        return .{};
    }

    pub fn createRenderBundleEncoder(self: *@This(), descriptor: RenderBundleEncoder.Descriptor) RenderBundleEncoder {
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createQuerySet(self: *@This(), descriptor: QuerySet.Descriptor) QuerySet {
        _ = self;
        _ = descriptor;
        return .{};
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
};

pub const Queue = struct {
    pub const OnSubmittedWorkDoneError = error{NotImplemented};

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    fn onSubmittedWorkDoneInternal(self: *@This()) OnSubmittedWorkDoneError!void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn onSubmittedWorkDone(self: *@This(), io: std.Io) std.Io.Future(OnSubmittedWorkDoneError!void) {
        return io.async(onSubmittedWorkDoneInternal, .{self});
    }
};

pub const BindGroupLayout = bind_group_layout.BindGroupLayout;

pub const PipelineLayout = pipeline_layout.PipelineLayout;

pub const BindGroup = bind_group.BindGroup;

pub const ShaderModule = struct {
    pub const CompilationInfoError = error{NotImplemented};

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub const CompilationInfo = struct {
        messages: []const CompilationMessage = &.{},
    };

    pub const CompilationMessage = struct {
        message: [*:0]const u8,
        type: CompilationMessageType,
        line_num: u64 = 0,
        line_pos: u64 = 0,
        offset: u64 = 0,
        length: u64 = 0,
    };

    pub const CompilationMessageType = enum {
        @"error",
        warning,
        info,
    };

    fn getCompilationInfoInternal(self: *@This()) CompilationInfoError!CompilationInfo {
        _ = self;
        return error.NotImplemented;
    }

    pub fn getCompilationInfo(self: *@This(), io: std.Io) std.Io.Future(CompilationInfoError!CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{self});
    }
};

pub const ComputePipeline = struct {
    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };
};

pub const RenderPipeline = struct {
    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };
};

pub const CommandEncoder = struct {
    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };
};

pub const RenderBundleEncoder = struct {
    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };
};

pub const QuerySet = struct {
    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };
};
