//! vulkan backend, powered by [Snektron/vulkan-zig]

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
const vulkan_windowing = @import("../windowing/vulkan.zig");
const DynLib = @import("../utils/dynamic_lib.zig").DynLib;

pub const vk = @import("vulkan");

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

const log = std.log.scoped(.vitellus_vulkan);

pub const InstanceDescriptor = struct {
    getInstanceProcAddr: ?vk.PfnGetInstanceProcAddr = null,
    required_extensions: []const [*:0]const u8 = &.{},
    application_name: [*:0]const u8 = "vitellus",
    application_version: u32 = vk.makeApiVersion(0, 1, 0, 0).toU32(),
    engine_name: [*:0]const u8 = "vitellus",
    engine_version: u32 = vk.makeApiVersion(0, 1, 0, 0).toU32(),
    api_version: u32 = vk.API_VERSION_1_4.toU32(),
};

pub const vkSurface = struct {
    const surface_vtable = hal.Surface.VTable{ .configure = configure, .unconfigure = unconfigure, .getCurrentTexture = getCurrentTexture, .destroy = deinit };

    gpu: *vkGPU,
    handle: vk.SurfaceKHR,

    pub fn initRaw(instance: *vkGPU, window: candler.WindowHandle, display: candler.DisplayHandle) !@This() {
        log.debug("creating vulkan surface: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return .{
            .gpu = instance,
            .handle = try vulkan_windowing.createSurface(instance.instance, window, display),
        };
    }

    pub fn initHeadless(instance: *vkGPU) !@This() {
        log.debug("creating headless vulkan surface", .{});
        return .{
            .gpu = instance,
            .handle = try vulkan_windowing.createHeadlessSurface(instance.instance),
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.handle != .null_handle) {
            log.debug("destroying vulkan surface: handle=0x{x}", .{@intFromEnum(typed.handle)});
            typed.gpu.instance.destroySurfaceKHR(typed.handle, null);
            typed.handle = .null_handle;
        }
        std.heap.page_allocator.destroy(typed);
    }

    fn configure(ptr: *anyopaque, desc: texture.Surface.Configuration) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = typed;
        _ = desc;
        log.debug("vulkan surface configure requested", .{});
    }

    fn unconfigure(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = typed;
        log.debug("vulkan surface unconfigure requested", .{});
    }

    fn getCurrentTexture(ptr: *anyopaque) !texture.Surface.CurrentSurfaceTexture {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = typed;
        log.debug("vulkan surface current texture requested", .{});
        return error.NotImplemented;
    }
};

