const std = @import("std");
const vk = @import("vulkan");

const hal = @import("../hal.zig");
const pipeline = @import("../../types/pipeline.zig");
const sampler = @import("../../types/sampler.zig");
const texture = @import("../../types/texture.zig");
const vkDevice = @import("device.zig").vkDevice;
const vkShaderModule = @import("shader.zig").vkShaderModule;
const debug = @import("debug.zig");

const logz = @import("logz");

pub const vkPipelineLayout = struct {
    device: *vkDevice,
    handle: vk.PipelineLayout,
    label: ?[*:0]const u8,

    pub const vtable = hal.PipelineLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(device: *vkDevice, descriptor: pipeline.PipelineLayout.Descriptor) !hal.PipelineLayout {
        logz.info().fmt("msg", "building vulkan pipeline layout: bind_group_layouts={}", .{descriptor.bindGroupLayouts.len}).log();
        if (descriptor.bindGroupLayouts.len != 0) {
            logz.info().fmt("msg", "vulkan pipeline layout rejected: bind group layouts are not implemented yet", .{}).log();
            return error.NotImplemented;
        }

        const create_info = vk.PipelineLayoutCreateInfo{};
        const handle = try device.device.createPipelineLayout(&create_info, null);
        errdefer device.device.destroyPipelineLayout(handle, null);

        const layout = try device.adapter.gpu.allocator.create(vkPipelineLayout);
        errdefer device.adapter.gpu.allocator.destroy(layout);
        layout.* = .{
            .device = device,
            .handle = handle,
            .label = descriptor.label,
        };
        debug.setObjectName(device, .pipeline_layout, handle, descriptor.label);

        logz.info().fmt("msg", "created vulkan pipeline layout: handle=0x{x}", .{@intFromEnum(handle)}).log();
        return .{
            .ptr = layout,
            .vtable = &vkPipelineLayout.vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.handle != .null_handle) {
            logz.info().fmt("msg", "destroying vulkan pipeline layout: handle=0x{x}", .{@intFromEnum(typed.handle)}).log();
            typed.device.device.destroyPipelineLayout(typed.handle, null);
            typed.handle = .null_handle;
        }
        typed.device.adapter.gpu.allocator.destroy(typed);
    }
};

pub const vkComputePipeline = struct {
    pub const vtable = hal.ComputePipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init(device: *vkDevice, descriptor: pipeline.ComputePipeline.Descriptor) !hal.ComputePipeline {
        _ = device;
        _ = descriptor;
        return error.NotImplemented;
    }

    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
        logz.info().fmt("msg", "destroying vulkan compute pipeline", .{}).log();
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: u32) anyerror!hal.BindGroupLayout {
        _ = ptr;
        _ = index;
        return error.NotImplemented;
    }
};

