const hal = @import("../backends/hal.zig");

pub const Sampler = struct {
    backend: ?hal.Sampler = null,
    descriptor: Descriptor,
    isComparison: bool,
    isFiltering: bool,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        addressModeU: AddressMode = .clamp_to_edge,
        addressModeV: AddressMode = .clamp_to_edge,
        addressModeW: AddressMode = .clamp_to_edge,
        magFilter: FilterMode = .nearest,
        minFilter: FilterMode = .nearest,
        mipmapFilter: MipmapFilterMode = .nearest,
        lodMinClamp: f32 = 0,
        lodMaxClamp: f32 = 32,
        compare: ?CompareFunction = null,
        maxAnisotropy: u16 = 1,
    };

    pub fn init(descriptor: Descriptor) Sampler {
        return .{
            .descriptor = descriptor,
            .isComparison = descriptor.compare != null,
            .isFiltering = descriptor.magFilter == .linear or
                descriptor.minFilter == .linear or
                descriptor.mipmapFilter == .linear or
                descriptor.maxAnisotropy > 1,
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

    pub const AddressMode = enum {
        clamp_to_edge,
        repeat,
        mirror_repeat,
    };

    pub const FilterMode = enum {
        nearest,
        linear,
    };

    pub const MipmapFilterMode = FilterMode;

    pub const CompareFunction = enum {
        never,
        less,
        equal,
        less_equal,
        greater,
        not_equal,
        greater_equal,
        always,
    };
};
