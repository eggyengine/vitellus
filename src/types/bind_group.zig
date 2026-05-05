const def = @import("def.zig");
const buffer_mod = @import("buffer.zig");
const bind_group_layout = @import("bind_group_layout.zig");
const sampler_mod = @import("sampler.zig");
const texture_mod = @import("texture.zig");

pub const BindGroup = struct {
    label: ?[*:0]const u8,
    layout: *const bind_group_layout.BindGroupLayout,
    entries: []const Entry,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        layout: *const bind_group_layout.BindGroupLayout,
        entries: []const Entry,
    };

    pub fn init(descriptor: Descriptor) BindGroup {
        return .{
            .label = descriptor.label,
            .layout = descriptor.layout,
            .entries = descriptor.entries,
        };
    }

    pub const Entry = struct {
        binding: def.Index32,
        resource: BindingResource,
        prevalidatedSize: bool = false,
    };

    pub const BindingResource = union(enum) {
        sampler: *sampler_mod.Sampler,
        texture: *texture_mod.Texture,
        textureView: *texture_mod.Texture.View,
        buffer: *buffer_mod.Buffer,
        bufferBinding: BufferBinding,
        externalTexture: *texture_mod.ExternalTexture,
    };

    pub const BufferBinding = struct {
        buffer: *buffer_mod.Buffer,
        offset: def.Size64 = 0,
        size: ?def.Size64 = null,
    };
};
