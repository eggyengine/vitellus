//! DirectX 12 resource entry points.

const resource = @import("../../interface/resource.zig");

pub fn createBuffer(_: *anyopaque, _: resource.BufferDescriptor) anyerror!resource.Buffer {
    return error.Unsupported;
}

pub fn destroyBuffer(_: *anyopaque, _: resource.Buffer) void {}
