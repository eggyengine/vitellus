//! Queue submission and cross-command synchronisation values.

/// Parameters used to create a monotonic CPU/GPU synchronisation object.
pub const FenceDescriptor = struct {
    label: ?[]const u8 = null,
    initial_value: u64 = 0,
};

/// Monotonic CPU/GPU synchronisation object.
pub const Fence = struct {
    handle: u64 = 0,
    vtable: *const VTable,

    pub const VTable = struct {
        deinitFn: *const fn (Fence) void,
        currentValueFn: *const fn (Fence) u64,
        waitFn: *const fn (FencePoint, ?u64) anyerror!bool,
    };

    /// Make a timeline fence starting at `desc.initial_value`. Submits signal it to higher values;
    /// the CPU reads or waits for them, and later submits can wait for them on the GPU.
    pub fn init(device: anytype, desc: FenceDescriptor) !Fence {
        return if (device.vtable.createFenceFn) |f| f(device.ptr, desc) else error.Unsupported;
    }

    /// The highest value the GPU has signalled so far, without waiting.
    pub fn currentValue(self: Fence) u64 {
        return self.vtable.currentValueFn(self);
    }

    /// Block until the fence reaches `value`: true when it did, false when `timeout_ns` ran out
    /// (null waits for ever).
    pub fn wait(self: Fence, value: u64, timeout_ns: ?u64) !bool {
        return self.vtable.waitFn(.{ .fence = self, .value = value }, timeout_ns);
    }

    /// Destroy the fence once no pending submit signals or waits for it.
    pub fn deinit(self: Fence) void {
        self.vtable.deinitFn(self);
    }
};
pub const FencePoint = struct { fence: Fence, value: u64 };
/// Parameters used to create a GPU-to-GPU synchronisation object.
pub const SemaphoreDescriptor = struct { label: ?[]const u8 = null };
/// GPU-to-GPU synchronisation object.
pub const Semaphore = struct {
    handle: u64 = 0,
    vtable: *const VTable,
    pub const VTable = struct { deinitFn: *const fn (Semaphore) void };

    /// Make a semaphore that orders GPU work: one submit or present signals it, the next waits
    /// for it (as between acquiring a swapchain image and drawing to it).
    pub fn init(device: anytype, desc: SemaphoreDescriptor) !Semaphore {
        return if (device.vtable.createSemaphoreFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
    /// Destroy the semaphore once no pending work signals or waits for it.
    pub fn deinit(self: Semaphore) void {
        self.vtable.deinitFn(self);
    }
};
/// Work and synchronisation passed to one queue submission.
pub const SubmitDescriptor = struct {
    /// Finished command buffers executed in slice order.
    command_buffers: []const @import("command.zig").CommandBuffer,
    /// Semaphores that must be signaled before execution begins.
    wait_semaphores: []const Semaphore = &.{},
    /// Semaphores signaled after execution completes.
    signal_semaphores: []const Semaphore = &.{},
    wait_fences: []const FencePoint = &.{},
    signal_fences: []const FencePoint = &.{},
};

const std = @import("std");
// Doc tests below: Zig's generated docs show each one as its type's example, and
// `zig build test` runs it, on the machine's GPU when it has one.
const vit = @import("../root.zig");
const ExampleGpu = @import("example_gpu.zig");

test Fence {
    const gpu = try ExampleGpu.open(.{});
    defer gpu.close();

    // A counter the GPU raises: each submission signals a higher value, and the CPU waits
    // for the value it needs, such as the frame from two frames ago, instead of `waitIdle`.
    const fence = try vit.Fence.init(gpu.device, .{});
    defer fence.deinit();
    const pool = try vit.CommandPool.init(gpu.device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.finish();
    try gpu.queue.submit(.{ .command_buffers = &.{cmd}, .signal_fences = &.{.{ .fence = fence, .value = 1 }} });

    // Null waits as long as it takes; with a timeout, false means the time ran out first.
    try std.testing.expect(try fence.wait(1, null));
    try std.testing.expect(fence.currentValue() >= 1);
}

test Semaphore {
    const gpu = try ExampleGpu.open(.{});
    defer gpu.close();

    // Orders two submissions on the GPU without the CPU waiting between them. A swapchain
    // uses one to say an image is free to draw into.
    const ready = try vit.Semaphore.init(gpu.device, .{});
    defer ready.deinit();
    const pool = try vit.CommandPool.init(gpu.device, .{});
    defer pool.deinit();
    const first = try vit.CommandBuffer.init(pool, .{});
    defer first.deinit();
    const second = try vit.CommandBuffer.init(pool, .{});
    defer second.deinit();
    try first.finish();
    try second.finish();
    try gpu.queue.submit(.{ .command_buffers = &.{first}, .signal_semaphores = &.{ready} });
    try gpu.queue.submit(.{ .command_buffers = &.{second}, .wait_semaphores = &.{ready} });
    try gpu.queue.waitIdle();
}
