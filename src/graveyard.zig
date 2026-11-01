//! Destroys GPU objects once the queue has finished every submit made before they were retired.
const std = @import("std");
const Device = @import("interface/device.zig").Device;
const Queue = @import("interface/queue.zig").Queue;
const sync = @import("interface/sync.zig");

const log = std.log.scoped(.graveyard);

/// Objects the GPU may still be using, each destroyed once a fence shows the queue is past them.
/// Call `mark` after each frame's submits and `collect` once a frame; nothing waits for the GPU.
///
/// ```zig
/// const graveyard = try vit.Graveyard.create(gpa, device, queue);
/// defer graveyard.destroy();
/// graveyard.retire(old_texture); // still drawn by the frame being recorded
/// try queue.submit(frame_submit);
/// try graveyard.mark();
/// graveyard.collect();
/// ```
pub const Graveyard = struct {
    gpa: std.mem.Allocator,
    queue: Queue,
    fence: sync.Fence,
    /// What the next `mark` signals: objects retired now are destroyed once it completes.
    next: u64 = 1,
    /// Oldest first, so the ones ready to destroy are always at the front.
    graves: std.ArrayList(Grave) = .empty,

    /// The largest object `retire` takes: a few handles, like a texture with its view and group.
    pub const max_object_bytes = 64;

    const Grave = struct {
        after: u64,
        object: [max_object_bytes]u8 align(16),
        deinit: *const fn (*const anyopaque) void,
    };

    /// Heap-allocated so caches can keep a pointer while their owners move. Destroy it before `queue`.
    pub fn create(gpa: std.mem.Allocator, device: Device, queue: Queue) !*Graveyard {
        const self = try gpa.create(Graveyard);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .queue = queue, .fence = try sync.Fence.init(device, .{ .label = "graveyard" }) };
        return self;
    }

    /// Wait for the queue, then destroy everything still retired.
    pub fn destroy(self: *Graveyard) void {
        self.drain();
        self.graves.deinit(self.gpa);
        self.fence.deinit();
        self.gpa.destroy(self);
    }

    /// Wait for the queue and destroy everything retired so far: for teardown, before freeing
    /// what retired objects were made from (layouts, samplers).
    pub fn drain(self: *Graveyard) void {
        if (self.graves.items.len == 0) return;
        self.queue.waitIdle() catch |err| log.warn("queue wait failed before destroying retired objects: {t}", .{err});
        for (self.graves.items) |*grave| grave.deinit(&grave.object);
        self.graves.clearRetainingCapacity();
    }

    /// Destroy `object` (anything with a public `deinit()`) once the GPU is done with work
    /// submitted before the next `mark`. Objects over `max_object_bytes` are kept on the heap.
    /// Never fails: without memory to remember it, it waits for the queue and destroys it now.
    pub fn retire(self: *Graveyard, object: anytype) void {
        self.bury(object) catch {
            self.queue.waitIdle() catch |err| log.warn("queue wait failed before destroying an object early: {t}", .{err});
            object.deinit();
        };
    }

    fn bury(self: *Graveyard, object: anytype) !void {
        const T = @TypeOf(object);
        if (comptime @sizeOf(T) > max_object_bytes or @alignOf(T) > 16) {
            const boxed = try self.gpa.create(T);
            errdefer self.gpa.destroy(boxed);
            boxed.* = object;
            return self.bury(Boxed(T){ .gpa = self.gpa, .object = boxed });
        }
        const destroyer = struct {
            fn deinit(stored: *const anyopaque) void {
                const value: *const T = @ptrCast(@alignCast(stored));
                value.deinit();
            }
        };
        var grave: Grave = .{ .after = self.next, .object = undefined, .deinit = destroyer.deinit };
        @as(*T, @ptrCast(@alignCast(&grave.object))).* = object;
        try self.graves.append(self.gpa, grave);
    }

    fn Boxed(comptime T: type) type {
        return struct {
            gpa: std.mem.Allocator,
            object: *T,

            pub fn deinit(self: @This()) void {
                self.object.deinit();
                self.gpa.destroy(self.object);
            }
        };
    }

    /// Note that every submit so far comes before the objects retired until now. Call after
    /// each frame's submits; cheap when nothing was retired.
    pub fn mark(self: *Graveyard) !void {
        if (self.graves.items.len == 0 or self.graves.items[self.graves.items.len - 1].after != self.next) return;
        try self.queue.submit(.{ .command_buffers = &.{}, .signal_fences = &.{.{ .fence = self.fence, .value = self.next }} });
        self.next += 1;
    }

    /// Destroy every object the GPU has finished with.
    pub fn collect(self: *Graveyard) void {
        if (self.graves.items.len == 0) return;
        const done = self.fence.currentValue();
        var finished: usize = 0;
        while (finished < self.graves.items.len and self.graves.items[finished].after <= done) : (finished += 1) {
            const grave = &self.graves.items[finished];
            grave.deinit(&grave.object);
        }
        self.graves.replaceRangeAssumeCapacity(0, finished, &.{});
    }
};

