//! DirectX 12 queue submission and synchronization entry points.

const sync = @import("../../interface/sync.zig");

pub fn submit(_: *anyopaque, _: sync.SubmitDescriptor) anyerror!void {
    return error.Unsupported;
}

pub fn waitIdle(_: *anyopaque) anyerror!void {
    return error.Unsupported;
}
