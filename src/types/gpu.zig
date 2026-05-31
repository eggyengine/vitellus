const std = @import("std");
const builtin = @import("builtin");

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
const splat = @import("splat");

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
        std.log.debug("enumerating adapters: options={}", .{options != null});
        const backend_adapters = try self.backend.enumerateAdapters(options orelse .{});
        defer self.allocator.free(backend_adapters);

        const adapters = try self.allocator.alloc(Adapter, backend_adapters.len);
        for (backend_adapters, adapters) |backend_adapter, *adapter| {
            adapter.* = self.adapterFromBackend(backend_adapter, options orelse .{});
        }

        return adapters;
    }

    pub fn requestAdapter(self: *@This(), io: std.Io, options: Adapter.RequestOptions) std.Io.Future(Adapter.RequestAdapterError!Adapter) {
        std.log.debug("requesting adapter: feature_level={s} fallback={} surface={}", .{
            @tagName(options.feature_level),
            options.force_fallback_adapter,
            options.surface != null,
        });
        return io.async(requestAdapterInternal, .{ self, io, options });
    }

    /// Initialises a `vit.Instance` with a specific backend type, with initialisation being done internally.
    ///
    /// The `init` function must have a signature of `fn init(descriptor: vit.Instance.Descriptor) !vit.Instance`
    pub fn init(comptime Backend: type, descriptor: Descriptor) !Instance {
        std.log.info("initializing instance with backend {s}", .{@typeName(Backend)});
        const backend = try Backend.init(descriptor);

        return .{
            .backend = backend,
            .descriptor = descriptor,
            .allocator = descriptor.allocator,
        };
    }

    /// Creates a `vit.Instance` object from an already initialised backend.
    pub fn initFromBackend(backend: hal.Instance, descriptor: Descriptor) Instance {
        std.log.info("initializing instance from backend handle", .{});
        return .{
            .backend = backend,
            .descriptor = descriptor,
            .allocator = descriptor.allocator,
        };
    }

    /// Initialises `vit.Instance` type using the Backends specified in `flags`.
    pub fn initFromPotentialBackends(comptime flags: hal.Backends, descriptor: Descriptor) hal.Instance.FromPotentialBackendsError!Instance {
        std.log.info("selecting instance backend: flags=0x{x}", .{flags.toFlags()});
        const available = comptime hal.Backends.defaultAvailable();

        switch (builtin.os.tag) {
            .windows => {
                // dx12 takes priority on windows
                if (comptime available.dx12 and flags.dx12) {
                    if (tryInitBackend(hal.dx12.DX_Instance, descriptor)) |instance| return instance;
                }

                if (comptime available.vulkan and flags.vulkan) {
                    if (tryInitBackend(hal.vulkan.vkInstance, descriptor)) |instance| return instance;
                }
            },

            .linux => {
                // vulkan only
                if (comptime available.vulkan and flags.vulkan) {
                    if (tryInitBackend(hal.vulkan.vkInstance, descriptor)) |instance| return instance;
                }
            },

            // vulkan can be supported through moltenvk
            .macos, .ios, .watchos, .tvos, .visionos => {
                if (comptime available.metal and flags.metal) {
                    std.log.err("metal backend is not implemented", .{});
                }
            },

            // wasm uses `navigator.gpu` api
            .emscripten, .wasi => {
                if (comptime available.browser_webgpu and flags.browser_webgpu) {
                    std.log.err("browser webgpu backend is not implemented", .{});
                }
            },

            else => {},
        }

        // basically all platforms support some form of opengl
        if (comptime available.opengl and flags.opengl) {
            std.log.err("opengl backend is not implemented", .{});
        }

        if (comptime available.noop and flags.noop) {
            if (tryInitBackend(hal.noop.NoopInstance, descriptor)) |instance| return instance;
        }

        return error.NoBackendAvailable;
    }

    fn tryInitBackend(comptime Backend: type, descriptor: Descriptor) ?Instance {
        return init(Backend, descriptor) catch |err| {
            std.log.err("failed to initialise instance with backend {s}: {s}", .{
                @typeName(Backend),
                @errorName(err),
            });
            return null;
        };
    }

    pub fn deinit(self: *@This()) void {
        std.log.debug("deinitializing instance", .{});
        self.backend.deinit();
    }

    pub fn destroy(self: *@This()) void {
        self.deinit();
    }

    pub fn createSurface(
        self: @This(),
        window: anytype,
    ) texture.Surface.CreateError!texture.Surface {
        std.log.debug("creating surface from window", .{});
        const window_handle = getWindowHandle(window) catch |err| {
            std.log.debug("window handle unavailable: {s}", .{@errorName(err)});
            return error.HandleUnavailable;
        };
        const display_handle = getDisplayHandle(window) catch |err| {
            std.log.debug("display handle unavailable: {s}", .{@errorName(err)});
            return error.HandleUnavailable;
        };
        const backend_surface = self.backend.createSurface(window_handle, display_handle) catch |err| {
            std.log.debug("backend surface creation failed: {s}", .{@errorName(err)});
            return error.BackendFailed;
        };

        std.log.debug("surface creation succeeded", .{});

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
            std.log.debug("adapter request failed: {s}", .{@errorName(err)});
            return error.NoAdapter;
        };
        std.log.debug("adapter request completed", .{});
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

    pub fn requestDevice(self: *@This(), io: std.Io, options: Device.Descriptor) std.Io.Future((Device.RequestDeviceError || splat.context.ParseSpirvError)!struct { Device, Queue }) {
        std.log.debug("requesting device: required_features={} required_limits={}", .{
            options.required_features.len,
            options.required_limits.len,
        });
        return io.async(requestDeviceInternal, .{ self, io, options });
    }

    pub fn deinit(self: *@This()) void {
        std.log.debug("deinitializing adapter: state={s}", .{@tagName(self.state)});
    }

    pub fn getInfo(self: *const @This()) Info {
        std.log.debug("getting adapter info", .{});
        return self.backend.getInfo();
    }

    pub fn getDownlevelCapabilities(self: *const @This()) anyerror!DownlevelCapabilities {
        std.log.debug("getting adapter downlevel capabilities", .{});
        return self.backend.getDownlevelCapabilities();
    }

    pub fn getTextureFormatFeatures(
        self: *const @This(),
        format: texture.Texture.Format,
    ) anyerror!TextureFormatFeatures {
        std.log.debug("getting adapter texture format features: format={s}", .{@tagName(format)});
        return self.backend.getTextureFormatFeatures(format);
    }

    pub fn isSurfaceSupported(self: *const @This(), surface: *const texture.Surface) bool {
        std.log.debug("checking adapter surface support", .{});
        return self.backend.isSurfaceSupported(surface.backend);
    }

    fn requestDeviceInternal(
        self: *@This(),
        io: std.Io,
        options: Device.Descriptor,
    ) (Device.RequestDeviceError || splat.context.ParseSpirvError)!struct { Device, Queue } {
        if (self.state != .valid) {
            std.log.debug("device request rejected: adapter state={s}", .{@tagName(self.state)});
            return error.InvalidAdapter;
        }

        var future = self.backend.requestDevice(io, options);
        defer _ = future.cancel(io) catch {};

        const backend_device, const backend_queue = future.await(io) catch |err| {
            std.log.debug("backend device request failed: {s}", .{@errorName(err)});
            return error.UnsupportedFeature;
        };
        self.state = .consumed;
        std.log.debug("device request completed", .{});

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
            .shader_context = try splat.Context.init(),
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
    shader_context: splat.Context,

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
            std.log.debug("device destroy ignored: already destroyed", .{});
            return;
        }

        std.log.debug("destroying device", .{});
        self.state = .destroyed;
        self.backend.destroy();
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }

    pub fn createBuffer(self: *@This(), descriptor: buffer.Buffer.Descriptor) !buffer.Buffer {
        std.log.debug("creating buffer", .{});
        const backend = try self.backend.createBuffer(descriptor);
        return .{
            .backend = backend,
            .size = descriptor.size,
            .usage = descriptor.usage,
            .map_state = if (descriptor.mappedAtCreation) .mapped else .unmapped,
        };
    }

    pub fn createTexture(self: *@This(), descriptor: texture.Texture.Descriptor) !texture.Texture {
        std.log.debug("creating texture", .{});
        const backend = try self.backend.createTexture(descriptor);
        return .{
            .backend = backend,
            .width = descriptor.size.width,
            .height = descriptor.size.height,
            .depthOrArrayLayers = descriptor.size.depthOrArrayLayers,
            .mipLevelCount = descriptor.mipLevelCount,
            .sampleCount = descriptor.sampleCount,
            .dimension = descriptor.dimension,
            .format = descriptor.format,
            .usage = descriptor.usage,
            .textureBindingViewDimension = descriptor.textureBindingViewDimension,
        };
    }

    pub fn createSampler(self: *@This(), descriptor: ?sampler.Sampler.Descriptor) sampler.Sampler {
        std.log.debug("creating sampler: descriptor={}", .{descriptor != null});
        const resolved = descriptor orelse sampler.Sampler.Descriptor{};
        const backend = self.backend.createSampler(resolved) catch |err| {
            std.log.err("backend sampler creation failed: {s}", .{@errorName(err)});
            return sampler.Sampler.init(resolved);
        };
        var result = sampler.Sampler.init(resolved);
        result.backend = backend;
        return result;
    }

    pub fn createBindGroupLayout(self: *@This(), descriptor: BindGroupLayout.Descriptor) BindGroupLayout {
        std.log.debug("creating bind group layout", .{});
        const backend = self.backend.createBindGroupLayout(descriptor) catch |err| {
            std.log.err("backend bind group layout creation failed: {s}", .{@errorName(err)});
            return BindGroupLayout.init(descriptor);
        };
        var layout = BindGroupLayout.init(descriptor);
        layout.backend = backend;
        return layout;
    }

    pub fn createPipelineLayout(self: *@This(), descriptor: PipelineLayout.Descriptor) PipelineLayout {
        std.log.debug("creating pipeline layout", .{});
        const backend = self.backend.createPipelineLayout(descriptor) catch |err| {
            std.log.err("backend pipeline layout creation failed: {s}", .{@errorName(err)});
            @panic("failed to create pipeline layout");
        };
        var layout = PipelineLayout.init(descriptor);
        layout.backend = backend;
        return layout;
    }

    pub fn createBindGroup(self: *@This(), descriptor: BindGroup.Descriptor) BindGroup {
        std.log.debug("creating bind group", .{});
        const backend = self.backend.createBindGroup(descriptor) catch |err| {
            std.log.err("backend bind group creation failed: {s}", .{@errorName(err)});
            return BindGroup.init(descriptor);
        };
        var group = BindGroup.init(descriptor);
        group.backend = backend;
        return group;
    }

    pub fn createShaderModule(self: *@This(), descriptor: shader.ShaderModule.Descriptor) !shader.ShaderModule {
        std.log.debug("creating shader module", .{});

        const backend = self.backend.createShaderModule(descriptor) catch |err| {
            std.log.err("backend shader module creation failed: {s}", .{@errorName(err)});
            @panic("failed to create shader module");
        };
        return .{
            .backend = backend,
            .label = descriptor.label,
        };
    }

    pub fn createComputePipeline(self: *@This(), descriptor: ComputePipeline.Descriptor) !ComputePipeline {
        std.log.debug("creating compute pipeline", .{});
        const backend = try self.backend.createComputePipeline(descriptor);
        return .{ .backend = backend };
    }

    pub fn createRenderPipeline(self: *@This(), descriptor: RenderPipeline.Descriptor) RenderPipeline {
        std.log.debug("creating render pipeline", .{});
        const backend = self.backend.createRenderPipeline(descriptor) catch |err| {
            std.log.err("backend render pipeline creation failed: {s}", .{@errorName(err)});
            @panic("failed to create render pipeline");
        };
        return .{
            .backend = backend,
        };
    }

    fn createComputePipelineAsyncInternal(
        self: *@This(),
        io: std.Io,
        descriptor: ComputePipeline.Descriptor,
    ) CreatePipelineAsyncError!ComputePipeline {
        var future = self.backend.createComputePipelineAsync(io, descriptor);
        defer _ = future.cancel(io) catch {};
        const backend = future.await(io) catch |err| {
            return switch (err) {
                error.Validation => error.Validation,
                else => error.Internal,
            };
        };
        return .{ .backend = backend };
    }

    fn createRenderPipelineAsyncInternal(
        self: *@This(),
        io: std.Io,
        descriptor: RenderPipeline.Descriptor,
    ) CreatePipelineAsyncError!RenderPipeline {
        var future = self.backend.createRenderPipelineAsync(io, descriptor);
        defer _ = future.cancel(io) catch {};
        const backend = future.await(io) catch |err| {
            return switch (err) {
                error.Validation => error.Validation,
                else => error.Internal,
            };
        };
        return .{ .backend = backend };
    }

    pub fn createComputePipelineAsync(
        self: *@This(),
        io: std.Io,
        descriptor: ComputePipeline.Descriptor,
    ) std.Io.Future(CreatePipelineAsyncError!ComputePipeline) {
        std.log.debug("creating compute pipeline asynchronously", .{});
        return io.async(createComputePipelineAsyncInternal, .{ self, io, descriptor });
    }

    pub fn createRenderPipelineAsync(
        self: *@This(),
        io: std.Io,
        descriptor: RenderPipeline.Descriptor,
    ) std.Io.Future(CreatePipelineAsyncError!RenderPipeline) {
        std.log.debug("creating render pipeline asynchronously", .{});
        return io.async(createRenderPipelineAsyncInternal, .{ self, io, descriptor });
    }

    pub fn createCommandEncoder(self: *@This(), descriptor: ?CommandEncoder.Descriptor) CommandEncoder {
        std.log.debug("creating command encoder: descriptor={}", .{descriptor != null});
        const backend = self.backend.createCommandEncoder(descriptor) catch |err| {
            std.log.err("backend command encoder creation failed: {s}", .{@errorName(err)});
            return .{ .label = if (descriptor) |d| d.label else null };
        };
        return .{ .backend = backend, .label = if (descriptor) |d| d.label else null };
    }

    pub fn createRenderBundleEncoder(self: *@This(), descriptor: RenderBundleEncoder.Descriptor) !RenderBundleEncoder {
        std.log.debug("creating render bundle encoder", .{});
        const backend = try self.backend.createRenderBundleEncoder(descriptor);
        return .{ .backend = backend, .label = descriptor.label };
    }

    pub fn createQuerySet(self: *@This(), descriptor: QuerySet.Descriptor) QuerySet {
        std.log.debug("creating query set: type={s} count={}", .{ @tagName(descriptor.type), descriptor.count });
        const backend = self.backend.createQuerySet(descriptor) catch |err| {
            std.log.err("backend query set creation failed: {s}", .{@errorName(err)});
            return .{
                .label = descriptor.label,
                .type = descriptor.type,
                .count = descriptor.count,
            };
        };
        return .{
            .backend = backend,
            .label = descriptor.label,
            .type = descriptor.type,
            .count = descriptor.count,
        };
    }

    fn lostInternal(self: *@This(), io: std.Io) LostError!LostInfo {
        var future = self.backend.lost(io);
        defer _ = future.cancel(io) catch {};
        return future.await(io) catch error.NotImplemented;
    }

    pub fn lost(self: *@This(), io: std.Io) std.Io.Future(LostError!LostInfo) {
        std.log.debug("querying device lost future", .{});
        return io.async(lostInternal, .{ self, io });
    }

    fn popErrorScopeInternal(self: *@This(), io: std.Io) PopErrorScopeError!?Error {
        var future = self.backend.popErrorScope(io);
        defer _ = future.cancel(io) catch {};
        return future.await(io) catch error.NotImplemented;
    }

    pub fn popErrorScope(self: *@This(), io: std.Io) std.Io.Future(PopErrorScopeError!?Error) {
        std.log.debug("popping error scope", .{});
        return io.async(popErrorScopeInternal, .{ self, io });
    }

    pub fn pushErrorScope(self: *@This(), filter: ErrorFilter) void {
        std.log.debug("pushing error scope: filter={s}", .{@tagName(filter)});
        self.backend.pushErrorScope(filter);
    }
};

