//! Fences.

const std = @import("std");
const c = @import("webgpu_c");
const sync = @import("../../interface/sync.zig");
const forever = @import("utils.zig").forever;
const ptrOf = @import("utils.zig").ptrOf;
const handleOf = @import("utils.zig").handleOf;
const waitFuture = @import("utils.zig").waitFuture;
const WgpuDevice = @import("device.zig").WgpuDevice;

/// A timeline value advanced by `onSubmittedWorkDone` callbacks, one per signalling submit.
pub const WgpuFence = struct {
    allocator: std.mem.Allocator,
    instance: c.WGPUInstance,
    completed: u64,
    pending: std.ArrayList(Pending) = .empty,

    const Pending = struct { future: c.WGPUFuture, value: u64 };
    const Signal = struct { fence: *WgpuFence, value: u64 };

    const vtable: sync.Fence.VTable = .{ .deinitFn = deinit, .currentValueFn = currentValue, .waitFn = wait };

    pub fn create(ptr: *anyopaque, desc: sync.FenceDescriptor) anyerror!sync.Fence {
        const device: *WgpuDevice = @ptrCast(@alignCast(ptr));
        const self = try device.allocator.create(WgpuFence);
        self.* = .{ .allocator = device.allocator, .instance = device.instance, .completed = desc.initial_value };
        return .{ .handle = handleOf(self), .vtable = &vtable };
    }

    pub fn signalAfter(self: *WgpuFence, queue: c.WGPUQueue, value: u64) !void {
        const signal = try self.allocator.create(Signal);
        signal.* = .{ .fence = self, .value = value };
        try self.pending.ensureUnusedCapacity(self.allocator, 1);
        const future = c.wgpuQueueOnSubmittedWorkDone(queue, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = done,
            .userdata1 = signal,
            .userdata2 = null,
        });
        self.pending.appendAssumeCapacity(.{ .future = future, .value = value });
    }

    fn done(_: c.WGPUQueueWorkDoneStatus, _: c.WGPUStringView, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const signal: *Signal = @ptrCast(@alignCast(user));
        const self = signal.fence;
        self.completed = @max(self.completed, signal.value);
        self.allocator.destroy(signal);
        var kept: usize = 0;
        for (self.pending.items) |item| {
            if (item.value > self.completed) {
                self.pending.items[kept] = item;
                kept += 1;
            }
        }
        self.pending.shrinkRetainingCapacity(kept);
    }

    fn currentValue(value: sync.Fence) u64 {
        const self = ptrOf(WgpuFence, value.handle);
        c.wgpuInstanceProcessEvents(self.instance);
        return self.completed;
    }

    fn wait(point: sync.FencePoint, timeout_ns: ?u64) anyerror!bool {
        const self = ptrOf(WgpuFence, point.fence.handle);
        // Work finishes in submit order, so waiting on the first future at or past the target is enough.
        while (self.completed < point.value) {
            const next = for (self.pending.items) |item| {
                if (item.value >= point.value) break item;
            } else return error.FenceValueNeverSignalled;
            if (!try waitFuture(self.instance, next.future, timeout_ns orelse forever)) return false;
        }
        return true;
    }

    fn deinit(value: sync.Fence) void {
        const self = ptrOf(WgpuFence, value.handle);
        // Signals still in flight point at this fence; let them land first.
        if (self.pending.items.len > 0) {
            _ = wait(.{ .fence = value, .value = self.pending.items[self.pending.items.len - 1].value }, null) catch {};
        }
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
