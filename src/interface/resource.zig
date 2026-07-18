//! Resource formats, usage flags, memory placement, and opaque handles.

/// Backend-independent texel or attachment format.
pub const Format = enum {
    undefined,
    r8_unorm,
    r8_snorm,
    r8_uint,
    r8_sint,
    rg8_unorm,
    rg8_snorm,
    rg8_uint,
    rg8_sint,
    rgba8_unorm,
    rgba8_snorm,
    rgba8_uint,
    rgba8_sint,
    rgba8_unorm_srgb,
    bgra8_unorm,
    bgra8_unorm_srgb,
    r16_unorm,
    r16_snorm,
    r16_uint,
    r16_sint,
    r16_float,
    rg16_unorm,
    rg16_snorm,
    rg16_uint,
    rg16_sint,
    rg16_float,
    rgba16_unorm,
    rgba16_snorm,
    rgba16_uint,
    rgba16_sint,
    rgba16_float,
    r32_uint,
    r32_sint,
    r32_float,
    rg32_uint,
    rg32_sint,
    rg32_float,
    rgb32_uint,
    rgb32_sint,
    rgb32_float,
    rgba32_uint,
    rgba32_sint,
    rgba32_float,
    rgb10a2_unorm,
    rg11b10_float,
    bc1_rgba_unorm,
    bc1_rgba_unorm_srgb,
    bc2_rgba_unorm,
    bc2_rgba_unorm_srgb,
    bc3_rgba_unorm,
    bc3_rgba_unorm_srgb,
    bc4_r_unorm,
    bc4_r_snorm,
    bc5_rg_unorm,
    bc5_rg_snorm,
    bc6h_rgb_ufloat,
    bc6h_rgb_float,
    bc7_rgba_unorm,
    bc7_rgba_unorm_srgb,
    stencil8,
    d16_unorm,
    d24_unorm_s8_uint,
    d32_float,
    d32_float_s8_uint,
};

/// Operations that may be performed on a buffer.
pub const BufferUsage = packed struct(u32) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    query_resolve: bool = false,
    _pad: u24 = 0,
};
/// Operations that may be performed on a texture.
pub const TextureUsage = packed struct(u32) {
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _pad: u26 = 0,
};
/// Preferred physical memory placement for a buffer.
///
/// `device` favours GPU access, `upload` favours CPU writes, and `readback`
/// favours CPU reads of data copied back from the GPU.
pub const MemoryLocation = enum { device, upload, readback };
pub const MapMode = enum { read, write };
pub const BufferRange = struct { offset: u64 = 0, size: u64 };
/// Parameters used to allocate a buffer.
///
/// `initial_data`, when present, is copied during creation and may be shorter
/// than `size`.
pub const BufferDescriptor = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsage,
    memory: MemoryLocation = .device,
    initial_data: ?[]const u8 = null,
};
/// Dimensionality of a texture resource.
pub const TextureDimension = enum { d1, d2, d3 };
pub const TextureViewDimension = enum { d1, d1_array, d2, d2_array, cube, cube_array, d3 };
pub const TextureAspect = enum { all, color, depth, stencil };
/// Shape, format, and permitted uses of a texture.
pub const TextureDescriptor = struct {
    label: ?[]const u8 = null,
    dimension: TextureDimension = .d2,
    width: u32,
    height: u32 = 1,
    depth_or_layers: u32 = 1,
    mip_levels: u32 = 1,
    sample_count: u32 = 1,
    format: Format,
    usage: TextureUsage,
    /// Optional tightly packed data for mip 0 and array layer 0.
    initial_data: ?[]const u8 = null,
    /// Source row stride for `initial_data`; `0` uses width × format size.
    bytes_per_row: u32 = 0,
};
/// Texture subresource range exposed by a view.
pub const TextureViewDescriptor = struct {
    label: ?[]const u8 = null,
    texture: Texture,
    format: ?Format = null,
    dimension: ?TextureViewDimension = null,
    aspect: TextureAspect = .all,
    base_mip: u32 = 0,
    mip_count: ?u32 = null,
    base_layer: u32 = 0,
    layer_count: ?u32 = null,
};
/// Texture sampling filter.
pub const FilterMode = enum { nearest, linear };
/// Coordinate handling outside the normalised texture range.
pub const AddressMode = enum { repeat, mirror_repeat, clamp_to_edge };
pub const CompareOp = enum { never, less, equal, less_equal, greater, not_equal, greater_equal, always };
/// Filtering and addressing used when sampling a texture.
pub const SamplerDescriptor = struct {
    label: ?[]const u8 = null,
    mag_filter: FilterMode = .linear,
    min_filter: FilterMode = .linear,
    mipmap_filter: FilterMode = .linear,
    address_u: AddressMode = .repeat,
    address_v: AddressMode = .repeat,
    address_w: AddressMode = .repeat,
    lod_min: f32 = 0,
    lod_max: f32 = 32,
    compare: ?CompareOp = null,
    max_anisotropy: u16 = 1,
};
/// Opaque backend buffer handle.
pub const Buffer = struct {
    handle: u64 = 0,
    vtable: *const VTable,

    pub const VTable = struct {
        deinitFn: *const fn (Buffer) void,
        mapFn: *const fn (Buffer, MapMode, BufferRange) anyerror![]u8,
        unmapFn: *const fn (Buffer, ?BufferRange) void,
    };

    pub fn init(device: anytype, desc: BufferDescriptor) !Buffer {
        return if (device.vtable.createBufferFn) |f| f(device.ptr, desc) else error.Unsupported;
    }

    /// Maps a CPU-visible range.
    pub fn map(self: Buffer, mode: MapMode, range: BufferRange) ![]u8 {
        return self.vtable.mapFn(self, mode, range);
    }

    /// Ends a mapping and optionally identifies the range written by the CPU.
    pub fn unmap(self: Buffer, written: ?BufferRange) void {
        self.vtable.unmapFn(self, written);
    }

    pub fn deinit(self: Buffer) void {
        self.vtable.deinitFn(self);
    }
};
/// Opaque backend texture handle.
pub const Texture = struct {
    handle: u64 = 0,
    vtable: *const VTable,

    pub const VTable = struct { deinitFn: *const fn (Texture) void };

    pub fn init(device: anytype, desc: TextureDescriptor) !Texture {
        return if (device.vtable.createTextureFn) |f| f(device.ptr, desc) else error.Unsupported;
    }

    pub fn deinit(self: Texture) void {
        self.vtable.deinitFn(self);
    }
};
/// Opaque view describing how a texture is accessed.
pub const TextureView = struct {
    handle: u64 = 0,
    vtable: *const VTable,

    pub const VTable = struct { deinitFn: *const fn (TextureView) void };

    pub fn init(device: anytype, desc: TextureViewDescriptor) !TextureView {
        return if (device.vtable.createTextureViewFn) |f| f(device.ptr, desc) else error.Unsupported;
    }

    pub fn deinit(self: TextureView) void {
        self.vtable.deinitFn(self);
    }
};
/// Opaque backend sampler handle.
pub const Sampler = struct {
    handle: u64 = 0,
    vtable: *const VTable,

    pub const VTable = struct { deinitFn: *const fn (Sampler) void };

    pub fn init(device: anytype, desc: SamplerDescriptor) !Sampler {
        return if (device.vtable.createSamplerFn) |f| f(device.ptr, desc) else error.Unsupported;
    }

    pub fn deinit(self: Sampler) void {
        self.vtable.deinitFn(self);
    }
};
