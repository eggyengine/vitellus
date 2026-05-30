const std = @import("std");

const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const resource = @import("resource.zig");


pub const NoopPipelineLayout = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.PipelineLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.PipelineLayout {
        const value = try allocator.create(NoopPipelineLayout);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopPipelineLayout = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop pipeline layout", .{});
        typed.allocator.destroy(typed);
    }
};

pub const NoopComputePipeline = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.ComputePipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.ComputePipeline {
        const value = try allocator.create(NoopComputePipeline);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopComputePipeline = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop compute pipeline", .{});
        typed.allocator.destroy(typed);
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: def.Index32) anyerror!hal.BindGroupLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = index;
        return resource.NoopBindGroupLayout.init(typed.allocator);
    }
};

pub const NoopRenderPipeline = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.RenderPipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.RenderPipeline {
        const value = try allocator.create(NoopRenderPipeline);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopRenderPipeline = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop render pipeline", .{});
        typed.allocator.destroy(typed);
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: def.Index32) anyerror!hal.BindGroupLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = index;
        return resource.NoopBindGroupLayout.init(typed.allocator);
    }
};
