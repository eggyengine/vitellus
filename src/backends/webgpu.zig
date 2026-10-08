//! WebGPU backend for the browser, on Emscripten's `emdawnwebgpu` port.
//!
//! WebGPU's adapter, device and completion requests are asynchronous. The backend blocks on
//! them with `wgpuInstanceWaitAny`, which in the browser needs the app linked with
//! `-sASYNCIFY` (or `-sJSPI`).
//!
//! Present is implicit: the browser shows the canvas texture once control returns to it, so
//! `present` only releases the frame's texture. Barriers, semaphores and command pools have
//! no WebGPU counterpart and are no-ops; queue order already serialises the work.

const std = @import("std");
const c = @import("webgpu_c");
const settings = @import("../interface/settings.zig");
const instance_if = @import("../interface/instance.zig");
const adapter_if = @import("../interface/adapter.zig");
const device_if = @import("../interface/device.zig");
const queue_if = @import("../interface/queue.zig");
const swapchain_if = @import("../interface/swapchain.zig");
const shader_if = @import("../interface/shader.zig");
const resource = @import("../interface/resource.zig");
const binding = @import("../interface/binding.zig");
const pipeline = @import("../interface/pipeline.zig");
const command = @import("../interface/command.zig");
const sync = @import("../interface/sync.zig");
const Window = @import("../windowing/windowing.zig").Window;

const log = std.log.scoped(.webgpu);

/// SDL and the default Emscripten shell both render into `#canvas`.
// ponytail: one fixed canvas; read the selector from the window handle if a page needs several.
const canvas_selector = "#canvas";
const forever = std.math.maxInt(u64);

// ---------------------------------------------------------------------------------------------
// Helpers

fn str(s: ?[]const u8) c.WGPUStringView {
    const value = s orelse return .{ .data = null, .length = std.math.maxInt(usize) };
    return .{ .data = value.ptr, .length = value.len };
}

fn slice(s: c.WGPUStringView) []const u8 {
    const data = s.data orelse return "";
    return if (s.length == std.math.maxInt(usize)) std.mem.span(data) else data[0..s.length];
}

/// `snake_case` → `PascalCase` at compile time, for enums whose WebGPU names match ours.
fn pascal(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (name) |ch| {
            if (ch == '_') {
                upper = true;
            } else {
                out = out ++ .{if (upper) std.ascii.toUpper(ch) else ch};
                upper = false;
            }
        }
        return out;
    }
}

/// Maps a Vitellus enum to the WebGPU constant `prefix ++ PascalCase(tag)`.
fn wgpuEnum(comptime prefix: []const u8, value: anytype) c_uint {
    return switch (value) {
        inline else => |tag| @intCast(@field(c, prefix ++ pascal(@tagName(tag)))),
    };
}

/// `std.mem.zeroInit` that also narrows integers: webgpu.h enum constants translate as `c_int`
/// while the struct fields holding them are `c_uint`.
fn zeroInit(comptime T: type, init: anytype) T {
    var value = std.mem.zeroes(T);
    inline for (@typeInfo(@TypeOf(init)).@"struct".fields) |field| {
        const Field = @TypeOf(@field(value, field.name));
        const given = @field(init, field.name);
        @field(value, field.name) = if (@typeInfo(Field) == .int and @typeInfo(@TypeOf(given)) == .int) @intCast(given) else given;
    }
    return value;
}

fn ptrOf(comptime T: type, handle: u64) *T {
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

fn handleOf(ptr: anytype) u64 {
    return @intFromPtr(ptr);
}

fn waitFuture(instance: c.WGPUInstance, future: c.WGPUFuture, timeout_ns: u64) !bool {
    var info = c.WGPUFutureWaitInfo{ .future = future, .completed = 0 };
    return switch (c.wgpuInstanceWaitAny(instance, 1, &info, timeout_ns)) {
        c.WGPUWaitStatus_Success => true,
        c.WGPUWaitStatus_TimedOut => false,
        else => error.WaitFailed,
    };
}

fn textureFormat(format: resource.Format) !c.WGPUTextureFormat {
    return switch (format) {
        .r8_unorm => c.WGPUTextureFormat_R8Unorm,
        .r8_snorm => c.WGPUTextureFormat_R8Snorm,
        .r8_uint => c.WGPUTextureFormat_R8Uint,
        .r8_sint => c.WGPUTextureFormat_R8Sint,
        .rg8_unorm => c.WGPUTextureFormat_RG8Unorm,
        .rg8_snorm => c.WGPUTextureFormat_RG8Snorm,
        .rg8_uint => c.WGPUTextureFormat_RG8Uint,
        .rg8_sint => c.WGPUTextureFormat_RG8Sint,
        .rgba8_unorm => c.WGPUTextureFormat_RGBA8Unorm,
        .rgba8_snorm => c.WGPUTextureFormat_RGBA8Snorm,
        .rgba8_uint => c.WGPUTextureFormat_RGBA8Uint,
        .rgba8_sint => c.WGPUTextureFormat_RGBA8Sint,
        .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8UnormSrgb,
        .bgra8_unorm => c.WGPUTextureFormat_BGRA8Unorm,
        .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8UnormSrgb,
        .r16_uint => c.WGPUTextureFormat_R16Uint,
        .r16_sint => c.WGPUTextureFormat_R16Sint,
        .r16_float => c.WGPUTextureFormat_R16Float,
        .rg16_uint => c.WGPUTextureFormat_RG16Uint,
        .rg16_sint => c.WGPUTextureFormat_RG16Sint,
        .rg16_float => c.WGPUTextureFormat_RG16Float,
        .rgba16_uint => c.WGPUTextureFormat_RGBA16Uint,
        .rgba16_sint => c.WGPUTextureFormat_RGBA16Sint,
        .rgba16_float => c.WGPUTextureFormat_RGBA16Float,
        .r32_uint => c.WGPUTextureFormat_R32Uint,
        .r32_sint => c.WGPUTextureFormat_R32Sint,
        .r32_float => c.WGPUTextureFormat_R32Float,
        .rg32_uint => c.WGPUTextureFormat_RG32Uint,
        .rg32_sint => c.WGPUTextureFormat_RG32Sint,
        .rg32_float => c.WGPUTextureFormat_RG32Float,
        .rgba32_uint => c.WGPUTextureFormat_RGBA32Uint,
        .rgba32_sint => c.WGPUTextureFormat_RGBA32Sint,
        .rgba32_float => c.WGPUTextureFormat_RGBA32Float,
        .rgb10a2_unorm => c.WGPUTextureFormat_RGB10A2Unorm,
        .rg11b10_float => c.WGPUTextureFormat_RG11B10Ufloat,
        .bc1_rgba_unorm => c.WGPUTextureFormat_BC1RGBAUnorm,
        .bc1_rgba_unorm_srgb => c.WGPUTextureFormat_BC1RGBAUnormSrgb,
        .bc2_rgba_unorm => c.WGPUTextureFormat_BC2RGBAUnorm,
        .bc2_rgba_unorm_srgb => c.WGPUTextureFormat_BC2RGBAUnormSrgb,
        .bc3_rgba_unorm => c.WGPUTextureFormat_BC3RGBAUnorm,
        .bc3_rgba_unorm_srgb => c.WGPUTextureFormat_BC3RGBAUnormSrgb,
        .bc4_r_unorm => c.WGPUTextureFormat_BC4RUnorm,
        .bc4_r_snorm => c.WGPUTextureFormat_BC4RSnorm,
        .bc5_rg_unorm => c.WGPUTextureFormat_BC5RGUnorm,
        .bc5_rg_snorm => c.WGPUTextureFormat_BC5RGSnorm,
        .bc6h_rgb_ufloat => c.WGPUTextureFormat_BC6HRGBUfloat,
        .bc6h_rgb_float => c.WGPUTextureFormat_BC6HRGBFloat,
        .bc7_rgba_unorm => c.WGPUTextureFormat_BC7RGBAUnorm,
        .bc7_rgba_unorm_srgb => c.WGPUTextureFormat_BC7RGBAUnormSrgb,
        .stencil8 => c.WGPUTextureFormat_Stencil8,
        .d16_unorm => c.WGPUTextureFormat_Depth16Unorm,
        // WebGPU only promises "at least 24 bits" of depth with stencil.
        .d24_unorm_s8_uint => c.WGPUTextureFormat_Depth24PlusStencil8,
        .d32_float => c.WGPUTextureFormat_Depth32Float,
        .d32_float_s8_uint => c.WGPUTextureFormat_Depth32FloatStencil8,
        // WebGPU has no 16-bit normalised or three-channel 32-bit formats.
        else => error.FormatUnsupported,
    };
}

fn swapchainTextureFormat(format: swapchain_if.SwapchainFormat) c.WGPUTextureFormat {
    return switch (format) {
        .bgra8_unorm => c.WGPUTextureFormat_BGRA8Unorm,
        .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8UnormSrgb,
        .rgba8_unorm => c.WGPUTextureFormat_RGBA8Unorm,
        .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8UnormSrgb,
        .rgba16_float => c.WGPUTextureFormat_RGBA16Float,
    };
}

fn hasStencil(format: c.WGPUTextureFormat) bool {
    return format == c.WGPUTextureFormat_Stencil8 or
        format == c.WGPUTextureFormat_Depth24PlusStencil8 or
        format == c.WGPUTextureFormat_Depth32FloatStencil8;
}

fn hasDepth(format: c.WGPUTextureFormat) bool {
    return format == c.WGPUTextureFormat_Depth16Unorm or
        format == c.WGPUTextureFormat_Depth24Plus or
        format == c.WGPUTextureFormat_Depth24PlusStencil8 or
        format == c.WGPUTextureFormat_Depth32Float or
        format == c.WGPUTextureFormat_Depth32FloatStencil8;
}

/// Bytes per texel of uncompressed colour formats, for tightly packed uploads.
fn texelSize(format: c.WGPUTextureFormat) !u32 {
    return switch (format) {
        c.WGPUTextureFormat_R8Unorm, c.WGPUTextureFormat_R8Snorm, c.WGPUTextureFormat_R8Uint, c.WGPUTextureFormat_R8Sint, c.WGPUTextureFormat_Stencil8 => 1,
        c.WGPUTextureFormat_RG8Unorm, c.WGPUTextureFormat_RG8Snorm, c.WGPUTextureFormat_RG8Uint, c.WGPUTextureFormat_RG8Sint, c.WGPUTextureFormat_R16Uint, c.WGPUTextureFormat_R16Sint, c.WGPUTextureFormat_R16Float, c.WGPUTextureFormat_Depth16Unorm => 2,
        c.WGPUTextureFormat_RG16Uint, c.WGPUTextureFormat_RG16Sint, c.WGPUTextureFormat_RG16Float, c.WGPUTextureFormat_RGBA8Unorm, c.WGPUTextureFormat_RGBA8UnormSrgb, c.WGPUTextureFormat_RGBA8Snorm, c.WGPUTextureFormat_RGBA8Uint, c.WGPUTextureFormat_RGBA8Sint, c.WGPUTextureFormat_BGRA8Unorm, c.WGPUTextureFormat_BGRA8UnormSrgb, c.WGPUTextureFormat_RGB10A2Unorm, c.WGPUTextureFormat_RG11B10Ufloat, c.WGPUTextureFormat_R32Uint, c.WGPUTextureFormat_R32Sint, c.WGPUTextureFormat_R32Float, c.WGPUTextureFormat_Depth32Float => 4,
        c.WGPUTextureFormat_RG32Uint, c.WGPUTextureFormat_RG32Sint, c.WGPUTextureFormat_RG32Float, c.WGPUTextureFormat_RGBA16Uint, c.WGPUTextureFormat_RGBA16Sint, c.WGPUTextureFormat_RGBA16Float => 8,
        c.WGPUTextureFormat_RGBA32Uint, c.WGPUTextureFormat_RGBA32Sint, c.WGPUTextureFormat_RGBA32Float => 16,
        else => error.PassBytesPerRow,
    };
}

fn viewDimension(dimension: resource.TextureViewDimension) c.WGPUTextureViewDimension {
    return switch (dimension) {
        .d1 => c.WGPUTextureViewDimension_1D,
        .d2 => c.WGPUTextureViewDimension_2D,
        .d2_array => c.WGPUTextureViewDimension_2DArray,
        .cube => c.WGPUTextureViewDimension_Cube,
        .cube_array => c.WGPUTextureViewDimension_CubeArray,
        .d3 => c.WGPUTextureViewDimension_3D,
        .d1_array => c.WGPUTextureViewDimension_Undefined, // not in WebGPU; validation reports it
    };
}

fn aspect(value: resource.TextureAspect) c.WGPUTextureAspect {
    return switch (value) {
        .all, .color => c.WGPUTextureAspect_All,
        .depth => c.WGPUTextureAspect_DepthOnly,
        .stencil => c.WGPUTextureAspect_StencilOnly,
    };
}

fn loadOp(op: command.LoadOp) c.WGPULoadOp {
    return switch (op) {
        .load => c.WGPULoadOp_Load,
        // WebGPU cannot leave contents undefined; clearing is the cheap equivalent.
        .clear, .discard => c.WGPULoadOp_Clear,
    };
}

fn storeOp(op: command.StoreOp) c.WGPUStoreOp {
    return wgpuEnum("WGPUStoreOp_", op);
}

fn visibility(v: binding.ShaderVisibility) c.WGPUShaderStage {
    var out: c.WGPUShaderStage = c.WGPUShaderStage_None;
    if (v.vertex) out |= c.WGPUShaderStage_Vertex;
    if (v.fragment) out |= c.WGPUShaderStage_Fragment;
    if (v.compute) out |= c.WGPUShaderStage_Compute;
    return out;
}

// ---------------------------------------------------------------------------------------------
// Instance and adapter

const WgpuInstance = struct {
    handle: c.WGPUInstance,

    const vtable: instance_if.Instance.VTable = .{
        .deinitFn = deinit,
        .createAdapterFn = createAdapter,
    };

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuInstance = @ptrCast(@alignCast(ptr));
        c.wgpuInstanceRelease(self.handle);
        allocator.destroy(self);
    }

    fn createAdapter(ptr: *anyopaque, allocator: std.mem.Allocator, desc: adapter_if.AdapterDescriptor) anyerror!adapter_if.Adapter {
        _ = desc;
        const self: *WgpuInstance = @ptrCast(@alignCast(ptr));
        const Result = struct {
            adapter: c.WGPUAdapter = null,
            fn done(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.WGPUStringView, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const result: *@This() = @ptrCast(@alignCast(user));
                if (status == c.WGPURequestAdapterStatus_Success) {
                    result.adapter = adapter;
                } else log.err("no WebGPU adapter: {s}", .{slice(message)});
            }
        };
        var result: Result = .{};
        const options = zeroInit(c.WGPURequestAdapterOptions, .{ .powerPreference = c.WGPUPowerPreference_HighPerformance });
        const future = c.wgpuInstanceRequestAdapter(self.handle, &options, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_WaitAnyOnly,
            .callback = Result.done,
            .userdata1 = &result,
            .userdata2 = null,
        });
        _ = try waitFuture(self.handle, future, forever);
        const handle = result.adapter orelse return error.NoAdapter;
        errdefer c.wgpuAdapterRelease(handle);
        const adapter = try allocator.create(WgpuAdapter);
        adapter.* = .{ .instance = self.handle, .handle = handle };
        return .{ .ptr = adapter, .vtable = &WgpuAdapter.vtable, .allocator = allocator };
    }
};

