const def = @import("def.zig");
const hal = @import("../backends/hal.zig");
const buffer_mod = @import("buffer.zig");
const sampler_mod = @import("sampler.zig");
const texture_mod = @import("texture.zig");

pub const BindGroup = struct {
    backend: ?hal.BindGroup = null,
    label: ?[*:0]const u8,
    layout: *const BindGroupLayout,
    entries: []const Entry,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        layout: *const BindGroupLayout,
        entries: []const Entry,
    };

    pub fn init(descriptor: Descriptor) BindGroup {
        return .{
            .label = descriptor.label,
            .layout = descriptor.layout,
            .entries = descriptor.entries,
        };
    }

    pub fn destroy(self: *@This()) void {
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
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
    };

    pub const BufferBinding = struct {
        buffer: *buffer_mod.Buffer,
        offset: def.Size64 = 0,
        size: ?def.Size64 = null,
    };
};

pub const BindGroupLayout = struct {
    backend: ?hal.BindGroupLayout = null,
    label: ?[*:0]const u8,
    entryMap: []const *const Entry,
    dynamicOffsetCount: def.Size32Out,
    exclusivePipeline: ?*anyopaque,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        entries: []const *const Entry,
    };

    pub fn init(descriptor: Descriptor) BindGroupLayout {
        var dynamic_offset_count: def.Size32Out = 0;
        for (descriptor.entries) |entry| {
            if (entry.*.buffer) |buffer| {
                if (buffer.hasDynamicOffset) {
                    dynamic_offset_count += 1;
                }
            }
        }

        return .{
            .label = descriptor.label,
            .entryMap = descriptor.entries,
            .dynamicOffsetCount = dynamic_offset_count,
            .exclusivePipeline = null,
        };
    }

    pub fn destroy(self: *@This()) void {
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }

    pub const ShaderStageFlags = def.ShaderStageFlags;

    pub const ShaderStage = packed struct(u32) {
        vertex: bool = false,
        fragment: bool = false,
        compute: bool = false,

        _: u29 = 0,

        pub const VERTEX: def.FlagsConstant = 0x1;
        pub const FRAGMENT: def.FlagsConstant = 0x2;
        pub const COMPUTE: def.FlagsConstant = 0x4;

        pub fn fromFlags(flags: ShaderStageFlags) ShaderStage {
            return @bitCast(flags);
        }

        pub fn toFlags(self: ShaderStage) ShaderStageFlags {
            return @bitCast(self);
        }
    };

    pub const Entry = struct {
        binding: def.Index32,
        visibility: ShaderStageFlags,

        buffer: ?Buffer = null,
        sampler: ?Sampler = null,
        texture: ?Texture = null,
        storageTexture: ?StorageTexture = null,

        pub const Buffer = struct {
            type: Type = .uniform,
            hasDynamicOffset: bool = false,
            minBindingSize: def.Size64 = 0,

            pub const Type = enum {
                uniform,
                storage,
                read_only_storage,
            };
        };

        pub const Sampler = struct {
            type: Type = .filtering,

            pub const Type = enum {
                filtering,
                non_filtering,
                comparison,
            };
        };

        pub const Texture = struct {
            sampleType: SampleType = .{ .float = .{ .filterable = true } },
            viewDimension: texture_mod.Texture.View.Dimension = .@"2d",
            multisampled: bool = false,

            pub const SampleType = union(enum) {
                float: struct { filterable: bool },
                depth: void,
                sint: void,
                uint: void,
            };
        };

        pub const StorageTexture = struct {
            access: Access = .write_only,
            format: texture_mod.Texture.Format,
            viewDimension: texture_mod.Texture.View.Dimension = .@"2d",

            pub const Access = enum {
                write_only,
                read_only,
                read_write,
            };
        };
    };
};
