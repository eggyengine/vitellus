const bind_group = @import("bind_group.zig");
const shader = @import("shader.zig");

pub const PipelineLayout = struct {
    label: ?[*:0]const u8,
    bindGroupLayouts: []const ?*const bind_group.BindGroupLayout,

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

    pub const Descriptor = DescriptorBase;

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
};

pub const RenderPipeline = struct {
    valid: bool = true,

    pub const Descriptor = DescriptorBase;

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
};

pub const PipelineConstantValue = f64;

pub const ProgrammableStage = struct {
    module: shader.ShaderModule,
    entry_point: []const u8,
    constants: []Constants,

    pub const Constants = struct {
        key: []const u8,
        value: PipelineConstantValue,
    };
};
