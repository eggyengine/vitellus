//! SPIR-V → HLSL via the SPIRV-Cross C API, then DXIL via DXC for DX12.

const std = @import("std");
const shader = @import("../../interface/shader.zig");
const options = @import("shader_options");
const hlsl_mod = @import("../dx12/hlsl_shader_module.zig");

const spvc = @cImport({
    @cInclude("spirv_cross_c.h");
});

const log = std.log.scoped(.spirv_cross);

pub fn compile(
    code: []const u8,
    entry_point: []const u8,
    allocator: std.mem.Allocator,
    request: shader.ShaderCompileRequest,
) !shader.CompiledShader {
    return switch (request.backend) {
        .dx12 => try compileDx12(code, entry_point, allocator, request),
        .metal => error.SpirvCrossTranslationNotImplemented,
        .vulkan, .custom => unreachable,
    };
}

fn compileDx12(
    code: []const u8,
    entry_point: []const u8,
    allocator: std.mem.Allocator,
    request: shader.ShaderCompileRequest,
) !shader.CompiledShader {
    if (comptime !options.enable_dxc) return error.ShaderCompilerUnavailable;

    const hlsl = try translateToHlsl(code, entry_point, request.stage, allocator);
    defer allocator.free(hlsl);

    const profile: hlsl_mod.HLSLProfile = switch (request.stage) {
        .vertex => .vs_6_6,
        .fragment => .ps_6_6,
        .compute => .cs_6_6,
    };

    const desc = hlsl_mod.HLSLShaderModule.Descriptor{
        .code = hlsl,
        .entry_point = entry_point,
        .profile = profile,
    };
    var compiled = try desc.compile(allocator, request);
    errdefer compiled.deinit(allocator);

    // Keep original SPIR-V so DX12 can reflect bind-group layouts.
    compiled.reflection_spirv = try allocator.dupe(u8, code);
    return compiled;
}

fn translateToHlsl(
    code: []const u8,
    entry_point: []const u8,
    stage: shader.ShaderStage,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (code.len == 0 or code.len % @sizeOf(spvc.SpvId) != 0) return error.InvalidSpirv;

    const words = try allocator.alloc(spvc.SpvId, code.len / @sizeOf(spvc.SpvId));
    defer allocator.free(words);
    @memcpy(std.mem.sliceAsBytes(words), code);

    var context: spvc.spvc_context = null;
    try check(spvc.spvc_context_create(&context), null);
    defer spvc.spvc_context_destroy(context);

    spvc.spvc_context_set_error_callback(context, errorCallback, null);

    var ir: spvc.spvc_parsed_ir = null;
    try check(spvc.spvc_context_parse_spirv(context, words.ptr, words.len, &ir), context);

    var compiler: spvc.spvc_compiler = null;
    try check(spvc.spvc_context_create_compiler(
        context,
        spvc.SPVC_BACKEND_HLSL,
        ir,
        spvc.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
        &compiler,
    ), context);

    var opts: spvc.spvc_compiler_options = null;
    try check(spvc.spvc_compiler_create_compiler_options(compiler, &opts), context);
    // Match DXC profiles vs_6_6 / ps_6_6 / cs_6_6.
    try check(spvc.spvc_compiler_options_set_uint(opts, spvc.SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL, 66), context);
    try check(spvc.spvc_compiler_options_set_bool(opts, spvc.SPVC_COMPILER_OPTION_HLSL_USE_ENTRY_POINT_NAME, spvc.SPVC_TRUE), context);
    try check(spvc.spvc_compiler_install_compiler_options(compiler, opts), context);

    const entry_z = try allocator.dupeZ(u8, entry_point);
    defer allocator.free(entry_z);
    try check(spvc.spvc_compiler_set_entry_point(compiler, entry_z.ptr, executionModel(stage)), context);

    var source: [*c]const u8 = null;
    try check(spvc.spvc_compiler_compile(compiler, &source), context);
    if (source == null) return error.SpirvCrossFailed;
    return allocator.dupe(u8, std.mem.span(source));
}

fn executionModel(stage: shader.ShaderStage) spvc.SpvExecutionModel {
    return switch (stage) {
        .vertex => spvc.SpvExecutionModelVertex,
        .fragment => spvc.SpvExecutionModelFragment,
        .compute => spvc.SpvExecutionModelGLCompute,
    };
}

fn errorCallback(_: ?*anyopaque, message: [*c]const u8) callconv(.c) void {
    if (message == null) return;
    log.err("{s}", .{std.mem.span(message)});
}

fn check(result: spvc.spvc_result, context: ?spvc.spvc_context) !void {
    if (result == spvc.SPVC_SUCCESS) return;
    if (context) |ctx| {
        const message = std.mem.span(spvc.spvc_context_get_last_error_string(ctx));
        if (message.len != 0) log.err("SPIRV-Cross failed: {s}", .{message});
    }
    return switch (result) {
        spvc.SPVC_ERROR_INVALID_SPIRV => error.InvalidSpirv,
        spvc.SPVC_ERROR_UNSUPPORTED_SPIRV => error.UnsupportedSpirv,
        spvc.SPVC_ERROR_OUT_OF_MEMORY => error.OutOfMemory,
        spvc.SPVC_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
        else => error.SpirvCrossFailed,
    };
}
