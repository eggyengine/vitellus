const std = @import("std");

const hal = @import("../hal.zig");
const shader = @import("../../types/shader.zig");


pub const DX_ShaderModule = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.ShaderModule.VTable{
        .destroy = destroy,
        .getCompilationInfo = getCompilationInfo,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.ShaderModule {
        const module = try allocator.create(DX_ShaderModule);
        module.* = .{ .allocator = allocator };
        return .{
            .ptr = module,
            .vtable = &vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_ShaderModule = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying DX_ shader module", .{});
        typed.allocator.destroy(typed);
    }

    fn getCompilationInfo(ptr: *anyopaque, io: std.Io) std.Io.Future(anyerror!shader.ShaderModule.CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{ptr});
    }

    fn getCompilationInfoInternal(ptr: *anyopaque) anyerror!shader.ShaderModule.CompilationInfo {
        _ = ptr;
        return error.NotImplemented;
    }
};
