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

    pub fn init(device: anytype, desc: FenceDescriptor) !Fence {
        return if (device.vtable.createFenceFn) |f| f(device.ptr, desc) else error.Unsupported;
    }

    pub fn currentValue(self: Fence) u64 {
        return self.vtable.currentValueFn(self);
    }

    pub fn wait(self: Fence, value: u64, timeout_ns: ?u64) !bool {
        return self.vtable.waitFn(.{ .fence = self, .value = value }, timeout_ns);
    }

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

    pub fn init(device: anytype, desc: SemaphoreDescriptor) !Semaphore {
        return if (device.vtable.createSemaphoreFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
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
