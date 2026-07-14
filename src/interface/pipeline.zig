const shader = @import("shader.zig");
const resource = @import("resource.zig");

pub const PrimitiveTopology = enum { point_list, line_list, line_strip, triangle_list, triangle_strip };
pub const FrontFace = enum { clockwise, counter_clockwise };
pub const CullMode = enum { none, front, back };
pub const PolygonMode = enum { fill, line, point };
pub const VertexFormat = enum { float, float2, float3, float4, uint, uint2, uint3, uint4, unorm8x4 };
pub const VertexStepMode = enum { vertex, instance };
pub const VertexAttribute = struct { location: u32, format: VertexFormat, offset: u32 };
pub const VertexBufferLayout = struct { stride: u32, step_mode: VertexStepMode = .vertex, attributes: []const VertexAttribute };
pub const RasterState = struct { front_face: FrontFace = .counter_clockwise, cull_mode: CullMode = .back, polygon_mode: PolygonMode = .fill };
pub const ColorTargetState = struct { format: resource.Format, write_mask: u8 = 0xf };
pub const DepthStencilState = struct { format: resource.Format, depth_write: bool = true, depth_compare: CompareOp = .less };
pub const CompareOp = enum { never, less, equal, less_equal, greater, not_equal, greater_equal, always };
pub const GraphicsPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    vertex: shader.Shader,
    fragment: ?shader.Shader = null,
    vertex_buffers: []const VertexBufferLayout = &.{},
    topology: PrimitiveTopology = .triangle_list,
    raster: RasterState = .{},
    color_targets: []const ColorTargetState,
    depth_stencil: ?DepthStencilState = null,
};
pub const GraphicsPipeline = struct { handle: u64 = 0 };

