const bind_group_layout = @import("bind_group_layout.zig");

pub const PipelineLayout = struct {
    label: ?[*:0]const u8,
    bindGroupLayouts: []const ?*const bind_group_layout.BindGroupLayout,

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        bindGroupLayouts: []const ?*const bind_group_layout.BindGroupLayout,
    };

    pub fn init(descriptor: Descriptor) PipelineLayout {
        return .{
            .label = descriptor.label,
            .bindGroupLayouts = descriptor.bindGroupLayouts,
        };
    }
};
