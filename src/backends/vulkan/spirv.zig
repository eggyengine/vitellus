const std = @import("std");
const builtin = @import("builtin");
const shader = @import("../../interface/shader.zig");
const options = @import("shader_options");

/// Only analyzed when `-Denable_spirv-cross` is on.
const spirv_cross = if (options.enable_spirv_cross)
    @import("spirv_cross_compile.zig")
else
    struct {};

/// SPIRV shader module compilation.
///
/// Cross-backend translation requires `-Denable_spirv-cross`.
/// DX12 additionally needs `-Denable_dxc` (SPIR-V → HLSL → DXIL).
///
/// Vulkan uses SPIR-V natively, so neither feature is required for that backend.
pub const SPIRVShaderModule = struct {
    pub const Descriptor = struct {
        code: []const u8,
        entry_point: []const u8 = "main",

        pub fn compile(
            self: *const Descriptor,
            allocator: std.mem.Allocator,
            request: shader.ShaderCompileRequest,
        ) !shader.CompiledShader {
            return switch (request.backend) {
                .vulkan => .{
                    .format = .spirv,
                    .bytes = try allocator.dupe(u8, self.code),
                    .entry_point = self.entry_point,
                },
                .dx12, .metal => if (options.enable_spirv_cross)
                    spirv_cross.compile(self.code, self.entry_point, allocator, request)
                else
                    error.ShaderCompilerUnavailable,
                .custom => error.UnsupportedShaderBackend,
            };
        }
    };

    pub fn init(desc: Descriptor) shader.ShaderModule {
        return shader.ShaderModule.init(desc);
    }
};

test "SPIR-V passes through for Vulkan without a compiler dependency" {
    const module = SPIRVShaderModule.init(.{ .code = &.{ 0x03, 0x02, 0x23, 0x07 } });
    var compiled = try module.compile(std.testing.allocator, .{ .backend = .vulkan, .stage = .compute });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.format.eql(.spirv));
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, compiled.bytes);
}

test "SPIR-V cross-compiles to DXIL for DX12" {
    if (comptime !options.enable_spirv_cross or !options.enable_dxc or builtin.target.os.tag != .windows)
        return error.SkipZigTest;

    const hlsl_mod = @import("../dx12/hlsl_shader_module.zig");

    // HLSL → SPIR-V via DXC, then SPIR-V → DXIL via SPIRV-Cross + DXC.
    const hlsl_desc = hlsl_mod.HLSLShaderModule.Descriptor{
        .code = "float4 main() : SV_Target { return 1; }",
        .entry_point = "main",
        .profile = .ps_6_6,
    };
    var spirv = try hlsl_desc.compile(std.testing.allocator, .{
        .backend = .vulkan,
        .stage = .fragment,
    });
    defer spirv.deinit(std.testing.allocator);
    try std.testing.expect(spirv.format.eql(.spirv));

    const module = SPIRVShaderModule.init(.{
        .code = spirv.bytes,
        .entry_point = "main",
    });
    var dxil = try module.compile(std.testing.allocator, .{
        .backend = .dx12,
        .stage = .fragment,
    });
    defer dxil.deinit(std.testing.allocator);

    try std.testing.expect(dxil.format.eql(.dxil));
    try std.testing.expectEqualStrings("DXBC", dxil.bytes[0..4]);
}
