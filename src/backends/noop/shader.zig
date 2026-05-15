const std = @import("std");

const hal = @import("../hal.zig");
const shader = @import("../../types/shader.zig");

const allocator = std.heap.page_allocator;
const log = std.log.scoped(.vitellus_noop);

pub const NoopShaderModule = struct {
    pub const vtable = hal.ShaderModule.VTable{
        .destroy = destroy,
        .getCompilationInfo = getCompilationInfo,
    };

    pub fn init() !hal.ShaderModule {
        const module = try allocator.create(NoopShaderModule);
        module.* = .{};
        return .{
            .ptr = module,
            .vtable = &vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopShaderModule = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop shader module", .{});
        allocator.destroy(typed);
    }

    fn getCompilationInfo(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!shader.ShaderModule.CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{ptr});
    }

    fn getCompilationInfoInternal(ptr: *anyopaque) anyerror!shader.ShaderModule.CompilationInfo {
        _ = ptr;
        return .{};
    }
};