pub const vkRenderPipeline = struct {
    device: *vkDevice,
    handle: vk.Pipeline,
    render_pass: vk.RenderPass,
    layout: *vkPipelineLayout,
    owns_layout: bool,
    label: ?[*:0]const u8,

    pub const vtable = hal.RenderPipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init(device: *vkDevice, descriptor: pipeline.RenderPipeline.Descriptor) !hal.RenderPipeline {
        logz.info().fmt("msg", "building vulkan render pipeline: topology={s} cull={s} samples={} color_targets={}", .{
            @tagName(descriptor.primitive.topology),
            @tagName(descriptor.primitive.cullMode),
            descriptor.multisample.count,
            if (descriptor.fragment) |fragment| fragment.targets.len else 0,
        }).log();
        const layout, const owns_layout = try resolvePipelineLayout(device, descriptor.layout, descriptor.label);
        errdefer if (owns_layout) layout.vtable.destroy(layout.ptr);
        const vk_layout: *vkPipelineLayout = @ptrCast(@alignCast(layout.ptr));

        const render_pass: vk.RenderPass = .null_handle;

        var entry_points = EntryPointSet{ .allocator = device.adapter.gpu.allocator };
        defer entry_points.deinit();

        var stages: [2]vk.PipelineShaderStageCreateInfo = undefined;
        var stage_count: usize = 0;
        stages[stage_count] = try shaderStageInfo(
            descriptor.vertex.module,
            .{ .vertex_bit = true },
            descriptor.vertex.entry_point,
            &entry_points,
        );
        stage_count += 1;

        if (descriptor.fragment) |fragment| {
            stages[stage_count] = try shaderStageInfo(
                fragment.module,
                .{ .fragment_bit = true },
                fragment.entry_point,
                &entry_points,
            );
            stage_count += 1;
            if (fragment.constants.len != 0) {
                logz.info().fmt("msg", "vulkan render pipeline rejected: fragment specialization constants are not implemented yet", .{}).log();
                return error.NotImplemented;
            }
        }
        if (descriptor.vertex.constants.len != 0) {
            logz.info().fmt("msg", "vulkan render pipeline rejected: vertex specialization constants are not implemented yet", .{}).log();
            return error.NotImplemented;
        }

        var vertex_state = try VertexInputState.init(device.adapter.gpu.allocator, descriptor.vertex);
        defer vertex_state.deinit();

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = primitiveTopologyToVulkan(descriptor.primitive.topology),
            .primitive_restart_enable = if (descriptor.primitive.stripIndexFormat != null) .true else .false,
        };

        const dynamic_states = [_]vk.DynamicState{
            .viewport,
            .scissor,
        };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        };
        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = if (descriptor.primitive.unclippedDepth) .true else .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = cullModeToVulkan(descriptor.primitive.cullMode),
            .front_face = frontFaceToVulkan(descriptor.primitive.frontFace),
            .depth_bias_enable = if (descriptor.depthStencil != null and descriptor.depthStencil.?.depthBias != 0) .true else .false,
            .depth_bias_constant_factor = if (descriptor.depthStencil) |depth| @floatFromInt(depth.depthBias) else 0.0,
            .depth_bias_clamp = if (descriptor.depthStencil) |depth| depth.depthBiasClamp else 0.0,
            .depth_bias_slope_factor = if (descriptor.depthStencil) |depth| depth.depthBiasSlopeScale else 0.0,
            .line_width = 1.0,
        };
        const sample_mask = @as(vk.SampleMask, descriptor.multisample.mask);
        const sample_masks = [_]vk.SampleMask{sample_mask};
        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = sampleCountToVulkan(descriptor.multisample.count),
            .sample_shading_enable = .false,
            .min_sample_shading = 1.0,
            .p_sample_mask = &sample_masks,
            .alpha_to_coverage_enable = if (descriptor.multisample.alphaToCoverageEnabled) .true else .false,
            .alpha_to_one_enable = .false,
        };

        var color_blend_state = try ColorBlendState.init(device.adapter.gpu.allocator, descriptor.fragment);
        defer color_blend_state.deinit();

        var color_formats: [8]vk.Format = undefined;
        var color_format_count: u32 = 0;
        if (descriptor.fragment) |fragment| {
            if (fragment.targets.len > color_formats.len) return error.TooManyColorTargets;
            for (fragment.targets) |maybe_target| {
                const target = maybe_target orelse {
                    color_formats[color_format_count] = .undefined;
                    color_format_count += 1;
                    continue;
                };
                color_formats[color_format_count] = textureFormatToVulkan(target.format) orelse .undefined;
                color_format_count += 1;
            }
        }
        const rendering_info = vk.PipelineRenderingCreateInfo{
            .view_mask = 0,
            .color_attachment_count = color_format_count,
            .p_color_attachment_formats = if (color_format_count == 0) null else &color_formats,
            .depth_attachment_format = if (descriptor.depthStencil) |depth| textureFormatToVulkan(depth.format) orelse .undefined else .undefined,
            .stencil_attachment_format = if (descriptor.depthStencil) |depth| textureFormatToVulkan(depth.format) orelse .undefined else .undefined,
        };

        const depth_stencil_state = if (descriptor.depthStencil) |depth_stencil|
            depthStencilStateToVulkan(depth_stencil)
        else
            null;

        const create_info = vk.GraphicsPipelineCreateInfo{
            .p_next = &rendering_info,
            .stage_count = @intCast(stage_count),
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_state.create_info,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = if (depth_stencil_state) |*state| state else null,
            .p_color_blend_state = &color_blend_state.create_info,
            .p_dynamic_state = &dynamic_state,
            .layout = vk_layout.handle,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var handle: vk.Pipeline = .null_handle;
        const result = try device.device.createGraphicsPipelines(
            .null_handle,
            &.{create_info},
            null,
            @as([*]vk.Pipeline, @ptrCast(&handle))[0..1],
        );
        if (result != .success) {
            logz.info().fmt("msg", "vulkan graphics pipeline creation returned non-success result: {s}", .{@tagName(result)}).log();
            return error.PipelineCompileRequired;
        }
        errdefer device.device.destroyPipeline(handle, null);

        const render_pipeline = try device.adapter.gpu.allocator.create(vkRenderPipeline);
        errdefer device.adapter.gpu.allocator.destroy(render_pipeline);
        render_pipeline.* = .{
            .device = device,
            .handle = handle,
            .render_pass = render_pass,
            .layout = vk_layout,
            .owns_layout = owns_layout,
            .label = descriptor.label,
        };
        device.registerDeviceChild(render_pipeline, destroy);
        device.registerRenderPipelineHandle(handle);
        debug.setObjectName(device, .pipeline, handle, descriptor.label);
        if (render_pass != .null_handle) {
            debug.setObjectName(device, .render_pass, render_pass, descriptor.label);
        }

        logz.info().fmt("msg", "created vulkan render pipeline: handle=0x{x} render_pass=0x{x}", .{
            @intFromEnum(handle),
            @intFromEnum(render_pass),
        }).log();
        return .{
            .ptr = render_pipeline,
            .vtable = &vkRenderPipeline.vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        typed.device.unregisterDeviceChild(ptr);
        if (typed.handle != .null_handle or typed.render_pass != .null_handle) {
            typed.device.device.deviceWaitIdle() catch |err| {
                logz.err().src(@src()).err(err).log();
            };
            typed.device.queue.cleanupCompleted(true);
        }
        if (typed.handle != .null_handle) {
            logz.info().fmt("msg", "destroying vulkan render pipeline: handle=0x{x}", .{@intFromEnum(typed.handle)}).log();
            typed.device.unregisterRenderPipelineHandle(typed.handle);
            typed.device.device.destroyPipeline(typed.handle, null);
            typed.handle = .null_handle;
        }
        if (typed.render_pass != .null_handle) {
            logz.info().fmt("msg", "destroying vulkan render pass: handle=0x{x}", .{@intFromEnum(typed.render_pass)}).log();
            typed.device.device.destroyRenderPass(typed.render_pass, null);
            typed.render_pass = .null_handle;
        }
        if (typed.owns_layout) {
            vkPipelineLayout.vtable.destroy(typed.layout);
            typed.owns_layout = false;
        }
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: u32) anyerror!hal.BindGroupLayout {
        _ = ptr;
        _ = index;
        return error.NotImplemented;
    }
};

