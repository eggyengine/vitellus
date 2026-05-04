// only place re-exports in this file.

// only keep lower-level types in here. do not export.
pub const hal = struct {
    const gpu = @import("gpu.zig");
    const formats = @import("formats.zig");
};

// re-export types
pub const GPU = hal.gpu.GPU;
pub const Adapter = hal.gpu.Adapter;

pub const TextureFormat = hal.formats.TextureFormat;
