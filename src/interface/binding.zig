//! Shader-visible resources grouped by explicit binding layouts.

const resource = @import("resource.zig");

/// Pipeline stages that may access a binding.
pub const ShaderVisibility = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _pad: u29 = 0,
};

pub const BufferBindingType = enum { uniform, storage_read, storage_read_write };
pub const TextureSampleType = enum { float_filterable, float_unfilterable, sint, uint, depth };
pub const StorageTextureAccess = enum { read, write, read_write };
pub const SamplerBindingType = enum { filtering, non_filtering, comparison };

/// Resource represented by a bind-group entry, including the validation data
/// needed by Vulkan, Metal, and DirectX 12.
pub const BindingType = union(enum) {
    buffer: struct { kind: BufferBindingType = .uniform, dynamic_offset: bool = false, min_size: u64 = 0 },
    sampled_texture: struct { sample_type: TextureSampleType = .float_filterable, dimension: resource.TextureViewDimension = .d2, multisampled: bool = false },
    storage_texture: struct { access: StorageTextureAccess = .write, format: resource.Format, dimension: resource.TextureViewDimension = .d2 },
    sampler: SamplerBindingType,
};

/// One binding declared by shaders and a pipeline layout.
pub const BindGroupLayoutEntry = struct {
    binding: u32,
    kind: BindingType,
    visibility: ShaderVisibility,
    count: u32 = 1,
};

/// Ordered set of bindings accepted by one bind-group slot.
pub const BindGroupLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry,
};

/// Opaque backend bind-group-layout handle.
pub const BindGroupLayout = struct {
    handle: u64 = 0,

    pub fn destroy(self: BindGroupLayout, device: anytype) void {
        device.destroyBindGroupLayout(self);
    }
};

/// Range of a buffer exposed to a shader.
pub const BufferBinding = struct {
    buffer: resource.Buffer,
    offset: u64 = 0,
    size: ?u64 = null,
};

/// Resource stored in one bind-group entry.
pub const BindingResource = union(enum) {
    buffer: BufferBinding,
    texture_view: resource.TextureView,
    sampler: resource.Sampler,
};

/// Resource assigned to a numbered layout binding.
pub const BindGroupEntry = struct {
    binding: u32,
    array_element: u32 = 0,
    resource: BindingResource,
};

/// Layout and resources used to create a bind group.
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: BindGroupLayout,
    entries: []const BindGroupEntry,
};

/// Opaque backend bind-group handle.
pub const BindGroup = struct {
    handle: u64 = 0,

    pub fn destroy(self: BindGroup, device: anytype) void {
        device.destroyBindGroup(self);
    }
};