pub const vkGPU = struct {
    vkb: BaseWrapper = undefined,
    vki: InstanceWrapper = undefined,
    instance: Instance = undefined,
    instance_handle: vk.Instance = .null_handle,
    loader: ?DynLib = null,

    var self: @This() = .{};

    const gpu_vtable = hal.Instance.VTable{
        .requestAdapter = requestAdapter,
        .destroy = destroyGPU,
        .createSurface = createSurface,
    };

    pub fn init() hal.Instance {
        log.debug("initializing vulkan backend with default descriptor", .{});
        return initWithDescriptor(.{}) catch @panic("failed to initialize Vulkan backend");
    }

    pub fn initWithDescriptor(descriptor: InstanceDescriptor) !hal.Instance {
        log.debug("initializing vulkan backend: required_extensions={} api_version=0x{x}", .{
            descriptor.required_extensions.len,
            descriptor.api_version,
        });
        destroyGPU(&self);
        errdefer destroyGPU(&self);

        const get_instance_proc_addr = descriptor.getInstanceProcAddr orelse try loadDefaultGetInstanceProcAddr();
        log.debug("loaded vkGetInstanceProcAddr", .{});
        self.vkb = BaseWrapper.load(get_instance_proc_addr);

        const extension_properties = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, std.heap.page_allocator);
        defer std.heap.page_allocator.free(extension_properties);

        var enabled_extensions: [64][*:0]const u8 = undefined;
        var enabled_extension_count: usize = 0;
        try addRequiredInstanceExtensions(
            &enabled_extensions,
            &enabled_extension_count,
            extension_properties,
            descriptor.required_extensions,
        );
        addSupportedInstanceExtensions(
            &enabled_extensions,
            &enabled_extension_count,
            extension_properties,
            vulkan_windowing.default_instance_extensions,
        );
        log.debug("enabled vulkan instance extensions: count={}", .{enabled_extension_count});

        const app_info = vk.ApplicationInfo{
            .p_application_name = descriptor.application_name,
            .application_version = descriptor.application_version,
            .p_engine_name = descriptor.engine_name,
            .engine_version = descriptor.engine_version,
            .api_version = descriptor.api_version,
        };

        const create_info = vk.InstanceCreateInfo{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(enabled_extension_count),
            .pp_enabled_extension_names = if (enabled_extension_count == 0) null else enabled_extensions[0..enabled_extension_count].ptr,
        };

        const instance_handle = try self.vkb.createInstance(&create_info, null);
        errdefer self.vkb.destroyInstance(instance_handle, null);
        log.debug("created vulkan instance: handle=0x{x}", .{@intFromEnum(instance_handle)});

        self.vki = InstanceWrapper.load(instance_handle, get_instance_proc_addr);
        self.instance = Instance.init(instance_handle, &self.vki);
        self.instance_handle = instance_handle;

        return .{
            .ptr = &self,
            .vtable = &vkGPU.gpu_vtable,
        };
    }

    fn destroyGPU(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.instance_handle != .null_handle) {
            log.debug("destroying vulkan instance: handle=0x{x}", .{@intFromEnum(typed.instance_handle)});
            typed.instance.destroyInstance(null);
            typed.instance_handle = .null_handle;
            typed.instance.handle = .null_handle;
        }

        if (typed.loader) |*loader| {
            log.debug("closing vulkan loader", .{});
            loader.close();
            typed.loader = null;
        }
    }

    fn createSurface(
        ptr: *anyopaque,
        window: candler.WindowHandle,
        display: candler.DisplayHandle,
    ) anyerror!hal.Surface {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        log.debug("allocating vulkan surface wrapper", .{});
        const surface = try std.heap.page_allocator.create(vkSurface);
        errdefer std.heap.page_allocator.destroy(surface);

        surface.* = try vkSurface.initRaw(typed, window, display);
        log.debug("created vulkan surface wrapper: handle=0x{x}", .{@intFromEnum(surface.handle)});
        return .{
            .ptr = surface,
            .vtable = &vkSurface.surface_vtable,
        };
    }

    fn requestAdapter(
        ptr: *anyopaque,
        io: std.Io,
        options: gpu.Adapter.RequestOptions,
    ) std.Io.Future(anyerror!hal.Adapter) {
        log.debug("requesting vulkan adapter", .{});
        return io.async(requestAdapterInternal, .{ ptr, options });
    }

    fn requestAdapterInternal(ptr: *anyopaque, options: gpu.Adapter.RequestOptions) anyerror!hal.Adapter {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = options;
        log.debug("returning vulkan adapter placeholder", .{});

        return .{
            .ptr = typed,
            .vtable = &adapter_vtable,
        };
    }
};

fn loadDefaultGetInstanceProcAddr() !vk.PfnGetInstanceProcAddr {
    if (vkGPU.self.loader == null) {
        log.debug("opening vulkan loader: {s}", .{defaultVulkanLoaderName()});
        vkGPU.self.loader = try DynLib.open(defaultVulkanLoaderName());
    }

    return vkGPU.self.loader.?.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse error.MissingVkGetInstanceProcAddr;
}

fn defaultVulkanLoaderName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "vulkan-1.dll",
        .macos, .ios, .tvos, .watchos, .visionos => "libvulkan.1.dylib",
        else => "libvulkan.so.1",
    };
}

fn addRequiredInstanceExtensions(
    enabled_extensions: *[64][*:0]const u8,
    enabled_extension_count: *usize,
    extension_properties: []const vk.ExtensionProperties,
    required_extensions: []const [*:0]const u8,
) !void {
    if (required_extensions.len == 0) {
        log.debug("no vulkan instance extensions requested", .{});
        return;
    }

    for (required_extensions) |required_extension| {
        if (!hasInstanceExtension(extension_properties, std.mem.span(required_extension))) {
            log.debug("missing vulkan instance extension: {s}", .{required_extension});
            return error.RequiredInstanceExtensionNotSupported;
        }
        try addInstanceExtension(enabled_extensions, enabled_extension_count, required_extension, true);
    }
}

