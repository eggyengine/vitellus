const std = @import("std");
const vk = @import("vulkan");
const sync = @import("../../interface/sync.zig");
const vkDevice = @import("device.zig").vkDevice;

const log = std.log.scoped(.vk_sync);

pub const vkSemaphore = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.Semaphore,

    fn fromInterface(value: sync.Semaphore) !*vkSemaphore {
        if (value.handle == 0) return error.InvalidSemaphore;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkFence = struct {
    allocator: std.mem.Allocator, device: vk.DeviceProxy, handle: vk.Semaphore,
    fn fromInterface(value: sync.Fence) !*vkFence {
        if (value.handle == 0) return error.InvalidFence;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const semaphore_vtable: sync.Semaphore.VTable = .{ .deinitFn = destroySemaphore };
const fence_vtable: sync.Fence.VTable = .{ .deinitFn = destroyFence, .currentValueFn = currentFenceValue, .waitFn = waitFence };

pub fn createFence(ptr: *anyopaque, desc: sync.FenceDescriptor) anyerror!sync.Fence {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    var type_info: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = desc.initial_value };
    const handle = try device.proxy.createSemaphore(&.{ .p_next = &type_info }, null);
    errdefer device.proxy.destroySemaphore(handle, null);
    const self = try device.allocator.create(vkFence);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = handle };
    device.instance.nameObject(device.allocator, device.proxy, .semaphore, @intFromEnum(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &fence_vtable };
}

fn destroyFence(value: sync.Fence) void { const self = vkFence.fromInterface(value) catch return; const a = self.allocator; self.device.destroySemaphore(self.handle, null); a.destroy(self); }
fn currentFenceValue(value: sync.Fence) u64 { const self = vkFence.fromInterface(value) catch return 0; return self.device.getSemaphoreCounterValue(self.handle) catch 0; }
fn waitFence(point: sync.FencePoint, timeout_ns: ?u64) anyerror!bool {
    const self = try vkFence.fromInterface(point.fence);
    const handles = [_]vk.Semaphore{self.handle}; const values = [_]u64{point.value};
    const result = try self.device.waitSemaphores(&.{ .semaphore_count = 1, .p_semaphores = &handles, .p_values = &values }, timeout_ns orelse std.math.maxInt(u64));
    return result == .success;
}

pub fn createSemaphore(ptr: *anyopaque, desc: sync.SemaphoreDescriptor) anyerror!sync.Semaphore {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(vkSemaphore);
    errdefer device.allocator.destroy(self);
    const handle = try device.proxy.createSemaphore(&.{}, null);
    self.* = .{
        .allocator = device.allocator,
        .device = device.proxy,
        .handle = handle,
    };
    device.instance.nameObject(device.allocator, device.proxy, .semaphore, @intFromEnum(handle), desc.label);
    log.debug("created Vulkan binary semaphore", .{});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &semaphore_vtable };
}

fn destroySemaphore(value: sync.Semaphore) void {
    const self = vkSemaphore.fromInterface(value) catch return;
    const allocator = self.allocator;
    self.device.destroySemaphore(self.handle, null);
    allocator.destroy(self);
    log.debug("destroyed Vulkan binary semaphore", .{});
}

pub fn rawSemaphore(value: sync.Semaphore) !vk.Semaphore {
    return (try vkSemaphore.fromInterface(value)).handle;
}

pub fn rawFence(value: sync.Fence) !vk.Semaphore { return (try vkFence.fromInterface(value)).handle; }
