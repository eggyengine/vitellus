//! Where each subresource of a texture's packed `initial_data` sits, for every backend to read the same way.
const std = @import("std");
const resource = @import("resource.zig");

/// A format's texel block: 1×1 for uncompressed formats, 4×4 for BC.
pub const Block = struct { width: u32 = 1, height: u32 = 1, bytes: u32 };

/// The texel block `format` is stored in; null for `undefined`.
pub fn block(format: resource.Format) ?Block {
    return switch (format) {
        .undefined => null,
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint, .stencil8 => .{ .bytes = 1 },
        .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint, .r16_unorm, .r16_snorm, .r16_uint, .r16_sint, .r16_float, .d16_unorm => .{ .bytes = 2 },
        .rgba8_unorm, .rgba8_snorm, .rgba8_uint, .rgba8_sint, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb, .rg16_unorm, .rg16_snorm, .rg16_uint, .rg16_sint, .rg16_float, .r32_uint, .r32_sint, .r32_float, .rgb10a2_unorm, .rg11b10_float, .d24_unorm_s8_uint, .d32_float => .{ .bytes = 4 },
        .rgba16_unorm, .rgba16_snorm, .rgba16_uint, .rgba16_sint, .rgba16_float, .rg32_uint, .rg32_sint, .rg32_float, .d32_float_s8_uint => .{ .bytes = 8 },
        .rgb32_uint, .rgb32_sint, .rgb32_float => .{ .bytes = 12 },
        .rgba32_uint, .rgba32_sint, .rgba32_float => .{ .bytes = 16 },
        .bc1_rgba_unorm, .bc1_rgba_unorm_srgb, .bc4_r_unorm, .bc4_r_snorm => .{ .width = 4, .height = 4, .bytes = 8 },
        .bc2_rgba_unorm, .bc2_rgba_unorm_srgb, .bc3_rgba_unorm, .bc3_rgba_unorm_srgb, .bc5_rg_unorm, .bc5_rg_snorm, .bc6h_rgb_ufloat, .bc6h_rgb_float, .bc7_rgba_unorm, .bc7_rgba_unorm_srgb => .{ .width = 4, .height = 4, .bytes = 16 },
    };
}

/// One mip of one array layer (or of the whole volume, for 3D textures) within the data.
pub const Subresource = struct {
    mip: u32,
    layer: u32,
    /// D3D12's subresource number: `mip + layer * mip_levels`.
    index: u32,
    offset: u64,
    /// Bytes from one row of blocks to the next.
    bytes_per_row: u64,
    /// Rows of blocks in one depth slice.
    rows: u32,
    width: u32,
    height: u32,
    depth: u32,

    /// Bytes the subresource takes in the data.
    pub fn size(self: Subresource) u64 {
        return self.bytes_per_row * self.rows * self.depth;
    }
};

/// Walks `desc.initial_data`'s subresources: layer by layer, each layer's mips from largest to
/// smallest, every one tightly packed except that `desc.bytes_per_row` (single-mip textures
/// only) sets the row stride. The data may stop after any whole subresource.
pub const Iterator = struct {
    desc: resource.TextureDescriptor,
    format_block: Block,
    data_len: u64,
    offset: u64 = 0,
    mip: u32 = 0,
    layer: u32 = 0,

    /// Start walking `desc.initial_data`. Fails for empty data, multisampled textures, formats
    /// with no block size, and `bytes_per_row` on a texture with several mips.
    pub fn init(desc: resource.TextureDescriptor) !Iterator {
        const data = desc.initial_data orelse return error.InvalidInitialData;
        if (data.len == 0) return error.InvalidInitialData;
        if (desc.sample_count != 1) return error.UnsupportedInitialTextureShape;
        if (desc.bytes_per_row != 0 and desc.mip_levels != 1) return error.InvalidBytesPerRow;
        return .{ .desc = desc, .format_block = block(desc.format) orelse return error.UnsupportedUploadFormat, .data_len = data.len };
    }

    /// The next subresource the data covers, or null once it ends.
    pub fn next(self: *Iterator) !?Subresource {
        const layers = if (self.desc.dimension == .d3) 1 else self.desc.depth_or_layers;
        if (self.layer >= layers or self.offset >= self.data_len) return null;
        const width = mipExtent(self.desc.width, self.mip);
        const height = mipExtent(self.desc.height, self.mip);
        const packed_row = @as(u64, std.math.divCeil(u32, width, self.format_block.width) catch unreachable) * self.format_block.bytes;
        if (self.desc.bytes_per_row != 0 and self.desc.bytes_per_row < packed_row) return error.InvalidBytesPerRow;
        const subresource: Subresource = .{
            .mip = self.mip,
            .layer = self.layer,
            .index = self.mip + self.layer * self.desc.mip_levels,
            .offset = self.offset,
            .bytes_per_row = if (self.desc.bytes_per_row != 0) self.desc.bytes_per_row else packed_row,
            .rows = std.math.divCeil(u32, height, self.format_block.height) catch unreachable,
            .width = width,
            .height = height,
            .depth = if (self.desc.dimension == .d3) mipExtent(self.desc.depth_or_layers, self.mip) else 1,
        };
        if (self.data_len - self.offset < subresource.size()) return error.InitialDataTooSmall;
        self.offset += subresource.size();
        self.mip += 1;
        if (self.mip == self.desc.mip_levels) {
            self.mip = 0;
            self.layer += 1;
        }
        return subresource;
    }
};

