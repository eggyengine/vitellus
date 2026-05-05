const bind_group_layout = @import("bind_group_layout.zig");
const pipeline_layout = @import("pipeline_layout.zig");

pub const AutoLayoutMode = enum {
    auto,
};

pub const DescriptorLayout = union(enum) {
    pipeline: *const pipeline_layout.PipelineLayout,
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

    pub fn getBindGroupLayout(self: *@This(), index: u32) bind_group_layout.BindGroupLayout {
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

    pub fn getBindGroupLayout(self: *@This(), index: u32) bind_group_layout.BindGroupLayout {
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