fn addSupportedInstanceExtensions(
    enabled_extensions: *[64][*:0]const u8,
    enabled_extension_count: *usize,
    extension_properties: []const vk.ExtensionProperties,
    candidate_extensions: []const [*:0]const u8,
) void {
    for (candidate_extensions) |candidate_extension| {
        if (!hasInstanceExtension(extension_properties, std.mem.span(candidate_extension))) {
            log.debug("skipping unsupported default vulkan instance extension: {s}", .{candidate_extension});
            continue;
        }
        addInstanceExtension(enabled_extensions, enabled_extension_count, candidate_extension, false) catch |err| {
            log.debug("skipping default vulkan instance extension {s}: {s}", .{ candidate_extension, @errorName(err) });
        };
    }
}

fn addInstanceExtension(
    enabled_extensions: *[64][*:0]const u8,
    enabled_extension_count: *usize,
    extension: [*:0]const u8,
    required: bool,
) !void {
    if (hasEnabledInstanceExtension(enabled_extensions[0..enabled_extension_count.*], std.mem.span(extension))) {
        return;
    }

    if (enabled_extension_count.* == enabled_extensions.len) {
        return error.TooManyVulkanInstanceExtensions;
    }

    enabled_extensions[enabled_extension_count.*] = extension;
    enabled_extension_count.* += 1;
    log.debug("{s} vulkan instance extension: {s}", .{ if (required) "required" else "default", extension });
}

fn hasEnabledInstanceExtension(enabled_extensions: []const [*:0]const u8, extension: []const u8) bool {
    for (enabled_extensions) |enabled_extension| {
        if (std.mem.eql(u8, std.mem.span(enabled_extension), extension)) {
            return true;
        }
    }

    return false;
}

fn hasInstanceExtension(extension_properties: []const vk.ExtensionProperties, required_extension: []const u8) bool {
    for (extension_properties) |extension_property| {
        const extension_name = std.mem.sliceTo(&extension_property.extension_name, 0);
        if (std.mem.eql(u8, extension_name, required_extension)) {
            return true;
        }
    }

    return false;
}

const adapter_vtable = hal.Adapter.VTable{
    .requestDevice = requestDevice,
};

const device_vtable = hal.Device.VTable{
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

const queue_vtable = hal.Queue.VTable{
    .submit = submit,
    .writeBuffer = writeBuffer,
    .writeTexture = writeTexture,
    .copyExternalImageToTexture = copyExternalImageToTexture,
    .onSubmittedWorkDone = onSubmittedWorkDone,
};

fn requestDevice(
    ptr: *anyopaque,
    io: std.Io,
    options: gpu.Device.Descriptor,
) std.Io.Future(anyerror!hal.Device) {
    log.debug("requesting vulkan device", .{});
    return io.async(requestDeviceInternal, .{ ptr, options });
}

fn requestDeviceInternal(ptr: *anyopaque, options: gpu.Device.Descriptor) anyerror!hal.Device {
    _ = ptr;
    _ = options;
    log.debug("returning vulkan device placeholder", .{});
    return .{
        .ptr = &vkGPU.self,
        .vtable = &device_vtable,
    };
}

fn destroy(ptr: *anyopaque) void {
    _ = ptr;
    log.debug("destroying vulkan device placeholder", .{});
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
    return error.NotImplemented;
}

fn createBindGroup(ptr: *anyopaque, descriptor: bind_group.BindGroup.Descriptor) anyerror!hal.BindGroup {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createShaderModule(ptr: *anyopaque, descriptor: shader.ShaderModule.Descriptor) anyerror!hal.ShaderModule {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createComputePipeline(ptr: *anyopaque, descriptor: pipeline.ComputePipeline.Descriptor) anyerror!hal.ComputePipeline {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
}

fn createRenderPipeline(ptr: *anyopaque, descriptor: pipeline.RenderPipeline.Descriptor) anyerror!hal.RenderPipeline {
    _ = ptr;
    _ = descriptor;
    return error.NotImplemented;
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
        .ptr = &vkGPU.self,
        .vtable = &queue_vtable,
    };
}

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
