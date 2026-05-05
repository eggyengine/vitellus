const def = @import("def.zig");
const texture = @import("texture.zig");

pub const BindGroupLayout = struct {
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
        externalTexture: ?ExternalTexture = null,

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
            sampleType: SampleType = .float,
            viewDimension: texture.Texture.View.Dimension = .@"2d",
            multisampled: bool = false,

            pub const SampleType = enum {
                float,
                unfilterable_float,
                depth,
                sint,
                uint,
            };
        };

        pub const StorageTexture = struct {
            access: Access = .write_only,
            format: texture.Texture.Format,
            viewDimension: texture.Texture.View.Dimension = .@"2d",

            pub const Access = enum {
                write_only,
                read_only,
                read_write,
            };
        };

        pub const ExternalTexture = struct {};
    };
};
