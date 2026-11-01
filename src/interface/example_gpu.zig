//! The GPU the HAL's doc examples (`test Buffer { ... }`) run on, skipping them where there is none.
const std = @import("std");
const vit = @import("../root.zig");

instance: vit.Instance,
adapter: vit.Adapter,
device: vit.Device,
queue: vit.Queue,

const ExampleGpu = @This();

/// The default adapter's device made with `desc`, and its graphics queue. Returns
/// `error.SkipZigTest` when the machine has no GPU or the GPU lacks a required feature.
pub fn open(desc: vit.DeviceDescriptor) !ExampleGpu {
    const instance = vit.Instance.init(std.testing.allocator, .{ .validation = .none }) catch return error.SkipZigTest;
    errdefer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{}) catch return error.SkipZigTest;
    errdefer adapter.deinit();
    const device = vit.Device.init(adapter, desc) catch |err| switch (err) {
        error.RequiredFeatureUnsupported => return error.SkipZigTest,
        else => return err,
    };
    errdefer device.deinit();
    const queue = try vit.Queue.init(device, .{});
    return .{ .instance = instance, .adapter = adapter, .device = device, .queue = queue };
}

/// Waits for the GPU, then releases everything `open` made.
pub fn close(self: ExampleGpu) void {
    self.queue.waitIdle() catch {};
    self.queue.deinit();
    self.device.deinit();
    self.adapter.deinit();
    self.instance.deinit();
}