const EntryPointSet = struct {
    allocator: std.mem.Allocator,
    owned: std.ArrayList([:0]u8) = .empty,

    fn dupe(self: *@This(), entry_point: ?[]const u8) ![*:0]const u8 {
        const name = entry_point orelse return "main";
        const copy = try self.allocator.dupeZ(u8, name);
        errdefer self.allocator.free(copy);
        try self.owned.append(self.allocator, copy);
        return copy.ptr;
    }

    fn deinit(self: *@This()) void {
        for (self.owned.items) |name| {
            self.allocator.free(name);
        }
        self.owned.deinit(self.allocator);
    }
};

fn shaderStageInfo(
    module: @import("../../types/shader.zig").ShaderModule,
    stage: vk.ShaderStageFlags,
    entry_point: ?[]const u8,
    entry_points: *EntryPointSet,
) !vk.PipelineShaderStageCreateInfo {
    const backend = module.backend orelse return error.InvalidShaderModule;
    const vk_module: *vkShaderModule = @ptrCast(@alignCast(backend.ptr));
    return .{
        .stage = stage,
        .module = vk_module.handle,
        .p_name = try entry_points.dupe(entry_point),
    };
}

fn resolvePipelineLayout(device: *vkDevice, layout: ?*const pipeline.PipelineLayout, label: ?[*:0]const u8) !struct { hal.PipelineLayout, bool } {
    if (layout) |explicit| {
        return .{
            explicit.backend orelse return error.InvalidPipelineLayout,
            false,
        };
    }

    return .{
        try vkPipelineLayout.init(device, .{
            .label = label,
            .bindGroupLayouts = &.{},
        }),
        true,
    };
}

