const std = @import("std");
const c = @import("spirv_cross");
const errors = @import("../error.zig");

pub const Error = errors.SPIRVcError;
const check = errors.check;

pub const RootConstants = c.spvc_hlsl_root_constants;
pub const VertexAttributeRemap = c.spvc_hlsl_vertex_attribute_remap;
pub const ResourceBindingMapping = c.spvc_hlsl_resource_binding_mapping;
pub const ResourceBinding = c.spvc_hlsl_resource_binding;

pub const push_constant_desc_set = c.SPVC_HLSL_PUSH_CONSTANT_DESC_SET;
pub const push_constant_binding = c.SPVC_HLSL_PUSH_CONSTANT_BINDING;

pub const BindingFlags = packed struct {
    bits: c.spvc_hlsl_binding_flags = none,

    pub const none: c.spvc_hlsl_binding_flags = c.SPVC_HLSL_BINDING_AUTO_NONE_BIT;
    pub const push_constant: c.spvc_hlsl_binding_flags = c.SPVC_HLSL_BINDING_AUTO_PUSH_CONSTANT_BIT;
    pub const cbv: c.spvc_hlsl_binding_flags = c.SPVC_HLSL_BINDING_AUTO_CBV_BIT;
    pub const srv: c.spvc_hlsl_binding_flags = c.SPVC_HLSL_BINDING_AUTO_SRV_BIT;
    pub const uav: c.spvc_hlsl_binding_flags = c.SPVC_HLSL_BINDING_AUTO_UAV_BIT;
    pub const sampler: c.spvc_hlsl_binding_flags = c.SPVC_HLSL_BINDING_AUTO_SAMPLER_BIT;
    pub const all: c.spvc_hlsl_binding_flags = c.SPVC_HLSL_BINDING_AUTO_ALL;

    pub fn init(bits: c.spvc_hlsl_binding_flags) BindingFlags {
        return .{ .bits = bits };
    }

    pub fn toC(self: BindingFlags) c.spvc_hlsl_binding_flags {
        return self.bits;
    }
};

pub const Option = enum(c.spvc_compiler_option) {
    shader_model = c.SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL,
    point_size_compat = c.SPVC_COMPILER_OPTION_HLSL_POINT_SIZE_COMPAT,
    point_coord_compat = c.SPVC_COMPILER_OPTION_HLSL_POINT_COORD_COMPAT,
    support_nonzero_base_vertex_base_instance = c.SPVC_COMPILER_OPTION_HLSL_SUPPORT_NONZERO_BASE_VERTEX_BASE_INSTANCE,
    force_storage_buffer_as_uav = c.SPVC_COMPILER_OPTION_HLSL_FORCE_STORAGE_BUFFER_AS_UAV,
    nonwritable_uav_texture_as_srv = c.SPVC_COMPILER_OPTION_HLSL_NONWRITABLE_UAV_TEXTURE_AS_SRV,
    enable_16bit_types = c.SPVC_COMPILER_OPTION_HLSL_ENABLE_16BIT_TYPES,
    flatten_matrix_vertex_input_semantics = c.SPVC_COMPILER_OPTION_HLSL_FLATTEN_MATRIX_VERTEX_INPUT_SEMANTICS,
    use_entry_point_name = c.SPVC_COMPILER_OPTION_HLSL_USE_ENTRY_POINT_NAME,
    preserve_structured_buffers = c.SPVC_COMPILER_OPTION_HLSL_PRESERVE_STRUCTURED_BUFFERS,
    user_semantic = c.SPVC_COMPILER_OPTION_HLSL_USER_SEMANTIC,

    pub fn toC(self: Option) c.spvc_compiler_option {
        return @intFromEnum(self);
    }
};

pub const Options = struct {
    inner: c.spvc_compiler_options = undefined,

    pub fn setBool(self: @This(), option: Option, value: bool) Error!void {
        try check(c.spvc_compiler_options_set_bool(
            self.inner,
            option.toC(),
            if (value) c.SPVC_TRUE else c.SPVC_FALSE,
        ));
    }

    pub fn setUInt(self: @This(), option: Option, value: c_uint) Error!void {
        try check(c.spvc_compiler_options_set_uint(self.inner, option.toC(), value));
    }
};

pub const Compiler = struct {
    inner: c.spvc_compiler = undefined,

    pub fn createOptions(self: @This()) Error!Options {
        var options: c.spvc_compiler_options = undefined;
        try check(c.spvc_compiler_create_compiler_options(self.inner, &options));
        return .{ .inner = options };
    }

    pub fn installOptions(self: @This(), options: Options) Error!void {
        try check(c.spvc_compiler_install_compiler_options(self.inner, options.inner));
    }

    pub fn setRootConstantsLayout(
        self: @This(),
        constant_info: []const RootConstants,
    ) Error!void {
        try check(c.spvc_compiler_hlsl_set_root_constants_layout(
            self.inner,
            constant_info.ptr,
            constant_info.len,
        ));
    }

    pub fn addVertexAttributeRemap(
        self: @This(),
        remaps: []const VertexAttributeRemap,
    ) Error!void {
        try check(c.spvc_compiler_hlsl_add_vertex_attribute_remap(
            self.inner,
            remaps.ptr,
            remaps.len,
        ));
    }

    pub fn remapNumWorkgroupsBuiltin(self: @This()) c.spvc_variable_id {
        return c.spvc_compiler_hlsl_remap_num_workgroups_builtin(self.inner);
    }

    pub fn setResourceBindingFlags(
        self: @This(),
        flags: BindingFlags,
    ) Error!void {
        try check(c.spvc_compiler_hlsl_set_resource_binding_flags(self.inner, flags.toC()));
    }

    pub fn addResourceBinding(
        self: @This(),
        binding: ResourceBinding,
    ) Error!void {
        try check(c.spvc_compiler_hlsl_add_resource_binding(self.inner, &binding));
    }

    pub fn isResourceUsed(
        self: @This(),
        model: c.SpvExecutionModel,
        set: c_uint,
        binding: c_uint,
    ) bool {
        return c.spvc_compiler_hlsl_is_resource_used(self.inner, model, set, binding) != c.SPVC_FALSE;
    }

    pub fn bufferIsCounterBuffer(self: @This(), id: c.spvc_variable_id) bool {
        return c.spvc_compiler_buffer_is_hlsl_counter_buffer(self.inner, id) != c.SPVC_FALSE;
    }

    pub fn bufferGetCounterBuffer(self: @This(), id: c.spvc_variable_id) ?c.spvc_variable_id {
        var counter_id: c.spvc_variable_id = undefined;
        if (c.spvc_compiler_buffer_get_hlsl_counter_buffer(self.inner, id, &counter_id) == c.SPVC_FALSE) {
            return null;
        }

        return counter_id;
    }
};

pub fn initResourceBinding() ResourceBinding {
    var binding: ResourceBinding = undefined;
    c.spvc_hlsl_resource_binding_init(&binding);
    return binding;
}

test "hlsl wrapper types" {
    try std.testing.expectEqual(BindingFlags.all, BindingFlags.init(BindingFlags.all).toC());
    try std.testing.expectEqual(
        @as(c.spvc_compiler_option, c.SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL),
        Option.shader_model.toC(),
    );
    try std.testing.expect(@hasDecl(Compiler, "setRootConstantsLayout"));
}