fn mipExtent(extent: u32, mip: u32) u32 {
    return @max(1, extent >> @intCast(@min(mip, 31)));
}

test "a cube's faces each hold their mip chain, smallest last" {
    // 4×4 RGBA8 with three mips: 64 + 16 + 4 bytes a face.
    const data: [84 * 6]u8 = @splat(0);
    var walk: Iterator = try .init(.{ .width = 4, .height = 4, .depth_or_layers = 6, .mip_levels = 3, .format = .rgba8_unorm, .usage = .{}, .initial_data = &data });
    var count: u32 = 0;
    while (try walk.next()) |sub| : (count += 1) {
        try std.testing.expectEqual(count % 3, sub.mip);
        try std.testing.expectEqual(count / 3, sub.layer);
        try std.testing.expectEqual(count, sub.index);
        const mip_offsets = [_]u64{ 0, 64, 80 };
        try std.testing.expectEqual(mip_offsets[sub.mip] + 84 * sub.layer, sub.offset);
    }
    try std.testing.expectEqual(@as(u32, 18), count);
}

test "a volume's mips shrink in depth and BC rows count blocks" {
    // 8×8×4 BC1: mip 0 is 2×2 blocks × 4 slices, mip 1 1×1 × 2, mip 2 (2×2×1) 1×1 × 1.
    const data: [8 * (16 + 2 + 1)]u8 = @splat(0);
    var walk: Iterator = try .init(.{ .dimension = .d3, .width = 8, .height = 8, .depth_or_layers = 4, .mip_levels = 3, .format = .bc1_rgba_unorm, .usage = .{}, .initial_data = &data });
    const expected = [_][3]u64{ .{ 16, 2, 4 }, .{ 8, 1, 2 }, .{ 8, 1, 1 } };
    for (expected) |want| {
        const sub = (try walk.next()).?;
        try std.testing.expectEqual(want[0], sub.bytes_per_row);
        try std.testing.expectEqual(want[1], sub.rows);
        try std.testing.expectEqual(want[2], sub.depth);
    }
    try std.testing.expectEqual(@as(?Subresource, null), try walk.next());
}

test "data may stop after a whole subresource but not inside one" {
    const just_mip_0: [64]u8 = @splat(0);
    var walk: Iterator = try .init(.{ .width = 4, .height = 4, .mip_levels = 3, .format = .rgba8_unorm, .usage = .{}, .initial_data = &just_mip_0 });
    _ = (try walk.next()).?;
    try std.testing.expectEqual(@as(?Subresource, null), try walk.next());

    const cut: [70]u8 = @splat(0);
    walk = try .init(.{ .width = 4, .height = 4, .mip_levels = 3, .format = .rgba8_unorm, .usage = .{}, .initial_data = &cut });
    _ = (try walk.next()).?;
    try std.testing.expectError(error.InitialDataTooSmall, walk.next());
}

test "every layer and mip of initial data reaches the texture" {
    const vit = @import("../root.zig");
    const gpa = std.testing.allocator;
    const instance = vit.Instance.init(gpa, .{ .validation = .none }) catch return error.SkipZigTest;
    defer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{}) catch return error.SkipZigTest;
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{});
    defer queue.deinit();

    // Two layers of 4×4 RGBA8 with two mips: 64 + 16 bytes a layer, each byte its own offset.
    var data: [160]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast(i);
    const texture = try vit.Texture.init(device, .{ .width = 4, .height = 4, .depth_or_layers = 2, .mip_levels = 2, .format = .rgba8_unorm, .usage = .{ .sampled = true, .transfer_src = true }, .initial_data = &data });
    defer texture.deinit();

    const readback = try vit.Buffer.init(device, .{ .size = 512, .usage = .{ .transfer_dst = true }, .memory = .readback });
    defer readback.deinit();
    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = .common, .after = .copy_source } }});
    try cmd.copyTextureToBuffer(.{ .buffer = readback, .bytes_per_row = 256, .texture = .{ .texture = texture, .mip_level = 1, .array_layer = 1 }, .extent = .{ .width = 2, .height = 2 } });
    try cmd.finish();
    try queue.submit(.{ .command_buffers = &.{cmd} });
    try queue.waitIdle();

    const read = try readback.map(.read, .{ .size = 512 });
    defer readback.unmap(null);
    // Layer 1's mip 1 starts at 80 + 64 and has two 8-byte rows.
    try std.testing.expectEqualSlices(u8, data[144..152], read[0..8]);
    try std.testing.expectEqualSlices(u8, data[152..160], read[256..264]);
}
