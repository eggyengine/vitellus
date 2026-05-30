const std = @import("std");

const hal = @import("../hal.zig");
const texture = @import("../../types/texture.zig");


pub const DX_Surface = struct {
    allocator: std.mem.Allocator,

    pub const vtable = hal.Surface.VTable{
        .destroy = destroy,
        .getCapabilities = getCapabilities,
        .configure = configure,
        .unconfigure = unconfigure,
        .getCurrentTexture = getCurrentTexture,
    };

    const formats = [_]texture.Texture.Format{
        .bgra8unorm,
        .bgra8unorm_srgb,
        .rgba8unorm,
        .rgba8unorm_srgb,
    };
    const present_modes = [_]texture.Surface.PresentMode{ .fifo, .immediate };
    const alpha_modes = [_]texture.Surface.AlphaMode{ .@"opaque", .premultiplied };

    pub fn init(allocator: std.mem.Allocator) !hal.Surface {
        const surface = try allocator.create(DX_Surface);
        surface.* = .{ .allocator = allocator };
        return .{
            .ptr = surface,
            .vtable = &vtable,
        };
    }

    fn destroy(ptr: *anyopaque) void {
        const typed: *DX_Surface = @ptrCast(@alignCast(ptr));
        std.log.debug("destroying DX_ surface", .{});
        typed.allocator.destroy(typed);
    }

    fn getCapabilities(ptr: *anyopaque, adapter: hal.Adapter) texture.Surface.Capabilities {
        _ = ptr;
        _ = adapter;
        return .{
            .formats = &formats,
            .present_modes = &present_modes,
            .alpha_modes = &alpha_modes,
        };
    }

    fn configure(ptr: *anyopaque, device: hal.Device, configuration: texture.Surface.Configuration) void {
        _ = ptr;
        _ = device;
        _ = configuration;
        std.log.debug("configuring DX_ surface", .{});
    }

    fn unconfigure(ptr: *anyopaque) void {
        _ = ptr;
        std.log.debug("unconfiguring DX_ surface", .{});
    }

    fn getCurrentTexture(ptr: *anyopaque) anyerror!texture.Surface.CurrentSurfaceTexture {
        _ = ptr;
        std.log.debug("DX_ surface current texture requested", .{});
        return .{ .success = .{
            .width = 1,
            .height = 1,
            .depthOrArrayLayers = 1,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .dimension = .@"2d",
            .format = .bgra8unorm,
            .usage = texture.Texture.Usage.RENDER_ATTACHMENT,
            .textureBindingViewDimension = .@"2d",
        } };
    }
};