pub fn createInstance(allocator: std.mem.Allocator, config: settings.VitellusConfig) anyerror!instance_if.Instance {
    _ = config;
    const features = [_]c.WGPUInstanceFeatureName{c.WGPUInstanceFeatureName_TimedWaitAny};
    const desc = zeroInit(c.WGPUInstanceDescriptor, .{ .requiredFeatureCount = features.len, .requiredFeatures = &features });
    const handle = c.wgpuCreateInstance(&desc) orelse return error.WebGpuUnavailable;
    const self = try allocator.create(WgpuInstance);
    self.* = .{ .handle = handle };
    return .{ .ptr = self, .vtable = &WgpuInstance.vtable, .allocator = allocator };
}

const WgpuAdapter = struct {
    instance: c.WGPUInstance,
    handle: c.WGPUAdapter,

    const vtable: adapter_if.Adapter.VTable = .{
        .deinitFn = deinit,
        .infoFn = info,
        .createDeviceFn = WgpuDevice.create,
        .createSwapchainFn = WgpuSwapchain.create,
        .capabilitiesFn = capabilities,
        .formatCapabilitiesFn = formatCapabilities,
        .surfaceCapabilitiesFn = surfaceCapabilities,
    };

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuAdapter = @ptrCast(@alignCast(ptr));
        c.wgpuAdapterRelease(self.handle);
        allocator.destroy(self);
    }

    fn info(ptr: *anyopaque) adapter_if.AdapterInfo {
        const self: *WgpuAdapter = @ptrCast(@alignCast(ptr));
        var raw = std.mem.zeroes(c.WGPUAdapterInfo);
        var out: adapter_if.AdapterInfo = .{};
        if (c.wgpuAdapterGetInfo(self.handle, &raw) != c.WGPUStatus_Success) return out;
        defer c.wgpuAdapterInfoFreeMembers(raw);
        // Browsers often hide the device name; fall back to the vendor, then the API.
        const name = for ([_][]const u8{ slice(raw.description), slice(raw.device), slice(raw.vendor) }) |candidate| {
            if (candidate.len > 0) break candidate;
        } else "WebGPU";
        out.name_len = @min(name.len, out.name.len);
        @memcpy(out.name[0..out.name_len], name[0..out.name_len]);
        out.kind = switch (raw.adapterType) {
            c.WGPUAdapterType_DiscreteGPU => .discrete,
            c.WGPUAdapterType_IntegratedGPU => .integrated,
            c.WGPUAdapterType_CPU => .software,
            else => .unknown,
        };
        out.vendor = switch (raw.vendorID) {
            0x10de => .nvidia,
            0x1002 => .amd,
            0x8086 => .intel,
            0x106b => .apple,
            else => .unknown,
        };
        return out;
    }

    fn capabilities(ptr: *anyopaque) adapter_if.AdapterCapabilities {
        const self: *WgpuAdapter = @ptrCast(@alignCast(ptr));
        var limits = std.mem.zeroes(c.WGPULimits);
        _ = c.wgpuAdapterGetLimits(self.handle, &limits);
        return .{
            .features = .{
                .timestamp_query = c.wgpuAdapterHasFeature(self.handle, c.WGPUFeatureName_TimestampQuery) != 0,
                .occlusion_query = true,
                .indirect_first_instance = c.wgpuAdapterHasFeature(self.handle, c.WGPUFeatureName_IndirectFirstInstance) != 0,
                .depth_clip_control = c.wgpuAdapterHasFeature(self.handle, c.WGPUFeatureName_DepthClipControl) != 0,
                .anisotropic_filtering = true,
                .bc_compression = c.wgpuAdapterHasFeature(self.handle, c.WGPUFeatureName_TextureCompressionBC) != 0,
            },
            .limits = .{
                .max_buffer_size = limits.maxBufferSize,
                .max_texture_dimension_1d = limits.maxTextureDimension1D,
                .max_texture_dimension_2d = limits.maxTextureDimension2D,
                .max_texture_dimension_3d = limits.maxTextureDimension3D,
                .max_texture_array_layers = limits.maxTextureArrayLayers,
                .max_bind_groups = limits.maxBindGroups,
                .max_bindings_per_group = limits.maxBindingsPerBindGroup,
                .max_uniform_buffer_binding_size = limits.maxUniformBufferBindingSize,
                .max_storage_buffer_binding_size = limits.maxStorageBufferBindingSize,
                .min_uniform_buffer_offset_alignment = limits.minUniformBufferOffsetAlignment,
                .min_storage_buffer_offset_alignment = limits.minStorageBufferOffsetAlignment,
                .max_vertex_buffers = limits.maxVertexBuffers,
                .max_vertex_attributes = limits.maxVertexAttributes,
                .max_vertex_stride = limits.maxVertexBufferArrayStride,
                .max_color_attachments = limits.maxColorAttachments,
                .max_compute_workgroup_storage = limits.maxComputeWorkgroupStorageSize,
                .max_compute_invocations = limits.maxComputeInvocationsPerWorkgroup,
                .max_compute_workgroup_size = .{ limits.maxComputeWorkgroupSizeX, limits.maxComputeWorkgroupSizeY, limits.maxComputeWorkgroupSizeZ },
                .max_compute_workgroups = .{ limits.maxComputeWorkgroupsPerDimension, limits.maxComputeWorkgroupsPerDimension, limits.maxComputeWorkgroupsPerDimension },
                .max_sampler_anisotropy = 16,
            },
        };
    }

    fn formatCapabilities(_: *anyopaque, format: resource.Format) adapter_if.FormatCapabilities {
        const wgpu_format = textureFormat(format) catch return .{ .usage = .{}, .sample_counts = .{ .one = false } };
        // ponytail: WebGPU's guaranteed core table, approximated; query per-format features if a caller needs exact answers.
        const depth = hasDepth(wgpu_format) or hasStencil(wgpu_format);
        return .{
            .usage = .{ .sampled = true, .color_attachment = !depth, .depth_stencil_attachment = depth, .transfer_src = true, .transfer_dst = true },
            .sample_counts = .{ .one = true, .four = true },
        };
    }

    fn surfaceCapabilities(ptr: *anyopaque, allocator: std.mem.Allocator, window: Window) anyerror!adapter_if.SurfaceCapabilities {
        _ = window;
        const self: *WgpuAdapter = @ptrCast(@alignCast(ptr));
        const surface = try createSurface(self.instance);
        defer c.wgpuSurfaceRelease(surface);
        var caps = std.mem.zeroes(c.WGPUSurfaceCapabilities);
        if (c.wgpuSurfaceGetCapabilities(surface, self.handle, &caps) != c.WGPUStatus_Success) return error.SurfaceCapabilitiesFailed;
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);

        var formats: std.ArrayList(swapchain_if.SwapchainFormat) = .empty;
        defer formats.deinit(allocator);
        for (caps.formats[0..caps.formatCount]) |format| {
            const mapped: swapchain_if.SwapchainFormat = switch (format) {
                c.WGPUTextureFormat_BGRA8Unorm => .bgra8_unorm,
                c.WGPUTextureFormat_RGBA8Unorm => .rgba8_unorm,
                c.WGPUTextureFormat_RGBA16Float => .rgba16_float,
                else => continue,
            };
            try formats.append(allocator, mapped);
        }
        // Canvases are never sRGB themselves, but an sRGB view of them is allowed.
        for (formats.items) |format| switch (format) {
            .bgra8_unorm => try formats.append(allocator, .bgra8_unorm_srgb),
            .rgba8_unorm => try formats.append(allocator, .rgba8_unorm_srgb),
            else => {},
        };
        const present_modes = try allocator.dupe(swapchain_if.PresentMode, &.{.fifo});
        errdefer allocator.free(present_modes);
        const composite_alpha = try allocator.dupe(swapchain_if.CompositeAlpha, &.{ .opaque_alpha, .premultiplied });
        errdefer allocator.free(composite_alpha);
        return .{
            .allocator = allocator,
            .formats = try formats.toOwnedSlice(allocator),
            .present_modes = present_modes,
            .composite_alpha = composite_alpha,
            .min_image_count = 1,
            .max_image_count = 1,
            .min_extent = .{ .width = 1, .height = 1 },
            .max_extent = .{ .width = 8192, .height = 8192 },
        };
    }
};

