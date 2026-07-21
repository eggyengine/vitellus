const std = @import("std");
const vk = @import("vulkan");
const pipeline = @import("../../interface/pipeline.zig");
const resource = @import("../../interface/resource.zig");
const resource_impl = @import("resource.zig");
const vkDevice = @import("device.zig").vkDevice;
const binding_impl = @import("binding.zig");
const shader_impl = @import("shader.zig");
const adapter_impl = @import("adapter.zig");

pub const vkPipelineLayout = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.PipelineLayout,

    pub fn fromHandle(value: pipeline.PipelineLayout) !*vkPipelineLayout {
        if (value.handle == 0) return error.InvalidPipelineLayout;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkGraphicsPipeline = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.Pipeline,
    layout: vk.PipelineLayout,

    pub fn fromHandle(value: pipeline.GraphicsPipeline) !*vkGraphicsPipeline {
        if (value.handle == 0) return error.InvalidGraphicsPipeline;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkComputePipeline = struct {
    allocator: std.mem.Allocator, device: vk.DeviceProxy, handle: vk.Pipeline, layout: vk.PipelineLayout,
    pub fn fromHandle(value: pipeline.ComputePipeline) !*vkComputePipeline {
        if (value.handle == 0) return error.InvalidComputePipeline;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const layout_vtable: pipeline.PipelineLayout.VTable = .{ .deinitFn = destroyLayout };
const graphics_vtable: pipeline.GraphicsPipeline.VTable = .{ .deinitFn = destroyGraphics };
const compute_vtable: pipeline.ComputePipeline.VTable = .{ .deinitFn = destroyCompute };

pub fn createLayout(ptr: *anyopaque, desc: pipeline.PipelineLayoutDescriptor) !pipeline.PipelineLayout {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const layouts = try device.allocator.alloc(vk.DescriptorSetLayout, desc.bind_group_layouts.len);
    defer device.allocator.free(layouts);
    for (desc.bind_group_layouts, layouts) |value, *native| native.* = (try binding_impl.vkBindGroupLayout.fromHandle(value)).handle;
    const handle = try device.proxy.createPipelineLayout(&.{
        .set_layout_count = @intCast(layouts.len),
        .p_set_layouts = if (layouts.len == 0) null else layouts.ptr,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, null);
    errdefer device.proxy.destroyPipelineLayout(handle, null);
    const self = try device.allocator.create(vkPipelineLayout);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = handle };
    device.instance.nameObject(device.allocator, device.proxy, .pipeline_layout, @intFromEnum(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &layout_vtable };
}

pub fn createGraphics(ptr: *anyopaque, desc: pipeline.GraphicsPipelineDescriptor) !pipeline.GraphicsPipeline {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const layout = try vkPipelineLayout.fromHandle(desc.layout);
    const vertex = try shader_impl.vkShader.fromHandle(desc.vertex);
    if (vertex.stage != .vertex) return error.InvalidVertexShader;
    var stages: [2]vk.PipelineShaderStageCreateInfo = undefined;
    stages[0] = shaderStage(vertex);
    var stage_count: usize = 1;
    if (desc.fragment) |value| {
        const fragment = try shader_impl.vkShader.fromHandle(value);
        if (fragment.stage != .fragment) return error.InvalidFragmentShader;
        stages[stage_count] = shaderStage(fragment);
        stage_count += 1;
    }

    const bindings = try device.allocator.alloc(vk.VertexInputBindingDescription, desc.vertex_buffers.len);
    defer device.allocator.free(bindings);
    var attribute_count: usize = 0;
    for (desc.vertex_buffers) |buffer| attribute_count += buffer.attributes.len;
    const attributes = try device.allocator.alloc(vk.VertexInputAttributeDescription, attribute_count);
    defer device.allocator.free(attributes);
    var attribute_index: usize = 0;
    for (desc.vertex_buffers, 0..) |buffer, binding_index| {
        bindings[binding_index] = .{
            .binding = @intCast(binding_index),
            .stride = buffer.stride,
            .input_rate = if (buffer.step_mode == .vertex) .vertex else .instance,
        };
        for (buffer.attributes) |attribute| {
            attributes[attribute_index] = .{
                .location = attribute.location,
                .binding = @intCast(binding_index),
                .format = vertexFormat(attribute.format),
                .offset = attribute.offset,
            };
            attribute_index += 1;
        }
    }
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = @intCast(bindings.len),
        .p_vertex_binding_descriptions = if (bindings.len == 0) null else bindings.ptr,
        .vertex_attribute_description_count = @intCast(attributes.len),
        .p_vertex_attribute_descriptions = if (attributes.len == 0) null else attributes.ptr,
    };
    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = primitiveTopology(desc.topology),
        .primitive_restart_enable = .false,
    };
    const viewport: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .scissor_count = 1 };
    const raster: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = if (desc.raster.depth_clip) .false else .true,
        .rasterizer_discard_enable = .false,
        .polygon_mode = switch (desc.raster.polygon_mode) { .fill => .fill, .line => .line, .point => .point },
        .cull_mode = switch (desc.raster.cull_mode) {
            .none => .{},
            .front => .{ .front_bit = true },
            .back => .{ .back_bit = true },
        },
        .front_face = if (desc.raster.front_face == .clockwise) .clockwise else .counter_clockwise,
        .depth_bias_enable = if (desc.raster.depth_bias != 0 or desc.raster.depth_bias_slope != 0) .true else .false,
        .depth_bias_constant_factor = @floatFromInt(desc.raster.depth_bias),
        .depth_bias_clamp = desc.raster.depth_bias_clamp,
        .depth_bias_slope_factor = desc.raster.depth_bias_slope,
        .line_width = 1,
    };
    var sample_mask = desc.multisample.mask;
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = sampleCount(desc.multisample.count),
        .sample_shading_enable = .false,
        .min_sample_shading = 0,
        .p_sample_mask = @ptrCast(&sample_mask),
        .alpha_to_coverage_enable = if (desc.multisample.alpha_to_coverage) .true else .false,
        .alpha_to_one_enable = .false,
    };
    const blend_attachments = try device.allocator.alloc(vk.PipelineColorBlendAttachmentState, desc.color_targets.len);
    defer device.allocator.free(blend_attachments);
    const color_formats = try device.allocator.alloc(vk.Format, desc.color_targets.len);
    defer device.allocator.free(color_formats);
    for (desc.color_targets, 0..) |target, index| {
        color_formats[index] = adapter_impl.toVkFormat(target.format);
        blend_attachments[index] = colorBlend(target);
    }
    const color_blend: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = @intCast(blend_attachments.len),
        .p_attachments = if (blend_attachments.len == 0) null else blend_attachments.ptr,
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };
    const rendering: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = @intCast(color_formats.len),
        .p_color_attachment_formats = if (color_formats.len == 0) null else color_formats.ptr,
        .depth_attachment_format = if (desc.depth_stencil) |depth| adapter_impl.toVkFormat(depth.format) else .undefined,
        .stencil_attachment_format = .undefined,
    };
    const depth_state: vk.PipelineDepthStencilStateCreateInfo = if (desc.depth_stencil) |depth| .{
        .depth_test_enable = .true, .depth_write_enable = if (depth.depth_write) .true else .false,
        .depth_compare_op = resource_impl.compare(depth.depth_compare), .depth_bounds_test_enable = .false,
        .stencil_test_enable = if (adapter_impl.toVkFormat(depth.format) == .d24_unorm_s8_uint or adapter_impl.toVkFormat(depth.format) == .d32_sfloat_s8_uint) .true else .false,
        .front = stencilState(depth.stencil_front, depth.stencil_read_mask, depth.stencil_write_mask),
        .back = stencilState(depth.stencil_back, depth.stencil_read_mask, depth.stencil_write_mask),
        .min_depth_bounds = 0, .max_depth_bounds = 1,
    } else .{ .depth_test_enable = .false, .depth_write_enable = .false, .depth_compare_op = .always,
        .depth_bounds_test_enable = .false, .stencil_test_enable = .false, .front = stencilState(.{}, 0xff, 0xff),
        .back = stencilState(.{}, 0xff, 0xff), .min_depth_bounds = 0, .max_depth_bounds = 1 };
    var native: vk.Pipeline = .null_handle;
    const result = try device.proxy.createGraphicsPipelines(.null_handle, &.{.{
        .p_next = &rendering,
        .stage_count = @intCast(stage_count),
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &raster,
        .p_multisample_state = &multisample,
        .p_depth_stencil_state = if (desc.depth_stencil != null) &depth_state else null,
        .p_color_blend_state = &color_blend,
        .p_dynamic_state = &dynamic,
        .layout = layout.handle,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, @as([]vk.Pipeline, (&native)[0..1]));
    if (result != .success) return error.PipelineCreationFailed;
    errdefer device.proxy.destroyPipeline(native, null);
    const self = try device.allocator.create(vkGraphicsPipeline);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = native, .layout = layout.handle };
    device.instance.nameObject(device.allocator, device.proxy, .pipeline, @intFromEnum(native), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &graphics_vtable };
}

