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
const candler = @import("candler");
const windowing = @import("../windowing/windowing.zig");

const logz = @import("logz");

pub const Instance = struct {
    allocator: std.mem.Allocator,
    backend: hal.Instance,
    descriptor: Descriptor,

    pub const Flags = packed struct(u32) {
        debug: bool = false,
        /// Enables validation layers
        validation: bool = @import("builtin").mode == .Debug,
        discard_hal_labels: bool = false,
        _: u29 = 0,

        pub const DEBUG: def.FlagsConstant = 0x01;
        pub const VALIDATION: def.FlagsConstant = 0x02;
        pub const DISCARD_HAL_LABELS: def.FlagsConstant = 0x04;

        pub fn fromFlags(flags: def.FlagsConstant) Flags {
            return @bitCast(flags);
        }

        pub fn toFlags(self: Flags) def.FlagsConstant {
            return @bitCast(self);
        }
    };

    pub const Descriptor = struct {
        allocator: std.mem.Allocator,
        flags: Flags = .{},
        wgslLanguageFeatures: []const []const u8 = &.{},
    };

    pub fn enumerateAdapters(self: *@This(), options: ?Adapter.RequestOptions) ![]Adapter {
        logz.info().fmt("msg", "enumerating adapters: options={}", .{options != null}).log();
        const backend_adapters = try self.backend.enumerateAdapters(options orelse .{});
        defer self.allocator.free(backend_adapters);

        const adapters = try self.allocator.alloc(Adapter, backend_adapters.len);
        for (backend_adapters, adapters) |backend_adapter, *adapter| {
            adapter.* = self.adapterFromBackend(backend_adapter, options orelse .{});
        }

        return adapters;
    }

    pub fn requestAdapter(self: *@This(), io: std.Io, options: Adapter.RequestOptions) std.Io.Future(Adapter.RequestAdapterError!Adapter) {
        logz.info().fmt("msg", "requesting adapter: feature_level={s} fallback={} surface={}", .{
            @tagName(options.feature_level),
            options.force_fallback_adapter,
            options.surface != null,
        }).log();
        return io.async(requestAdapterInternal, .{ self, io, options });
    }

    /// Initialises a `vit.Instance` with a specific backend type, with initialisation being done internally.
    ///
    /// The `init` function must have a signature of `fn init(descriptor: vit.Instance.Descriptor) !vit.Instance`
    pub fn init(comptime Backend: type, descriptor: Descriptor) !Instance {
        logz.info().fmt("msg", "initializing instance with backend {s}", .{@typeName(Backend)}).log();
        const backend = try Backend.init(descriptor);

        return .{
            .backend = backend,
            .descriptor = descriptor,
            .allocator = descriptor.allocator,
        };
    }

    /// Creates a `vit.Instance` object from an already initialised backend.
    pub fn initFromBackend(backend: hal.Instance, descriptor: Descriptor) Instance {
        logz.info().fmt("msg", "initializing instance from backend handle", .{}).log();
        return .{
            .backend = backend,
            .descriptor = descriptor,
            .allocator = descriptor.allocator,
        };
    }

    /// Initialises `vit.Instance` type using the Backends specified in `flags`.
    pub fn initFromPotentialBackends(comptime flags: hal.Backends, descriptor: Descriptor) hal.Instance.FromPotentialBackendsError!Instance {
        logz.info().fmt("msg", "selecting instance backend: flags=0x{x}", .{flags.toFlags()}).log();
        const Backend = try hal.Instance.fromPotentialBackends(flags);
        return init(Backend, descriptor);
    }

    pub fn deinit(self: *@This()) void {
        logz.info().fmt("msg", "deinitializing instance", .{}).log();
        self.backend.deinit();
    }

    pub fn createSurface(
        self: @This(),
        window: anytype,
    ) texture.Surface.CreateError!texture.Surface {
        logz.info().fmt("msg", "creating surface from window", .{}).log();
        const window_handle = getWindowHandle(window) catch |err| {
            logz.info().fmt("msg", "window handle unavailable: {s}", .{@errorName(err)}).log();
            return error.HandleUnavailable;
        };
        const display_handle = getDisplayHandle(window) catch |err| {
            logz.info().fmt("msg", "display handle unavailable: {s}", .{@errorName(err)}).log();
            return error.HandleUnavailable;
        };
        const backend_surface = self.backend.createSurface(window_handle, display_handle) catch |err| {
            logz.info().fmt("msg", "backend surface creation failed: {s}", .{@errorName(err)}).log();
            return error.BackendFailed;
        };

        logz.info().fmt("msg", "surface creation succeeded", .{}).log();

        return texture.Surface.init(backend_surface, window_handle, display_handle);
    }

    fn getWindowHandle(window: anytype) candler.HandleError!candler.WindowHandle {
        return if (@TypeOf(window) == windowing.Window)
            window.window_handle.windowHandle()
        else
            window.windowHandle();
    }

    fn getDisplayHandle(window: anytype) candler.HandleError!candler.DisplayHandle {
        return if (@TypeOf(window) == windowing.Window)
            window.display_handle.displayHandle()
        else
            window.displayHandle();
    }

    pub fn getPreferredCanvasFormat() texture.Texture.Format {
        return .bgra8unorm;
    }

    fn requestAdapterInternal(
        self: *@This(),
        io: std.Io,
        options: Adapter.RequestOptions,
    ) Adapter.RequestAdapterError!Adapter {
        var future = self.backend.requestAdapter(io, options);
        defer _ = future.cancel(io) catch {};

        const backend_adapter = future.await(io) catch |err| {
            logz.info().fmt("msg", "adapter request failed: {s}", .{@errorName(err)}).log();
            return error.NoAdapter;
        };
        logz.info().fmt("msg", "adapter request completed", .{}).log();
        return self.adapterFromBackend(backend_adapter, options);
    }

    fn adapterFromBackend(self: *@This(), backend_adapter: hal.Adapter, options: Adapter.RequestOptions) Adapter {
        const info = backend_adapter.getInfo();
        return .{
            .backend = backend_adapter,
            .features = &.{},
            .limits = &.{},
            .fallback = false,
            .defaultFeatureLevel = options.feature_level,
            .state = .valid,
            .info = info,
            .instance = self,
        };
    }
};

