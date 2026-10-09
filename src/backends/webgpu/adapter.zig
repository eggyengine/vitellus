//! The browser's one adapter and its canvas surface.

const std = @import("std");
const c = @import("webgpu_c");
const adapter_if = @import("../../interface/adapter.zig");
const swapchain_if = @import("../../interface/swapchain.zig");
const resource = @import("../../interface/resource.zig");
const Window = @import("../../windowing/windowing.zig").Window;
const canvas_selector = @import("utils.zig").canvas_selector;
const str = @import("utils.zig").str;
const slice = @import("utils.zig").slice;
const textureFormat = @import("utils.zig").textureFormat;
const hasStencil = @import("utils.zig").hasStencil;
const hasDepth = @import("utils.zig").hasDepth;
const WgpuDevice = @import("device.zig").WgpuDevice;
const WgpuSwapchain = @import("swapchain.zig").WgpuSwapchain;

pub const WgpuAdapter = struct {
    instance: c.WGPUInstance,
    handle: c.WGPUAdapter,

    pub const vtable: adapter_if.Adapter.VTable = .{
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

pub fn createSurface(instance: c.WGPUInstance) !c.WGPUSurface {
    var canvas = c.WGPUEmscriptenSurfaceSourceCanvasHTMLSelector{
        .chain = .{ .next = null, .sType = c.WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector },
        .selector = str(canvas_selector),
    };
    const desc = c.WGPUSurfaceDescriptor{ .nextInChain = &canvas.chain, .label = str(null) };
    return c.wgpuInstanceCreateSurface(instance, &desc) orelse error.SurfaceCreationFailed;
}
