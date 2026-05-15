const std = @import("std");

const buffer = @import("../../types/buffer.zig");
const def = @import("../../types/def.zig");
const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");

const allocator = std.heap.page_allocator;
const log = std.log.scoped(.vitellus_noop);

pub const NoopBuffer = struct {
    pub const vtable = hal.Buffer.VTable{
        .destroy = destroy,
        .mapAsync = mapAsync,
        .getMappedRange = getMappedRange,
        .unmap = unmap,
    };

    pub fn init() !hal.Buffer {
        const value = try allocator.create(NoopBuffer);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopBuffer = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop buffer", .{});
        allocator.destroy(typed);
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
    }

    fn getMappedRange(ptr: *anyopaque, offset: ?def.Size64, size: ?def.Size64) ?def.ArrayBuffer {
        _ = ptr;
        _ = offset;
        _ = size;
        return null;
    }

    fn unmap(ptr: *anyopaque) void {
        _ = ptr;
    }
};

pub const NoopTexture = struct {
    pub const vtable = hal.Texture.VTable{
        .destroy = destroy,
        .createView = createView,
    };

    pub fn init() !hal.Texture {
        const value = try allocator.create(NoopTexture);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopTexture = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop texture", .{});
        allocator.destroy(typed);
    }

    fn createView(ptr: *anyopaque, descriptor: texture.Texture.View.Descriptor) anyerror!hal.TextureView {
        _ = ptr;
        _ = descriptor;
        return NoopTextureView.init();
    }
};

pub const NoopTextureView = struct {
    pub const vtable = hal.TextureView.VTable{
        .destroy = destroy,
    };

    pub fn init() !hal.TextureView {
        const value = try allocator.create(NoopTextureView);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopTextureView = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop texture view", .{});
        allocator.destroy(typed);
    }
};

pub const NoopExternalTexture = struct {
    pub const vtable = hal.ExternalTexture.VTable{
        .destroy = destroy,
    };

    pub fn init() !hal.ExternalTexture {
        const value = try allocator.create(NoopExternalTexture);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopExternalTexture = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop external texture", .{});
        allocator.destroy(typed);
    }
};

pub const NoopSampler = struct {
    pub const vtable = hal.Sampler.VTable{
        .destroy = destroy,
    };

    pub fn init() !hal.Sampler {
        const value = try allocator.create(NoopSampler);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopSampler = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop sampler", .{});
        allocator.destroy(typed);
    }
};

pub const NoopBindGroupLayout = struct {
    pub const vtable = hal.BindGroupLayout.VTable{
        .destroy = destroy,
    };

    pub fn init() !hal.BindGroupLayout {
        const value = try allocator.create(NoopBindGroupLayout);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopBindGroupLayout = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop bind group layout", .{});
        allocator.destroy(typed);
    }
};

pub const NoopBindGroup = struct {
    pub const vtable = hal.BindGroup.VTable{
        .destroy = destroy,
    };

    pub fn init() !hal.BindGroup {
        const value = try allocator.create(NoopBindGroup);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopBindGroup = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop bind group", .{});
        allocator.destroy(typed);
    }
};

pub const NoopQuerySet = struct {
    pub const vtable = hal.QuerySet.VTable{
        .destroy = destroy,
    };

    pub fn init() !hal.QuerySet {
        const value = try allocator.create(NoopQuerySet);
        value.* = .{};
        return .{ .ptr = value, .vtable = &vtable };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *NoopQuerySet = @ptrCast(@alignCast(ptr));
        log.debug("destroying noop query set", .{});
        allocator.destroy(typed);
    }
};