pub const Adapter = struct {
    backend: hal.Adapter,
    features: []const features.FeatureName,
    limits: []const features.SupportedLimitNumber,
    fallback: bool,
    defaultFeatureLevel: FeatureLevel,
    state: State,
    info: Info,
    instance: *Instance,

    pub const RequestOptions = struct {
        label: ?[*:0]const u8 = null,
        surface: ?texture.Surface = null, // null surface means headless
        feature_level: FeatureLevel = .core,
        power_preference: ?PowerPreference = null,
        force_fallback_adapter: bool = false,
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

    pub const DownlevelCapabilities = struct {
        flags: DownlevelFlags = .{},
        limits: DownlevelLimits = .{},
        shaderModel: ShaderModel = .unknown,
    };

    pub const DownlevelFlags = packed struct(u32) {
        compute_shaders: bool = false,
        fragment_storage: bool = false,
        indirect_execution: bool = false,
        base_vertex: bool = false,
        read_only_depth_stencil: bool = false,
        non_power_of_two_mipmapped_textures: bool = false,
        cube_array_textures: bool = false,
        comparison_samplers: bool = false,
        independent_blend: bool = false,
        vertex_storage: bool = false,
        multisampled_shading: bool = false,
        depth_texture_and_buffer_copies: bool = false,

        _: u20 = 0,
    };

    pub const DownlevelLimits = struct {
        maxTextureDimension1D: def.IntegerCoordinate = 0,
        maxTextureDimension2D: def.IntegerCoordinate = 0,
        maxTextureDimension3D: def.IntegerCoordinate = 0,
        maxTextureArrayLayers: def.IntegerCoordinate = 0,
        maxBindGroups: def.Size32 = 0,
    };

    pub const ShaderModel = enum {
        unknown,
        sm5,
        sm6,
    };

    pub const TextureFormatFeatures = struct {
        allowedUsages: texture.Texture.UsageFlags = 0,
        flags: TextureFormatFeatureFlags = .{},
    };

    pub const TextureFormatFeatureFlags = packed struct(u32) {
        filterable: bool = false,
        blendable: bool = false,
        multisample_x2: bool = false,
        multisample_x4: bool = false,
        multisample_x8: bool = false,
        multisample_x16: bool = false,

        _: u26 = 0,
    };

    pub const RequestAdapterError = error{NoAdapter};

    pub const FeatureLevel = enum { core, compatibility };

    pub const State = enum {
        valid,
        consumed,
        expired,
    };

    pub const PowerPreference = enum {
        lowPower,
        highPerformance,
    };

    pub fn requestDevice(self: *@This(), io: std.Io, options: Device.Descriptor) std.Io.Future(Device.RequestDeviceError!struct { Device, Queue }) {
        logz.info().fmt("msg", "requesting device: required_features={} required_limits={}", .{
            options.required_features.len,
            options.required_limits.len,
        }).log();
        return io.async(requestDeviceInternal, .{ self, io, options });
    }

    pub fn deinit(self: *@This()) void {
        logz.info().fmt("msg", "deinitializing adapter: state={s}", .{@tagName(self.state)}).log();
    }

    pub fn getInfo(self: *const @This()) Info {
        logz.info().fmt("msg", "getting adapter info", .{}).log();
        return self.backend.getInfo();
    }

    pub fn getDownlevelCapabilities(self: *const @This()) DownlevelCapabilities {
        logz.info().fmt("msg", "getting adapter downlevel capabilities", .{}).log();
        return self.backend.getDownlevelCapabilities();
    }

    pub fn getTextureFormatFeatures(
        self: *const @This(),
        format: texture.Texture.Format,
    ) TextureFormatFeatures {
        logz.info().fmt("msg", "getting adapter texture format features: format={s}", .{@tagName(format)}).log();
        return self.backend.getTextureFormatFeatures(format);
    }

    pub fn isSurfaceSupported(self: *const @This(), surface: *const texture.Surface) bool {
        logz.info().fmt("msg", "checking adapter surface support", .{}).log();
        return self.backend.isSurfaceSupported(surface.backend);
    }

    fn requestDeviceInternal(
        self: *@This(),
        io: std.Io,
        options: Device.Descriptor,
    ) Device.RequestDeviceError!struct { Device, Queue } {
        if (self.state != .valid) {
            logz.info().fmt("msg", "device request rejected: adapter state={s}", .{@tagName(self.state)}).log();
            return error.InvalidAdapter;
        }

        var future = self.backend.requestDevice(io, options);
        defer _ = future.cancel(io) catch {};

        const backend_device, const backend_queue = future.await(io) catch |err| {
            logz.info().fmt("msg", "backend device request failed: {s}", .{@errorName(err)}).log();
            return error.UnsupportedFeature;
        };
        self.state = .consumed;
        logz.info().fmt("msg", "device request completed", .{}).log();

        const device = Device{
            .backend = backend_device,
            .adapter = self.*,
            .features = options.required_features,
            .limits = options.required_limits,
            .state = .valid,
            .contentDevice = null,
            .queue = .{
                .backend = backend_queue,
            },
        };
        return .{ device, device.queue };
    }
};

pub const Device = struct {
    backend: hal.Device,
    adapter: Adapter,
    features: []const features.FeatureName,
    limits: []const features.SupportedLimitNumber,
    state: State,
    contentDevice: ?*Device,

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
        InvalidAdapter,
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

    pub const State = enum {
        valid,
        lost,
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
        if (self.state == .destroyed) {
            logz.info().fmt("msg", "device destroy ignored: already destroyed", .{}).log();
            return;
        }

        logz.info().fmt("msg", "destroying device", .{}).log();
        self.state = .destroyed;
        self.backend.destroy();
    }

    pub fn createBuffer(self: *@This(), descriptor: buffer.Buffer.Descriptor) buffer.Buffer {
        logz.info().fmt("msg", "creating buffer", .{}).log();
        _ = self;
        return .{
            .size = descriptor.size,
            .usage = descriptor.usage,
            .map_state = if (descriptor.mappedAtCreation) .mapped else .unmapped,
        };
    }

    pub fn createTexture(self: *@This(), descriptor: texture.Texture.Descriptor) texture.Texture {
        logz.info().fmt("msg", "creating texture", .{}).log();
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createSampler(self: *@This(), descriptor: ?sampler.Sampler.Descriptor) sampler.Sampler {
        logz.info().fmt("msg", "creating sampler: descriptor={}", .{descriptor != null}).log();
        _ = self;
        return sampler.Sampler.init(descriptor orelse .{});
    }

    pub fn importExternalTexture(self: *@This(), descriptor: texture.ExternalTexture.Descriptor) texture.ExternalTexture {
        logz.info().fmt("msg", "importing external texture", .{}).log();
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createBindGroupLayout(self: *@This(), descriptor: BindGroupLayout.Descriptor) BindGroupLayout {
        logz.info().fmt("msg", "creating bind group layout", .{}).log();
        _ = self;
        return BindGroupLayout.init(descriptor);
    }

    pub fn createPipelineLayout(self: *@This(), descriptor: PipelineLayout.Descriptor) PipelineLayout {
        logz.info().fmt("msg", "creating pipeline layout", .{}).log();
        const backend = self.backend.createPipelineLayout(descriptor) catch |err| {
            logz.err().fmt("msg", "backend pipeline layout creation failed: {s}", .{@errorName(err)}).log();
            @panic("failed to create pipeline layout");
        };
        var layout = PipelineLayout.init(descriptor);
        layout.backend = backend;
        return layout;
    }

    pub fn createBindGroup(self: *@This(), descriptor: BindGroup.Descriptor) BindGroup {
        logz.info().fmt("msg", "creating bind group", .{}).log();
        _ = self;
        return BindGroup.init(descriptor);
    }

    pub fn createShaderModule(self: *@This(), descriptor: shader.ShaderModule.Descriptor) !shader.ShaderModule {
        logz.info().fmt("msg", "creating shader module", .{}).log();
        const backend = self.backend.createShaderModule(descriptor) catch |err| {
            logz.err().fmt("msg", "backend shader module creation failed: {s}", .{@errorName(err)}).log();
            @panic("failed to create shader module");
        };
        return .{
            .backend = backend,
            .label = descriptor.label,
        };
    }

    pub fn createComputePipeline(self: *@This(), descriptor: ComputePipeline.Descriptor) ComputePipeline {
        logz.info().fmt("msg", "creating compute pipeline", .{}).log();
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createRenderPipeline(self: *@This(), descriptor: RenderPipeline.Descriptor) RenderPipeline {
        logz.info().fmt("msg", "creating render pipeline", .{}).log();
        const backend = self.backend.createRenderPipeline(descriptor) catch |err| {
            logz.err().fmt("msg", "backend render pipeline creation failed: {s}", .{@errorName(err)}).log();
            @panic("failed to create render pipeline");
        };
        return .{
            .backend = backend,
        };
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
        return self.createRenderPipeline(descriptor);
    }

    pub fn createComputePipelineAsync(
        self: *@This(),
        io: std.Io,
        descriptor: ComputePipeline.Descriptor,
    ) std.Io.Future(CreatePipelineAsyncError!ComputePipeline) {
        logz.info().fmt("msg", "creating compute pipeline asynchronously", .{}).log();
        return io.async(createComputePipelineAsyncInternal, .{ self, descriptor });
    }

    pub fn createRenderPipelineAsync(
        self: *@This(),
        io: std.Io,
        descriptor: RenderPipeline.Descriptor,
    ) std.Io.Future(CreatePipelineAsyncError!RenderPipeline) {
        logz.info().fmt("msg", "creating render pipeline asynchronously", .{}).log();
        return io.async(createRenderPipelineAsyncInternal, .{ self, descriptor });
    }

    pub fn createCommandEncoder(self: *@This(), descriptor: ?CommandEncoder.Descriptor) CommandEncoder {
        logz.debug().fmt("msg", "creating command encoder: descriptor={}", .{descriptor != null}).log();
        const backend = self.backend.createCommandEncoder(descriptor) catch |err| {
            logz.err().fmt("msg", "backend command encoder creation failed: {s}", .{@errorName(err)}).log();
            return .{ .label = if (descriptor) |d| d.label else null };
        };
        return .{ .backend = backend, .label = if (descriptor) |d| d.label else null };
    }

    pub fn createRenderBundleEncoder(self: *@This(), descriptor: RenderBundleEncoder.Descriptor) RenderBundleEncoder {
        logz.info().fmt("msg", "creating render bundle encoder", .{}).log();
        _ = self;
        _ = descriptor;
        return .{};
    }

    pub fn createQuerySet(self: *@This(), descriptor: QuerySet.Descriptor) QuerySet {
        logz.info().fmt("msg", "creating query set: type={s} count={}", .{ @tagName(descriptor.type), descriptor.count }).log();
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
        logz.info().fmt("msg", "querying device lost future", .{}).log();
        return io.async(lostInternal, .{self});
    }

    fn popErrorScopeInternal(self: *@This()) PopErrorScopeError!?Error {
        _ = self;
        return error.NotImplemented;
    }

    pub fn popErrorScope(self: *@This(), io: std.Io) std.Io.Future(PopErrorScopeError!?Error) {
        logz.info().fmt("msg", "popping error scope", .{}).log();
        return io.async(popErrorScopeInternal, .{self});
    }

    pub fn pushErrorScope(self: *@This(), filter: ErrorFilter) void {
        logz.info().fmt("msg", "pushing error scope: filter={s}", .{@tagName(filter)}).log();
        _ = self;
    }
};

pub const Queue = struct {
    backend: hal.Queue,

    pub const OnSubmittedWorkDoneError = error{NotImplemented};

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub fn submit(self: *@This(), commandBuffers: []const command.CommandBuffer) void {
        logz.debug().fmt("msg", "submitting queue work: command_buffers={}", .{commandBuffers.len}).log();
        var backend_buffers = std.heap.page_allocator.alloc(hal.CommandBuffer, commandBuffers.len) catch return;
        defer std.heap.page_allocator.free(backend_buffers);
        var count: usize = 0;
        for (commandBuffers) |command_buffer| {
            if (command_buffer.backend) |backend| {
                backend_buffers[count] = backend;
                count += 1;
            }
        }
        self.backend.submit(backend_buffers[0..count]);
    }

    pub fn writeBuffer(
        self: *@This(),
        target: *buffer.Buffer,
        bufferOffset: def.Size64,
        data: def.AllowSharedBufferSource,
        dataOffset: def.Size64,
        size: ?def.Size64,
    ) void {
        logz.debug().fmt("msg", "writing buffer: offset={} data_offset={} size={?}", .{ bufferOffset, dataOffset, size }).log();
        _ = self;
        _ = target;
        _ = data;
    }

    pub fn writeTexture(
        self: *@This(),
        destination: texture.TexelCopyTextureInfo,
        data: def.AllowSharedBufferSource,
        dataLayout: texture.TexelCopyBufferLayout,
        size: texture.Texture.Extent3D,
    ) void {
        logz.debug().fmt("msg", "writing texture", .{}).log();
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
        logz.debug().fmt("msg", "copying external image to texture", .{}).log();
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
        logz.info().fmt("msg", "waiting for submitted queue work", .{}).log();
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
