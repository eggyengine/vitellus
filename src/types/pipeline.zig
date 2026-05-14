const bind_group = @import("bind_group.zig");
const def = @import("def.zig");
const hal = @import("../backends/hal.zig");
const shader = @import("shader.zig");
const sampler = @import("sampler.zig");
const texture = @import("texture.zig");

pub const PipelineLayout = struct {
    label: ?[*:0]const u8,
    bindGroupLayouts: []const ?*const bind_group.BindGroupLayout,
    backend: ?hal.PipelineLayout = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        bindGroupLayouts: []const ?*const bind_group.BindGroupLayout,
    };

    pub fn init(descriptor: Descriptor) PipelineLayout {
        return .{
            .label = descriptor.label,
            .bindGroupLayouts = descriptor.bindGroupLayouts,
        };
    }

    pub fn destroy(self: *@This()) void {
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }
};

pub const AutoLayoutMode = enum {
    auto,
};

pub const DescriptorLayout = union(enum) {
    pipeline: *const PipelineLayout,
    auto: AutoLayoutMode,
};

pub const DescriptorBase = struct {
    label: ?[*:0]const u8 = null,
    layout: DescriptorLayout,
};

pub const PipelineError = struct {
    message: []const u8 = "",
    reason: Reason,

    pub const Reason = enum {
        validation,
        internal,
    };

    pub const Error = error{
        Validation,
        Internal,
    };

    pub fn reasonFromError(err: Error) Reason {
        return switch (err) {
            error.Validation => .validation,
            error.Internal => .internal,
        };
    }
};

pub const ComputePipeline = struct {
    valid: bool = true,
    backend: ?hal.ComputePipeline = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        layout: DescriptorLayout,
        compute: ProgrammableStage,
    };

    pub fn getBindGroupLayout(self: *@This(), index: u32) bind_group.BindGroupLayout {
        _ = self;
        _ = index;
        return .{
            .label = null,
            .entryMap = &.{},
            .dynamicOffsetCount = 0,
            .exclusivePipeline = null,
        };
    }

    pub fn destroy(self: *@This()) void {
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
        self.valid = false;
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }
};

pub const RenderPipeline = struct {
    valid: bool = true,
    backend: ?hal.RenderPipeline = null,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        layout: DescriptorLayout,
        vertex: VertexState,
        primitive: PrimitiveState = .{},
        depthStencil: ?DepthStencilState = null,
        multisample: MultisampleState = .{},
        fragment: ?FragmentState = null,
    };

    pub fn getBindGroupLayout(self: *@This(), index: u32) bind_group.BindGroupLayout {
        _ = self;
        _ = index;
        return .{
            .label = null,
            .entryMap = &.{},
            .dynamicOffsetCount = 0,
            .exclusivePipeline = null,
        };
    }

    pub fn destroy(self: *@This()) void {
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
        self.valid = false;
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }
};

pub const PipelineConstantValue = f64;

pub const ProgrammableStage = struct {
    module: shader.ShaderModule,
    entry_point: ?[]const u8 = null,
    constants: []const Constant = &.{},

    pub const Constant = struct {
        key: []const u8,
        value: PipelineConstantValue,
    };
};

pub const PrimitiveState = struct {
    topology: PrimitiveTopology = .triangle_list,
    stripIndexFormat: ?IndexFormat = null,
    frontFace: FrontFace = .ccw,
    cullMode: CullMode = .none,
    unclippedDepth: bool = false,
};

pub const PrimitiveTopology = enum {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
};

pub const FrontFace = enum {
    ccw,
    cw,
};

pub const CullMode = enum {
    none,
    front,
    back,
};

pub const MultisampleState = struct {
    count: def.Size32 = 1,
    mask: def.SampleMask = 0xFFFFFFFF,
    alphaToCoverageEnabled: bool = false,
};

