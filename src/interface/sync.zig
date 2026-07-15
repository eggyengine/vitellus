//! Queue submission and cross-command synchronisation values.

/// Monotonic CPU/GPU synchronisation object.
pub const Fence = struct {
    handle: u64 = 0,

    pub fn currentValue(self: Fence, device: anytype) u64 {
        return device.fenceValue(self);
    }

    pub fn wait(self: Fence, device: anytype, value: u64, timeout_ns: ?u64) !bool {
        return device.waitFence(.{ .fence = self, .value = value }, timeout_ns);
    }

    pub fn destroy(self: Fence, device: anytype) void {
        device.destroyFence(self);
    }
};
pub const FencePoint = struct { fence: Fence, value: u64 };
/// GPU-to-GPU synchronisation object.
pub const Semaphore = struct {
    handle: u64 = 0,

    pub fn destroy(self: Semaphore, device: anytype) void {
        device.destroySemaphore(self);
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