const VertexInputState = struct {
    allocator: std.mem.Allocator,
    bindings: []vk.VertexInputBindingDescription,
    attributes: []vk.VertexInputAttributeDescription,
    create_info: vk.PipelineVertexInputStateCreateInfo,

    fn init(allocator: std.mem.Allocator, vertex: pipeline.VertexState) !@This() {
        var binding_list = std.ArrayList(vk.VertexInputBindingDescription).empty;
        errdefer binding_list.deinit(allocator);
        var attribute_list = std.ArrayList(vk.VertexInputAttributeDescription).empty;
        errdefer attribute_list.deinit(allocator);

        for (vertex.buffers, 0..) |maybe_buffer, binding_index| {
            const buffer = maybe_buffer orelse continue;
            try binding_list.append(allocator, .{
                .binding = @intCast(binding_index),
                .stride = @intCast(buffer.arrayStride),
                .input_rate = switch (buffer.stepMode) {
                    .vertex => .vertex,
                    .instance => .instance,
                },
            });

            for (buffer.attributes) |attribute| {
                try attribute_list.append(allocator, .{
                    .location = attribute.shaderLocation,
                    .binding = @intCast(binding_index),
                    .format = vertexFormatToVulkan(attribute.format),
                    .offset = @intCast(attribute.offset),
                });
            }
        }

        const bindings = try binding_list.toOwnedSlice(allocator);
        errdefer allocator.free(bindings);
        const attributes = try attribute_list.toOwnedSlice(allocator);
        errdefer allocator.free(attributes);

        return .{
            .allocator = allocator,
            .bindings = bindings,
            .attributes = attributes,
            .create_info = .{
                .vertex_binding_description_count = @intCast(bindings.len),
                .p_vertex_binding_descriptions = if (bindings.len == 0) null else bindings.ptr,
                .vertex_attribute_description_count = @intCast(attributes.len),
                .p_vertex_attribute_descriptions = if (attributes.len == 0) null else attributes.ptr,
            },
        };
    }

    fn deinit(self: *@This()) void {
        self.allocator.free(self.bindings);
        self.allocator.free(self.attributes);
    }
};

const ColorBlendState = struct {
    allocator: std.mem.Allocator,
    attachments: []vk.PipelineColorBlendAttachmentState,
    create_info: vk.PipelineColorBlendStateCreateInfo,

    fn init(allocator: std.mem.Allocator, fragment: ?pipeline.FragmentState) !@This() {
        const target_count = if (fragment) |frag| frag.targets.len else 0;
        const attachments = try allocator.alloc(vk.PipelineColorBlendAttachmentState, target_count);
        errdefer allocator.free(attachments);

        if (fragment) |frag| {
            for (frag.targets, attachments) |maybe_target, *attachment| {
                attachment.* = colorBlendAttachmentToVulkan(maybe_target);
            }
        }

        return .{
            .allocator = allocator,
            .attachments = attachments,
            .create_info = .{
                .logic_op_enable = .false,
                .logic_op = .copy,
                .attachment_count = @intCast(attachments.len),
                .p_attachments = if (attachments.len == 0) null else attachments.ptr,
                .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
            },
        };
    }

    fn deinit(self: *@This()) void {
        self.allocator.free(self.attachments);
    }
};

