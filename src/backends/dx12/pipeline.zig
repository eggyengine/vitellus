//! DirectX 12 graphics pipeline creation.

const std = @import("std");
const pipeline = @import("../../interface/pipeline.zig");
const shader = @import("shader.zig");
const resource = @import("resource.zig");
const Dx12Device = @import("device.zig").Dx12Device;
const dx = @import("dx.zig").c;
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

pub const Dx12GraphicsPipeline = struct {
    allocator: std.mem.Allocator,
    root_signature: ComPtr(dx.ID3D12RootSignature) = .{},
    state: ComPtr(dx.ID3D12PipelineState) = .{},
    topology: dx.D3D12_PRIMITIVE_TOPOLOGY,
    vertex_strides: [32]u32 = [_]u32{0} ** 32,
    vertex_buffer_count: usize = 0,

    pub fn fromHandle(value: pipeline.GraphicsPipeline) !*Dx12GraphicsPipeline {
        if (value.handle == 0) return error.InvalidPipeline;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub fn createGraphics(ptr: *anyopaque, desc: pipeline.GraphicsPipelineDescriptor) anyerror!pipeline.GraphicsPipeline {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
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
    };
    for (desc.vertex_buffers, 0..) |layout, i| self.vertex_strides[i] = layout.stride;
    errdefer {
        self.state.deinit();
        self.root_signature.deinit();
        device.allocator.destroy(self);
    }

    var signature_blob: ComPtr(dx.ID3DBlob) = .{};
    defer signature_blob.deinit();
    var error_blob: ComPtr(dx.ID3DBlob) = .{};
    defer error_blob.deinit();
    const signature_desc = dx.D3D12_ROOT_SIGNATURE_DESC{
        .NumParameters = 0,
        .pParameters = null,
        .NumStaticSamplers = 0,
        .pStaticSamplers = null,
        .Flags = dx.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
    };
    try checkHr(dx.D3D12SerializeRootSignature(
        &signature_desc,
        dx.D3D_ROOT_SIGNATURE_VERSION_1,
        signature_blob.put(),
        error_blob.put(),
    ));

    const raw_device = device.device.unwrap();
    const blob = signature_blob.unwrap();
    try checkHr(raw_device.lpVtbl.*.CreateRootSignature.?(
        raw_device,
        0,
        blob.lpVtbl.*.GetBufferPointer.?(blob),
        blob.lpVtbl.*.GetBufferSize.?(blob),
        &dx.IID_ID3D12RootSignature,
        @ptrCast(self.root_signature.put()),
    ));

    const input_elements = try makeInputElements(device.allocator, desc.vertex_buffers);
    defer device.allocator.free(input_elements);

    var state_desc: dx.D3D12_GRAPHICS_PIPELINE_STATE_DESC = std.mem.zeroes(dx.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
    state_desc.pRootSignature = self.root_signature.get();
    state_desc.VS = bytecode(vertex);
    if (fragment) |value| state_desc.PS = bytecode(value);
    state_desc.BlendState = defaultBlendState();
    for (desc.color_targets, 0..) |target, i| state_desc.BlendState.RenderTarget[i].RenderTargetWriteMask = target.write_mask;
    state_desc.SampleMask = std.math.maxInt(dx.UINT);
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
    state_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    state_desc.Flags = dx.D3D12_PIPELINE_STATE_FLAG_NONE;

    try checkHr(raw_device.lpVtbl.*.CreateGraphicsPipelineState.?(
        raw_device,
        &state_desc,
        &dx.IID_ID3D12PipelineState,
        @ptrCast(self.state.put()),
    ));
    return .{ .handle = @intCast(@intFromPtr(self)) };
}

pub fn destroyGraphics(_: *anyopaque, value: pipeline.GraphicsPipeline) void {
    const self = Dx12GraphicsPipeline.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.state.deinit();
    self.root_signature.deinit();
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
        .float => dx.DXGI_FORMAT_R32_FLOAT,
        .float2 => dx.DXGI_FORMAT_R32G32_FLOAT,
        .float3 => dx.DXGI_FORMAT_R32G32B32_FLOAT,
        .float4 => dx.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .uint => dx.DXGI_FORMAT_R32_UINT,
        .uint2 => dx.DXGI_FORMAT_R32G32_UINT,
        .uint3 => dx.DXGI_FORMAT_R32G32B32_UINT,
        .uint4 => dx.DXGI_FORMAT_R32G32B32A32_UINT,
        .unorm8x4 => dx.DXGI_FORMAT_R8G8B8A8_UNORM,
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
        .DepthBias = dx.D3D12_DEFAULT_DEPTH_BIAS,
        .DepthBiasClamp = dx.D3D12_DEFAULT_DEPTH_BIAS_CLAMP,
        .SlopeScaledDepthBias = dx.D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS,
        .DepthClipEnable = 1,
        .MultisampleEnable = 0,
        .AntialiasedLineEnable = 0,
        .ForcedSampleCount = 0,
        .ConservativeRaster = dx.D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF,
    };
}

fn depthStencilState(value: ?pipeline.DepthStencilState) dx.D3D12_DEPTH_STENCIL_DESC {
    const enabled = value != null;
    const depth_write = if (value) |depth| depth.depth_write else false;
    const depth_compare = if (value) |depth| depth.depth_compare else .always;
    return .{
        .DepthEnable = @intFromBool(enabled),
        .DepthWriteMask = if (depth_write) dx.D3D12_DEPTH_WRITE_MASK_ALL else dx.D3D12_DEPTH_WRITE_MASK_ZERO,
        .DepthFunc = compareOp(depth_compare),
        .StencilEnable = 0,
        .StencilReadMask = dx.D3D12_DEFAULT_STENCIL_READ_MASK,
        .StencilWriteMask = dx.D3D12_DEFAULT_STENCIL_WRITE_MASK,
        .FrontFace = std.mem.zeroes(dx.D3D12_DEPTH_STENCILOP_DESC),
        .BackFace = std.mem.zeroes(dx.D3D12_DEPTH_STENCILOP_DESC),
    };
}

fn compareOp(value: pipeline.CompareOp) dx.D3D12_COMPARISON_FUNC {
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
