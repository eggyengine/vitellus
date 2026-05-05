const vit = @import("root.zig");
const std = @import("std");

test "basic" {
    const io = std.testing.io;

    var future = vit.GPU.requestAdapterAsync(io, .{});
    defer future.cancel(io) catch {};

    const adapter = try future.await(io);

    _ = adapter;
}