fn createRenderPass(device: *vkDevice, descriptor: pipeline.RenderPipeline.Descriptor) !vk.RenderPass {
    const color_target_count = if (descriptor.fragment) |frag| frag.targets.len else 0;
    const has_depth = descriptor.depthStencil != null;
    const max_attachments = color_target_count + @as(usize, if (has_depth) 1 else 0);

    const allocator = device.adapter.gpu.allocator;
    var attachments = try allocator.alloc(vk.AttachmentDescription, max_attachments);
    defer allocator.free(attachments);
    var color_refs = try allocator.alloc(vk.AttachmentReference, color_target_count);
    defer allocator.free(color_refs);

    var attachment_count: usize = 0;
    if (descriptor.fragment) |fragment| {
        for (fragment.targets, 0..) |maybe_target, target_index| {
            if (maybe_target) |target| {
                const attachment_index = attachment_count;
                attachments[attachment_count] = .{
                    .format = textureFormatToVulkan(target.format) orelse return error.UnsupportedTextureFormat,
                    .samples = sampleCountToVulkan(descriptor.multisample.count),
                    .load_op = .clear,
                    .store_op = .store,
                    .stencil_load_op = .dont_care,
                    .stencil_store_op = .dont_care,
                    .initial_layout = .undefined,
                    .final_layout = .present_src_khr,
                };
                attachment_count += 1;
                color_refs[target_index] = .{
                    .attachment = @intCast(attachment_index),
                    .layout = .color_attachment_optimal,
                };
            } else {
                color_refs[target_index] = .{
                    .attachment = vk.ATTACHMENT_UNUSED,
                    .layout = .color_attachment_optimal,
                };
            }
        }
    }

    var depth_ref: vk.AttachmentReference = undefined;
    if (descriptor.depthStencil) |depth| {
        const attachment_index = attachment_count;
        attachments[attachment_count] = .{
            .format = textureFormatToVulkan(depth.format) orelse return error.UnsupportedTextureFormat,
            .samples = sampleCountToVulkan(descriptor.multisample.count),
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
        };
        attachment_count += 1;
        depth_ref = .{
            .attachment = @intCast(attachment_index),
            .layout = .depth_stencil_attachment_optimal,
        };
    }

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = @intCast(color_refs.len),
        .p_color_attachments = if (color_refs.len == 0) null else color_refs.ptr,
        .p_depth_stencil_attachment = if (has_depth) &depth_ref else null,
    };
    const render_pass_info = vk.RenderPassCreateInfo{
        .attachment_count = @intCast(attachment_count),
        .p_attachments = if (attachment_count == 0) null else attachments.ptr,
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    };

    const render_pass = try device.device.createRenderPass(&render_pass_info, null);
    logz.info().fmt("msg", "created vulkan render pass: handle=0x{x} attachments={} color_targets={} has_depth={}", .{
        @intFromEnum(render_pass),
        attachment_count,
        color_refs.len,
        has_depth,
    }).log();
    return render_pass;
}

fn colorBlendAttachmentToVulkan(target: ?pipeline.ColorTargetState) vk.PipelineColorBlendAttachmentState {
    const color_write_mask = if (target) |t| colorWriteMaskToVulkan(t.writeMask) else vk.ColorComponentFlags{};
    if (target) |t| {
        if (t.blend) |blend| {
            return .{
                .blend_enable = .true,
                .src_color_blend_factor = blendFactorToVulkan(blend.color.srcFactor),
                .dst_color_blend_factor = blendFactorToVulkan(blend.color.dstFactor),
                .color_blend_op = blendOpToVulkan(blend.color.operation),
                .src_alpha_blend_factor = blendFactorToVulkan(blend.alpha.srcFactor),
                .dst_alpha_blend_factor = blendFactorToVulkan(blend.alpha.dstFactor),
                .alpha_blend_op = blendOpToVulkan(blend.alpha.operation),
                .color_write_mask = color_write_mask,
            };
        }
    }

    return .{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = color_write_mask,
    };
}

fn depthStencilStateToVulkan(depth: pipeline.DepthStencilState) vk.PipelineDepthStencilStateCreateInfo {
    return .{
        .depth_test_enable = if (depth.depthCompare != null) .true else .false,
        .depth_write_enable = if (depth.depthWriteEnabled orelse false) .true else .false,
        .depth_compare_op = compareFunctionToVulkan(depth.depthCompare orelse .always),
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = stencilFaceToVulkan(depth.stencilFront, depth.stencilReadMask, depth.stencilWriteMask),
        .back = stencilFaceToVulkan(depth.stencilBack, depth.stencilReadMask, depth.stencilWriteMask),
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };
}

