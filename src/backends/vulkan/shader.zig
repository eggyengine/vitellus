const std = @import("std");
const vk = @import("vulkan");
const shader = @import("../../interface/shader.zig");
const vkDevice = @import("device.zig").vkDevice;

const log = std.log.scoped(.vk_shader);

pub const vkShader = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.ShaderModule,
    stage: shader.ShaderStage,
    entry_point: [:0]u8,

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
    };
    device.instance.nameObject(allocator, device.proxy, .shader_module, @intFromEnum(handle), desc.label);
    log.debug("created Vulkan {s} shader module", .{@tagName(desc.stage)});
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &vtable };
}

fn destroy(value: shader.Shader) void {
    const self = vkShader.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.device.destroyShaderModule(self.handle, null);
    allocator.free(self.entry_point);
    allocator.destroy(self);
    log.debug("destroyed Vulkan shader module", .{});
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