pub fn createCompute(ptr: *anyopaque, desc: pipeline.ComputePipelineDescriptor) !pipeline.ComputePipeline {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const layout = try vkPipelineLayout.fromHandle(desc.layout);
    const shader = try shader_impl.vkShader.fromHandle(desc.compute);
    if (shader.stage != .compute) return error.InvalidComputeShader;
    var native: vk.Pipeline = .null_handle;
    const result = try device.proxy.createComputePipelines(.null_handle, &.{.{ .stage = shaderStage(shader), .layout = layout.handle, .base_pipeline_index = -1 }}, null, @as([]vk.Pipeline, (&native)[0..1]));
    if (result != .success) return error.PipelineCreationFailed;
    errdefer device.proxy.destroyPipeline(native, null);
    const self = try device.allocator.create(vkComputePipeline);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = native, .layout = layout.handle };
    device.instance.nameObject(device.allocator, device.proxy, .pipeline, @intFromEnum(native), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &compute_vtable };
}

fn destroyLayout(value: pipeline.PipelineLayout) void {
    const self = vkPipelineLayout.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.device.destroyPipelineLayout(self.handle, null);
    allocator.destroy(self);
}

fn destroyGraphics(value: pipeline.GraphicsPipeline) void {
    const self = vkGraphicsPipeline.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.device.destroyPipeline(self.handle, null);
    allocator.destroy(self);
}
fn destroyCompute(value: pipeline.ComputePipeline) void { const self = vkComputePipeline.fromHandle(value) catch return; const a = self.allocator; self.device.destroyPipeline(self.handle, null); a.destroy(self); }

