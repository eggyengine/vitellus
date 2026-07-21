const std = @import("std");
const vk = @import("vulkan");
const queue_interface = @import("../../interface/queue.zig");
const Queue = queue_interface.Queue;
const QueueDescriptor = queue_interface.QueueDescriptor;
const sync = @import("../../interface/sync.zig");
const sync_impl = @import("sync.zig");
const command_impl = @import("command.zig");

const log = std.log.scoped(.vk_queue);

pub const vkQueue = struct {
    device: vk.DeviceProxy,
    queue: vk.Queue,
    family_index: u32,
    kind: queue_interface.QueueKind,

    const vtable: Queue.VTable = .{
        .deinitFn = deinitImpl,
        .submitFn = submitImpl,
        .waitIdleFn = waitIdleImpl,
    };

    pub fn init(device_ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) !Queue {
        if (desc.node_mask != 0) return error.InvalidNodeMask;
        const device: *@import("device.zig").vkDevice = @ptrCast(@alignCast(device_ptr));
        const family_index = switch (desc.kind) {
            .graphics => device.queues.graphics_family,
            .compute => device.queues.compute_family orelse return error.QueueKindUnsupported,
            .copy => device.queues.copy_family,
        };
        const self = try allocator.create(vkQueue);
        self.* = .{
            .device = device.proxy,
            .queue = device.proxy.getDeviceQueue(family_index, 0),
            .family_index = family_index,
            .kind = desc.kind,
        };
        device.instance.nameObject(allocator, device.proxy, .queue, @intFromEnum(self.queue), desc.label);
        log.debug("created Vulkan {s} queue wrapper for family {}", .{ @tagName(desc.kind), family_index });
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *vkQueue = @ptrCast(@alignCast(ptr));
        _ = self.device.queueWaitIdle(self.queue) catch |err| log.warn("Vulkan queue wait-idle failed during destruction: {}", .{err});
        allocator.destroy(self);
    }

    fn waitIdleImpl(ptr: *anyopaque) anyerror!void {
        const self: *vkQueue = @ptrCast(@alignCast(ptr));
        try self.device.queueWaitIdle(self.queue);
    }

    fn submitImpl(ptr: *anyopaque, desc: sync.SubmitDescriptor) !void {
        const self: *vkQueue = @ptrCast(@alignCast(ptr));
        const commands = try std.heap.page_allocator.alloc(vk.CommandBuffer, desc.command_buffers.len); defer std.heap.page_allocator.free(commands);
        const waits = try std.heap.page_allocator.alloc(vk.Semaphore, desc.wait_semaphores.len + desc.wait_fences.len); defer std.heap.page_allocator.free(waits);
        const wait_values = try std.heap.page_allocator.alloc(u64, waits.len); defer std.heap.page_allocator.free(wait_values);
        const stages = try std.heap.page_allocator.alloc(vk.PipelineStageFlags, waits.len); defer std.heap.page_allocator.free(stages);
        const signals = try std.heap.page_allocator.alloc(vk.Semaphore, desc.signal_semaphores.len + desc.signal_fences.len); defer std.heap.page_allocator.free(signals);
        const signal_values = try std.heap.page_allocator.alloc(u64, signals.len); defer std.heap.page_allocator.free(signal_values);
        for (desc.command_buffers, commands) |value, *out| { const cmd = command_impl.vkCommandBuffer.fromInterface(value); if (!cmd.finished) return error.CommandBufferNotFinished; out.* = cmd.handle; }
        for (desc.wait_semaphores, 0..) |value, i| { waits[i] = try sync_impl.rawSemaphore(value); wait_values[i] = 0; stages[i] = .{ .all_commands_bit = true }; }
        for (desc.wait_fences, 0..) |value, i| { const n = desc.wait_semaphores.len + i; waits[n] = try sync_impl.rawFence(value.fence); wait_values[n] = value.value; stages[n] = .{ .all_commands_bit = true }; }
        for (desc.signal_semaphores, 0..) |value, i| { signals[i] = try sync_impl.rawSemaphore(value); signal_values[i] = 0; }
        for (desc.signal_fences, 0..) |value, i| { const n = desc.signal_semaphores.len + i; signals[n] = try sync_impl.rawFence(value.fence); signal_values[n] = value.value; }
        var timeline: vk.TimelineSemaphoreSubmitInfo = .{ .wait_semaphore_value_count = @intCast(wait_values.len), .p_wait_semaphore_values = if (wait_values.len == 0) null else wait_values.ptr, .signal_semaphore_value_count = @intCast(signal_values.len), .p_signal_semaphore_values = if (signal_values.len == 0) null else signal_values.ptr };
        try self.device.queueSubmit(self.queue, &.{.{ .p_next = &timeline, .wait_semaphore_count = @intCast(waits.len), .p_wait_semaphores = if (waits.len == 0) null else waits.ptr, .p_wait_dst_stage_mask = if (stages.len == 0) null else stages.ptr, .command_buffer_count = @intCast(commands.len), .p_command_buffers = if (commands.len == 0) null else commands.ptr, .signal_semaphore_count = @intCast(signals.len), .p_signal_semaphores = if (signals.len == 0) null else signals.ptr }}, .null_handle);
    }
};
