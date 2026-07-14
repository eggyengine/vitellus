//! DirectX 12 pipeline entry points.

const pipeline = @import("../../interface/pipeline.zig");

pub fn createGraphics(_: *anyopaque, _: pipeline.GraphicsPipelineDescriptor) anyerror!pipeline.GraphicsPipeline {
    return error.Unsupported;
}

pub fn destroyGraphics(_: *anyopaque, _: pipeline.GraphicsPipeline) void {}
