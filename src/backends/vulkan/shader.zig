const std = @import("std");
const vk = @import("vulkan");
const shader = @import("../../interface/shader.zig");
const vkDevice = @import("device.zig").vkDevice;
const spirv_reflect = @import("../spirv_reflect.zig");

const log = std.log.scoped(.vk_shader);

pub const ReflectedBinding = spirv_reflect.ReflectedBinding;

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
    const reflected = try spirv_reflect.reflectBindings(allocator, words, desc.stage);
    errdefer if (reflected.len != 0) allocator.free(reflected);
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
    if (self.bindings.len != 0) allocator.free(self.bindings);
    allocator.free(self.entry_point);
    allocator.destroy(self);
    log.debug("destroyed Vulkan shader module", .{});
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
    const reflected = try spirv_reflect.reflectBindings(std.testing.allocator, &words, .fragment);
    defer if (reflected.len != 0) std.testing.allocator.free(reflected);
    try std.testing.expectEqual(@as(usize, 1), reflected.len);
    try std.testing.expectEqual(@as(u32, 0), reflected[0].set);
    try std.testing.expectEqual(@as(u32, 0), reflected[0].entry.binding);
    try std.testing.expect(reflected[0].entry.kind == .combined_texture_sampler);
    try std.testing.expect(reflected[0].entry.visibility.fragment);
}

test "Vulkan device creates SPIR-V compiled from HLSL" {
    if (comptime !@import("shader_options").enable_dxc or @import("builtin").target.os.tag != .windows)
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
