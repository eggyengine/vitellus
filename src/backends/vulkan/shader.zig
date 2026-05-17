const std = @import("std");
const vk = @import("vulkan");

const vkDevice = @import("device.zig").vkDevice;
const hal = @import("../hal.zig");
const shader = @import("../../types/shader.zig");
const debug = @import("debug.zig");

const log = std.log.scoped(.vitellus_vulkan);

pub const vkShaderModule = struct {
    device: *vkDevice,
    handle: vk.ShaderModule,
    label: ?[*:0]const u8,

    pub const vtable = hal.ShaderModule.VTable{
        .destroy = destroy,
        .getCompilationInfo = getCompilationInfo,
    };

    pub fn init(device: *vkDevice, descriptor: shader.ShaderModule.Descriptor) !hal.ShaderModule {
        log.debug("validating vulkan shader module bytecode: bytes={}", .{descriptor.code.len});
        if (descriptor.code.len == 0) {
            log.debug("vulkan shader module rejected: empty bytecode", .{});
            return error.EmptyShaderCode;
        }
        if (descriptor.code.len % @sizeOf(u32) != 0) {
            log.debug("vulkan shader module rejected: byte length is not 4-byte aligned", .{});
            return error.InvalidSpirVByteLength;
        }

        const word_count = descriptor.code.len / @sizeOf(u32);
        const words = try device.adapter.gpu.allocator.alloc(u32, word_count);
        defer device.adapter.gpu.allocator.free(words);

        for (words, 0..) |*word, i| {
            const offset = i * @sizeOf(u32);
            word.* = std.mem.readInt(u32, descriptor.code[offset..][0..4], .little);
        }

        if (words[0] != 0x07230203) {
            log.debug("vulkan shader module rejected: invalid SPIR-V magic 0x{x}", .{words[0]});
            return error.InvalidSpirVMagic;
        }

        const create_info = vk.ShaderModuleCreateInfo{
            .code_size = descriptor.code.len,
            .p_code = words.ptr,
        };

        const handle = try device.device.createShaderModule(&create_info, null);
        errdefer device.device.destroyShaderModule(handle, null);

        const module = try device.adapter.gpu.allocator.create(vkShaderModule);
        errdefer device.adapter.gpu.allocator.destroy(module);
        module.* = .{
            .device = device,
            .handle = handle,
            .label = descriptor.label,
        };
        debug.setObjectName(device, .shader_module, handle, descriptor.label);

        log.debug("created vulkan shader module: handle=0x{x} bytes={}", .{
            @intFromEnum(handle),
            descriptor.code.len,
        });
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