// A queue and fence that only count: the fence completes what the test says it has.
const Fake = struct {
    var signalled: u64 = 0;
    var completed: u64 = 0;
    var waited_idle = false;
    var destroyed: u32 = 0;

    const queue_vtable: Queue.VTable = .{ .deinitFn = undefined, .submitFn = submit, .waitIdleFn = waitIdle };
    const fence_vtable: sync.Fence.VTable = .{ .deinitFn = fenceDeinit, .currentValueFn = current, .waitFn = undefined };

    fn submit(_: *anyopaque, desc: sync.SubmitDescriptor) anyerror!void {
        for (desc.signal_fences) |point| signalled = point.value;
    }
    fn waitIdle(_: *anyopaque) anyerror!void {
        waited_idle = true;
        completed = signalled;
    }
    fn current(_: sync.Fence) u64 {
        return completed;
    }
    fn fenceDeinit(_: sync.Fence) void {}

    const Object = struct {
        pub fn deinit(_: Object) void {
            destroyed += 1;
        }
    };
};

test "retired objects are destroyed only once the queue passes the mark after them" {
    Fake.signalled = 0;
    Fake.completed = 0;
    Fake.destroyed = 0;
    var self: Graveyard = .{
        .gpa = std.testing.allocator,
        .queue = .{ .ptr = undefined, .vtable = &Fake.queue_vtable, .allocator = std.testing.allocator },
        .fence = .{ .vtable = &Fake.fence_vtable },
    };
    defer self.graves.deinit(std.testing.allocator);

    self.retire(Fake.Object{});
    try self.mark();
    self.retire(Fake.Object{});
    try self.mark();
    try std.testing.expectEqual(@as(u64, 2), Fake.signalled);

    self.collect();
    try std.testing.expectEqual(@as(u32, 0), Fake.destroyed);
    Fake.completed = 1;
    self.collect();
    try std.testing.expectEqual(@as(u32, 1), Fake.destroyed);
    Fake.completed = 2;
    self.collect();
    try std.testing.expectEqual(@as(u32, 2), Fake.destroyed);
    try std.testing.expectEqual(@as(usize, 0), self.graves.items.len);
}

test "objects too big to keep inline are boxed and still destroyed" {
    Fake.signalled = 0;
    Fake.completed = 0;
    Fake.destroyed = 0;
    var self: Graveyard = .{
        .gpa = std.testing.allocator,
        .queue = .{ .ptr = undefined, .vtable = &Fake.queue_vtable, .allocator = std.testing.allocator },
        .fence = .{ .vtable = &Fake.fence_vtable },
    };
    defer self.graves.deinit(std.testing.allocator);
    const Big = struct {
        padding: [Graveyard.max_object_bytes * 2]u8 = undefined,
        pub fn deinit(_: @This()) void {
            Fake.destroyed += 1;
        }
    };
    self.retire(Big{});
    try self.mark();
    Fake.completed = 1;
    self.collect();
    try std.testing.expectEqual(@as(u32, 1), Fake.destroyed);
}

test "marking with nothing retired submits nothing" {
    Fake.signalled = 0;
    var self: Graveyard = .{
        .gpa = std.testing.allocator,
        .queue = .{ .ptr = undefined, .vtable = &Fake.queue_vtable, .allocator = std.testing.allocator },
        .fence = .{ .vtable = &Fake.fence_vtable },
    };
    try self.mark();
    try std.testing.expectEqual(@as(u64, 0), Fake.signalled);
    try std.testing.expectEqual(@as(u64, 1), self.next);
}
