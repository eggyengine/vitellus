const std = @import("std");

const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const resource = @import("resource.zig");

const allocator = std.heap.page_allocator;
const log = std.log.scoped(.vitellus_noop);

pub const NoopPipelineLayout = struct {
    pub const vtable = hal.PipelineLayout.VTable{
        .destroy = destroy,
    };

    pub fn init() !hal.PipelineLayout {
        const value = try allocator.create(NoopPipelineLayout);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopPipelineLayout = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop pipeline layout", .{});
        allocator.destroy(typed);
    }
};

pub const NoopComputePipeline = struct {
    pub const vtable = hal.ComputePipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init() !hal.ComputePipeline {
        const value = try allocator.create(NoopComputePipeline);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopComputePipeline = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop compute pipeline", .{});
        allocator.destroy(typed);
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: def.Index32) anyerror!hal.BindGroupLayout {
        _ = ptr;
        _ = index;
        return resource.NoopBindGroupLayout.init();
    }
};

pub const NoopRenderPipeline = struct {
    pub const vtable = hal.RenderPipeline.VTable{
        .destroy = destroy,
        .getBindGroupLayout = getBindGroupLayout,
    };

    pub fn init() !hal.RenderPipeline {
        const value = try allocator.create(NoopRenderPipeline);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopRenderPipeline = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop render pipeline", .{});
        allocator.destroy(typed);
    }

    fn getBindGroupLayout(ptr: *anyopaque, index: def.Index32) anyerror!hal.BindGroupLayout {
        _ = ptr;
        _ = index;
        return resource.NoopBindGroupLayout.init();
    }
};
