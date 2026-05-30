const std = @import("std");

const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const resource = @import("resource.zig");


pub const DX_PipelineLayout = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.PipelineLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.PipelineLayout {
        const value = try allocator.create(DX_PipelineLayout);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_PipelineLayout = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying DX_ pipeline layout", .{});
        typed.allocator.destroy(typed);
    }
};

pub const DX_ComputePipeline = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.ComputePipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.ComputePipeline {
        const value = try allocator.create(DX_ComputePipeline);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_ComputePipeline = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying DX_ compute pipeline", .{});
        typed.allocator.destroy(typed);
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: def.Index32) anyerror!hal.BindGroupLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = index;
        return resource.DX_BindGroupLayout.init(typed.allocator);
    }
};

pub const DX_RenderPipeline = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.RenderPipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.RenderPipeline {
        const value = try allocator.create(DX_RenderPipeline);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_RenderPipeline = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying DX_ render pipeline", .{});
        typed.allocator.destroy(typed);
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: def.Index32) anyerror!hal.BindGroupLayout {
        const typed: *@This() = @ptrCast(@alignCast(ptr));
        _ = index;
        return resource.DX_BindGroupLayout.init(typed.allocator);
    }
};
