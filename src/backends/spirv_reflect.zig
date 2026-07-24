//! Shared SPIR-V bind-group reflection used by Vulkan and DX12.

const std = @import("std");
const binding = @import("../interface/binding.zig");
const shader = @import("../interface/shader.zig");

pub const ReflectedBinding = struct {
    set: u32,
    entry: binding.BindGroupLayoutEntry,
};

const SpirvId = struct {
    opcode: u16 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    set: ?u32 = null,
    binding_number: ?u32 = null,
};

/// Reflects descriptor bindings from SPIR-V words for `stage`.
/// Returns an empty non-owned slice when no bindings are present.
pub fn reflectBindings(
    allocator: std.mem.Allocator,
    words: []const u32,
    stage: shader.ShaderStage,
) ![]ReflectedBinding {
    if (words.len < 5 or words[0] != 0x07230203) return error.InvalidSpirv;
    const ids = try allocator.alloc(SpirvId, words[3]);
    defer allocator.free(ids);
    @memset(ids, .{});

    var offset: usize = 5;
    while (offset < words.len) {
        const instruction = words[offset];
        const count: usize = instruction >> 16;
        const opcode: u16 = @truncate(instruction);
        if (count == 0 or offset + count > words.len) return error.InvalidSpirv;
        const operands = words[offset + 1 .. offset + count];
        switch (opcode) {
            25 => {
                if (operands.len >= 8) ids[operands[0]] = .{ .opcode = opcode, .a = operands[6], .b = operands[2], .c = operands[5] };
            }, // OpTypeImage
            26, 30 => {
                if (operands.len >= 1) ids[operands[0]].opcode = opcode;
            }, // OpTypeSampler/Struct
            27 => {
                if (operands.len >= 2) ids[operands[0]] = .{ .opcode = opcode, .a = operands[1] };
            }, // OpTypeSampledImage
            28 => {
                if (operands.len >= 3) ids[operands[0]] = .{ .opcode = opcode, .a = operands[1], .b = operands[2] };
            }, // OpTypeArray
            32 => {
                if (operands.len >= 3) ids[operands[0]] = .{ .opcode = opcode, .a = operands[2] };
            }, // OpTypePointer
            43 => {
                if (operands.len >= 3) ids[operands[1]] = .{ .opcode = opcode, .a = operands[2] };
            }, // OpConstant
            59 => if (operands.len >= 3) {
                ids[operands[1]].opcode = opcode;
                ids[operands[1]].a = operands[0];
                ids[operands[1]].b = operands[2];
            }, // OpVariable
            71 => if (operands.len >= 3) switch (operands[1]) {
                33 => ids[operands[0]].binding_number = operands[2],
                34 => ids[operands[0]].set = operands[2],
                else => {},
            }, // OpDecorate
            else => {},
        }
        offset += count;
    }

    var count: usize = 0;
    for (ids) |id| {
        if (id.opcode == 59 and id.set != null and id.binding_number != null) count += 1;
    }
    if (count == 0) return &.{};

    const result = try allocator.alloc(ReflectedBinding, count);
    errdefer allocator.free(result);
    var index: usize = 0;
    for (ids) |variable| {
        if (variable.opcode != 59 or variable.set == null or variable.binding_number == null) continue;
        var type_id = ids[variable.a].a; // variable result type is a pointer
        var descriptor_count: u32 = 1;
        if (ids[type_id].opcode == 28) {
            descriptor_count = ids[ids[type_id].b].a;
            type_id = ids[type_id].a;
        }
        const kind: binding.BindingType = switch (ids[type_id].opcode) {
            26 => .{ .sampler = .filtering },
            27 => .{ .combined_texture_sampler = imageBinding(ids[ids[type_id].a]) },
            25 => if (ids[type_id].a == 2)
                return error.UnsupportedReflectedStorageTexture
            else
                .{ .sampled_texture = imageBinding(ids[type_id]) },
            30 => .{ .buffer = .{ .kind = if (variable.b == 12) .storage_read_write else .uniform } },
            else => return error.UnsupportedReflectedBinding,
        };
        result[index] = .{
            .set = variable.set.?,
            .entry = .{
                .binding = variable.binding_number.?,
                .kind = kind,
                .visibility = switch (stage) {
                    .vertex => .{ .vertex = true },
                    .fragment => .{ .fragment = true },
                    .compute => .{ .compute = true },
                },
                .count = descriptor_count,
            },
        };
        index += 1;
    }
    return result;
}

/// Reflects bindings from a SPIR-V byte blob.
pub fn reflectBindingsBytes(
    allocator: std.mem.Allocator,
    code: []const u8,
    stage: shader.ShaderStage,
) ![]ReflectedBinding {
    if (code.len == 0 or code.len % @sizeOf(u32) != 0) return error.InvalidSpirv;
    const words = try allocator.alloc(u32, code.len / @sizeOf(u32));
    defer allocator.free(words);
    @memcpy(std.mem.sliceAsBytes(words), code);
    return reflectBindings(allocator, words, stage);
}

fn imageBinding(image: SpirvId) binding.SampledTextureBindingLayout {
    return .{
        .dimension = switch (image.b) {
            0 => .d1,
            1 => .d2,
            2 => .d3,
            3 => .cube,
            else => .d2,
        },
        .multisampled = image.c != 0,
    };
}

test "reflects a combined image sampler" {
    const words = [_]u32{
        0x07230203, 0x00010000, 0, 8, 0,
        (4 << 16) | 71, 7, 33, 0, // binding 0
        (4 << 16) | 71, 7, 34, 0, // set 0
        (9 << 16) | 25, 1, 2, 1,              0, 0, 0, 1,              0, // 2D sampled image
        (3 << 16) | 27, 3, 1, (4 << 16) | 32, 4, 0, 3, (4 << 16) | 59, 4,
        7,              0,
    };
    const reflected = try reflectBindings(std.testing.allocator, &words, .fragment);
    defer if (reflected.len != 0) std.testing.allocator.free(reflected);
    try std.testing.expectEqual(@as(usize, 1), reflected.len);
    try std.testing.expectEqual(@as(u32, 0), reflected[0].set);
    try std.testing.expectEqual(@as(u32, 0), reflected[0].entry.binding);
    try std.testing.expect(reflected[0].entry.kind == .combined_texture_sampler);
    try std.testing.expect(reflected[0].entry.visibility.fragment);
}
