//! Copies data into GPU buffers and textures through staging memory, in batches submitted without waiting.
const std = @import("std");
const Device = @import("interface/device.zig").Device;
const Queue = @import("interface/queue.zig").Queue;
const resource = @import("interface/resource.zig");
const command = @import("interface/command.zig");
const Graveyard = @import("graveyard.zig").Graveyard;

/// Writes recorded into one command buffer and submitted by `flush`, which never waits: the
/// queue runs them before anything submitted after. Staging memory is freed through the
/// graveyard once the copies have run.
///
/// ```zig
/// try uploader.writeBuffer(.{ .buffer = vertices, .data = bytes, .after = .vertex });
/// try uploader.flush(); // before the submit that draws with `vertices`
/// try queue.submit(frame_submit);
/// try graveyard.mark();
/// ```
pub const Uploader = struct {
    gpa: std.mem.Allocator,
    device: Device,
    queue: Queue,
    graveyard: *Graveyard,
    /// What is recorded and not yet submitted.
    pending: ?Batch = null,

    const Batch = struct {
        pool: command.CommandPool,
        cmd: command.CommandBuffer,
        staging: std.ArrayList(resource.Buffer) = .empty,
    };

    /// A buffer write. `buffer` must have `transfer_dst` usage; `after` is how it is used next.
    pub const BufferWrite = struct {
        buffer: resource.Buffer,
        offset: u64 = 0,
        data: []const u8,
        before: command.BufferState = .common,
        after: command.BufferState,
    };

    /// One subresource of a texture write, laid out in `TextureWrite.data` at `offset`.
    pub const TextureLevel = struct {
        offset: u64 = 0,
        /// Bytes between rows; DX12 needs a multiple of 256 and `offset` a multiple of 512.
        bytes_per_row: u32,
        width: u32,
        height: u32 = 1,
        depth: u32 = 1,
        mip_level: u32 = 0,
        layer: u32 = 0,
    };

    /// A texture write. `texture` must have `transfer_dst` usage; every subresource is moved
    /// from `before` to `after`.
    pub const TextureWrite = struct {
        texture: resource.Texture,
        data: []const u8,
        levels: []const TextureLevel,
        before: command.TextureState = .common,
        after: command.TextureState = .sampled,
    };

    /// Heap-allocated so its owner can move. `graveyard` must outlive it.
    pub fn create(gpa: std.mem.Allocator, device: Device, queue: Queue, graveyard: *Graveyard) !*Uploader {
        const self = try gpa.create(Uploader);
        self.* = .{ .gpa = gpa, .device = device, .queue = queue, .graveyard = graveyard };
        return self;
    }

    /// Submit what is pending, then free the uploader.
    pub fn destroy(self: *Uploader) void {
        self.flush() catch |err| std.log.scoped(.uploader).warn("pending uploads dropped: {t}", .{err});
        self.gpa.destroy(self);
    }

    /// Record copying `write.data` into `write.buffer` at `write.offset`, moving the buffer from
    /// `before` to `after`. The data is copied now, so it may be freed on return; the GPU copies
    /// it once the next `flush` is submitted.
    pub fn writeBuffer(self: *Uploader, write: BufferWrite) !void {
        if (write.data.len == 0) return;
        const batch = try self.open();
        const staging = try self.stage(batch, write.data);
        try batch.cmd.barrier(&.{.{ .buffer = .{ .buffer = write.buffer, .before = write.before, .after = .copy_destination } }});
        try batch.cmd.copyBuffer(.{ .source = staging, .destination = write.buffer, .destination_offset = write.offset, .size = write.data.len });
        try batch.cmd.barrier(&.{.{ .buffer = .{ .buffer = write.buffer, .before = .copy_destination, .after = write.after } }});
    }

    /// Record copying each of `write.levels` from `write.data` into the texture's subresources,
    /// moving all of them from `before` to `after`. Like `writeBuffer`, the data is copied now.
    pub fn writeTexture(self: *Uploader, write: TextureWrite) !void {
        if (write.levels.len == 0) return;
        const batch = try self.open();
        const staging = try self.stage(batch, write.data);
        try batch.cmd.barrier(&.{.{ .texture = .{ .texture = write.texture, .before = write.before, .after = .copy_destination } }});
        for (write.levels) |level| try batch.cmd.copyBufferToTexture(.{
            .buffer = staging,
            .buffer_offset = level.offset,
            .bytes_per_row = level.bytes_per_row,
            .texture = .{ .texture = write.texture, .mip_level = level.mip_level, .array_layer = level.layer },
            .extent = .{ .width = level.width, .height = level.height, .depth = level.depth },
        });
        try batch.cmd.barrier(&.{.{ .texture = .{ .texture = write.texture, .before = .copy_destination, .after = write.after } }});
    }

    /// Submit every write since the last flush. Call before any submit that uses what they wrote.
    /// If it fails, those writes are dropped.
    pub fn flush(self: *Uploader) !void {
        const batch = if (self.pending) |*pending| pending else return;
        errdefer self.discard(batch);
        try batch.cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{batch.cmd} });
        // Submitted: the staging memory and commands now only wait for the GPU to run them.
        for (batch.staging.items) |staging| self.graveyard.retire(staging);
        self.graveyard.retire(batch.cmd);
        self.graveyard.retire(batch.pool);
        batch.staging.deinit(self.gpa);
        self.pending = null;
    }

    fn open(self: *Uploader) !*Batch {
        if (self.pending) |*pending| return pending;
        const pool = try command.CommandPool.init(self.device, .{ .label = "uploads", .transient = true });
        errdefer pool.deinit();
        const cmd = try command.CommandBuffer.init(pool, .{ .label = "uploads" });
        self.pending = .{ .pool = pool, .cmd = cmd };
        return &self.pending.?;
    }

    fn stage(self: *Uploader, pending: *Batch, data: []const u8) !resource.Buffer {
        try pending.staging.ensureUnusedCapacity(self.gpa, 1);
        const staging = try resource.Buffer.init(self.device, .{ .label = "upload staging", .size = data.len, .usage = .{ .transfer_src = true }, .memory = .upload, .initial_data = data });
        pending.staging.appendAssumeCapacity(staging);
        return staging;
    }

    // Never submitted, so the GPU never saw any of it.
    fn discard(self: *Uploader, pending: *Batch) void {
        for (pending.staging.items) |staging| staging.deinit();
        pending.staging.deinit(self.gpa);
        pending.cmd.deinit();
        pending.pool.deinit();
        self.pending = null;
    }
};