pub const Queue = struct {
    backend: hal.Queue,

    pub const OnSubmittedWorkDoneError = error{NotImplemented};

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
    };

    pub fn submit(self: *@This(), commandBuffers: []const command.CommandBuffer) void {
        std.log.debug("submitting queue work: command_buffers={}", .{commandBuffers.len});
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
        std.log.debug("writing buffer: offset={} data_offset={} size={?}", .{ bufferOffset, dataOffset, size });
        if (target.backend) |backend| {
            self.backend.writeBuffer(backend, bufferOffset, data, dataOffset, size);
        }
    }

    pub fn writeTexture(
        self: *@This(),
        destination: texture.TexelCopyTextureInfo,
        data: def.AllowSharedBufferSource,
        dataLayout: texture.TexelCopyBufferLayout,
        size: texture.Texture.Extent3D,
    ) void {
        std.log.debug("writing texture", .{});
        self.backend.writeTexture(destination, data, dataLayout, size);
    }

    fn onSubmittedWorkDoneInternal(self: *@This(), io: std.Io) OnSubmittedWorkDoneError!void {
        var future = self.backend.onSubmittedWorkDone(io);
        defer _ = future.cancel(io) catch {};
        return future.await(io) catch error.NotImplemented;
    }

    pub fn onSubmittedWorkDone(self: *@This(), io: std.Io) std.Io.Future(OnSubmittedWorkDoneError!void) {
        std.log.debug("waiting for submitted queue work", .{});
        return io.async(onSubmittedWorkDoneInternal, .{ self, io });
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
    backend: ?hal.QuerySet = null,
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
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }
};
