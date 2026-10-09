//! The WebGPU device, which creates every other object.

const std = @import("std");
const c = @import("webgpu_c");
const device_if = @import("../../interface/device.zig");
const shader_if = @import("../../interface/shader.zig");
const resource = @import("../../interface/resource.zig");
const binding = @import("../../interface/binding.zig");
const pipeline = @import("../../interface/pipeline.zig");
const command = @import("../../interface/command.zig");
const sync = @import("../../interface/sync.zig");
const log = @import("utils.zig").log;
const forever = @import("utils.zig").forever;
const str = @import("utils.zig").str;
const slice = @import("utils.zig").slice;
const wgpuEnum = @import("utils.zig").wgpuEnum;
const zeroInit = @import("utils.zig").zeroInit;
const ptrOf = @import("utils.zig").ptrOf;
const handleOf = @import("utils.zig").handleOf;
const waitFuture = @import("utils.zig").waitFuture;
const textureFormat = @import("utils.zig").textureFormat;
const texelSize = @import("utils.zig").texelSize;
const viewDimension = @import("utils.zig").viewDimension;
const aspect = @import("utils.zig").aspect;
const visibility = @import("utils.zig").visibility;
const WgpuAdapter = @import("adapter.zig").WgpuAdapter;
const WgpuShader = @import("shader.zig").WgpuShader;
const WgpuView = @import("resource.zig").WgpuView;
const WgpuBuffer = @import("resource.zig").WgpuBuffer;
const WgpuQueue = @import("queue.zig").WgpuQueue;
const WgpuFence = @import("sync.zig").WgpuFence;
const WgpuCommandBuffer = @import("command.zig").WgpuCommandBuffer;

pub const WgpuDevice = struct {
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

    pub fn create(ptr: *anyopaque, allocator: std.mem.Allocator, desc: device_if.DeviceDescriptor) anyerror!device_if.Device {
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
        if (compiled.format != .wgsl) return error.UnsupportedShaderFormat;
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

pub fn blendComponent(component: pipeline.BlendComponent) c.WGPUBlendComponent {
    return .{
        .operation = wgpuEnum("WGPUBlendOperation_", component.operation),
        .srcFactor = wgpuEnum("WGPUBlendFactor_", component.source),
        .dstFactor = wgpuEnum("WGPUBlendFactor_", component.destination),
    };
}

pub fn stencilFace(face: pipeline.StencilFaceState) c.WGPUStencilFaceState {
    return .{
        .compare = wgpuEnum("WGPUCompareFunction_", face.compare),
        .failOp = wgpuEnum("WGPUStencilOperation_", face.fail),
        .depthFailOp = wgpuEnum("WGPUStencilOperation_", face.depth_fail),
        .passOp = wgpuEnum("WGPUStencilOperation_", face.pass),
    };
}

/// Release-only vtables for objects whose handle is the WebGPU object itself.
pub fn releaser(comptime Interface: type, comptime T: type, comptime release: fn (T) callconv(.c) void) Interface.VTable {
    return .{ .deinitFn = struct {
        fn deinit(value: Interface) void {
            release(@ptrFromInt(@as(usize, @intCast(value.handle))));
        }
    }.deinit };
}

pub const texture_vtable = releaser(resource.Texture, c.WGPUTexture, c.wgpuTextureRelease);
pub const sampler_vtable = releaser(resource.Sampler, c.WGPUSampler, c.wgpuSamplerRelease);
pub const bind_group_layout_vtable = releaser(binding.BindGroupLayout, c.WGPUBindGroupLayout, c.wgpuBindGroupLayoutRelease);
pub const bind_group_vtable = releaser(binding.BindGroup, c.WGPUBindGroup, c.wgpuBindGroupRelease);
pub const pipeline_layout_vtable = releaser(pipeline.PipelineLayout, c.WGPUPipelineLayout, c.wgpuPipelineLayoutRelease);
pub const graphics_pipeline_vtable = releaser(pipeline.GraphicsPipeline, c.WGPURenderPipeline, c.wgpuRenderPipelineRelease);
pub const compute_pipeline_vtable = releaser(pipeline.ComputePipeline, c.WGPUComputePipeline, c.wgpuComputePipelineRelease);
pub const semaphore_vtable: sync.Semaphore.VTable = .{ .deinitFn = struct {
    fn deinit(_: sync.Semaphore) void {}
}.deinit };
pub const command_pool_vtable: command.CommandPool.VTable = .{
    .deinitFn = struct {
        fn deinit(_: command.CommandPool) void {}
    }.deinit,
    .resetFn = struct {
        fn reset(_: command.CommandPool) anyerror!void {}
    }.reset,
    .createCommandBufferFn = WgpuCommandBuffer.create,
};
