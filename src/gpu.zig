const std = @import("std");

const format = @import("formats.zig");

pub const GPU = struct {
    pub const RequestAdapterError = error{};

    pub const FeatureLevel = enum { core, compatibility };

    pub const PowerPreference = enum {
        lowPower,
        highPerformance,
    };

    pub const Options = struct {
        feature_level: FeatureLevel = .core,
        power_preference: ?PowerPreference = null,
        force_fallback_adapter: bool = false,
        xr_compatible: bool = false,
    };

    pub fn requestAdapter(options: Options) RequestAdapterError!Adapter {
        return error.NotImplemented;
    }

    pub fn requestAdapterAsync(
        io: std.Io,
        options: Options,
    ) std.Io.Future(RequestAdapterError!Adapter) {
        return io.async(requestAdapter, .{options});
    }

    pub fn getPreferredCanvasFormat() format.TextureFormat {}
};

pub const Adapter = struct {};