fn createSurface(instance: c.WGPUInstance) !c.WGPUSurface {
    var canvas = c.WGPUEmscriptenSurfaceSourceCanvasHTMLSelector{
        .chain = .{ .next = null, .sType = c.WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector },
        .selector = str(canvas_selector),
    };
    const desc = c.WGPUSurfaceDescriptor{ .nextInChain = &canvas.chain, .label = str(null) };
    return c.wgpuInstanceCreateSurface(instance, &desc) orelse error.SurfaceCreationFailed;
}

// ---------------------------------------------------------------------------------------------
// Device, queue and synchronisation

const WgpuDevice = struct {
    allocator: std.mem.Allocator,
    instance: c.WGPUInstance,
    handle: c.WGPUDevice,

    const vtable: device_if.Device.VTable = .{
        .deinitFn = deinit,
        .createQueueFn = WgpuQueue.create,
        .createShaderFn = createShader,
        .createBufferFn = WgpuBuffer.create,
        .createTextureFn = createTexture,
        .createTextureViewFn = WgpuView.create,
        .createSamplerFn = createSampler,
        .createBindGroupLayoutFn = createBindGroupLayout,
        .createBindGroupFn = createBindGroup,
        .createPipelineLayoutFn = createPipelineLayout,
        .createGraphicsPipelineFn = createGraphicsPipeline,
        .createComputePipelineFn = createComputePipeline,
        .createCommandPoolFn = createCommandPool,
        .createFenceFn = WgpuFence.create,
        .createSemaphoreFn = createSemaphore,
    };

    fn create(ptr: *anyopaque, allocator: std.mem.Allocator, desc: device_if.DeviceDescriptor) anyerror!device_if.Device {
        const adapter: *WgpuAdapter = @ptrCast(@alignCast(ptr));
        var features: std.ArrayList(c.WGPUFeatureName) = .empty;
        defer features.deinit(allocator);
        const wanted = desc.required_features;
        if (wanted.timestamp_query) try features.append(allocator, c.WGPUFeatureName_TimestampQuery);
        if (wanted.indirect_first_instance) try features.append(allocator, c.WGPUFeatureName_IndirectFirstInstance);
        if (wanted.depth_clip_control) try features.append(allocator, c.WGPUFeatureName_DepthClipControl);
        if (wanted.bc_compression) try features.append(allocator, c.WGPUFeatureName_TextureCompressionBC);
        if (wanted.wireframe) return error.RequiredFeatureUnsupported;

        const Result = struct {
            device: c.WGPUDevice = null,
            fn done(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: c.WGPUStringView, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const result: *@This() = @ptrCast(@alignCast(user));
                if (status == c.WGPURequestDeviceStatus_Success) {
                    result.device = device;
                } else log.err("WebGPU device request failed: {s}", .{slice(message)});
            }
        };
        var result: Result = .{};
        const device_desc = zeroInit(c.WGPUDeviceDescriptor, .{
            .label = str(desc.label),
            .requiredFeatureCount = features.items.len,
            .requiredFeatures = features.items.ptr,
            .deviceLostCallbackInfo = zeroInit(c.WGPUDeviceLostCallbackInfo, .{ .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = onDeviceLost }),
            .uncapturedErrorCallbackInfo = zeroInit(c.WGPUUncapturedErrorCallbackInfo, .{ .callback = onUncapturedError }),
        });
        const future = c.wgpuAdapterRequestDevice(adapter.handle, &device_desc, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_WaitAnyOnly,
            .callback = Result.done,
            .userdata1 = &result,
            .userdata2 = null,
        });
        _ = try waitFuture(adapter.instance, future, forever);
        const handle = result.device orelse return error.DeviceCreationFailed;
        const self = try allocator.create(WgpuDevice);
        self.* = .{ .allocator = allocator, .instance = adapter.instance, .handle = handle };
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn onDeviceLost(_: [*c]const c.WGPUDevice, reason: c.WGPUDeviceLostReason, message: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        if (reason == c.WGPUDeviceLostReason_Destroyed or reason == c.WGPUDeviceLostReason_CallbackCancelled) return;
        log.err("WebGPU device lost: {s}", .{slice(message)});
    }

    fn onUncapturedError(_: [*c]const c.WGPUDevice, _: c.WGPUErrorType, message: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        log.err("WebGPU: {s}", .{slice(message)});
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        c.wgpuDeviceRelease(self.handle);
        allocator.destroy(self);
    }

    fn createShader(ptr: *anyopaque, allocator: std.mem.Allocator, desc: shader_if.ShaderDescriptor) anyerror!shader_if.Shader {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        var compiled = try desc.source.compile(allocator, .{ .backend = .webgpu, .stage = desc.stage, .label = desc.label });
        defer compiled.deinit(allocator);
        if (!compiled.format.eql(.wgsl)) return error.UnsupportedShaderFormat;
        var wgsl = c.WGPUShaderSourceWGSL{
            .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = str(compiled.bytes),
        };
        const module = c.wgpuDeviceCreateShaderModule(self.handle, &.{ .nextInChain = &wgsl.chain, .label = str(desc.label) }) orelse return error.ShaderCreationFailed;
        errdefer c.wgpuShaderModuleRelease(module);
        const shader = try self.allocator.create(WgpuShader);
        errdefer self.allocator.destroy(shader);
        shader.* = .{ .allocator = self.allocator, .module = module, .entry_point = try self.allocator.dupe(u8, compiled.entry_point) };
        return .{ .handle = handleOf(shader), .vtable = &WgpuShader.vtable };
    }

    fn createTexture(ptr: *anyopaque, desc: resource.TextureDescriptor) anyerror!resource.Texture {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const format = try textureFormat(desc.format);
        var usage: c.WGPUTextureUsage = c.WGPUTextureUsage_None;
        if (desc.usage.sampled) usage |= c.WGPUTextureUsage_TextureBinding;
        if (desc.usage.storage) usage |= c.WGPUTextureUsage_StorageBinding;
        if (desc.usage.color_attachment or desc.usage.depth_stencil_attachment) usage |= c.WGPUTextureUsage_RenderAttachment;
        if (desc.usage.transfer_src) usage |= c.WGPUTextureUsage_CopySrc;
        if (desc.usage.transfer_dst or desc.initial_data != null) usage |= c.WGPUTextureUsage_CopyDst;
        const size = c.WGPUExtent3D{ .width = desc.width, .height = desc.height, .depthOrArrayLayers = desc.depth_or_layers };
        const texture = c.wgpuDeviceCreateTexture(self.handle, &zeroInit(c.WGPUTextureDescriptor, .{
            .label = str(desc.label),
            .usage = usage,
            .dimension = switch (desc.dimension) {
                .d1 => c.WGPUTextureDimension_1D,
                .d2 => c.WGPUTextureDimension_2D,
                .d3 => c.WGPUTextureDimension_3D,
            },
            .size = size,
            .format = format,
            .mipLevelCount = desc.mip_levels,
            .sampleCount = desc.sample_count,
        })) orelse return error.TextureCreationFailed;
        if (desc.initial_data) |data| {
            const queue = c.wgpuDeviceGetQueue(self.handle);
            defer c.wgpuQueueRelease(queue);
            const bytes_per_row = if (desc.bytes_per_row != 0) desc.bytes_per_row else desc.width * try texelSize(format);
            c.wgpuQueueWriteTexture(
                queue,
                &zeroInit(c.WGPUTexelCopyTextureInfo, .{ .texture = texture, .aspect = c.WGPUTextureAspect_All }),
                data.ptr,
                data.len,
                &.{ .offset = 0, .bytesPerRow = bytes_per_row, .rowsPerImage = desc.height },
                &size,
            );
        }
        return .{ .handle = handleOf(texture), .vtable = &texture_vtable };
    }

    fn createSampler(ptr: *anyopaque, desc: resource.SamplerDescriptor) anyerror!resource.Sampler {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const sampler = c.wgpuDeviceCreateSampler(self.handle, &zeroInit(c.WGPUSamplerDescriptor, .{
            .label = str(desc.label),
            .addressModeU = wgpuEnum("WGPUAddressMode_", desc.address_u),
            .addressModeV = wgpuEnum("WGPUAddressMode_", desc.address_v),
            .addressModeW = wgpuEnum("WGPUAddressMode_", desc.address_w),
            .magFilter = wgpuEnum("WGPUFilterMode_", desc.mag_filter),
            .minFilter = wgpuEnum("WGPUFilterMode_", desc.min_filter),
            .mipmapFilter = wgpuEnum("WGPUMipmapFilterMode_", desc.mipmap_filter),
            .lodMinClamp = desc.lod_min,
            .lodMaxClamp = desc.lod_max,
            .compare = if (desc.compare) |op| wgpuEnum("WGPUCompareFunction_", op) else c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = desc.max_anisotropy,
        })) orelse return error.SamplerCreationFailed;
        return .{ .handle = handleOf(sampler), .vtable = &sampler_vtable };
    }

    fn createBindGroupLayout(ptr: *anyopaque, desc: binding.BindGroupLayoutDescriptor) anyerror!binding.BindGroupLayout {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const entries = try self.allocator.alloc(c.WGPUBindGroupLayoutEntry, desc.entries.len);
        defer self.allocator.free(entries);
        for (desc.entries, entries) |entry, *out| {
            if (entry.count != 1) return error.BindingArraysUnsupported;
            out.* = zeroInit(c.WGPUBindGroupLayoutEntry, .{ .binding = entry.binding, .visibility = visibility(entry.visibility) });
            switch (entry.kind) {
                .buffer => |buffer| out.buffer = zeroInit(c.WGPUBufferBindingLayout, .{
                    .type = switch (buffer.kind) {
                        .uniform => c.WGPUBufferBindingType_Uniform,
                        .storage_read => c.WGPUBufferBindingType_ReadOnlyStorage,
                        .storage_read_write => c.WGPUBufferBindingType_Storage,
                    },
                    .hasDynamicOffset = @intFromBool(buffer.dynamic_offset),
                    .minBindingSize = buffer.min_size,
                }),
                .sampled_texture => |texture| out.texture = zeroInit(c.WGPUTextureBindingLayout, .{
                    .sampleType = switch (texture.sample_type) {
                        .float_filterable => c.WGPUTextureSampleType_Float,
                        .float_unfilterable => c.WGPUTextureSampleType_UnfilterableFloat,
                        .sint => c.WGPUTextureSampleType_Sint,
                        .uint => c.WGPUTextureSampleType_Uint,
                        .depth => c.WGPUTextureSampleType_Depth,
                    },
                    .viewDimension = viewDimension(texture.dimension),
                    .multisampled = @intFromBool(texture.multisampled),
                }),
                .storage_texture => |texture| out.storageTexture = zeroInit(c.WGPUStorageTextureBindingLayout, .{
                    .access = switch (texture.access) {
                        .read => c.WGPUStorageTextureAccess_ReadOnly,
                        .write => c.WGPUStorageTextureAccess_WriteOnly,
                        .read_write => c.WGPUStorageTextureAccess_ReadWrite,
                    },
                    .format = try textureFormat(texture.format),
                    .viewDimension = viewDimension(texture.dimension),
                }),
                .sampler => |kind| out.sampler = .{ .nextInChain = null, .type = wgpuEnum("WGPUSamplerBindingType_", kind) },
                // WGSL has no combined image-samplers; bind the texture and sampler separately.
                .combined_texture_sampler => return error.CombinedSamplersUnsupported,
            }
        }
        const layout = c.wgpuDeviceCreateBindGroupLayout(self.handle, &.{
            .nextInChain = null,
            .label = str(desc.label),
            .entryCount = entries.len,
            .entries = entries.ptr,
        }) orelse return error.BindGroupLayoutCreationFailed;
        return .{ .handle = handleOf(layout), .vtable = &bind_group_layout_vtable };
    }

    fn createBindGroup(ptr: *anyopaque, desc: binding.BindGroupDescriptor) anyerror!binding.BindGroup {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const entries = try self.allocator.alloc(c.WGPUBindGroupEntry, desc.entries.len);
        defer self.allocator.free(entries);
        for (desc.entries, entries) |entry, *out| {
            if (entry.array_element != 0) return error.BindingArraysUnsupported;
            out.* = zeroInit(c.WGPUBindGroupEntry, .{ .binding = entry.binding });
            switch (entry.resource) {
                .buffer => |buffer| {
                    out.buffer = ptrOf(WgpuBuffer, buffer.buffer.handle).handle;
                    out.offset = buffer.offset;
                    out.size = buffer.size orelse c.WGPU_WHOLE_SIZE;
                },
                .texture_view => |view| out.textureView = ptrOf(WgpuView, view.handle).handle,
                .sampler => |sampler| out.sampler = @ptrFromInt(@as(usize, @intCast(sampler.handle))),
                .combined_texture_sampler => return error.CombinedSamplersUnsupported,
            }
        }
        const group = c.wgpuDeviceCreateBindGroup(self.handle, &.{
            .nextInChain = null,
            .label = str(desc.label),
            .layout = @ptrFromInt(@as(usize, @intCast(desc.layout.handle))),
            .entryCount = entries.len,
            .entries = entries.ptr,
        }) orelse return error.BindGroupCreationFailed;
        return .{ .handle = handleOf(group), .vtable = &bind_group_vtable };
    }

    fn createPipelineLayout(ptr: *anyopaque, desc: pipeline.PipelineLayoutDescriptor) anyerror!pipeline.PipelineLayout {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const layouts = try self.allocator.alloc(c.WGPUBindGroupLayout, desc.bind_group_layouts.len);
        defer self.allocator.free(layouts);
        for (desc.bind_group_layouts, layouts) |layout, *out| out.* = @ptrFromInt(@as(usize, @intCast(layout.handle)));
        const layout = c.wgpuDeviceCreatePipelineLayout(self.handle, &zeroInit(c.WGPUPipelineLayoutDescriptor, .{
            .label = str(desc.label),
            .bindGroupLayoutCount = layouts.len,
            .bindGroupLayouts = layouts.ptr,
        })) orelse return error.PipelineLayoutCreationFailed;
        return .{ .handle = handleOf(layout), .vtable = &pipeline_layout_vtable };
    }

    fn createGraphicsPipeline(ptr: *anyopaque, desc: pipeline.GraphicsPipelineDescriptor) anyerror!pipeline.GraphicsPipeline {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        if (desc.raster.polygon_mode != .fill) return error.PolygonModeUnsupported;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const buffers = try arena.alloc(c.WGPUVertexBufferLayout, desc.vertex_buffers.len);
        for (desc.vertex_buffers, buffers) |layout, *out| {
            const attributes = try arena.alloc(c.WGPUVertexAttribute, layout.attributes.len);
            for (layout.attributes, attributes) |attribute, *a| a.* = .{
                .nextInChain = null,
                .format = wgpuEnum("WGPUVertexFormat_", attribute.format),
                .offset = attribute.offset,
                .shaderLocation = attribute.location,
            };
            out.* = .{
                .nextInChain = null,
                .stepMode = wgpuEnum("WGPUVertexStepMode_", layout.step_mode),
                .arrayStride = layout.stride,
                .attributeCount = attributes.len,
                .attributes = attributes.ptr,
            };
        }
        const targets = try arena.alloc(c.WGPUColorTargetState, desc.color_targets.len);
        const blends = try arena.alloc(c.WGPUBlendState, desc.color_targets.len);
        for (desc.color_targets, targets, blends) |target, *out, *blend| {
            if (target.blend) |state| blend.* = .{
                .color = blendComponent(state.color),
                .alpha = blendComponent(state.alpha),
            };
            const mask = target.write_mask;
            var write: c.WGPUColorWriteMask = c.WGPUColorWriteMask_None;
            if (mask.red) write |= c.WGPUColorWriteMask_Red;
            if (mask.green) write |= c.WGPUColorWriteMask_Green;
            if (mask.blue) write |= c.WGPUColorWriteMask_Blue;
            if (mask.alpha) write |= c.WGPUColorWriteMask_Alpha;
            out.* = .{
                .nextInChain = null,
                .format = try textureFormat(target.format),
                .blend = if (target.blend != null) blend else null,
                .writeMask = write,
            };
        }
        const vertex = ptrOf(WgpuShader, desc.vertex.handle);
        const fragment_state: ?c.WGPUFragmentState = if (desc.fragment) |fragment| blk: {
            const shader = ptrOf(WgpuShader, fragment.handle);
            break :blk zeroInit(c.WGPUFragmentState, .{
                .module = shader.module,
                .entryPoint = str(shader.entry_point),
                .targetCount = targets.len,
                .targets = targets.ptr,
            });
        } else null;
        const depth_state: ?c.WGPUDepthStencilState = if (desc.depth_stencil) |ds| blk: {
            const format = try textureFormat(ds.format);
            break :blk zeroInit(c.WGPUDepthStencilState, .{
                .format = format,
                .depthWriteEnabled = if (ds.depth_write) c.WGPUOptionalBool_True else c.WGPUOptionalBool_False,
                .depthCompare = wgpuEnum("WGPUCompareFunction_", ds.depth_compare),
                .stencilFront = stencilFace(ds.stencil_front),
                .stencilBack = stencilFace(ds.stencil_back),
                .stencilReadMask = ds.stencil_read_mask,
                .stencilWriteMask = ds.stencil_write_mask,
                .depthBias = desc.raster.depth_bias,
                .depthBiasSlopeScale = desc.raster.depth_bias_slope,
                .depthBiasClamp = desc.raster.depth_bias_clamp,
            });
        } else null;
        const render_pipeline = c.wgpuDeviceCreateRenderPipeline(self.handle, &zeroInit(c.WGPURenderPipelineDescriptor, .{
            .label = str(desc.label),
            .layout = @as(c.WGPUPipelineLayout, @ptrFromInt(@as(usize, @intCast(desc.layout.handle)))),
            .vertex = zeroInit(c.WGPUVertexState, .{
                .module = vertex.module,
                .entryPoint = str(vertex.entry_point),
                .bufferCount = buffers.len,
                .buffers = buffers.ptr,
            }),
            .primitive = zeroInit(c.WGPUPrimitiveState, .{
                .topology = wgpuEnum("WGPUPrimitiveTopology_", desc.topology),
                .frontFace = switch (desc.raster.front_face) {
                    .clockwise => c.WGPUFrontFace_CW,
                    .counter_clockwise => c.WGPUFrontFace_CCW,
                },
                .cullMode = wgpuEnum("WGPUCullMode_", desc.raster.cull_mode),
                .unclippedDepth = @intFromBool(!desc.raster.depth_clip),
            }),
            .depthStencil = if (depth_state) |*state| state else null,
            .multisample = c.WGPUMultisampleState{
                .nextInChain = null,
                .count = desc.multisample.count,
                .mask = desc.multisample.mask,
                .alphaToCoverageEnabled = @intFromBool(desc.multisample.alpha_to_coverage),
            },
            .fragment = if (fragment_state) |*state| state else null,
        })) orelse return error.PipelineCreationFailed;
        return .{ .handle = handleOf(render_pipeline), .vtable = &graphics_pipeline_vtable };
    }

    fn createComputePipeline(ptr: *anyopaque, desc: pipeline.ComputePipelineDescriptor) anyerror!pipeline.ComputePipeline {
        const self: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const shader = ptrOf(WgpuShader, desc.compute.handle);
        const compute = c.wgpuDeviceCreateComputePipeline(self.handle, &zeroInit(c.WGPUComputePipelineDescriptor, .{
            .label = str(desc.label),
            .layout = @as(c.WGPUPipelineLayout, @ptrFromInt(@as(usize, @intCast(desc.layout.handle)))),
            .compute = zeroInit(c.WGPUComputeState, .{ .module = shader.module, .entryPoint = str(shader.entry_point) }),
        })) orelse return error.PipelineCreationFailed;
        return .{ .handle = handleOf(compute), .vtable = &compute_pipeline_vtable };
    }

    fn createCommandPool(ptr: *anyopaque, desc: command.CommandPoolDescriptor) anyerror!command.CommandPool {
        _ = desc;
        // Encoders are one-shot in WebGPU, so a pool is only the device to create them from.
        return .{ .handle = handleOf(ptr), .vtable = &command_pool_vtable };
    }

    fn createSemaphore(_: *anyopaque, _: sync.SemaphoreDescriptor) anyerror!sync.Semaphore {
        return .{ .handle = 1, .vtable = &semaphore_vtable };
    }
};

