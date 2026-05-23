const std = @import("std");

const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");

const logz = @import("logz");

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
        logz.info().fmt("msg", "destroying noop buffer", .{}).log();
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
        logz.info().fmt("msg", "destroying noop texture", .{}).log();
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
        logz.info().fmt("msg", "destroying noop texture view", .{}).log();
        typed.allocator.destroy(typed);
    }
};

pub const NoopExternalTexture = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.ExternalTexture.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.ExternalTexture {
        const value = try allocator.create(NoopExternalTexture);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopExternalTexture = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "destroying noop external texture", .{}).log();
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
        logz.info().fmt("msg", "destroying noop sampler", .{}).log();
        typed.allocator.destroy(typed);
    }
};

pub const NoopBindGroupLayout = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.BindGroupLayout.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.BindGroupLayout {
        const value = try allocator.create(NoopBindGroupLayout);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopBindGroupLayout = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "destroying noop bind group layout", .{}).log();
        typed.allocator.destroy(typed);
    }
};

pub const NoopBindGroup = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.BindGroup.VTable{
        .destroy = destroy,
    };

    pub fn init(allocator: std.mem.Allocator) !hal.BindGroup {
        const value = try allocator.create(NoopBindGroup);
        value.* = .{ .allocator = allocator };
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopBindGroup = @ptrCast(@alignCast(ptr));
        logz.info().fmt("msg", "destroying noop bind group", .{}).log();
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
        logz.info().fmt("msg", "destroying noop query set", .{}).log();
        typed.allocator.destroy(typed);
    }
};
