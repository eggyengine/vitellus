const std = @import("std");
const shader = @import("../../interface/shader.zig");
const options = @import("shader_options");

/// SPIRV shader module compilation.
///
/// This requires the feature `-Denable_spirv-cross` if you wish to compile for other backends.
/// Vulkan uses SPIR-V natively, so the feature is not required for that backend.
pub const SPIRVShaderModule = struct {
    pub const Descriptor = struct {
        code: []const u8,
        entry_point: []const u8 = "main",

        pub fn compile(
            self: *const Descriptor,
            allocator: std.mem.Allocator,
            request: shader.ShaderCompileRequest,
        ) anyerror!shader.CompiledShader {
            return switch (request.backend) {
                .vulkan => .{
                    .format = .spirv,
                    .bytes = try allocator.dupe(u8, self.code),
                    .entry_point = self.entry_point,
                },
                .dx12, .metal => if (options.enable_spirv_cross)
                    error.SpirvCrossTranslationNotImplemented
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