fn blendComponent(component: pipeline.BlendComponent) c.WGPUBlendComponent {
    return .{
        .operation = wgpuEnum("WGPUBlendOperation_", component.operation),
        .srcFactor = wgpuEnum("WGPUBlendFactor_", component.source),
        .dstFactor = wgpuEnum("WGPUBlendFactor_", component.destination),
    };
}

fn stencilFace(face: pipeline.StencilFaceState) c.WGPUStencilFaceState {
    return .{
        .compare = wgpuEnum("WGPUCompareFunction_", face.compare),
        .failOp = wgpuEnum("WGPUStencilOperation_", face.fail),
        .depthFailOp = wgpuEnum("WGPUStencilOperation_", face.depth_fail),
        .passOp = wgpuEnum("WGPUStencilOperation_", face.pass),
    };
}

/// Release-only vtables for objects whose handle is the WebGPU object itself.
fn releaser(comptime Interface: type, comptime T: type, comptime release: fn (T) callconv(.c) void) Interface.VTable {
    return .{ .deinitFn = struct {
        fn deinit(value: Interface) void {
            release(@ptrFromInt(@as(usize, @intCast(value.handle))));
        }
    }.deinit };
}

const texture_vtable = releaser(resource.Texture, c.WGPUTexture, c.wgpuTextureRelease);
const sampler_vtable = releaser(resource.Sampler, c.WGPUSampler, c.wgpuSamplerRelease);
const bind_group_layout_vtable = releaser(binding.BindGroupLayout, c.WGPUBindGroupLayout, c.wgpuBindGroupLayoutRelease);
const bind_group_vtable = releaser(binding.BindGroup, c.WGPUBindGroup, c.wgpuBindGroupRelease);
const pipeline_layout_vtable = releaser(pipeline.PipelineLayout, c.WGPUPipelineLayout, c.wgpuPipelineLayoutRelease);
const graphics_pipeline_vtable = releaser(pipeline.GraphicsPipeline, c.WGPURenderPipeline, c.wgpuRenderPipelineRelease);
const compute_pipeline_vtable = releaser(pipeline.ComputePipeline, c.WGPUComputePipeline, c.wgpuComputePipelineRelease);
const semaphore_vtable: sync.Semaphore.VTable = .{ .deinitFn = struct {
    fn deinit(_: sync.Semaphore) void {}
}.deinit };
const command_pool_vtable: command.CommandPool.VTable = .{
    .deinitFn = struct {
        fn deinit(_: command.CommandPool) void {}
    }.deinit,
    .resetFn = struct {
        fn reset(_: command.CommandPool) anyerror!void {}
    }.reset,
    .createCommandBufferFn = WgpuCommandBuffer.create,
};

