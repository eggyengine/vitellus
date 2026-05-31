const std = @import("std");

const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");

pub const DX_Buffer = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Buffer.VTable{
        .destroy = destroy,
        .mapAsync = mapAsync,
        .getMappedRange = getMappedRange,
        .unmap = unmap,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.Buffer {
        const value = try allocator.create(DX_Buffer);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_Buffer = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 buffer", .{});
        typed.allocator.destroy(typed);
    }

    fn mapAsync(
        ptr: *anyopaque,
        io: std.Io,
        mode: buffer.Buffer.MapMode,
        offset: ?def.Size64,
        size: def.Size64,
    ) std.Io.Future(anyerror!void) {
        return io.async(mapAsyncInternal, .{ ptr, mode, offset, size });
    }

    fn mapAsyncInternal(
        ptr: *anyopaque,
        mode: buffer.Buffer.MapMode,
        offset: ?def.Size64,
        size: def.Size64,
    ) anyerror!void {
        _ = ptr;
        _ = mode;
        _ = offset;
        _ = size;
        return error.NotImplemented;
    }

    fn getMappedRange(ptr: *anyopaque, offset: ?def.Size64, size: ?def.Size64) anyerror!?def.ArrayBuffer {
        _ = ptr;
        _ = offset;
        _ = size;
        return error.NotImplemented;
    }

    fn unmap(ptr: *anyopaque) void {
        _ = ptr;
    }
};

pub const DX_Texture = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Texture.VTable{
        .destroy = destroy,
        .createView = createView,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.Texture {
        const value = try allocator.create(DX_Texture);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_Texture = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 texture", .{});
        typed.allocator.destroy(typed);
    }

    fn createView(ptr: *anyopaque, descriptor: texture.Texture.View.Descriptor) anyerror!hal.TextureView {
        const typed: *DX_Texture = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return DX_TextureView.init(typed.allocator);
    }
};

pub const DX_TextureView = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.TextureView.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.TextureView {
        const value = try allocator.create(DX_TextureView);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_TextureView = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 texture view", .{});
        typed.allocator.destroy(typed);
    }
};

pub const DX_Sampler = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Sampler.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.Sampler {
        const value = try allocator.create(DX_Sampler);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_Sampler = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 sampler", .{});
        typed.allocator.destroy(typed);
    }
};

pub const DX_BindGroupLayout = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.BindGroupLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.BindGroupLayout {
        const value = try allocator.create(DX_BindGroupLayout);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_BindGroupLayout = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 bind group layout", .{});
        typed.allocator.destroy(typed);
    }
};

pub const DX_BindGroup = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.BindGroup.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.BindGroup {
        const value = try allocator.create(DX_BindGroup);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_BindGroup = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 bind group", .{});
        typed.allocator.destroy(typed);
    }
};

pub const DX_QuerySet = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.QuerySet.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.QuerySet {
        const value = try allocator.create(DX_QuerySet);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_QuerySet = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying dx12 query set", .{});
        typed.allocator.destroy(typed);
    }
};
