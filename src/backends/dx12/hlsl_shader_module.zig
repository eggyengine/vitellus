//! HLSL shader module and DX12-oriented shader model profiles.

const std = @import("std");
const builtin = @import("builtin");
const shader = @import("../../interface/shader.zig");
const dxc = @import("dxc.zig");
const options = @import("shader_options");

const CompiledShader = shader.CompiledShader;
const ShaderCompileRequest = shader.ShaderCompileRequest;
const ShaderModule = shader.ShaderModule;
const log = std.log.scoped(.dxc);

pub const HLSLProfile = enum {
    vs_6_0,
    vs_6_1,
    vs_6_2,
    vs_6_3,
    vs_6_4,
    vs_6_5,
    vs_6_6,
    vs_6_7,
    ps_6_0,
    ps_6_1,
    ps_6_2,
    ps_6_3,
    ps_6_4,
    ps_6_5,
    ps_6_6,
    ps_6_7,
    cs_6_0,
    cs_6_1,
    cs_6_2,
    cs_6_3,
    cs_6_4,
    cs_6_5,
    cs_6_6,
    cs_6_7,
    gs_6_0,
    hs_6_0,
    ds_6_0,
    ms_6_5,
    ms_6_6,
    ms_6_7,
    as_6_5,
    as_6_6,
    as_6_7,
    lib_6_3,
    lib_6_4,
    lib_6_5,
    lib_6_6,
    lib_6_7,

    pub fn name(self: HLSLProfile) []const u8 {
        return @tagName(self);
    }

    pub fn supportsStage(self: HLSLProfile, stage: shader.ShaderStage) bool {
        if (std.mem.startsWith(u8, self.name(), "lib_")) return true;
        const prefix: []const u8 = switch (stage) {
            .vertex => "vs_",
            .fragment => "ps_",
            .compute => "cs_",
        };
        return std.mem.startsWith(u8, self.name(), prefix);
    }
};

/// HLSL shader module compilation backed by the [DirectX Shader Compiler](https://github.com/microsoft/directxshadercompiler).
///
/// This requires the feature `-Denable_dxc`. If you do not wish to bundle `dxc` libraries,
/// you might prefer to use `vit.BinaryShaderModule`, which allows for DXIL shaders instead.
///
/// It is currently only supported on Windows.
pub const HLSLShaderModule = struct {
    pub const Descriptor = struct {
        code: []const u8,
        entry_point: []const u8 = "main",
        profile: HLSLProfile,

        pub fn compile(
            self: *const Descriptor,
            allocator: std.mem.Allocator,
            request: ShaderCompileRequest,
        ) anyerror!CompiledShader {
            if (comptime !options.enable_dxc) return error.ShaderCompilerUnavailable;
            const format: shader.ShaderBinaryFormat = switch (request.backend) {
                .dx12 => .dxil,
                .vulkan => .spirv,
                .metal => return error.ShaderCompilerUnavailable,
                .custom => return error.UnsupportedShaderBackend,
            };
            if (comptime builtin.target.os.tag != .windows) return error.ShaderCompilerUnavailable;
            if (!self.profile.supportsStage(request.stage)) return error.ShaderProfileStageMismatch;

            var raw_compiler: ?*anyopaque = null;
            try checkHr(dxc.DxcCreateInstance(
                &dxc.CLSID_DxcCompiler,
                &dxc.IID_IDxcCompiler3,
                &raw_compiler,
            ));
            const compiler: *dxc.IDxcCompiler3 = @ptrCast(@alignCast(raw_compiler orelse return error.ShaderCompilerUnavailable));
            defer _ = compiler.lpVtbl.Release(compiler);

            const entry_point = try std.unicode.utf8ToUtf16LeAllocZ(allocator, self.entry_point);
            defer allocator.free(entry_point);
            const profile = try std.unicode.utf8ToUtf16LeAllocZ(allocator, self.profile.name());
            defer allocator.free(profile);

            const L = std.unicode.utf8ToUtf16LeStringLiteral;
            var arguments = [_][*:0]const u16{
                L("-E"),   entry_point.ptr,
                L("-T"),   profile.ptr,
                L("-HV"),  L("2021"),
                L("-O3"),  undefined,
                undefined,
            };
            var argument_count: u32 = 7;
            if (format == .spirv) {
                arguments[7] = L("-spirv");
                arguments[8] = L("-fspv-target-env=vulkan1.3");
                argument_count = arguments.len;
            }

            const source: dxc.DxcBuffer = .{
                .Ptr = self.code.ptr,
                .Size = self.code.len,
                .Encoding = dxc.DXC_CP_UTF8,
            };
            var raw_result: ?*anyopaque = null;
            try checkHr(compiler.lpVtbl.Compile(
                compiler,
                &source,
                &arguments,
                argument_count,
                null,
                &dxc.IID_IDxcResult,
                &raw_result,
            ));
            const result: *dxc.IDxcResult = @ptrCast(@alignCast(raw_result orelse return error.ShaderCompilationFailed));
            defer _ = result.lpVtbl.Release(result);

            var status: dxc.HRESULT = 0;
            try checkHr(result.lpVtbl.GetStatus(result, &status));
            logDiagnostics(result, status < 0);
            if (status < 0) return error.ShaderCompilationFailed;

            var object: ?*dxc.IDxcBlob = null;
            try checkHr(result.lpVtbl.GetResult(result, &object));
            const blob = object orelse return error.InvalidShaderCompilerOutput;
            defer _ = blob.lpVtbl.Release(blob);

            const byte_count = blob.lpVtbl.GetBufferSize(blob);
            const data = blob.lpVtbl.GetBufferPointer(blob) orelse return error.InvalidShaderCompilerOutput;
            const bytes = try allocator.alloc(u8, byte_count);
            @memcpy(bytes, @as([*]const u8, @ptrCast(data))[0..byte_count]);

            return .{
                .format = format,
                .bytes = bytes,
                .entry_point = self.entry_point,
            };
        }
    };

    pub fn init(desc: Descriptor) ShaderModule {
        return ShaderModule.init(desc);
    }
};

