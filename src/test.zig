const vit = @import("root.zig");
const std = @import("std");

test "basic" {
    const io = std.testing.io;
    // const gpu = try vit.GPU.init();
    const adapter = try vit.GPU.requestAdapterAsync(io, .{}).cancel(io);
}
