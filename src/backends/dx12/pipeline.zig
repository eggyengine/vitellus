//! DirectX 12 graphics pipeline creation.

const std = @import("std");
const pipeline = @import("../../interface/pipeline.zig");
const shader = @import("shader.zig");
const resource = @import("resource.zig");
const binding = @import("binding.zig");
const Dx12Device = @import("device.zig").Dx12Device;
const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;
const log = std.log.scoped(.dx12_pipeline);

pub const BindGroupRoots = struct { resources: ?u32 = null, samplers: ?u32 = null };
pub const Dx12PipelineLayout = struct {
    allocator: std.mem.Allocator,
    bind_group_layouts: [8]?*binding.Dx12BindGroupLayout = [_]?*binding.Dx12BindGroupLayout{null} ** 8,
    bind_group_roots: [8]BindGroupRoots = [_]BindGroupRoots{.{}} ** 8,
    bind_group_count: u32 = 0,
    root_signature: ComPtr(dx.ID3D12RootSignature) = .{},
    pub fn fromHandle(value: pipeline.PipelineLayout) !*Dx12PipelineLayout {
        if (value.handle == 0) return error.InvalidPipelineLayout;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};
pub const Dx12GraphicsPipeline = struct {
    allocator: std.mem.Allocator,
    root_signature: ComPtr(dx.ID3D12RootSignature) = .{},
    state: ComPtr(dx.ID3D12PipelineState) = .{},
    topology: dx.D3D12_PRIMITIVE_TOPOLOGY,
    vertex_strides: [32]u32 = [_]u32{0} ** 32,
    vertex_buffer_count: usize = 0,
    bind_group_layouts: [8]?*binding.Dx12BindGroupLayout = [_]?*binding.Dx12BindGroupLayout{null} ** 8,
    bind_group_roots: [8]BindGroupRoots = [_]BindGroupRoots{.{}} ** 8,
    bind_group_count: u32 = 0,

    pub fn fromHandle(value: pipeline.GraphicsPipeline) !*Dx12GraphicsPipeline {
        if (value.handle == 0) return error.InvalidPipeline;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const Dx12ComputePipeline = struct {
    allocator: std.mem.Allocator,
    layout: *Dx12PipelineLayout,
    state: ComPtr(dx.ID3D12PipelineState) = .{},
    pub fn fromHandle(value: pipeline.ComputePipeline) !*Dx12ComputePipeline {
        if (value.handle == 0) return error.InvalidPipeline;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const layout_vtable: pipeline.PipelineLayout.VTable = .{ .deinitFn = destroyLayout };
const graphics_vtable: pipeline.GraphicsPipeline.VTable = .{ .deinitFn = destroyGraphics };
const compute_vtable: pipeline.ComputePipeline.VTable = .{ .deinitFn = destroyCompute };

pub fn createLayout(ptr: *anyopaque, desc: pipeline.PipelineLayoutDescriptor) anyerror!pipeline.PipelineLayout {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    if (desc.bind_group_layouts.len > 8) return error.TooManyBindGroups;
    const self = try device.allocator.create(Dx12PipelineLayout);
    self.* = .{ .allocator = device.allocator, .bind_group_count = @intCast(desc.bind_group_layouts.len) };
    errdefer device.allocator.destroy(self);
    for (desc.bind_group_layouts, 0..) |layout, i| self.bind_group_layouts[i] = try binding.Dx12BindGroupLayout.fromHandle(layout);
    self.root_signature = try makeRootSignature(device, self.bind_group_layouts[0..self.bind_group_count], &self.bind_group_roots);
    log.debug("created DX12 pipeline layout bind-groups={}", .{self.bind_group_count});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &layout_vtable };
}

pub fn destroyLayout(value: pipeline.PipelineLayout) void {
    const self = Dx12PipelineLayout.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.root_signature.deinit();
    log.debug("destroyed DX12 pipeline layout", .{});
    allocator.destroy(self);
}

pub fn createGraphics(ptr: *anyopaque, desc: pipeline.GraphicsPipelineDescriptor) anyerror!pipeline.GraphicsPipeline {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const layout = try Dx12PipelineLayout.fromHandle(desc.layout);
    const vertex = try shader.Dx12Shader.fromHandle(desc.vertex);
    if (vertex.stage != .vertex) return error.InvalidShaderStage;
    const fragment = if (desc.fragment) |value| try shader.Dx12Shader.fromHandle(value) else null;
    if (fragment) |value| if (value.stage != .fragment) return error.InvalidShaderStage;
    if (desc.color_targets.len > 8) return error.TooManyColorTargets;
    if (desc.vertex_buffers.len > 32) return error.TooManyVertexBuffers;

    const self = try device.allocator.create(Dx12GraphicsPipeline);
    self.* = .{
        .allocator = device.allocator,
        .topology = toDxTopology(desc.topology),
        .vertex_buffer_count = desc.vertex_buffers.len,
        .bind_group_count = layout.bind_group_count,
        .root_signature = layout.root_signature.clone(),
    };
    for (desc.vertex_buffers, 0..) |vertex_layout, i| self.vertex_strides[i] = vertex_layout.stride;
    for (layout.bind_group_layouts[0..layout.bind_group_count], 0..) |group, i| {
        self.bind_group_layouts[i] = group;
        self.bind_group_roots[i] = layout.bind_group_roots[i];
    }
    errdefer {
        self.state.deinit();
        self.root_signature.deinit();
        device.allocator.destroy(self);
    }

    const raw_device = device.device.unwrap();

    const input_elements = try makeInputElements(device.allocator, desc.vertex_buffers);
    defer device.allocator.free(input_elements);

    var state_desc: dx.D3D12_GRAPHICS_PIPELINE_STATE_DESC = std.mem.zeroes(dx.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
    state_desc.pRootSignature = self.root_signature.get();
    state_desc.VS = bytecode(vertex);
    if (fragment) |value| state_desc.PS = bytecode(value);
    state_desc.BlendState = defaultBlendState();
    for (desc.color_targets, 0..) |target, i| {
        state_desc.BlendState.RenderTarget[i] = blendTarget(target);
    }
    state_desc.BlendState.AlphaToCoverageEnable = @intFromBool(desc.multisample.alpha_to_coverage);
    state_desc.SampleMask = desc.multisample.mask;
    state_desc.RasterizerState = rasterState(desc.raster);
    state_desc.DepthStencilState = depthStencilState(desc.depth_stencil);
    state_desc.InputLayout = .{
        .pInputElementDescs = if (input_elements.len == 0) null else input_elements.ptr,
        .NumElements = @intCast(input_elements.len),
    };
    state_desc.PrimitiveTopologyType = toDxTopologyType(desc.topology);
    state_desc.NumRenderTargets = @intCast(desc.color_targets.len);
    for (desc.color_targets, 0..) |target, i| state_desc.RTVFormats[i] = resource.toDxFormat(target.format);
    state_desc.DSVFormat = if (desc.depth_stencil) |depth| resource.toDxFormat(depth.format) else dx.DXGI_FORMAT_UNKNOWN;
    state_desc.SampleDesc = .{ .Count = desc.multisample.count, .Quality = 0 };
    state_desc.Flags = dx.D3D12_PIPELINE_STATE_FLAG_NONE;

    const hr = raw_device.lpVtbl.*.CreateGraphicsPipelineState.?(
        raw_device,
        &state_desc,
        &dx.IID_ID3D12PipelineState,
        @ptrCast(self.state.put()),
    );
    if (hr < 0) device.debug_device.logMessages();
    try checkHr(hr);
    log.debug("created DX12 graphics pipeline vertex-buffers={} color-targets={} topology={s}", .{ desc.vertex_buffers.len, desc.color_targets.len, @tagName(desc.topology) });
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &graphics_vtable };
}

fn makeRootSignature(device: *Dx12Device, layouts: []const ?*binding.Dx12BindGroupLayout, roots: *[8]BindGroupRoots) !ComPtr(dx.ID3D12RootSignature) {
    var parameter_count: usize = 0;
    var range_count: usize = 0;
    for (layouts) |maybe| if (maybe) |layout| {
        if (layout.resource_count > 0) parameter_count += 1;
        if (layout.sampler_count > 0) parameter_count += 1;
        range_count += layout.entries.len;
    };
    const parameters = try device.allocator.alloc(dx.D3D12_ROOT_PARAMETER, parameter_count);
    defer device.allocator.free(parameters);
    const ranges = try device.allocator.alloc(dx.D3D12_DESCRIPTOR_RANGE, range_count);
    defer device.allocator.free(ranges);
    var parameter_index: usize = 0;
    var range_index: usize = 0;
    for (layouts, 0..) |maybe, group_index| {
        const layout = maybe.?;
        const resource_start = range_index;
        for (layout.entries) |entry| if (entry.kind != .sampler) {
            ranges[range_index] = descriptorRange(entry.kind, entry.binding, @intCast(group_index), entry.count);
            range_index += 1;
        };
        if (layout.resource_count > 0) {
            roots[group_index].resources = @intCast(parameter_index);
            parameters[parameter_index] = descriptorTableParameter(ranges[resource_start..range_index]);
            parameter_index += 1;
        }
        const sampler_start = range_index;
        for (layout.entries) |entry| if (entry.kind == .sampler) {
            ranges[range_index] = descriptorRange(entry.kind, entry.binding, @intCast(group_index), entry.count);
            range_index += 1;
        };
        if (layout.sampler_count > 0) {
            roots[group_index].samplers = @intCast(parameter_index);
            parameters[parameter_index] = descriptorTableParameter(ranges[sampler_start..range_index]);
            parameter_index += 1;
        }
    }
    var signature_blob: ComPtr(dx.ID3DBlob) = .{};
    defer signature_blob.deinit();
    var error_blob: ComPtr(dx.ID3DBlob) = .{};
    defer error_blob.deinit();
    const desc = dx.D3D12_ROOT_SIGNATURE_DESC{ .NumParameters = @intCast(parameters.len), .pParameters = if (parameters.len == 0) null else parameters.ptr, .NumStaticSamplers = 0, .pStaticSamplers = null, .Flags = dx.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT };
    try checkHr(dx.D3D12SerializeRootSignature(&desc, dx.D3D_ROOT_SIGNATURE_VERSION_1, signature_blob.put(), error_blob.put()));
    var result: ComPtr(dx.ID3D12RootSignature) = .{};
    const blob = signature_blob.unwrap();
    const raw = device.device.unwrap();
    try checkHr(raw.lpVtbl.*.CreateRootSignature.?(raw, 0, blob.lpVtbl.*.GetBufferPointer.?(blob), blob.lpVtbl.*.GetBufferSize.?(blob), &dx.IID_ID3D12RootSignature, @ptrCast(result.put())));
    return result;
}

fn descriptorRange(kind: @import("../../interface/binding.zig").BindingType, binding_number: u32, space: u32, count: u32) dx.D3D12_DESCRIPTOR_RANGE {
    return .{
        .RangeType = switch (kind) {
            .buffer => |value| switch (value.kind) {
                .uniform => dx.D3D12_DESCRIPTOR_RANGE_TYPE_CBV,
                .storage_read => dx.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
                .storage_read_write => dx.D3D12_DESCRIPTOR_RANGE_TYPE_UAV,
            },
            .sampled_texture => dx.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
            .storage_texture => dx.D3D12_DESCRIPTOR_RANGE_TYPE_UAV,
            .sampler => dx.D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,
        },
        .NumDescriptors = count,
        .BaseShaderRegister = binding_number,
        .RegisterSpace = space,
        .OffsetInDescriptorsFromTableStart = dx.D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND,
    };
}

fn descriptorTableParameter(ranges: []const dx.D3D12_DESCRIPTOR_RANGE) dx.D3D12_ROOT_PARAMETER {
    return .{
        .ParameterType = dx.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
        .unnamed_0 = .{ .DescriptorTable = .{
            .NumDescriptorRanges = @intCast(ranges.len),
            .pDescriptorRanges = ranges.ptr,
        } },
        .ShaderVisibility = dx.D3D12_SHADER_VISIBILITY_ALL,
    };
}

pub fn destroyGraphics(value: pipeline.GraphicsPipeline) void {
    const self = Dx12GraphicsPipeline.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.state.deinit();
    self.root_signature.deinit();
    log.debug("destroyed DX12 graphics pipeline", .{});
    allocator.destroy(self);
}

pub fn createCompute(ptr: *anyopaque, desc: pipeline.ComputePipelineDescriptor) anyerror!pipeline.ComputePipeline {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const layout = try Dx12PipelineLayout.fromHandle(desc.layout);
    const compute = try shader.Dx12Shader.fromHandle(desc.compute);
    if (compute.stage != .compute) return error.InvalidShaderStage;
    const self = try device.allocator.create(Dx12ComputePipeline);
    self.* = .{ .allocator = device.allocator, .layout = layout };
    errdefer device.allocator.destroy(self);
    const raw = device.device.unwrap();
    const state_desc = dx.D3D12_COMPUTE_PIPELINE_STATE_DESC{ .pRootSignature = layout.root_signature.unwrap(), .CS = bytecode(compute), .NodeMask = 0, .CachedPSO = .{ .pCachedBlob = null, .CachedBlobSizeInBytes = 0 }, .Flags = dx.D3D12_PIPELINE_STATE_FLAG_NONE };
    try checkHr(raw.lpVtbl.*.CreateComputePipelineState.?(raw, &state_desc, &dx.IID_ID3D12PipelineState, @ptrCast(self.state.put())));
    log.debug("created DX12 compute pipeline", .{});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &compute_vtable };
}

pub fn destroyCompute(value: pipeline.ComputePipeline) void {
    const self = Dx12ComputePipeline.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.state.deinit();
    log.debug("destroyed DX12 compute pipeline", .{});
    allocator.destroy(self);
}

fn bytecode(value: *shader.Dx12Shader) dx.D3D12_SHADER_BYTECODE {
    return .{ .pShaderBytecode = value.bytecode.ptr, .BytecodeLength = value.bytecode.len };
}

fn makeInputElements(allocator: std.mem.Allocator, layouts: []const pipeline.VertexBufferLayout) ![]dx.D3D12_INPUT_ELEMENT_DESC {
    var count: usize = 0;
    for (layouts) |layout| count += layout.attributes.len;
    const result = try allocator.alloc(dx.D3D12_INPUT_ELEMENT_DESC, count);
    var index: usize = 0;
    for (layouts, 0..) |layout, slot| for (layout.attributes) |attribute| {
        result[index] = .{
            .SemanticName = "TEXCOORD",
            .SemanticIndex = attribute.location,
            .Format = vertexFormat(attribute.format),
            .InputSlot = @intCast(slot),
            .AlignedByteOffset = attribute.offset,
            .InputSlotClass = if (layout.step_mode == .instance) dx.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA else dx.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
            .InstanceDataStepRate = if (layout.step_mode == .instance) 1 else 0,
        };
        index += 1;
    };
    return result;
}

fn vertexFormat(format: pipeline.VertexFormat) dx.DXGI_FORMAT {
    return switch (format) {
        .uint8x2 => dx.DXGI_FORMAT_R8G8_UINT,
        .uint8x4 => dx.DXGI_FORMAT_R8G8B8A8_UINT,
        .sint8x2 => dx.DXGI_FORMAT_R8G8_SINT,
        .sint8x4 => dx.DXGI_FORMAT_R8G8B8A8_SINT,
        .unorm8x2 => dx.DXGI_FORMAT_R8G8_UNORM,
        .unorm8x4 => dx.DXGI_FORMAT_R8G8B8A8_UNORM,
        .snorm8x2 => dx.DXGI_FORMAT_R8G8_SNORM,
        .snorm8x4 => dx.DXGI_FORMAT_R8G8B8A8_SNORM,
        .uint16x2 => dx.DXGI_FORMAT_R16G16_UINT,
        .uint16x4 => dx.DXGI_FORMAT_R16G16B16A16_UINT,
        .sint16x2 => dx.DXGI_FORMAT_R16G16_SINT,
        .sint16x4 => dx.DXGI_FORMAT_R16G16B16A16_SINT,
        .unorm16x2 => dx.DXGI_FORMAT_R16G16_UNORM,
        .unorm16x4 => dx.DXGI_FORMAT_R16G16B16A16_UNORM,
        .snorm16x2 => dx.DXGI_FORMAT_R16G16_SNORM,
        .snorm16x4 => dx.DXGI_FORMAT_R16G16B16A16_SNORM,
        .float16x2 => dx.DXGI_FORMAT_R16G16_FLOAT,
        .float16x4 => dx.DXGI_FORMAT_R16G16B16A16_FLOAT,
        .float32 => dx.DXGI_FORMAT_R32_FLOAT,
        .float32x2 => dx.DXGI_FORMAT_R32G32_FLOAT,
        .float32x3 => dx.DXGI_FORMAT_R32G32B32_FLOAT,
        .float32x4 => dx.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .uint32 => dx.DXGI_FORMAT_R32_UINT,
        .uint32x2 => dx.DXGI_FORMAT_R32G32_UINT,
        .uint32x3 => dx.DXGI_FORMAT_R32G32B32_UINT,
        .uint32x4 => dx.DXGI_FORMAT_R32G32B32A32_UINT,
        .sint32 => dx.DXGI_FORMAT_R32_SINT,
        .sint32x2 => dx.DXGI_FORMAT_R32G32_SINT,
        .sint32x3 => dx.DXGI_FORMAT_R32G32B32_SINT,
        .sint32x4 => dx.DXGI_FORMAT_R32G32B32A32_SINT,
    };
}

fn defaultBlendState() dx.D3D12_BLEND_DESC {
    var result: dx.D3D12_BLEND_DESC = std.mem.zeroes(dx.D3D12_BLEND_DESC);
    for (&result.RenderTarget) |*target| target.* = .{
        .BlendEnable = 0,
        .LogicOpEnable = 0,
        .SrcBlend = dx.D3D12_BLEND_ONE,
        .DestBlend = dx.D3D12_BLEND_ZERO,
        .BlendOp = dx.D3D12_BLEND_OP_ADD,
        .SrcBlendAlpha = dx.D3D12_BLEND_ONE,
        .DestBlendAlpha = dx.D3D12_BLEND_ZERO,
        .BlendOpAlpha = dx.D3D12_BLEND_OP_ADD,
        .LogicOp = dx.D3D12_LOGIC_OP_NOOP,
        .RenderTargetWriteMask = dx.D3D12_COLOR_WRITE_ENABLE_ALL,
    };
    return result;
}

fn blendTarget(target: pipeline.ColorTargetState) dx.D3D12_RENDER_TARGET_BLEND_DESC {
    var result = defaultBlendState().RenderTarget[0];
    result.RenderTargetWriteMask = @bitCast(target.write_mask);
    if (target.blend) |blend| {
        result.BlendEnable = 1;
        result.SrcBlend = blendFactor(blend.color.source);
        result.DestBlend = blendFactor(blend.color.destination);
        result.BlendOp = blendOp(blend.color.operation);
        result.SrcBlendAlpha = blendFactor(blend.alpha.source);
        result.DestBlendAlpha = blendFactor(blend.alpha.destination);
        result.BlendOpAlpha = blendOp(blend.alpha.operation);
    }
    return result;
}
fn blendFactor(value: pipeline.BlendFactor) dx.D3D12_BLEND {
    return switch (value) {
        .zero => dx.D3D12_BLEND_ZERO,
        .one => dx.D3D12_BLEND_ONE,
        .src => dx.D3D12_BLEND_SRC_COLOR,
        .one_minus_src => dx.D3D12_BLEND_INV_SRC_COLOR,
        .src_alpha => dx.D3D12_BLEND_SRC_ALPHA,
        .one_minus_src_alpha => dx.D3D12_BLEND_INV_SRC_ALPHA,
        .dst => dx.D3D12_BLEND_DEST_COLOR,
        .one_minus_dst => dx.D3D12_BLEND_INV_DEST_COLOR,
        .dst_alpha => dx.D3D12_BLEND_DEST_ALPHA,
        .one_minus_dst_alpha => dx.D3D12_BLEND_INV_DEST_ALPHA,
        .src_alpha_saturated => dx.D3D12_BLEND_SRC_ALPHA_SAT,
        .constant => dx.D3D12_BLEND_BLEND_FACTOR,
        .one_minus_constant => dx.D3D12_BLEND_INV_BLEND_FACTOR,
    };
}
fn blendOp(value: pipeline.BlendOp) dx.D3D12_BLEND_OP {
    return switch (value) {
        .add => dx.D3D12_BLEND_OP_ADD,
        .subtract => dx.D3D12_BLEND_OP_SUBTRACT,
        .reverse_subtract => dx.D3D12_BLEND_OP_REV_SUBTRACT,
        .min => dx.D3D12_BLEND_OP_MIN,
        .max => dx.D3D12_BLEND_OP_MAX,
    };
}

fn rasterState(value: pipeline.RasterState) dx.D3D12_RASTERIZER_DESC {
    return .{
        .FillMode = switch (value.polygon_mode) {
            .fill => dx.D3D12_FILL_MODE_SOLID,
            .line => dx.D3D12_FILL_MODE_WIREFRAME,
            .point => dx.D3D12_FILL_MODE_SOLID,
        },
        .CullMode = switch (value.cull_mode) {
            .none => dx.D3D12_CULL_MODE_NONE,
            .front => dx.D3D12_CULL_MODE_FRONT,
            .back => dx.D3D12_CULL_MODE_BACK,
        },
        .FrontCounterClockwise = @intFromBool(value.front_face == .counter_clockwise),
        .DepthBias = value.depth_bias,
        .DepthBiasClamp = value.depth_bias_clamp,
        .SlopeScaledDepthBias = value.depth_bias_slope,
        .DepthClipEnable = @intFromBool(value.depth_clip),
        .MultisampleEnable = 1,
        .AntialiasedLineEnable = 0,
        .ForcedSampleCount = 0,
        .ConservativeRaster = dx.D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF,
    };
}

fn depthStencilState(value: ?pipeline.DepthStencilState) dx.D3D12_DEPTH_STENCIL_DESC {
    const enabled = value != null;
    const depth_write = if (value) |depth| depth.depth_write else false;
    const depth_compare = if (value) |depth| depth.depth_compare else .always;
    const default_face = stencilFace(.{});
    return .{
        .DepthEnable = @intFromBool(enabled),
        .DepthWriteMask = if (depth_write) dx.D3D12_DEPTH_WRITE_MASK_ALL else dx.D3D12_DEPTH_WRITE_MASK_ZERO,
        .DepthFunc = compareOp(depth_compare),
        .StencilEnable = @intFromBool(enabled and (value.?.stencil_read_mask != 0 or value.?.stencil_write_mask != 0)),
        .StencilReadMask = if (value) |v| v.stencil_read_mask else 0,
        .StencilWriteMask = if (value) |v| v.stencil_write_mask else 0,
        .FrontFace = if (value) |v| stencilFace(v.stencil_front) else default_face,
        .BackFace = if (value) |v| stencilFace(v.stencil_back) else default_face,
    };
}

fn stencilFace(value: pipeline.StencilFaceState) dx.D3D12_DEPTH_STENCILOP_DESC {
    return .{ .StencilFailOp = stencilOp(value.fail), .StencilDepthFailOp = stencilOp(value.depth_fail), .StencilPassOp = stencilOp(value.pass), .StencilFunc = compareOp(value.compare) };
}
fn stencilOp(value: pipeline.StencilOp) dx.D3D12_STENCIL_OP {
    return switch (value) {
        .keep => dx.D3D12_STENCIL_OP_KEEP,
        .zero => dx.D3D12_STENCIL_OP_ZERO,
        .replace => dx.D3D12_STENCIL_OP_REPLACE,
        .invert => dx.D3D12_STENCIL_OP_INVERT,
        .increment_clamp => dx.D3D12_STENCIL_OP_INCR_SAT,
        .decrement_clamp => dx.D3D12_STENCIL_OP_DECR_SAT,
        .increment_wrap => dx.D3D12_STENCIL_OP_INCR,
        .decrement_wrap => dx.D3D12_STENCIL_OP_DECR,
    };
}
fn compareOp(value: @import("../../interface/resource.zig").CompareOp) dx.D3D12_COMPARISON_FUNC {
    return switch (value) {
        .never => dx.D3D12_COMPARISON_FUNC_NEVER,
        .less => dx.D3D12_COMPARISON_FUNC_LESS,
        .equal => dx.D3D12_COMPARISON_FUNC_EQUAL,
        .less_equal => dx.D3D12_COMPARISON_FUNC_LESS_EQUAL,
        .greater => dx.D3D12_COMPARISON_FUNC_GREATER,
        .not_equal => dx.D3D12_COMPARISON_FUNC_NOT_EQUAL,
        .greater_equal => dx.D3D12_COMPARISON_FUNC_GREATER_EQUAL,
        .always => dx.D3D12_COMPARISON_FUNC_ALWAYS,
    };
}

fn toDxTopology(value: pipeline.PrimitiveTopology) dx.D3D12_PRIMITIVE_TOPOLOGY {
    return switch (value) {
        .point_list => dx.D3D_PRIMITIVE_TOPOLOGY_POINTLIST,
        .line_list => dx.D3D_PRIMITIVE_TOPOLOGY_LINELIST,
        .line_strip => dx.D3D_PRIMITIVE_TOPOLOGY_LINESTRIP,
        .triangle_list => dx.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
        .triangle_strip => dx.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
    };
}

fn toDxTopologyType(value: pipeline.PrimitiveTopology) dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE {
    return switch (value) {
        .point_list => dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT,
        .line_list, .line_strip => dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE,
        .triangle_list, .triangle_strip => dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
    };
}

test "pipeline topology mappings cover the public primitive modes" {
    try std.testing.expectEqual(@as(dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE, dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT), toDxTopologyType(.point_list));
    try std.testing.expectEqual(@as(dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE, dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE), toDxTopologyType(.line_strip));
    try std.testing.expectEqual(@as(dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE, dx.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE), toDxTopologyType(.triangle_list));
}

test "disabled depth stencil state still uses valid D3D12 enum values" {
    const state = depthStencilState(null);
    try std.testing.expectEqual(@as(dx.D3D12_STENCIL_OP, dx.D3D12_STENCIL_OP_KEEP), state.FrontFace.StencilFailOp);
    try std.testing.expectEqual(@as(dx.D3D12_COMPARISON_FUNC, dx.D3D12_COMPARISON_FUNC_ALWAYS), state.FrontFace.StencilFunc);
}