fn stencilState(value: pipeline.StencilFaceState, read_mask: u8, write_mask: u8) vk.StencilOpState {
    return .{ .fail_op = stencilOp(value.fail), .pass_op = stencilOp(value.pass), .depth_fail_op = stencilOp(value.depth_fail),
        .compare_op = resource_impl.compare(value.compare), .compare_mask = read_mask, .write_mask = write_mask, .reference = 0 };
}
fn stencilOp(value: pipeline.StencilOp) vk.StencilOp { return switch (value) { .keep => .keep, .zero => .zero, .replace => .replace, .invert => .invert, .increment_clamp => .increment_and_clamp, .decrement_clamp => .decrement_and_clamp, .increment_wrap => .increment_and_wrap, .decrement_wrap => .decrement_and_wrap }; }

fn shaderStage(value: *shader_impl.vkShader) vk.PipelineShaderStageCreateInfo {
    return .{
        .stage = switch (value.stage) {
            .vertex => .{ .vertex_bit = true },
            .fragment => .{ .fragment_bit = true },
            .compute => .{ .compute_bit = true },
        },
        .module = value.handle,
        .p_name = value.entry_point.ptr,
    };
}

fn primitiveTopology(value: pipeline.PrimitiveTopology) vk.PrimitiveTopology {
    return switch (value) {
        .point_list => .point_list,
        .line_list => .line_list,
        .line_strip => .line_strip,
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
    };
}

