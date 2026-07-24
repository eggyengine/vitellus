const std = @import("std");
const vk = @import("vulkan");
const shader = @import("../../interface/shader.zig");
const binding = @import("../../interface/binding.zig");
const vkDevice = @import("device.zig").vkDevice;

const log = std.log.scoped(.vk_shader);

pub const vkShader = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.ShaderModule,
    stage: shader.ShaderStage,
    entry_point: [:0]u8,
    bindings: []ReflectedBinding,

    pub fn fromHandle(value: shader.Shader) !*vkShader {
        if (value.handle == 0) return error.InvalidShader;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const ReflectedBinding = struct {
    set: u32,
    entry: binding.BindGroupLayoutEntry,
};

const vtable: shader.Shader.VTable = .{ .deinitFn = destroy };

pub fn create(ptr: *anyopaque, allocator: std.mem.Allocator, desc: shader.ShaderDescriptor) anyerror!shader.Shader {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    var compiled = try desc.source.compile(allocator, .{
        .backend = .vulkan,
        .stage = desc.stage,
        .label = desc.label,
    });
    defer compiled.deinit(allocator);
    if (!compiled.format.eql(.spirv)) return error.UnsupportedShaderFormat;
    if (compiled.bytes.len == 0 or compiled.bytes.len % @sizeOf(u32) != 0) return error.InvalidSpirv;

    const words = try allocator.alloc(u32, compiled.bytes.len / @sizeOf(u32));
    defer allocator.free(words);
    @memcpy(std.mem.sliceAsBytes(words), compiled.bytes);
    const reflected = try reflectBindings(allocator, words, desc.stage);
    errdefer allocator.free(reflected);
    const handle = try device.proxy.createShaderModule(&.{
        .code_size = compiled.bytes.len,
        .p_code = words.ptr,
    }, null);
    errdefer device.proxy.destroyShaderModule(handle, null);
    const entry_point = try allocator.dupeZ(u8, compiled.entry_point);
    errdefer allocator.free(entry_point);

    const self = try allocator.create(vkShader);
    self.* = .{
        .allocator = allocator,
        .device = device.proxy,
        .handle = handle,
        .stage = desc.stage,
        .entry_point = entry_point,
        .bindings = reflected,
    };
    device.instance.nameObject(allocator, device.proxy, .shader_module, @intFromEnum(handle), desc.label);
    log.debug("created Vulkan {s} shader module", .{@tagName(desc.stage)});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &vtable };
}

fn destroy(value: shader.Shader) void {
    const self = vkShader.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.device.destroyShaderModule(self.handle, null);
    allocator.free(self.bindings);
    allocator.free(self.entry_point);
    allocator.destroy(self);
    log.debug("destroyed Vulkan shader module", .{});
}

const SpirvId = struct {
    opcode: u16 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    set: ?u32 = null,
    binding_number: ?u32 = null,
};

fn reflectBindings(allocator: std.mem.Allocator, words: []const u32, stage: shader.ShaderStage) ![]ReflectedBinding {
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
    defer std.testing.allocator.free(reflected);
    try std.testing.expectEqual(@as(usize, 1), reflected.len);
    try std.testing.expectEqual(@as(u32, 0), reflected[0].set);
    try std.testing.expectEqual(@as(u32, 0), reflected[0].entry.binding);
    try std.testing.expect(reflected[0].entry.kind == .combined_texture_sampler);
    try std.testing.expect(reflected[0].entry.visibility.fragment);
}

test "Vulkan device creates SPIR-V compiled from HLSL" {
    if (!@import("shader_options").enable_dxc or @import("builtin").target.os.tag != .windows)
        return error.SkipZigTest;

    const instance = @import("instance.zig").vkInstance.init(std.testing.allocator, .{
        .backend = .{ .vulkan = true },
        .validation = .none,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer instance.deinit();
    const adapter = try instance.createAdapter(.{});
    defer adapter.deinit();
    const device = try @import("../../interface/device.zig").Device.init(adapter, .{});
    defer device.deinit();

    const value = try shader.Shader.init(device, .{
        .stage = .compute,
        .source = @import("../dx12/hlsl_shader_module.zig").HLSLShaderModule.init(.{
            .code = "[numthreads(1, 1, 1)] void main() {}",
            .profile = .cs_6_7,
        }),
    });
    value.deinit();
}
