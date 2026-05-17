const std = @import("std");

const hal = @import("../hal.zig");
const shader = @import("../../types/shader.zig");

const log = std.log.scoped(.vitellus_noop);

pub const NoopShaderModule = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.ShaderModule.VTable{
        .destroy = destroy,
        .getCompilationInfo = getCompilationInfo,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.ShaderModule {
        const module = try allocator.create(NoopShaderModule);
        module.* = .{ .allocator = allocator };
        return .{
            .ptr = module,
            .vtable = &vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopShaderModule = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop shader module", .{});
        typed.allocator.destroy(typed);
    }

    fn getCompilationInfo(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!shader.ShaderModule.CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{ptr});
    }

    fn getCompilationInfoInternal(ptr: *anyopaque) anyerror!shader.ShaderModule.CompilationInfo {
        _ = ptr;
        return .{};
    }
};