fn sampleCount(value: u32) vk.SampleCountFlags {
    return switch (value) {
        1 => .{ .@"1_bit" = true }, 2 => .{ .@"2_bit" = true }, 4 => .{ .@"4_bit" = true },
        8 => .{ .@"8_bit" = true }, 16 => .{ .@"16_bit" = true }, 32 => .{ .@"32_bit" = true },
        64 => .{ .@"64_bit" = true }, else => .{},
    };
}

fn colorBlend(target: pipeline.ColorTargetState) vk.PipelineColorBlendAttachmentState {
    const blend: pipeline.BlendState = target.blend orelse .{};
    return .{
        .blend_enable = if (target.blend != null) .true else .false,
        .src_color_blend_factor = blendFactor(blend.color.source),
        .dst_color_blend_factor = blendFactor(blend.color.destination),
        .color_blend_op = blendOp(blend.color.operation),
        .src_alpha_blend_factor = blendFactor(blend.alpha.source),
        .dst_alpha_blend_factor = blendFactor(blend.alpha.destination),
        .alpha_blend_op = blendOp(blend.alpha.operation),
        .color_write_mask = .{
            .r_bit = target.write_mask.red, .g_bit = target.write_mask.green,
            .b_bit = target.write_mask.blue, .a_bit = target.write_mask.alpha,
        },
    };
}

fn blendFactor(value: pipeline.BlendFactor) vk.BlendFactor {
    return switch (value) {
        .zero => .zero, .one => .one, .src => .src_color, .one_minus_src => .one_minus_src_color,
        .src_alpha => .src_alpha, .one_minus_src_alpha => .one_minus_src_alpha, .dst => .dst_color,
        .one_minus_dst => .one_minus_dst_color, .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha, .src_alpha_saturated => .src_alpha_saturate,
        .constant => .constant_color, .one_minus_constant => .one_minus_constant_color,
    };
}

fn blendOp(value: pipeline.BlendOp) vk.BlendOp {
    return switch (value) { .add => .add, .subtract => .subtract, .reverse_subtract => .reverse_subtract, .min => .min, .max => .max };
}

fn vertexFormat(value: pipeline.VertexFormat) vk.Format {
    return switch (value) {
        .uint8x2 => .r8g8_uint, .uint8x4 => .r8g8b8a8_uint, .sint8x2 => .r8g8_sint, .sint8x4 => .r8g8b8a8_sint,
        .unorm8x2 => .r8g8_unorm, .unorm8x4 => .r8g8b8a8_unorm, .snorm8x2 => .r8g8_snorm, .snorm8x4 => .r8g8b8a8_snorm,
        .uint16x2 => .r16g16_uint, .uint16x4 => .r16g16b16a16_uint, .sint16x2 => .r16g16_sint, .sint16x4 => .r16g16b16a16_sint,
        .unorm16x2 => .r16g16_unorm, .unorm16x4 => .r16g16b16a16_unorm, .snorm16x2 => .r16g16_snorm, .snorm16x4 => .r16g16b16a16_snorm,
        .float16x2 => .r16g16_sfloat, .float16x4 => .r16g16b16a16_sfloat, .float32 => .r32_sfloat,
        .float32x2 => .r32g32_sfloat, .float32x3 => .r32g32b32_sfloat, .float32x4 => .r32g32b32a32_sfloat,
        .uint32 => .r32_uint, .uint32x2 => .r32g32_uint, .uint32x3 => .r32g32b32_uint, .uint32x4 => .r32g32b32a32_uint,
        .sint32 => .r32_sint, .sint32x2 => .r32g32_sint, .sint32x3 => .r32g32b32_sint, .sint32x4 => .r32g32b32a32_sint,
    };
}
