//! `vitellus_spirv`: SPIR-V shaders. Vulkan takes them as is. With `-Denable_spirv_cross` (which
//! needs `-Denable_dxc`), DirectX 12 runs them too: SPIRV-Cross translates them to HLSL and DXC
//! compiles that to DXIL.
const std = @import("std");
const vit = @import("vitellus");
const options = @import("spirv_options");
const cross = if (options.cross) @import("cross.zig") else struct {};

pub const SPIRVShaderModule = struct {
    pub const Descriptor = struct {
        code: []const u8,
        entry_point: []const u8 = "main",

        pub fn compile(
            self: *const Descriptor,
            allocator: std.mem.Allocator,
            request: vit.ShaderCompileRequest,
        ) !vit.CompiledShader {
            return switch (request.backend) {
                .vulkan => .{
                    .format = .spirv,
                    .bytes = try allocator.dupe(u8, self.code),
                    .entry_point = self.entry_point,
                },
                .dx12 => if (options.cross) cross.compileDx12(self.code, self.entry_point, allocator, request) else error.ShaderCompilerUnavailable,
                .metal, .webgpu => error.UnsupportedShaderBackend,
            };
        }
    };

    pub fn init(desc: Descriptor) vit.ShaderModule {
        return vit.ShaderModule.init(desc);
    }
};

test "SPIR-V passes through for Vulkan without a compiler dependency" {
    const module = SPIRVShaderModule.init(.{ .code = &.{ 0x03, 0x02, 0x23, 0x07 } });
    var compiled = try module.compile(std.testing.allocator, .{ .backend = .vulkan, .stage = .compute });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.format == .spirv);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, compiled.bytes);
}

test "SPIR-V cross-compiles to DXIL for DX12" {
    if (comptime !options.cross) return error.SkipZigTest;
    const hlsl_mod = @import("vitellus_dxc");

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
    try std.testing.expect(spirv.format == .spirv);

    const module = SPIRVShaderModule.init(.{
        .code = spirv.bytes,
        .entry_point = "main",
    });
    var dxil = try module.compile(std.testing.allocator, .{
        .backend = .dx12,
        .stage = .fragment,
    });
    defer dxil.deinit(std.testing.allocator);

    try std.testing.expect(dxil.format == .dxil);
    try std.testing.expectEqualStrings("DXBC", dxil.bytes[0..4]);
}