test "uploads reach a buffer and a texture before later submits read them" {
    const vit = @import("root.zig");
    const gpa = std.testing.allocator;
    const instance = vit.Instance.init(gpa, .{ .validation = .none }) catch return error.SkipZigTest;
    defer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{}) catch return error.SkipZigTest;
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{});
    defer queue.deinit();
    const graveyard = try vit.Graveyard.create(gpa, device, queue);
    defer graveyard.destroy();
    const uploader = try Uploader.create(gpa, device, queue, graveyard);
    defer uploader.destroy();

    const bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const buffer = try vit.Buffer.init(device, .{ .size = bytes.len, .usage = .{ .transfer_dst = true, .transfer_src = true } });
    defer buffer.deinit();
    // Two rows of two RGBA8 texels, each row padded to DX12's 256-byte pitch.
    var pixels: [512]u8 = @splat(0);
    for (0..2) |row| for (0..8) |i| {
        pixels[row * 256 + i] = @intCast(row * 8 + i + 10);
    };
    const texture = try vit.Texture.init(device, .{ .width = 2, .height = 2, .format = .rgba8_unorm, .usage = .{ .sampled = true, .transfer_dst = true, .transfer_src = true } });
    defer texture.deinit();
    try uploader.writeBuffer(.{ .buffer = buffer, .data = &bytes, .after = .copy_source });
    try uploader.writeTexture(.{ .texture = texture, .data = &pixels, .levels = &.{.{ .bytes_per_row = 256, .width = 2, .height = 2 }}, .after = .copy_source });
    try uploader.flush();

    // Read both back with commands submitted after the flush, without waiting in between.
    const readback = try vit.Buffer.init(device, .{ .size = 512 + bytes.len, .usage = .{ .transfer_dst = true }, .memory = .readback });
    defer readback.deinit();
    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.barrier(&.{.{ .buffer = .{ .buffer = readback, .before = .common, .after = .copy_destination } }});
    try cmd.copyTextureToBuffer(.{ .buffer = readback, .bytes_per_row = 256, .texture = .{ .texture = texture }, .extent = .{ .width = 2, .height = 2 } });
    try cmd.copyBuffer(.{ .source = buffer, .destination = readback, .destination_offset = 512, .size = bytes.len });
    try cmd.barrier(&.{.{ .buffer = .{ .buffer = readback, .before = .copy_destination, .after = .host_read } }});
    try cmd.finish();
    try queue.submit(.{ .command_buffers = &.{cmd} });
    try queue.waitIdle();

    const read = try readback.map(.read, .{ .size = 512 + bytes.len });
    defer readback.unmap(null);
    try std.testing.expectEqualSlices(u8, &bytes, read[512..]);
    for (0..2) |row| try std.testing.expectEqualSlices(u8, pixels[row * 256 ..][0..8], read[row * 256 ..][0..8]);
}