pub const FragmentState = struct {
    module: shader.ShaderModule,
    entry_point: ?[]const u8 = null,
    constants: []const ProgrammableStage.Constant = &.{},
    targets: []const ?ColorTargetState,
};

pub const ColorTargetState = struct {
    format: texture.Texture.Format,
    blend: ?BlendState = null,
    writeMask: ColorWriteFlags = ColorWrite.ALL,
};

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

pub const BlendComponent = struct {
    operation: BlendOperation = .add,
    srcFactor: BlendFactor = .one,
    dstFactor: BlendFactor = .zero,
};

pub const BlendFactor = enum {
    zero,
    one,
    src,
    one_minus_src,
    src_alpha,
    one_minus_src_alpha,
    dst,
    one_minus_dst,
    dst_alpha,
    one_minus_dst_alpha,
    src_alpha_saturated,
    constant,
    one_minus_constant,
    src1,
    one_minus_src1,
    src1_alpha,
    one_minus_src1_alpha,
};

pub const BlendOperation = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

pub const ColorWriteFlags = def.ColorWriteFlags;

pub const ColorWrite = packed struct(u32) {
    red: bool = false,
    green: bool = false,
    blue: bool = false,
    alpha: bool = false,

    _: u28 = 0,

    pub const RED: def.FlagsConstant = 0x1;
    pub const GREEN: def.FlagsConstant = 0x2;
    pub const BLUE: def.FlagsConstant = 0x4;
    pub const ALPHA: def.FlagsConstant = 0x8;
    pub const ALL: def.FlagsConstant = 0xF;

    pub fn fromFlags(flags: ColorWriteFlags) ColorWrite {
        return @bitCast(flags);
    }

    pub fn toFlags(self: ColorWrite) ColorWriteFlags {
        return @bitCast(self);
    }
};

pub const DepthStencilState = struct {
    format: texture.Texture.Format,
    depthWriteEnabled: ?bool = null,
    depthCompare: ?sampler.Sampler.CompareFunction = null,
    stencilFront: StencilFaceState = .{},
    stencilBack: StencilFaceState = .{},
    stencilReadMask: def.StencilValue = 0xFFFFFFFF,
    stencilWriteMask: def.StencilValue = 0xFFFFFFFF,
    depthBias: def.DepthBias = 0,
    depthBiasSlopeScale: f32 = 0,
    depthBiasClamp: f32 = 0,
};

pub const StencilFaceState = struct {
    compare: sampler.Sampler.CompareFunction = .always,
    failOp: StencilOperation = .keep,
    depthFailOp: StencilOperation = .keep,
    passOp: StencilOperation = .keep,
};

pub const StencilOperation = enum {
    keep,
    zero,
    replace,
    invert,
    increment_clamp,
    decrement_clamp,
    increment_wrap,
    decrement_wrap,
};

pub const IndexFormat = enum {
    uint16,
    uint32,
};

pub const VertexFormat = enum {
    uint8,
    uint8x2,
    uint8x4,
    sint8,
    sint8x2,
    sint8x4,
    unorm8,
    unorm8x2,
    unorm8x4,
    snorm8,
    snorm8x2,
    snorm8x4,
    uint16,
    uint16x2,
    uint16x4,
    sint16,
    sint16x2,
    sint16x4,
    unorm16,
    unorm16x2,
    unorm16x4,
    snorm16,
    snorm16x2,
    snorm16x4,
    float16,
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
    @"unorm10-10-10-2",
    unorm8x4_bgra,
};

pub const VertexStepMode = enum {
    vertex,
    instance,
};

pub const VertexState = struct {
    module: shader.ShaderModule,
    entry_point: ?[]const u8 = null,
    constants: []const ProgrammableStage.Constant = &.{},
    buffers: []const ?VertexBufferLayout = &.{},
};

pub const VertexBufferLayout = struct {
    arrayStride: def.Size64,
    stepMode: VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

pub const VertexAttribute = struct {
    format: VertexFormat,
    offset: def.Size64,
    shaderLocation: def.Index32,
};
