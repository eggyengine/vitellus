//! `vitellus_slangc`: compiles Slang at runtime with the Slang shared library. Enable it with
//! `-Denable_slang`; `installLibraries` puts the library beside your app.
const std = @import("std");
const builtin = @import("builtin");
const vit = @import("vitellus");
const options = @import("slang_options");

/// Slang source, compiled for whichever backend is running: SPIR-V for Vulkan, DXIL for DirectX 12
/// (Slang loads DXC for this) and WGSL for WebGPU.
pub const SlangShaderModule = struct {
    pub const Descriptor = struct {
        code: []const u8,
        entry_point: []const u8,

        pub fn compile(self: *const Descriptor, allocator: std.mem.Allocator, request: vit.ShaderCompileRequest) !vit.CompiledShader {
            const target: Target, const format: vit.ShaderBinaryFormat = switch (request.backend) {
                .vulkan => .{ .spirv, .spirv },
                .dx12 => .{ .dxil, .dxil },
                .webgpu => .{ .wgsl, .wgsl },
                .metal, .custom => return error.UnsupportedShaderBackend,
            };
            const stage: Stage = switch (request.stage) {
                .vertex => .vertex,
                .fragment => .fragment,
                .compute => .compute,
            };
            // Slang renames the entry point to `main` for SPIR-V.
            const entry_point = if (target == .spirv) "main" else self.entry_point;
            return .{ .format = format, .bytes = try compileSource(allocator, self.code, self.entry_point, stage, target), .entry_point = entry_point };
        }
    };

    pub fn init(desc: Descriptor) vit.ShaderModule {
        return vit.ShaderModule.init(desc);
    }
};

pub const Stage = enum(u32) { vertex = 1, fragment = 5, compute = 6 };
pub const Target = enum(u32) { spirv = 6, dxil = 10, wgsl = 28 };

/// Compiles one entry point of Slang `source`. The caller owns the returned bytes.
pub fn compileSource(allocator: std.mem.Allocator, source: []const u8, entry_point: []const u8, stage: Stage, target: Target) ![]u8 {
    if (comptime !options.available) return error.ShaderCompilerUnavailable;
    // Found through the app's rpath (lib/ beside bin/, then the package cache), or beside the exe on Windows.
    var lib = vit.DynLib.open(switch (builtin.os.tag) {
        .windows => "slang-compiler.dll",
        .macos => "@rpath/libslang-compiler.dylib",
        else => "libslang-compiler.so",
    }) catch return error.ShaderCompilerUnavailable;
    defer lib.close();
    // ponytail: Slang's compatibility C ABI keeps this wrapper small; switch to a C++ bridge if Slang removes it.
    const create_session = try symbol(*const fn (?[*:0]const u8) callconv(.c) ?*anyopaque, &lib, "spCreateSession");
    const destroy_session = try symbol(*const fn (*anyopaque) callconv(.c) void, &lib, "spDestroySession");
    const create_request = try symbol(*const fn (*anyopaque) callconv(.c) ?*anyopaque, &lib, "spCreateCompileRequest");
    const destroy_request = try symbol(*const fn (*anyopaque) callconv(.c) void, &lib, "spDestroyCompileRequest");
    const set_target = try symbol(*const fn (*anyopaque, u32) callconv(.c) void, &lib, "spSetCodeGenTarget");
    const add_unit = try symbol(*const fn (*anyopaque, u32, ?[*:0]const u8) callconv(.c) c_int, &lib, "spAddTranslationUnit");
    const add_source = try symbol(*const fn (*anyopaque, c_int, [*:0]const u8, [*:0]const u8) callconv(.c) void, &lib, "spAddTranslationUnitSourceString");
    const add_entry = try symbol(*const fn (*anyopaque, c_int, [*:0]const u8, u32) callconv(.c) c_int, &lib, "spAddEntryPoint");
    const compile_request = try symbol(*const fn (*anyopaque) callconv(.c) c_int, &lib, "spCompile");
    const diagnostics = try symbol(*const fn (*anyopaque) callconv(.c) ?[*:0]const u8, &lib, "spGetDiagnosticOutput");
    const get_code = try symbol(*const fn (*anyopaque, c_int, *usize) callconv(.c) ?*const anyopaque, &lib, "spGetEntryPointCode");

    const session = create_session(null) orelse return error.SlangInitializationFailed;
    defer destroy_session(session);
    const request = create_request(session) orelse return error.SlangInitializationFailed;
    defer destroy_request(request);
    set_target(request, @intFromEnum(target));
    const unit = add_unit(request, 1, null); // SLANG_SOURCE_LANGUAGE_SLANG
    if (unit < 0) return error.ShaderCompilationFailed;
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    const entry_z = try allocator.dupeZ(u8, entry_point);
    defer allocator.free(entry_z);
    add_source(request, unit, "shader.slang", source_z);
    const index = add_entry(request, unit, entry_z, @intFromEnum(stage));
    if (index < 0) return error.ShaderCompilationFailed;
    if (compile_request(request) < 0) {
        if (diagnostics(request)) |message| std.log.scoped(.slang).err("{s}", .{std.mem.span(message)});
        return error.ShaderCompilationFailed;
    }
    var len: usize = 0;
    const code: [*]const u8 = @ptrCast(get_code(request, index, &len) orelse return error.ShaderCompilationFailed);
    return allocator.dupe(u8, code[0..len]);
}

fn symbol(comptime T: type, lib: *vit.DynLib, comptime name: [:0]const u8) !T {
    return lib.lookup(T, name) orelse error.MissingSlangSymbol;
}

test "Slang compiles to SPIR-V and WGSL" {
    if (comptime !options.available) return error.SkipZigTest;
    const source =
        \\[shader("vertex")] float4 vertexMain(uint id : SV_VertexID) : SV_Position { return float4(float(id), 0, 0, 1); }
    ;
    const spirv = try compileSource(std.testing.allocator, source, "vertexMain", .vertex, .spirv);
    defer std.testing.allocator.free(spirv);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, spirv[0..4]);
    try std.testing.expect(std.mem.indexOf(u8, spirv, "main\x00") != null);
    const wgsl = try compileSource(std.testing.allocator, source, "vertexMain", .vertex, .wgsl);
    defer std.testing.allocator.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vertexMain") != null);
}