fn stencilFaceToVulkan(face: pipeline.StencilFaceState, read_mask: u32, write_mask: u32) vk.StencilOpState {
    return .{
        .fail_op = stencilOpToVulkan(face.failOp),
        .pass_op = stencilOpToVulkan(face.passOp),
        .depth_fail_op = stencilOpToVulkan(face.depthFailOp),
        .compare_op = compareFunctionToVulkan(face.compare),
        .compare_mask = read_mask,
        .write_mask = write_mask,
        .reference = 0,
    };
}

fn primitiveTopologyToVulkan(topology: pipeline.PrimitiveTopology) vk.PrimitiveTopology {
    return switch (topology) {
        .point_list => .point_list,
        .line_list => .line_list,
        .line_strip => .line_strip,
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
    };
}

fn cullModeToVulkan(cull_mode: pipeline.CullMode) vk.CullModeFlags {
    return switch (cull_mode) {
        .none => .{},
        .front => .{ .front_bit = true },
        .back => .{ .back_bit = true },
    };
}

fn frontFaceToVulkan(front_face: pipeline.FrontFace) vk.FrontFace {
    return switch (front_face) {
        .ccw => .counter_clockwise,
        .cw => .clockwise,
    };
}

fn sampleCountToVulkan(count: u32) vk.SampleCountFlags {
    return switch (count) {
        1 => .{ .@"1_bit" = true },
        2 => .{ .@"2_bit" = true },
        4 => .{ .@"4_bit" = true },
        8 => .{ .@"8_bit" = true },
        16 => .{ .@"16_bit" = true },
        32 => .{ .@"32_bit" = true },
        64 => .{ .@"64_bit" = true },
        else => .{ .@"1_bit" = true },
    };
}

fn colorWriteMaskToVulkan(mask: pipeline.ColorWriteFlags) vk.ColorComponentFlags {
    const typed = pipeline.ColorWrite.fromFlags(mask);
    return .{
        .r_bit = typed.red,
        .g_bit = typed.green,
        .b_bit = typed.blue,
        .a_bit = typed.alpha,
    };
}

fn blendFactorToVulkan(factor: pipeline.BlendFactor) vk.BlendFactor {
    return switch (factor) {
        .zero => .zero,
        .one => .one,
        .src => .src_color,
        .one_minus_src => .one_minus_src_color,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
        .dst => .dst_color,
        .one_minus_dst => .one_minus_dst_color,
        .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha,
        .src_alpha_saturated => .src_alpha_saturate,
        .constant => .constant_color,
        .one_minus_constant => .one_minus_constant_color,
        .src1 => .src1_color,
        .one_minus_src1 => .one_minus_src1_color,
        .src1_alpha => .src1_alpha,
        .one_minus_src1_alpha => .one_minus_src1_alpha,
    };
}

fn blendOpToVulkan(op: pipeline.BlendOperation) vk.BlendOp {
    return switch (op) {
        .add => .add,
        .subtract => .subtract,
        .reverse_subtract => .reverse_subtract,
        .min => .min,
        .max => .max,
    };
}

fn compareFunctionToVulkan(compare: sampler.Sampler.CompareFunction) vk.CompareOp {
    return switch (compare) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_or_equal,
        .always => .always,
    };
}

fn stencilOpToVulkan(op: pipeline.StencilOperation) vk.StencilOp {
    return switch (op) {
        .keep => .keep,
        .zero => .zero,
        .replace => .replace,
        .invert => .invert,
        .increment_clamp => .increment_and_clamp,
        .decrement_clamp => .decrement_and_clamp,
        .increment_wrap => .increment_and_wrap,
        .decrement_wrap => .decrement_and_wrap,
    };
}