fn checkHr(hr: dxc.HRESULT) !void {
    if (hr < 0) return error.ShaderCompilerCallFailed;
}

fn logDiagnostics(result: *dxc.IDxcResult, failed: bool) void {
    var diagnostics: ?*dxc.IDxcBlob = null;
    if (result.lpVtbl.GetErrorBuffer(result, &diagnostics) < 0) return;
    const blob = diagnostics orelse return;
    defer _ = blob.lpVtbl.Release(blob);

    const byte_count = blob.lpVtbl.GetBufferSize(blob);
    if (byte_count == 0) return;
    const data = blob.lpVtbl.GetBufferPointer(blob) orelse return;
    const message = std.mem.trimEnd(u8, @as([*]const u8, @ptrCast(data))[0..byte_count], "\x00\r\n");
    if (failed) {
        log.err("HLSL compilation failed: {s}", .{message});
    } else {
        log.warn("HLSL compilation diagnostics: {s}", .{message});
    }
}

test "HLSL module compiles DXIL as an inline temporary" {
    if (!options.enable_dxc or builtin.target.os.tag != .windows) return error.SkipZigTest;

    const module = HLSLShaderModule.init(.{
        .code = "float4 main() : SV_Target { return 1; }",
        .entry_point = "main",
        .profile = .ps_6_7,
    });

    var compiled = try module.compile(std.testing.allocator, .{
        .backend = .dx12,
        .stage = .fragment,
    });
    defer compiled.deinit(std.testing.allocator);

    try std.testing.expect(compiled.format.eql(.dxil));
    try std.testing.expectEqualStrings("DXBC", compiled.bytes[0..4]);
}

test "HLSL module compiles SPIR-V" {
    if (!options.enable_dxc or builtin.target.os.tag != .windows) return error.SkipZigTest;

    const module = HLSLShaderModule.init(.{
        .code = "float4 main() : SV_Target { return 1; }",
        .entry_point = "main",
        .profile = .ps_6_7,
    });

    var compiled = try module.compile(std.testing.allocator, .{
        .backend = .vulkan,
        .stage = .fragment,
    });
    defer compiled.deinit(std.testing.allocator);

    try std.testing.expect(compiled.format.eql(.spirv));
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, compiled.bytes[0..4]);
}
