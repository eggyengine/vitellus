//! DX12 integration tests through the public API.
const std = @import("std");
const vit = @import("../../root.zig");

test "DX12 capability queries reflect the live adapter" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try vit.Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();

    const caps = adapter.capabilities();
    try std.testing.expect(caps.limits.max_buffer_size >= std.math.maxInt(u32));
    try std.testing.expect(caps.limits.max_texture_dimension_2d >= 16384);
    try std.testing.expect(caps.limits.max_bindings_per_group >= 64);
    try std.testing.expect(caps.limits.min_uniform_buffer_offset_alignment == 256);
    try std.testing.expect(caps.features.bc_compression);

    const rgba8 = adapter.formatCapabilities(.rgba8_unorm);
    try std.testing.expect(rgba8.usage.sampled);
    try std.testing.expect(rgba8.usage.color_attachment);
    try std.testing.expect(!rgba8.usage.depth_stencil_attachment);
    try std.testing.expect(rgba8.sample_counts.four);

    const depth = adapter.formatCapabilities(.d32_float);
    try std.testing.expect(depth.usage.depth_stencil_attachment);
    try std.testing.expect(!depth.usage.color_attachment);
    try std.testing.expect(!depth.usage.storage);

    const bc7 = adapter.formatCapabilities(.bc7_rgba_unorm);
    try std.testing.expect(bc7.usage.sampled);
    try std.testing.expect(!bc7.usage.color_attachment);
    try std.testing.expect(!bc7.sample_counts.four);

    try std.testing.expectEqual(vit.hal.adapter.FormatCapabilities{}, adapter.formatCapabilities(.undefined));
}