const WgpuShader = struct {
    allocator: std.mem.Allocator,
    module: c.WGPUShaderModule,
    entry_point: []u8,

    const vtable: shader_if.Shader.VTable = .{ .deinitFn = deinit };

    fn deinit(value: shader_if.Shader) void {
        const self = ptrOf(WgpuShader, value.handle);
        c.wgpuShaderModuleRelease(self.module);
        self.allocator.free(self.entry_point);
        self.allocator.destroy(self);
    }
};

/// A view and the format it was created with; render passes need the format to know which
/// depth/stencil aspects to set up.
const WgpuView = struct {
    allocator: std.mem.Allocator,
    handle: c.WGPUTextureView,
    format: c.WGPUTextureFormat,

    const vtable: resource.TextureView.VTable = .{ .deinitFn = deinit };

    fn create(ptr: *anyopaque, desc: resource.TextureViewDescriptor) anyerror!resource.TextureView {
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const texture: c.WGPUTexture = @ptrFromInt(@as(usize, @intCast(desc.texture.handle)));
        const format = if (desc.format) |f| try textureFormat(f) else c.wgpuTextureGetFormat(texture);
        const view = c.wgpuTextureCreateView(texture, &zeroInit(c.WGPUTextureViewDescriptor, .{
            .label = str(desc.label),
            .format = format,
            .dimension = if (desc.dimension) |d| viewDimension(d) else c.WGPUTextureViewDimension_Undefined,
            .baseMipLevel = desc.base_mip,
            .mipLevelCount = desc.mip_count orelse c.WGPU_MIP_LEVEL_COUNT_UNDEFINED,
            .baseArrayLayer = desc.base_layer,
            .arrayLayerCount = desc.layer_count orelse c.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
            .aspect = aspect(desc.aspect),
        })) orelse return error.TextureViewCreationFailed;
        return wrap(device.allocator, view, format);
    }

    fn wrap(allocator: std.mem.Allocator, view: c.WGPUTextureView, format: c.WGPUTextureFormat) !resource.TextureView {
        errdefer c.wgpuTextureViewRelease(view);
        const self = try allocator.create(WgpuView);
        self.* = .{ .allocator = allocator, .handle = view, .format = format };
        return .{ .handle = handleOf(self), .vtable = &vtable };
    }

    fn deinit(value: resource.TextureView) void {
        const self = ptrOf(WgpuView, value.handle);
        c.wgpuTextureViewRelease(self.handle);
        self.allocator.destroy(self);
    }
};

