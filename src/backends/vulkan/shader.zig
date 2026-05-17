const std = @import("std");
const vk = @import("vulkan");

const vkDevice = @import("device.zig").vkDevice;
const hal = @import("../hal.zig");
const shader = @import("../../types/shader.zig");
const log = std.log.scoped(.vitellus_vulkan);

pub const vkShader = struct {};

pub const vkShaderModule = struct {
    device: *vkDevice,
    handle: vk.ShaderModule,
    label: ?[*:0]const u8,

    pub const vtable = hal.ShaderModule.VTable{
        .destroy = destroy,
        .getCompilationInfo = getCompilationInfo,
    };

    /// Initialising a Vulkan shader module consumes backend-ready shader data.
    /// Source-language conversion/validation happens before this backend layer.
    pub fn init(device: *vkDevice, shader_data: vkShader) !hal.ShaderModule {
        _ = shader_data;
        log.debug("creating vulkan shader module from backend shader data", .{});

        const module = try device.adapter.gpu.allocator.create(vkShaderModule);
        errdefer device.adapter.gpu.allocator.destroy(module);
        module.* = .{
            .device = device,
            .handle = .null_handle,
            .label = null,
        };

        log.debug("created placeholder vulkan shader module", .{});
        return .{
            .ptr = module,
            .vtable = &vkShaderModule.vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.handle != .null_handle) {
            log.debug("destroying vulkan shader module: handle=0x{x}", .{@intFromEnum(typed.handle)});
            typed.device.device.destroyShaderModule(typed.handle, null);
            typed.handle = .null_handle;
        }
        typed.device.adapter.gpu.allocator.destroy(typed);
    }

    fn getCompilationInfo(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!shader.ShaderModule.CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{ptr});
    }

    fn getCompilationInfoInternal(ptr: *anyopaque) anyerror!shader.ShaderModule.CompilationInfo {
        _ = ptr;
        return .{};
    }
};
