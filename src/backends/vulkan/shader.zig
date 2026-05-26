const std = @import("std");
const vk = @import("vulkan");

const vkDevice = @import("device.zig").vkDevice;
const hal = @import("../hal.zig");
const shader = @import("../../types/shader.zig");
const logz = @import("logz");

pub const vkShader = struct {
    source: shader.ShaderModule.ShaderSource,
    label: ?[*:0]const u8 = null,
};

pub const vkShaderModule = struct {
    device: *vkDevice,
    handle: vk.ShaderModule,
    label: ?[*:0]const u8,

    pub const vtable = hal.ShaderModule.VTable{
        .destroy = destroy,
        .getCompilationInfo = getCompilationInfo,
    };

    pub fn init(device: *vkDevice, shader_data: vkShader) !hal.ShaderModule {
        logz.info().fmt("msg", "creating vulkan shader module", .{}).log();

        // SPIRV is natively supported on vulkan, so no need for translation.
        const code = switch (shader_data.source) {
            .spirv => |bytes| bytes,
        };
        if (code.len == 0 or code.len % @sizeOf(u32) != 0) {
            logz.err().fmt("msg", "vulkan shader module creation rejected: SPIR-V bytecode length ({}) is not a non-zero multiple of 4", .{code.len}).log();
            return error.InvalidShaderModule;
        }

        const word_count = code.len / @sizeOf(u32);
        const words = try device.adapter.gpu.allocator.alloc(u32, word_count);
        defer device.adapter.gpu.allocator.free(words);
        @memcpy(std.mem.sliceAsBytes(words), code);

        const create_info = vk.ShaderModuleCreateInfo{
            .code_size = code.len,
            .p_code = words.ptr,
        };
        const handle = try device.device.createShaderModule(&create_info, null);
        errdefer device.device.destroyShaderModule(handle, null);

        const module = try device.adapter.gpu.allocator.create(vkShaderModule);
        errdefer device.adapter.gpu.allocator.destroy(module);
        module.* = .{
            .device = device,
            .handle = handle,
            .label = shader_data.label,
        };

        logz.info().fmt("msg", "created vulkan shader module: handle=0x{x}", .{@intFromEnum(handle)}).log();
        return .{
            .ptr = module,
            .vtable = &vkShaderModule.vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        if (typed.handle != .null_handle) {
            logz.info().fmt("msg", "destroying vulkan shader module: handle=0x{x}", .{@intFromEnum(typed.handle)}).log();
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
        return error.NotImplemented;
    }
};