/// WebGPU only maps buffers asynchronously, and never while the GPU may use them. Writes go
/// through a CPU copy that `unmap` uploads with `wgpuQueueWriteBuffer`, which the queue
/// orders after earlier work, so frames in flight never see a half-written buffer.
const WgpuBuffer = struct {
    allocator: std.mem.Allocator,
    handle: c.WGPUBuffer,
    queue: c.WGPUQueue,
    size: u64,
    shadow: ?[]align(4) u8 = null,

    const vtable: resource.Buffer.VTable = .{ .deinitFn = deinit, .mapFn = map, .unmapFn = unmap };

    fn create(ptr: *anyopaque, desc: resource.BufferDescriptor) anyerror!resource.Buffer {
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        if (desc.memory == .readback) return error.ReadbackUnsupported; // ponytail: add mapAsync(read) when something reads results back
        var usage: c.WGPUBufferUsage = c.WGPUBufferUsage_CopyDst;
        if (desc.usage.vertex) usage |= c.WGPUBufferUsage_Vertex;
        if (desc.usage.index) usage |= c.WGPUBufferUsage_Index;
        if (desc.usage.uniform) usage |= c.WGPUBufferUsage_Uniform;
        if (desc.usage.storage) usage |= c.WGPUBufferUsage_Storage;
        if (desc.usage.indirect) usage |= c.WGPUBufferUsage_Indirect;
        if (desc.usage.transfer_src) usage |= c.WGPUBufferUsage_CopySrc;
        if (desc.usage.query_resolve) usage |= c.WGPUBufferUsage_QueryResolve;
        const size = std.mem.alignForward(u64, desc.size, 4);
        const handle = c.wgpuDeviceCreateBuffer(device.handle, &.{
            .nextInChain = null,
            .label = str(desc.label),
            .usage = usage,
            .size = size,
            .mappedAtCreation = @intFromBool(desc.initial_data != null),
        }) orelse return error.BufferCreationFailed;
        errdefer c.wgpuBufferRelease(handle);
        if (desc.initial_data) |data| {
            const mapped: [*]u8 = @ptrCast(c.wgpuBufferGetMappedRange(handle, 0, @intCast(size)) orelse return error.BufferMapFailed);
            @memcpy(mapped[0..data.len], data);
            c.wgpuBufferUnmap(handle);
        }
        const self = try device.allocator.create(WgpuBuffer);
        self.* = .{ .allocator = device.allocator, .handle = handle, .queue = c.wgpuDeviceGetQueue(device.handle), .size = size };
        return .{ .handle = handleOf(self), .vtable = &vtable };
    }

    fn map(value: resource.Buffer, mode: resource.MapMode, range: resource.BufferRange) anyerror![]u8 {
        const self = ptrOf(WgpuBuffer, value.handle);
        if (mode == .read) return error.ReadbackUnsupported;
        if (range.offset + range.size > self.size) return error.OutOfBounds;
        const shadow = self.shadow orelse blk: {
            const bytes = try self.allocator.alignedAlloc(u8, .@"4", @intCast(self.size));
            self.shadow = bytes;
            break :blk bytes;
        };
        return shadow[@intCast(range.offset)..@intCast(range.offset + range.size)];
    }

    fn unmap(value: resource.Buffer, written: ?resource.BufferRange) void {
        const self = ptrOf(WgpuBuffer, value.handle);
        const shadow = self.shadow orelse return;
        const range = written orelse resource.BufferRange{ .size = self.size };
        // writeBuffer wants 4-byte aligned offsets and sizes.
        const start = std.mem.alignBackward(u64, range.offset, 4);
        const end = @min(self.size, std.mem.alignForward(u64, range.offset + range.size, 4));
        c.wgpuQueueWriteBuffer(self.queue, self.handle, start, shadow.ptr + @as(usize, @intCast(start)), @intCast(end - start));
    }

    fn deinit(value: resource.Buffer) void {
        const self = ptrOf(WgpuBuffer, value.handle);
        if (self.shadow) |shadow| self.allocator.free(shadow);
        c.wgpuQueueRelease(self.queue);
        c.wgpuBufferRelease(self.handle);
        self.allocator.destroy(self);
    }
};

const WgpuQueue = struct {
    instance: c.WGPUInstance,
    device: c.WGPUDevice,
    handle: c.WGPUQueue,

    const vtable: queue_if.Queue.VTable = .{ .deinitFn = deinit, .submitFn = submit, .waitIdleFn = waitIdle };

    fn create(ptr: *anyopaque, allocator: std.mem.Allocator, desc: queue_if.QueueDescriptor) anyerror!queue_if.Queue {
        _ = desc; // WebGPU has one queue that does everything.
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const self = try allocator.create(WgpuQueue);
        c.wgpuDeviceAddRef(device.handle);
        self.* = .{ .instance = device.instance, .device = device.handle, .handle = c.wgpuDeviceGetQueue(device.handle) };
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuQueue = @ptrCast(@alignCast(ptr));
        c.wgpuQueueRelease(self.handle);
        c.wgpuDeviceRelease(self.device);
        allocator.destroy(self);
    }

    fn submit(ptr: *anyopaque, desc: sync.SubmitDescriptor) anyerror!void {
        const self: *WgpuQueue = @ptrCast(@alignCast(ptr));
        var buffers: [16]c.WGPUCommandBuffer = undefined;
        if (desc.command_buffers.len > buffers.len) return error.TooManyCommandBuffers;
        for (desc.command_buffers, buffers[0..desc.command_buffers.len]) |cmd, *out| {
            const recorded: *WgpuCommandBuffer = @ptrCast(@alignCast(cmd.ptr));
            out.* = recorded.finished orelse return error.CommandBufferNotFinished;
        }
        c.wgpuQueueSubmit(self.handle, desc.command_buffers.len, &buffers);
        for (desc.command_buffers) |cmd| {
            const recorded: *WgpuCommandBuffer = @ptrCast(@alignCast(cmd.ptr));
            c.wgpuCommandBufferRelease(recorded.finished);
            recorded.finished = null;
        }
        for (desc.signal_fences) |point| try ptrOf(WgpuFence, point.fence.handle).signalAfter(self.handle, point.value);
    }

    fn waitIdle(ptr: *anyopaque) anyerror!void {
        const self: *WgpuQueue = @ptrCast(@alignCast(ptr));
        const future = c.wgpuQueueOnSubmittedWorkDone(self.handle, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_WaitAnyOnly,
            .callback = struct {
                fn done(_: c.WGPUQueueWorkDoneStatus, _: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
            }.done,
            .userdata1 = null,
            .userdata2 = null,
        });
        _ = try waitFuture(self.instance, future, forever);
    }
};