test "DX12 buffers cover upload, device, and readback memory" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try vit.Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();

    const upload = try vit.Buffer.init(device, .{
        .size = 4,
        .usage = .{ .vertex = true },
        .memory = .upload,
        .initial_data = &.{ 1, 2, 3, 4 },
    });
    defer upload.deinit();
    const local = try vit.Buffer.init(device, .{
        .size = 4,
        .usage = .{ .vertex = true },
        .initial_data = &.{ 1, 2, 3, 4 },
    });
    defer local.deinit();
    const readback = try vit.Buffer.init(device, .{
        .size = 4,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer readback.deinit();
}

test "DX12 command transfers copy buffers and textures" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try vit.Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();

    const expected = [4]u8{ 1, 2, 3, 4 };
    const upload = try vit.Buffer.init(device, .{
        .size = expected.len,
        .usage = .{ .transfer_src = true },
        .memory = .upload,
    });
    defer upload.deinit();
    const upload_mapping = try upload.map(.write, .{ .size = expected.len });
    @memcpy(upload_mapping, &expected);
    upload.unmap(.{ .size = expected.len });
    const local = try vit.Buffer.init(device, .{
        .size = expected.len,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer local.deinit();
    const readback = try vit.Buffer.init(device, .{
        .size = expected.len,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer readback.deinit();

    const pixels = [4]u8{ 10, 20, 30, 255 };
    const texture_upload = try vit.Buffer.init(device, .{
        .size = 256,
        .usage = .{ .transfer_src = true },
        .memory = .upload,
        .initial_data = &pixels,
    });
    defer texture_upload.deinit();
    const source_texture = try vit.hal.resource.Texture.init(device, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer source_texture.deinit();
    const destination_texture = try vit.hal.resource.Texture.init(device, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer destination_texture.deinit();
    const texture_readback = try vit.Buffer.init(device, .{
        .size = 256,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer texture_readback.deinit();

    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const commands = try vit.CommandBuffer.init(pool, .{});
    commands.beginDebugGroup("transfer test");
    try commands.barrier(&.{.{ .buffer = .{ .buffer = local, .before = .common, .after = .copy_destination } }});
    try commands.copyBuffer(.{ .source = upload, .destination = local, .size = expected.len });
    try commands.barrier(&.{.{ .buffer = .{ .buffer = local, .before = .copy_destination, .after = .copy_source } }});
    try commands.copyBuffer(.{ .source = local, .destination = readback, .size = expected.len });
    try commands.barrier(&.{.{ .texture = .{ .texture = source_texture, .before = .common, .after = .copy_destination } }});
    try commands.copyBufferToTexture(.{
        .buffer = texture_upload,
        .texture = .{ .texture = source_texture },
        .extent = .{ .width = 1 },
    });
    try commands.barrier(&.{
        .{ .texture = .{ .texture = source_texture, .before = .copy_destination, .after = .copy_source } },
        .{ .texture = .{ .texture = destination_texture, .before = .common, .after = .copy_destination } },
    });
    try commands.copyTexture(.{
        .source = .{ .texture = source_texture },
        .destination = .{ .texture = destination_texture },
        .extent = .{ .width = 1 },
    });
    try commands.barrier(&.{.{ .texture = .{ .texture = destination_texture, .before = .copy_destination, .after = .copy_source } }});
    try commands.copyTextureToBuffer(.{
        .buffer = texture_readback,
        .texture = .{ .texture = destination_texture },
        .extent = .{ .width = 1 },
    });
    commands.insertDebugMarker("copies recorded");
    commands.endDebugGroup();
    try commands.finish();
    try queue.submit(.{ .command_buffers = &.{commands} });
    try queue.waitIdle();
    commands.deinit();

    try expectBufferBytes(readback, &expected);
    try expectBufferBytes(texture_readback, &pixels);
}

fn expectBufferBytes(value: vit.Buffer, expected: []const u8) !void {
    const bytes = try value.map(.read, .{ .size = expected.len });
    defer value.unmap(null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "DX12 submission signals timeline fences asynchronously" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const instance = try vit.Instance.init(std.testing.allocator, .{ .backend = .{ .dx12 = true }, .validation = .none });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();
    const fence = try vit.hal.sync.Fence.init(device, .{});
    defer fence.deinit();
    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const commands = try vit.CommandBuffer.init(pool, .{});
    try commands.finish();
    try queue.submit(.{ .command_buffers = &.{commands}, .signal_fences = &.{.{ .fence = fence, .value = 1 }} });
    try std.testing.expect(try fence.wait(1, 5 * std.time.ns_per_s));
    try std.testing.expect(fence.currentValue() >= 1);
    commands.deinit();
    try pool.reset();
}

test "DX12 descriptor heaps grow past their first size and keep earlier descriptors" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const Dx12Device = @import("device.zig").Dx12Device;

    const instance = try vit.Instance.init(gpa, .{ .backend = .{ .dx12 = true }, .validation = .none });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();
    const dx12: *Dx12Device = @ptrCast(@alignCast(device.ptr));

    // More render-target views and sampler groups than the heaps start with.
    const count = 300;
    const texture = try vit.hal.resource.Texture.init(device, .{ .width = 1, .height = 1, .format = .rgba8_unorm, .usage = .{ .color_attachment = true, .transfer_src = true } });
    defer texture.deinit();
    var views: [count]vit.hal.resource.TextureView = undefined;
    for (&views, 0..) |*view, made| {
        errdefer for (views[0..made]) |earlier| earlier.deinit();
        view.* = try vit.hal.resource.TextureView.init(device, .{ .texture = texture });
    }
    defer for (views) |view| view.deinit();
    try std.testing.expect(dx12.rtvs.pages.items.len > 1);

    const sampler = try vit.hal.resource.Sampler.init(device, .{});
    defer sampler.deinit();
    const layout = try vit.hal.binding.BindGroupLayout.init(device, .{ .entries = &.{.{ .binding = 0, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } }} });
    defer layout.deinit();
    var groups: [count]vit.hal.binding.BindGroup = undefined;
    for (&groups, 0..) |*group, made| {
        errdefer for (groups[0..made]) |earlier| earlier.deinit();
        group.* = try vit.hal.binding.BindGroup.init(device, .{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .sampler = sampler } }} });
    }
    defer for (groups) |group| group.deinit();
    try std.testing.expect(dx12.samplers.generation > 0);

    // The first view was written before the heap moved; clearing through it must still work.
    const readback = try vit.Buffer.init(device, .{ .size = 256, .usage = .{ .transfer_dst = true }, .memory = .readback });
    defer readback.deinit();
    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.beginRenderPass(.{ .color_attachments = &.{.{ .view = views[0], .clear_value = .{ .r = 1, .g = 0, .b = 0, .a = 1 } }} });
    cmd.endRenderPass();
    try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = .color_attachment, .after = .copy_source } }});
    try cmd.copyTextureToBuffer(.{ .buffer = readback, .bytes_per_row = 256, .texture = .{ .texture = texture }, .extent = .{ .width = 1, .height = 1 } });
    try cmd.finish();
    try queue.submit(.{ .command_buffers = &.{cmd} });
    try queue.waitIdle();
    const read = try readback.map(.read, .{ .size = 4 });
    defer readback.unmap(null);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, read[0..4]);
}

test "DX12 software adapter is WARP and makes a working device" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try vit.Instance.init(std.testing.allocator, .{ .backend = .{ .dx12 = true }, .validation = .none });
    defer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{ .source = .software }) catch |err| switch (err) {
        error.NoSoftwareAdapter => return error.SkipZigTest, // Wine has no WARP
        else => return err,
    };
    defer adapter.deinit();
    try std.testing.expectEqual(vit.hal.adapter.Kind.software, adapter.info().kind);

    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const buffer = try vit.Buffer.init(device, .{ .size = 256, .usage = .{ .uniform = true }, .memory = .upload });
    defer buffer.deinit();
}
