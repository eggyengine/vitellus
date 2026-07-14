pub const Format = enum {
    undefined,
    r8_unorm, rg8_unorm, rgba8_unorm, rgba8_unorm_srgb, bgra8_unorm, bgra8_unorm_srgb,
    r16_float, rg16_float, rgba16_float, r32_float, rg32_float, rgb32_float, rgba32_float,
    d16_unorm, d24_unorm_s8_uint, d32_float,
};

pub const BufferUsage = packed struct(u32) {
    vertex: bool = false, index: bool = false, uniform: bool = false, storage: bool = false,
    indirect: bool = false, transfer_src: bool = false, transfer_dst: bool = false, _pad: u25 = 0,
};
pub const TextureUsage = packed struct(u32) {
    sampled: bool = false, storage: bool = false, color_attachment: bool = false,
    depth_stencil_attachment: bool = false, transfer_src: bool = false, transfer_dst: bool = false,
    _pad: u26 = 0,
};
pub const MemoryLocation = enum { device, upload, readback };
pub const BufferDescriptor = struct {
    label: ?[]const u8 = null, size: u64, usage: BufferUsage, memory: MemoryLocation = .device,
    initial_data: ?[]const u8 = null,
};
pub const TextureDimension = enum { d1, d2, d3 };
pub const TextureDescriptor = struct {
    label: ?[]const u8 = null, dimension: TextureDimension = .d2,
    width: u32, height: u32 = 1, depth_or_layers: u32 = 1, mip_levels: u32 = 1,
    sample_count: u32 = 1, format: Format, usage: TextureUsage,
};
pub const Buffer = struct { handle: u64 = 0 };
pub const Texture = struct { handle: u64 = 0 };
pub const TextureView = struct { handle: u64 = 0 };