/// A timeline value advanced by `onSubmittedWorkDone` callbacks, one per signalling submit.
const WgpuFence = struct {
    allocator: std.mem.Allocator,
    instance: c.WGPUInstance,
    completed: u64,
    pending: std.ArrayList(Pending) = .empty,

    const Pending = struct { future: c.WGPUFuture, value: u64 };
    const Signal = struct { fence: *WgpuFence, value: u64 };

    const vtable: sync.Fence.VTable = .{ .deinitFn = deinit, .currentValueFn = currentValue, .waitFn = wait };

    fn create(ptr: *anyopaque, desc: sync.FenceDescriptor) anyerror!sync.Fence {
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const self = try device.allocator.create(WgpuFence);
        self.* = .{ .allocator = device.allocator, .instance = device.instance, .completed = desc.initial_value };
        return .{ .handle = handleOf(self), .vtable = &vtable };
    }

    fn signalAfter(self: *WgpuFence, queue: c.WGPUQueue, value: u64) !void {
        const signal = try self.allocator.create(Signal);
        signal.* = .{ .fence = self, .value = value };
        try self.pending.ensureUnusedCapacity(self.allocator, 1);
        const future = c.wgpuQueueOnSubmittedWorkDone(queue, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = done,
            .userdata1 = signal,
            .userdata2 = null,
        });
        self.pending.appendAssumeCapacity(.{ .future = future, .value = value });
    }

    fn done(_: c.WGPUQueueWorkDoneStatus, _: c.WGPUStringView, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const signal: *Signal = @ptrCast(@alignCast(user));
        const self = signal.fence;
        self.completed = @max(self.completed, signal.value);
        self.allocator.destroy(signal);
        var kept: usize = 0;
        for (self.pending.items) |item| {
            if (item.value > self.completed) {
                self.pending.items[kept] = item;
                kept += 1;
            }
        }
        self.pending.shrinkRetainingCapacity(kept);
    }

    fn currentValue(value: sync.Fence) u64 {
        const self = ptrOf(WgpuFence, value.handle);
        c.wgpuInstanceProcessEvents(self.instance);
        return self.completed;
    }

    fn wait(point: sync.FencePoint, timeout_ns: ?u64) anyerror!bool {
        const self = ptrOf(WgpuFence, point.fence.handle);
        // Work finishes in submit order, so waiting on the first future at or past the target is enough.
        while (self.completed < point.value) {
            const next = for (self.pending.items) |item| {
                if (item.value >= point.value) break item;
            } else return error.FenceValueNeverSignalled;
            if (!try waitFuture(self.instance, next.future, timeout_ns orelse forever)) return false;
        }
        return true;
    }

    fn deinit(value: sync.Fence) void {
        const self = ptrOf(WgpuFence, value.handle);
        // Signals still in flight point at this fence; let them land first.
        if (self.pending.items.len > 0) {
            _ = wait(.{ .fence = value, .value = self.pending.items[self.pending.items.len - 1].value }, null) catch {};
        }
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------------------------
// Swapchain

const WgpuSwapchain = struct {
    allocator: std.mem.Allocator,
    device: c.WGPUDevice,
    surface: c.WGPUSurface,
    config: c.WGPUSurfaceConfiguration,
    /// sRGB formats render through a view of the (never sRGB) canvas texture.
    view_format: c.WGPUTextureFormat,
    swapchain_format: swapchain_if.SwapchainFormat,
    image_count: u32,
    current: ?struct { texture: c.WGPUTexture, view: resource.TextureView } = null,

    const vtable: swapchain_if.Swapchain.VTable = .{
        .deinitFn = deinit,
        .acquireNextImageFn = acquire,
        .presentFn = present,
        .resizeFn = resize,
        .infoFn = info,
    };

    fn create(ptr: *anyopaque, allocator: std.mem.Allocator, desc: swapchain_if.SwapchainDescriptor) anyerror!swapchain_if.Swapchain {
        const adapter: *WgpuAdapter = @ptrCast(@alignCast(ptr));
        const queue: *WgpuQueue = @ptrCast(@alignCast(desc.queue.ptr));
        const device = queue.device;
        c.wgpuDeviceAddRef(device);
        errdefer c.wgpuDeviceRelease(device);
        const surface = try createSurface(adapter.instance);
        errdefer c.wgpuSurfaceRelease(surface);
        const view_format = swapchainTextureFormat(desc.format);
        const canvas_format: c.WGPUTextureFormat = switch (desc.format) {
            .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8Unorm,
            .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8Unorm,
            else => view_format,
        };
        var usage: c.WGPUTextureUsage = c.WGPUTextureUsage_None;
        if (desc.usage.render_target) usage |= c.WGPUTextureUsage_RenderAttachment;
        if (desc.usage.sampled) usage |= c.WGPUTextureUsage_TextureBinding;
        if (desc.usage.transfer_src) usage |= c.WGPUTextureUsage_CopySrc;
        if (desc.usage.transfer_dst) usage |= c.WGPUTextureUsage_CopyDst;
        const self = try allocator.create(WgpuSwapchain);
        self.* = .{
            .allocator = allocator,
            .device = device,
            .surface = surface,
            .view_format = view_format,
            .swapchain_format = desc.format,
            .image_count = desc.image_count,
            .config = zeroInit(c.WGPUSurfaceConfiguration, .{
                .device = device,
                .format = canvas_format,
                .usage = usage,
                .width = desc.extent.width,
                .height = desc.extent.height,
                .alphaMode = switch (desc.composite_alpha) {
                    .opaque_alpha => c.WGPUCompositeAlphaMode_Opaque,
                    .premultiplied => c.WGPUCompositeAlphaMode_Premultiplied,
                    .postmultiplied, .inherit => c.WGPUCompositeAlphaMode_Auto,
                },
                .presentMode = c.WGPUPresentMode_Fifo, // the only mode a canvas has
            }),
        };
        if (view_format != canvas_format) {
            self.config.viewFormatCount = 1;
            self.config.viewFormats = &self.view_format;
        }
        c.wgpuSurfaceConfigure(surface, &self.config);
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn releaseCurrent(self: *WgpuSwapchain) void {
        const current = self.current orelse return;
        current.view.deinit();
        c.wgpuTextureRelease(current.texture);
        self.current = null;
    }

    fn acquire(ptr: *anyopaque, _: ?sync.Semaphore) anyerror!swapchain_if.AcquireResult {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        self.releaseCurrent();
        var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        const status: swapchain_if.AcquireStatus = switch (surface_texture.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal => .optimal,
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal => .suboptimal,
            c.WGPUSurfaceGetCurrentTextureStatus_Timeout, c.WGPUSurfaceGetCurrentTextureStatus_Outdated, c.WGPUSurfaceGetCurrentTextureStatus_Lost => return error.OutOfDate,
            else => return error.AcquireFailed,
        };
        const texture = surface_texture.texture orelse return error.AcquireFailed;
        errdefer c.wgpuTextureRelease(texture);
        const raw_view = c.wgpuTextureCreateView(texture, &zeroInit(c.WGPUTextureViewDescriptor, .{
            .format = self.view_format,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .arrayLayerCount = 1,
            .aspect = c.WGPUTextureAspect_All,
        })) orelse return error.AcquireFailed;
        const view = try WgpuView.wrap(self.allocator, raw_view, self.view_format);
        self.current = .{ .texture = texture, .view = view };
        return .{ .index = 0, .view = view, .status = status };
    }

    fn present(ptr: *anyopaque, _: []const sync.Semaphore) anyerror!swapchain_if.PresentStatus {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        // The browser presents the canvas when this frame's callback returns.
        self.releaseCurrent();
        return .optimal;
    }

    fn resize(ptr: *anyopaque, extent: swapchain_if.Extent2D) anyerror!void {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        self.releaseCurrent();
        self.config.width = extent.width;
        self.config.height = extent.height;
        c.wgpuSurfaceConfigure(self.surface, &self.config);
    }

    fn info(ptr: *anyopaque) swapchain_if.SwapchainInfo {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        return .{
            .extent = .{ .width = self.config.width, .height = self.config.height },
            .format = self.swapchain_format,
            .image_count = self.image_count,
        };
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WgpuSwapchain = @ptrCast(@alignCast(ptr));
        self.releaseCurrent();
        c.wgpuSurfaceUnconfigure(self.surface);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuDeviceRelease(self.device);
        allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------------------------
// Command recording

const WgpuCommandBuffer = struct {
    device: *WgpuDevice,
    encoder: c.WGPUCommandEncoder,
    pass: union(enum) { none, render: c.WGPURenderPassEncoder, compute: c.WGPUComputePassEncoder } = .none,
    finished: c.WGPUCommandBuffer = null,

    fn create(pool: command.CommandPool, desc: command.CommandBufferDescriptor) anyerror!command.CommandBuffer {
        const device = ptrOf(WgpuDevice, pool.handle);
        const encoder = c.wgpuDeviceCreateCommandEncoder(device.handle, &.{ .nextInChain = null, .label = str(desc.label) }) orelse return error.CommandBufferCreationFailed;
        errdefer c.wgpuCommandEncoderRelease(encoder);
        const self = try device.allocator.create(WgpuCommandBuffer);
        self.* = .{ .device = device, .encoder = encoder };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn from(ptr: *anyopaque) *WgpuCommandBuffer {
        return @ptrCast(@alignCast(ptr));
    }

    fn render(ptr: *anyopaque) c.WGPURenderPassEncoder {
        return switch (from(ptr).pass) {
            .render => |pass| pass,
            else => @panic("draw command recorded outside a render pass"),
        };
    }

    fn compute(ptr: *anyopaque) c.WGPUComputePassEncoder {
        return switch (from(ptr).pass) {
            .compute => |pass| pass,
            else => @panic("dispatch recorded outside a compute pass"),
        };
    }

    fn buffer(value: resource.Buffer) c.WGPUBuffer {
        return ptrOf(WgpuBuffer, value.handle).handle;
    }

    fn texture(value: resource.Texture) c.WGPUTexture {
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }

    const vtable: command.CommandBuffer.VTable = .{
        .deinitFn = deinit,
        .beginRenderPassFn = beginRenderPass,
        .setGraphicsPipelineFn = setGraphicsPipeline,
        .beginComputePassFn = beginComputePass,
        .setComputePipelineFn = setComputePipeline,
        .setVertexBufferFn = setVertexBuffer,
        .setVertexBuffersFn = setVertexBuffers,
        .setIndexBufferFn = setIndexBuffer,
        .setBindGroupFn = setBindGroup,
        .setViewportFn = setViewport,
        .setViewportsFn = setViewports,
        .setScissorFn = setScissor,
        .setScissorsFn = setScissors,
        .setBlendConstantFn = setBlendConstant,
        .setStencilReferenceFn = setStencilReference,
        .drawFn = draw,
        .drawIndexedFn = drawIndexed,
        .drawIndirectFn = drawIndirect,
        .drawIndexedIndirectFn = drawIndexedIndirect,
        .drawIndirectMultiFn = drawIndirectMulti,
        .drawIndexedIndirectMultiFn = drawIndexedIndirectMulti,
        .drawIndirectCountFn = drawIndirectCount,
        .drawIndexedIndirectCountFn = drawIndirectCount,
        .dispatchFn = dispatch,
        .dispatchIndirectFn = dispatchIndirect,
        .endComputePassFn = endComputePass,
        .endRenderPassFn = endRenderPass,
        .barrierFn = barrier,
        .copyBufferFn = copyBuffer,
        .copyTextureFn = copyTexture,
        .copyBufferToTextureFn = copyBufferToTexture,
        .copyTextureToBufferFn = copyTextureToBuffer,
        .resolveTextureFn = resolveTexture,
        .resetQueriesFn = resetQueries,
        .beginQueryFn = query,
        .endQueryFn = query,
        .writeTimestampFn = query,
        .resolveQueriesFn = resolveQueries,
        .beginDebugGroupFn = beginDebugGroup,
        .endDebugGroupFn = endDebugGroup,
        .insertDebugMarkerFn = insertDebugMarker,
        .finishFn = finish,
    };

    fn deinit(ptr: *anyopaque) void {
        const self = from(ptr);
        switch (self.pass) {
            .none => {},
            .render => |pass| c.wgpuRenderPassEncoderRelease(pass),
            .compute => |pass| c.wgpuComputePassEncoderRelease(pass),
        }
        if (self.finished) |finished| c.wgpuCommandBufferRelease(finished);
        c.wgpuCommandEncoderRelease(self.encoder);
        self.device.allocator.destroy(self);
    }

    fn beginRenderPass(ptr: *anyopaque, desc: command.RenderPassDescriptor) anyerror!void {
        const self = from(ptr);
        var colors: [8]c.WGPURenderPassColorAttachment = undefined;
        if (desc.color_attachments.len > colors.len) return error.TooManyColorAttachments;
        for (desc.color_attachments, colors[0..desc.color_attachments.len]) |attachment, *out| out.* = .{
            .nextInChain = null,
            .view = ptrOf(WgpuView, attachment.view.handle).handle,
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = if (attachment.resolve_target) |target| ptrOf(WgpuView, target.handle).handle else null,
            .loadOp = loadOp(attachment.load_op),
            .storeOp = storeOp(attachment.store_op),
            .clearValue = .{ .r = attachment.clear_value.r, .g = attachment.clear_value.g, .b = attachment.clear_value.b, .a = attachment.clear_value.a },
        };
        var depth: c.WGPURenderPassDepthStencilAttachment = undefined;
        if (desc.depth_stencil_attachment) |ds| {
            const view = ptrOf(WgpuView, ds.view.handle);
            depth = zeroInit(c.WGPURenderPassDepthStencilAttachment, .{
                .view = view.handle,
                .depthClearValue = ds.depth_clear,
                .depthReadOnly = @intFromBool(ds.depth_read_only),
                .stencilClearValue = ds.stencil_clear,
                .stencilReadOnly = @intFromBool(ds.stencil_read_only),
            });
            // Load/store ops are only allowed for aspects the format has and that are writable.
            if (hasDepth(view.format) and !ds.depth_read_only) {
                depth.depthLoadOp = loadOp(ds.depth_load_op);
                depth.depthStoreOp = storeOp(ds.depth_store_op);
            }
            if (hasStencil(view.format) and !ds.stencil_read_only) {
                depth.stencilLoadOp = loadOp(ds.stencil_load_op);
                depth.stencilStoreOp = storeOp(ds.stencil_store_op);
            }
        }
        const pass = c.wgpuCommandEncoderBeginRenderPass(self.encoder, &zeroInit(c.WGPURenderPassDescriptor, .{
            .label = str(desc.label),
            .colorAttachmentCount = desc.color_attachments.len,
            .colorAttachments = &colors,
            .depthStencilAttachment = if (desc.depth_stencil_attachment != null) &depth else null,
        })) orelse return error.RenderPassFailed;
        self.pass = .{ .render = pass };
    }

    fn endRenderPass(ptr: *anyopaque) void {
        const self = from(ptr);
        const pass = render(ptr);
        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
        self.pass = .none;
    }

    fn beginComputePass(ptr: *anyopaque, label: ?[]const u8) anyerror!void {
        const self = from(ptr);
        const pass = c.wgpuCommandEncoderBeginComputePass(self.encoder, &zeroInit(c.WGPUComputePassDescriptor, .{ .label = str(label) })) orelse return error.ComputePassFailed;
        self.pass = .{ .compute = pass };
    }

    fn endComputePass(ptr: *anyopaque) void {
        const self = from(ptr);
        const pass = compute(ptr);
        c.wgpuComputePassEncoderEnd(pass);
        c.wgpuComputePassEncoderRelease(pass);
        self.pass = .none;
    }

    fn setGraphicsPipeline(ptr: *anyopaque, value: pipeline.GraphicsPipeline) void {
        c.wgpuRenderPassEncoderSetPipeline(render(ptr), @ptrFromInt(@as(usize, @intCast(value.handle))));
    }

    fn setComputePipeline(ptr: *anyopaque, value: pipeline.ComputePipeline) void {
        c.wgpuComputePassEncoderSetPipeline(compute(ptr), @ptrFromInt(@as(usize, @intCast(value.handle))));
    }

    fn setVertexBuffer(ptr: *anyopaque, slot: u32, value: resource.Buffer, offset: u64) void {
        c.wgpuRenderPassEncoderSetVertexBuffer(render(ptr), slot, buffer(value), offset, c.WGPU_WHOLE_SIZE);
    }

    fn setVertexBuffers(ptr: *anyopaque, first_slot: u32, bindings: []const command.VertexBufferBinding) void {
        for (bindings, 0..) |b, i| setVertexBuffer(ptr, first_slot + @as(u32, @intCast(i)), b.buffer, b.offset);
    }

    fn setIndexBuffer(ptr: *anyopaque, value: resource.Buffer, format: command.IndexFormat, offset: u64) void {
        c.wgpuRenderPassEncoderSetIndexBuffer(render(ptr), buffer(value), wgpuEnum("WGPUIndexFormat_", format), offset, c.WGPU_WHOLE_SIZE);
    }

    fn setBindGroup(ptr: *anyopaque, slot: u32, group: binding.BindGroup, dynamic_offsets: []const u32) void {
        const handle: c.WGPUBindGroup = @ptrFromInt(@as(usize, @intCast(group.handle)));
        switch (from(ptr).pass) {
            .render => |pass| c.wgpuRenderPassEncoderSetBindGroup(pass, slot, handle, dynamic_offsets.len, dynamic_offsets.ptr),
            .compute => |pass| c.wgpuComputePassEncoderSetBindGroup(pass, slot, handle, dynamic_offsets.len, dynamic_offsets.ptr),
            .none => @panic("bind group set outside a pass"),
        }
    }

    fn setViewport(ptr: *anyopaque, v: command.Viewport) void {
        c.wgpuRenderPassEncoderSetViewport(render(ptr), v.x, v.y, v.width, v.height, v.min_depth, v.max_depth);
    }

    fn setViewports(ptr: *anyopaque, viewports: []const command.Viewport) void {
        // WebGPU has a single viewport.
        if (viewports.len > 0) setViewport(ptr, viewports[0]);
    }

    fn setScissor(ptr: *anyopaque, rect: command.ScissorRect) void {
        c.wgpuRenderPassEncoderSetScissorRect(render(ptr), rect.x, rect.y, rect.width, rect.height);
    }

    fn setScissors(ptr: *anyopaque, rects: []const command.ScissorRect) void {
        if (rects.len > 0) setScissor(ptr, rects[0]);
    }

    fn setBlendConstant(ptr: *anyopaque, colour: command.Color) void {
        c.wgpuRenderPassEncoderSetBlendConstant(render(ptr), &.{ .r = colour.r, .g = colour.g, .b = colour.b, .a = colour.a });
    }

    fn setStencilReference(ptr: *anyopaque, value: u32) void {
        c.wgpuRenderPassEncoderSetStencilReference(render(ptr), value);
    }

    fn draw(ptr: *anyopaque, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
        c.wgpuRenderPassEncoderDraw(render(ptr), vertices, instances, first_vertex, first_instance);
    }

    fn drawIndexed(ptr: *anyopaque, indices: u32, instances: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        c.wgpuRenderPassEncoderDrawIndexed(render(ptr), indices, instances, first_index, base_vertex, first_instance);
    }

    fn drawIndirect(ptr: *anyopaque, value: resource.Buffer, offset: u64) void {
        c.wgpuRenderPassEncoderDrawIndirect(render(ptr), buffer(value), offset);
    }

    fn drawIndexedIndirect(ptr: *anyopaque, value: resource.Buffer, offset: u64) void {
        c.wgpuRenderPassEncoderDrawIndexedIndirect(render(ptr), buffer(value), offset);
    }

    fn drawIndirectMulti(ptr: *anyopaque, value: resource.Buffer, offset: u64, count: u32) void {
        for (0..count) |i| drawIndirect(ptr, value, offset + i * 16);
    }

    fn drawIndexedIndirectMulti(ptr: *anyopaque, value: resource.Buffer, offset: u64, count: u32) void {
        for (0..count) |i| drawIndexedIndirect(ptr, value, offset + i * 20);
    }

    fn drawIndirectCount(_: *anyopaque, _: resource.Buffer, _: u64, _: resource.Buffer, _: u64, _: u32) void {
        @panic("WebGPU has no GPU-driven draw counts");
    }

    fn dispatch(ptr: *anyopaque, x: u32, y: u32, z: u32) void {
        c.wgpuComputePassEncoderDispatchWorkgroups(compute(ptr), x, y, z);
    }

    fn dispatchIndirect(ptr: *anyopaque, value: resource.Buffer, offset: u64) void {
        c.wgpuComputePassEncoderDispatchWorkgroupsIndirect(compute(ptr), buffer(value), offset);
    }

    fn barrier(_: *anyopaque, _: []const command.ResourceBarrier) anyerror!void {
        // WebGPU tracks resource state itself.
    }

    fn copyBuffer(ptr: *anyopaque, region: command.BufferCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyBufferToBuffer(from(ptr).encoder, buffer(region.source), region.source_offset, buffer(region.destination), region.destination_offset, region.size);
    }

    fn textureInfo(view: command.TextureCopyView) c.WGPUTexelCopyTextureInfo {
        return .{
            .texture = texture(view.texture),
            .mipLevel = view.mip_level,
            .origin = .{ .x = view.origin.x, .y = view.origin.y, .z = view.origin.z + view.array_layer },
            .aspect = c.WGPUTextureAspect_All,
        };
    }

    fn bufferInfo(region: command.BufferTextureCopyRegion) !c.WGPUTexelCopyBufferInfo {
        const bytes_per_row = if (region.bytes_per_row != 0)
            region.bytes_per_row
        else
            std.mem.alignForward(u32, region.extent.width * try texelSize(c.wgpuTextureGetFormat(texture(region.texture.texture))), 256);
        return .{
            .layout = .{
                .offset = region.buffer_offset,
                .bytesPerRow = bytes_per_row,
                .rowsPerImage = if (region.rows_per_image != 0) region.rows_per_image else region.extent.height,
            },
            .buffer = buffer(region.buffer),
        };
    }

    fn extent(e: command.Extent3D) c.WGPUExtent3D {
        return .{ .width = e.width, .height = e.height, .depthOrArrayLayers = e.depth };
    }

    fn copyTexture(ptr: *anyopaque, region: command.TextureCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyTextureToTexture(from(ptr).encoder, &textureInfo(region.source), &textureInfo(region.destination), &extent(region.extent));
    }

    fn copyBufferToTexture(ptr: *anyopaque, region: command.BufferTextureCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyBufferToTexture(from(ptr).encoder, &try bufferInfo(region), &textureInfo(region.texture), &extent(region.extent));
    }

    fn copyTextureToBuffer(ptr: *anyopaque, region: command.BufferTextureCopyRegion) anyerror!void {
        c.wgpuCommandEncoderCopyTextureToBuffer(from(ptr).encoder, &textureInfo(region.texture), &try bufferInfo(region), &extent(region.extent));
    }

    fn resolveTexture(_: *anyopaque, _: command.TextureResolveRegion) anyerror!void {
        // ponytail: WebGPU resolves only as a render-pass resolve target; emulate with an empty pass if needed.
        return error.Unsupported;
    }

    // `QuerySet.init` fails on this backend (no `createQuerySetFn`), so these are never reached.
    fn resetQueries(_: *anyopaque, _: command.QuerySet, _: u32, _: u32) void {
        unreachable;
    }

    fn query(_: *anyopaque, _: command.QuerySet, _: u32) void {
        unreachable;
    }

    fn resolveQueries(_: *anyopaque, _: command.QuerySet, _: u32, _: u32, _: resource.Buffer, _: u64) void {
        unreachable;
    }

    fn beginDebugGroup(ptr: *anyopaque, label: []const u8) void {
        switch (from(ptr).pass) {
            .none => c.wgpuCommandEncoderPushDebugGroup(from(ptr).encoder, str(label)),
            .render => |pass| c.wgpuRenderPassEncoderPushDebugGroup(pass, str(label)),
            .compute => |pass| c.wgpuComputePassEncoderPushDebugGroup(pass, str(label)),
        }
    }

    fn endDebugGroup(ptr: *anyopaque) void {
        switch (from(ptr).pass) {
            .none => c.wgpuCommandEncoderPopDebugGroup(from(ptr).encoder),
            .render => |pass| c.wgpuRenderPassEncoderPopDebugGroup(pass),
            .compute => |pass| c.wgpuComputePassEncoderPopDebugGroup(pass),
        }
    }

    fn insertDebugMarker(ptr: *anyopaque, label: []const u8) void {
        switch (from(ptr).pass) {
            .none => c.wgpuCommandEncoderInsertDebugMarker(from(ptr).encoder, str(label)),
            .render => |pass| c.wgpuRenderPassEncoderInsertDebugMarker(pass, str(label)),
            .compute => |pass| c.wgpuComputePassEncoderInsertDebugMarker(pass, str(label)),
        }
    }

    fn finish(ptr: *anyopaque) anyerror!void {
        const self = from(ptr);
        self.finished = c.wgpuCommandEncoderFinish(self.encoder, &.{ .nextInChain = null, .label = str(null) }) orelse return error.CommandBufferFinishFailed;
    }
};

test "snake_case tags map onto WebGPU's PascalCase names" {
    try std.testing.expectEqualStrings("OneMinusSrcAlpha", comptime pascal("one_minus_src_alpha"));
    try std.testing.expectEqualStrings("Float32x3", comptime pascal("float32x3"));
}
