const std = @import("std");

const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");


pub const NoopBuffer = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Buffer.VTable{
        .destroy = destroy,
        .mapAsync = mapAsync,
        .getMappedRange = getMappedRange,
        .unmap = unmap,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.Buffer {
        const value = try allocator.create(NoopBuffer);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopBuffer = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop buffer", .{});
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

pub const NoopTexture = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Texture.VTable{
        .destroy = destroy,
        .createView = createView,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.Texture {
        const value = try allocator.create(NoopTexture);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopTexture = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop texture", .{});
        typed.allocator.destroy(typed);
    }

    fn createView(ptr: *anyopaque, descriptor: texture.Texture.View.Descriptor) anyerror!hal.TextureView {
        const typed: *NoopTexture = @ptrCast(@alignCast(ptr));
        _ = descriptor;
        return NoopTextureView.init(typed.allocator);
    }
};

pub const NoopTextureView = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.TextureView.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.TextureView {
        const value = try allocator.create(NoopTextureView);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopTextureView = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop texture view", .{});
        typed.allocator.destroy(typed);
    }
};

pub const NoopSampler = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Sampler.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.Sampler {
        const value = try allocator.create(NoopSampler);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopSampler = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop sampler", .{});
        typed.allocator.destroy(typed);
    }
};

pub const NoopDescriptorSetLayout = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.DescriptorSetLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.DescriptorSetLayout {
        const value = try allocator.create(NoopDescriptorSetLayout);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopDescriptorSetLayout = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop descriptor set layout", .{});
        typed.allocator.destroy(typed);
    }
};

pub const NoopDescriptorSet = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.DescriptorSet.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.DescriptorSet {
        const value = try allocator.create(NoopDescriptorSet);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopDescriptorSet = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop descriptor set", .{});
        typed.allocator.destroy(typed);
    }
};

pub const NoopQuerySet = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.QuerySet.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.QuerySet {
        const value = try allocator.create(NoopQuerySet);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopQuerySet = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying noop query set", .{});
        typed.allocator.destroy(typed);
    }
};