fn vertexFormatToVulkan(format: pipeline.VertexFormat) vk.Format {
    return switch (format) {
        .uint8 => .r8_uint,
        .uint8x2 => .r8g8_uint,
        .uint8x4 => .r8g8b8a8_uint,
        .sint8 => .r8_sint,
        .sint8x2 => .r8g8_sint,
        .sint8x4 => .r8g8b8a8_sint,
        .unorm8 => .r8_unorm,
        .unorm8x2 => .r8g8_unorm,
        .unorm8x4 => .r8g8b8a8_unorm,
        .snorm8 => .r8_snorm,
        .snorm8x2 => .r8g8_snorm,
        .snorm8x4 => .r8g8b8a8_snorm,
        .uint16 => .r16_uint,
        .uint16x2 => .r16g16_uint,
        .uint16x4 => .r16g16b16a16_uint,
        .sint16 => .r16_sint,
        .sint16x2 => .r16g16_sint,
        .sint16x4 => .r16g16b16a16_sint,
        .unorm16 => .r16_unorm,
        .unorm16x2 => .r16g16_unorm,
        .unorm16x4 => .r16g16b16a16_unorm,
        .snorm16 => .r16_snorm,
        .snorm16x2 => .r16g16_snorm,
        .snorm16x4 => .r16g16b16a16_snorm,
        .float16 => .r16_sfloat,
        .float16x2 => .r16g16_sfloat,
        .float16x4 => .r16g16b16a16_sfloat,
        .float32 => .r32_sfloat,
        .float32x2 => .r32g32_sfloat,
        .float32x3 => .r32g32b32_sfloat,
        .float32x4 => .r32g32b32a32_sfloat,
        .uint32 => .r32_uint,
        .uint32x2 => .r32g32_uint,
        .uint32x3 => .r32g32b32_uint,
        .uint32x4 => .r32g32b32a32_uint,
        .sint32 => .r32_sint,
        .sint32x2 => .r32g32_sint,
        .sint32x3 => .r32g32b32_sint,
        .sint32x4 => .r32g32b32a32_sint,
        .@"unorm10-10-10-2" => .a2b10g10r10_unorm_pack32,
        .unorm8x4_bgra => .b8g8r8a8_unorm,
    };
}

fn textureFormatToVulkan(format: texture.Texture.Format) ?vk.Format {
    return switch (format) {
        .r8unorm => .r8_unorm,
        .r8snorm => .r8_snorm,
        .r8uint => .r8_uint,
        .r8sint => .r8_sint,
        .r16uint => .r16_uint,
        .r16sint => .r16_sint,
        .r16float => .r16_sfloat,
        .rg8uint => .r8g8_uint,
        .rg8sint => .r8g8_sint,
        .r32uint => .r32_uint,
        .r32sint => .r32_sint,
        .r32float => .r32_sfloat,
        .rg16unorm => .r16g16_unorm,
        .rg16snorm => .r16g16_snorm,
        .rg16uint => .r16g16_uint,
        .rg16sint => .r16g16_sint,
        .rg16float => .r16g16_sfloat,
        .rgba8unorm => .r8g8b8a8_unorm,
        .rgba8unorm_srgb => .r8g8b8a8_srgb,
        .rgba8snorm => .r8g8b8a8_snorm,
        .rgba8uint => .r8g8b8a8_uint,
        .rgba8sint => .r8g8b8a8_sint,
        .bgra8unorm => .b8g8r8a8_unorm,
        .bgra8unorm_srgb => .b8g8r8a8_srgb,
        .rg32uint => .r32g32_uint,
        .rg32sint => .r32g32_sint,
        .rg32float => .r32g32_sfloat,
        .rgba16unorm => .r16g16b16a16_unorm,
        .rgba16snorm => .r16g16b16a16_snorm,
        .rgba16uint => .r16g16b16a16_uint,
        .rgba16sint => .r16g16b16a16_sint,
        .rgba16float => .r16g16b16a16_sfloat,
        .rgba32uint => .r32g32b32a32_uint,
        .rgba32sint => .r32g32b32a32_sint,
        .rgba32float => .r32g32b32a32_sfloat,
        .depth16unorm => .d16_unorm,
        .depth24plus => .d32_sfloat,
        .depth32float => .d32_sfloat,
        .depth24plus_stencil8 => .d24_unorm_s8_uint,
        .depth32float_stencil8 => .d32_sfloat_s8_uint,
        .stencil8 => .s8_uint,
        else => null,
    };
}
