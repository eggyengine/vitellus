//! Immutable graphics-pipeline and vertex-input descriptions.
//!
//! Coordinates follow D3D/Metal on every backend: clip-space X/Y span
//! `[-w, w]`, clip-space Z spans `[0, w]`, framebuffer origin is top-left,
//! and normalized texture coordinates use `(0, 0)` for the top-left texel.

const shader = @import("shader.zig");
const resource = @import("resource.zig");
const binding = @import("binding.zig");

/// Primitive assembly mode used by draw commands.
pub const PrimitiveTopology = enum { point_list, line_list, line_strip, triangle_list, triangle_strip };
/// Winding order considered front-facing.
pub const FrontFace = enum { clockwise, counter_clockwise };
/// Triangle faces removed before rasterisation.
pub const CullMode = enum { none, front, back };
/// Rasterised polygon representation.
pub const PolygonMode = enum { fill, line, point };
/// Scalar or packed value read from a vertex buffer.
pub const VertexFormat = enum {
    uint8x2,
    uint8x4,
    sint8x2,
    sint8x4,
    unorm8x2,
    unorm8x4,
    snorm8x2,
    snorm8x4,
    uint16x2,
    uint16x4,
    sint16x2,
    sint16x4,
    unorm16x2,
    unorm16x4,
    snorm16x2,
    snorm16x4,
    float16x2,
    float16x4,
    float32,
    float32x2,
    float32x3,
    float32x4,
    uint32,
    uint32x2,
    uint32x3,
    uint32x4,
    sint32,
    sint32x2,
    sint32x3,
    sint32x4,
};
/// Whether a vertex-buffer element advances per vertex or per instance.
pub const VertexStepMode = enum { vertex, instance };
/// One shader input read from a vertex-buffer layout.
pub const VertexAttribute = struct { location: u32, format: VertexFormat, offset: u32 };
/// Byte layout and attributes for one vertex-buffer slot.
pub const VertexBufferLayout = struct { stride: u32, step_mode: VertexStepMode = .vertex, attributes: []const VertexAttribute };
/// Fixed-function rasterisation state.
pub const RasterState = struct {
    front_face: FrontFace = .counter_clockwise,
    cull_mode: CullMode = .back,
    polygon_mode: PolygonMode = .fill,
    depth_clip: bool = true,
    depth_bias: i32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope: f32 = 0,
};
pub const BlendFactor = enum { zero, one, src, one_minus_src, src_alpha, one_minus_src_alpha, dst, one_minus_dst, dst_alpha, one_minus_dst_alpha, src_alpha_saturated, constant, one_minus_constant };
pub const BlendOp = enum { add, subtract, reverse_subtract, min, max };
pub const BlendComponent = struct { operation: BlendOp = .add, source: BlendFactor = .one, destination: BlendFactor = .zero };
pub const BlendState = struct { color: BlendComponent = .{}, alpha: BlendComponent = .{} };
pub const ColorWriteMask = packed struct(u8) { red: bool = true, green: bool = true, blue: bool = true, alpha: bool = true, _pad: u4 = 0 };
/// Format and channel write mask for one colour attachment.
pub const ColorTargetState = struct { format: resource.Format, blend: ?BlendState = null, write_mask: ColorWriteMask = .{} };
pub const StencilOp = enum { keep, zero, replace, invert, increment_clamp, decrement_clamp, increment_wrap, decrement_wrap };
pub const StencilFaceState = struct { compare: resource.CompareOp = .always, fail: StencilOp = .keep, depth_fail: StencilOp = .keep, pass: StencilOp = .keep };
/// Depth attachment format, writes, and comparison behaviour.
pub const DepthStencilState = struct {
    format: resource.Format,
    depth_write: bool = true,
    depth_compare: resource.CompareOp = .less,
    stencil_front: StencilFaceState = .{},
    stencil_back: StencilFaceState = .{},
    stencil_read_mask: u8 = 0xff,
    stencil_write_mask: u8 = 0xff,
};
pub const MultisampleState = struct { count: u32 = 1, mask: u32 = 0xffff_ffff, alpha_to_coverage: bool = false };
pub const PipelineLayoutDescriptor = struct { label: ?[]const u8 = null, bind_group_layouts: []const binding.BindGroupLayout = &.{} };
pub const PipelineLayout = struct {
    handle: u64 = 0,
    vtable: *const VTable,
    pub const VTable = struct { deinitFn: *const fn (PipelineLayout) void };

    /// Combine bind-group layouts, slot by slot in order, into the layout pipelines are made
    /// with. The bind-group layouts must outlive it.
    pub fn init(device: anytype, desc: PipelineLayoutDescriptor) !PipelineLayout {
        return if (device.vtable.createPipelineLayoutFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
    /// Destroy the layout, after every pipeline made with it.
    pub fn deinit(self: PipelineLayout) void {
        self.vtable.deinitFn(self);
    }
};
/// Complete immutable state used to create a graphics pipeline.
///
/// All slices are borrowed only for the duration of pipeline creation.
pub const GraphicsPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    vertex: shader.Shader,
    fragment: ?shader.Shader = null,
    vertex_buffers: []const VertexBufferLayout = &.{},
    topology: PrimitiveTopology = .triangle_list,
    raster: RasterState = .{},
    color_targets: []const ColorTargetState,
    depth_stencil: ?DepthStencilState = null,
    multisample: MultisampleState = .{},
    layout: PipelineLayout,
};
/// Opaque backend graphics-pipeline handle.
pub const GraphicsPipeline = struct {
    handle: u64 = 0,
    vtable: *const VTable,
    pub const VTable = struct { deinitFn: *const fn (GraphicsPipeline) void };

    /// Compile a graphics pipeline: shaders, vertex layout, raster, depth and blend state, and
    /// the attachment formats it draws to. Slow: make pipelines up front, not per frame, and
    /// pass `DeviceDescriptor.pipeline_cache` to skip compiling them again next run.
    pub fn init(device: anytype, desc: GraphicsPipelineDescriptor) !GraphicsPipeline {
        return if (device.vtable.createGraphicsPipelineFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
    /// Destroy the pipeline once no submitted work uses it.
    pub fn deinit(self: GraphicsPipeline) void {
        self.vtable.deinitFn(self);
    }
};
pub const ComputePipelineDescriptor = struct { label: ?[]const u8 = null, compute: shader.Shader, layout: PipelineLayout };
pub const ComputePipeline = struct {
    handle: u64 = 0,
    vtable: *const VTable,
    pub const VTable = struct { deinitFn: *const fn (ComputePipeline) void };

    /// Compile a compute pipeline from a compute shader and the layout of its bindings.
    pub fn init(device: anytype, desc: ComputePipelineDescriptor) !ComputePipeline {
        return if (device.vtable.createComputePipelineFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
    /// Destroy the pipeline once no submitted work uses it.
    pub fn deinit(self: ComputePipeline) void {
        self.vtable.deinitFn(self);
    }
};

const std = @import("std");
// Doc tests below: Zig's generated docs show each one as its type's example, and
// `zig build test` runs it, on the machine's GPU when it has one.
const vit = @import("../root.zig");
const ExampleGpu = @import("example_gpu.zig");

test PipelineLayout {
    const gpu = try ExampleGpu.open(.{});
    defer gpu.close();

    // Every bind group a pipeline's shaders read, in set order: here one, at set 0.
    const material = try vit.BindGroupLayout.init(gpu.device, .{ .entries = &.{
        .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true } },
    } });
    defer material.deinit();
    const layout = try vit.PipelineLayout.init(gpu.device, .{ .bind_group_layouts = &.{material} });
    defer layout.deinit();
}

test GraphicsPipeline {
    // Compiled, not run: the shaders come from your shader compiler (see `vit.Shader`).
    _ = &struct {
        fn example(device: vit.Device, vertex: vit.Shader, fragment: vit.Shader, layout: vit.PipelineLayout) !vit.GraphicsPipeline {
            // Two floats of position per vertex at location 0, alpha-blended into an
            // sRGB target. Everything here is fixed once made; make one pipeline per variant.
            return vit.GraphicsPipeline.init(device, .{
                .vertex = vertex,
                .fragment = fragment,
                .layout = layout,
                .vertex_buffers = &.{.{ .stride = 2 * @sizeOf(f32), .attributes = &.{.{ .location = 0, .format = .float32x2, .offset = 0 }} }},
                .raster = .{ .cull_mode = .none },
                .color_targets = &.{.{
                    .format = .bgra8_unorm_srgb,
                    .blend = .{ .color = .{ .source = .src_alpha, .destination = .one_minus_src_alpha } },
                }},
            });
        }
    }.example;
}

test ComputePipeline {
    // Compiled, not run: the shader comes from your shader compiler (see `vit.Shader`).
    _ = &struct {
        fn example(device: vit.Device, cmd: vit.CommandBuffer, compute: vit.Shader, layout: vit.PipelineLayout, group: vit.BindGroup, count: u32) !vit.ComputePipeline {
            const pipeline = try vit.ComputePipeline.init(device, .{ .compute = compute, .layout = layout });
            errdefer pipeline.deinit();

            // One workgroup per 64 elements, for a shader declared `[numthreads(64, 1, 1)]`.
            // Keep the pipeline until the GPU has run the commands.
            try cmd.beginComputePass("scale");
            cmd.setComputePipeline(pipeline);
            cmd.setBindGroup(0, group, &.{});
            cmd.dispatch((count + 63) / 64, 1, 1);
            cmd.endComputePass();
            return pipeline;
        }
    }.example;
}
