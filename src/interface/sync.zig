pub const Fence = struct { handle: u64 = 0, value: u64 = 0 };
pub const Semaphore = struct { handle: u64 = 0 };
pub const SubmitDescriptor = struct {
    command_buffers: []const @import("command.zig").CommandBuffer,
    wait_semaphores: []const Semaphore = &.{},
    signal_semaphores: []const Semaphore = &.{},
    signal_fence: ?Fence = null,
};

