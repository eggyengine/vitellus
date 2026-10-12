//! Conversions and small helpers shared by the WebGPU backend.

const std = @import("std");
const c = @import("webgpu_c");
const swapchain_if = @import("../../interface/swapchain.zig");
const resource = @import("../../interface/resource.zig");
const binding = @import("../../interface/binding.zig");
const command = @import("../../interface/command.zig");

pub const log = std.log.scoped(.webgpu);

/// SDL and the default Emscripten shell both render into `#canvas`.
// ponytail: one fixed canvas; read the selector from the window handle if a page needs several.
pub const canvas_selector = "#canvas";
pub const forever = std.math.maxInt(u64);

// ---------------------------------------------------------------------------------------------
// Helpers

pub fn str(s: ?[]const u8) c.WGPUStringView {
    const value = s orelse return .{ .data = null, .length = std.math.maxInt(usize) };
    return .{ .data = value.ptr, .length = value.len };
}

pub fn slice(s: c.WGPUStringView) []const u8 {
    const data = s.data orelse return "";
    return if (s.length == std.math.maxInt(usize)) std.mem.span(data) else data[0..s.length];
}

/// `snake_case` → `PascalCase` at compile time, for enums whose WebGPU names match ours.
pub fn pascal(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (name) |ch| {
            if (ch == '_') {
                upper = true;
            } else {
                out = out ++ .{if (upper) std.ascii.toUpper(ch) else ch};
                upper = false;
            }
        }
        return out;
    }
}

/// Maps a Vitellus enum to the WebGPU constant `prefix ++ PascalCase(tag)`.
pub fn wgpuEnum(comptime prefix: []const u8, value: anytype) c_uint {
    return switch (value) {
        inline else => |tag| @intCast(@field(c, prefix ++ pascal(@tagName(tag)))),
    };
}

/// `std.mem.zeroInit` that also narrows integers: webgpu.h enum constants translate as `c_int`
/// while the struct fields holding them are `c_uint`.
pub fn zeroInit(comptime T: type, init: anytype) T {
    var value = std.mem.zeroes(T);
    inline for (@typeInfo(@TypeOf(init)).@"struct".fields) |field| {
        const Field = @TypeOf(@field(value, field.name));
        const given = @field(init, field.name);
        @field(value, field.name) = if (@typeInfo(Field) == .int and @typeInfo(@TypeOf(given)) == .int) @intCast(given) else given;
    }
    return value;
}

pub fn ptrOf(comptime T: type, handle: u64) *T {
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

pub fn handleOf(ptr: anytype) u64 {
    return @intFromPtr(ptr);
}

pub fn waitFuture(instance: c.WGPUInstance, future: c.WGPUFuture, timeout_ns: u64) !bool {
    var info = c.WGPUFutureWaitInfo{ .future = future, .completed = 0 };
    return switch (c.wgpuInstanceWaitAny(instance, 1, &info, timeout_ns)) {
        c.WGPUWaitStatus_Success => true,
        c.WGPUWaitStatus_TimedOut => false,
        else => error.WaitFailed,
    };
}

pub fn textureFormat(format: resource.Format) !c.WGPUTextureFormat {
    return switch (format) {
        .r8_unorm => c.WGPUTextureFormat_R8Unorm,
        .r8_snorm => c.WGPUTextureFormat_R8Snorm,
        .r8_uint => c.WGPUTextureFormat_R8Uint,
        .r8_sint => c.WGPUTextureFormat_R8Sint,
        .rg8_unorm => c.WGPUTextureFormat_RG8Unorm,
        .rg8_snorm => c.WGPUTextureFormat_RG8Snorm,
        .rg8_uint => c.WGPUTextureFormat_RG8Uint,
        .rg8_sint => c.WGPUTextureFormat_RG8Sint,
        .rgba8_unorm => c.WGPUTextureFormat_RGBA8Unorm,
        .rgba8_snorm => c.WGPUTextureFormat_RGBA8Snorm,
        .rgba8_uint => c.WGPUTextureFormat_RGBA8Uint,
        .rgba8_sint => c.WGPUTextureFormat_RGBA8Sint,
        .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8UnormSrgb,
        .bgra8_unorm => c.WGPUTextureFormat_BGRA8Unorm,
        .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8UnormSrgb,
        .r16_uint => c.WGPUTextureFormat_R16Uint,
        .r16_sint => c.WGPUTextureFormat_R16Sint,
        .r16_float => c.WGPUTextureFormat_R16Float,
        .rg16_uint => c.WGPUTextureFormat_RG16Uint,
        .rg16_sint => c.WGPUTextureFormat_RG16Sint,
        .rg16_float => c.WGPUTextureFormat_RG16Float,
        .rgba16_uint => c.WGPUTextureFormat_RGBA16Uint,
        .rgba16_sint => c.WGPUTextureFormat_RGBA16Sint,
        .rgba16_float => c.WGPUTextureFormat_RGBA16Float,
        .r32_uint => c.WGPUTextureFormat_R32Uint,
        .r32_sint => c.WGPUTextureFormat_R32Sint,
        .r32_float => c.WGPUTextureFormat_R32Float,
        .rg32_uint => c.WGPUTextureFormat_RG32Uint,
        .rg32_sint => c.WGPUTextureFormat_RG32Sint,
        .rg32_float => c.WGPUTextureFormat_RG32Float,
        .rgba32_uint => c.WGPUTextureFormat_RGBA32Uint,
        .rgba32_sint => c.WGPUTextureFormat_RGBA32Sint,
        .rgba32_float => c.WGPUTextureFormat_RGBA32Float,
        .rgb10a2_unorm => c.WGPUTextureFormat_RGB10A2Unorm,
        .rg11b10_float => c.WGPUTextureFormat_RG11B10Ufloat,
        .bc1_rgba_unorm => c.WGPUTextureFormat_BC1RGBAUnorm,
        .bc1_rgba_unorm_srgb => c.WGPUTextureFormat_BC1RGBAUnormSrgb,
        .bc2_rgba_unorm => c.WGPUTextureFormat_BC2RGBAUnorm,
        .bc2_rgba_unorm_srgb => c.WGPUTextureFormat_BC2RGBAUnormSrgb,
        .bc3_rgba_unorm => c.WGPUTextureFormat_BC3RGBAUnorm,
        .bc3_rgba_unorm_srgb => c.WGPUTextureFormat_BC3RGBAUnormSrgb,
        .bc4_r_unorm => c.WGPUTextureFormat_BC4RUnorm,
        .bc4_r_snorm => c.WGPUTextureFormat_BC4RSnorm,
        .bc5_rg_unorm => c.WGPUTextureFormat_BC5RGUnorm,
        .bc5_rg_snorm => c.WGPUTextureFormat_BC5RGSnorm,
        .bc6h_rgb_ufloat => c.WGPUTextureFormat_BC6HRGBUfloat,
        .bc6h_rgb_float => c.WGPUTextureFormat_BC6HRGBFloat,
        .bc7_rgba_unorm => c.WGPUTextureFormat_BC7RGBAUnorm,
        .bc7_rgba_unorm_srgb => c.WGPUTextureFormat_BC7RGBAUnormSrgb,
        .stencil8 => c.WGPUTextureFormat_Stencil8,
        .d16_unorm => c.WGPUTextureFormat_Depth16Unorm,
        // WebGPU only promises "at least 24 bits" of depth with stencil.
        .d24_unorm_s8_uint => c.WGPUTextureFormat_Depth24PlusStencil8,
        .d32_float => c.WGPUTextureFormat_Depth32Float,
        .d32_float_s8_uint => c.WGPUTextureFormat_Depth32FloatStencil8,
        // WebGPU has no 16-bit normalised or three-channel 32-bit formats.
        else => error.FormatUnsupported,
    };
}

pub fn swapchainTextureFormat(format: swapchain_if.SwapchainFormat) c.WGPUTextureFormat {
    return switch (format) {
        .bgra8_unorm => c.WGPUTextureFormat_BGRA8Unorm,
        .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8UnormSrgb,
        .rgba8_unorm => c.WGPUTextureFormat_RGBA8Unorm,
        .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8UnormSrgb,
        .rgba16_float => c.WGPUTextureFormat_RGBA16Float,
    };
}

pub fn hasStencil(format: c.WGPUTextureFormat) bool {
    return format == c.WGPUTextureFormat_Stencil8 or
        format == c.WGPUTextureFormat_Depth24PlusStencil8 or
        format == c.WGPUTextureFormat_Depth32FloatStencil8;
}

pub fn hasDepth(format: c.WGPUTextureFormat) bool {
    return format == c.WGPUTextureFormat_Depth16Unorm or
        format == c.WGPUTextureFormat_Depth24Plus or
        format == c.WGPUTextureFormat_Depth24PlusStencil8 or
        format == c.WGPUTextureFormat_Depth32Float or
        format == c.WGPUTextureFormat_Depth32FloatStencil8;
}

/// Bytes per texel of uncompressed colour formats, for tightly packed uploads.
pub fn texelSize(format: c.WGPUTextureFormat) !u32 {
    return switch (format) {
        c.WGPUTextureFormat_R8Unorm, c.WGPUTextureFormat_R8Snorm, c.WGPUTextureFormat_R8Uint, c.WGPUTextureFormat_R8Sint, c.WGPUTextureFormat_Stencil8 => 1,
        c.WGPUTextureFormat_RG8Unorm, c.WGPUTextureFormat_RG8Snorm, c.WGPUTextureFormat_RG8Uint, c.WGPUTextureFormat_RG8Sint, c.WGPUTextureFormat_R16Uint, c.WGPUTextureFormat_R16Sint, c.WGPUTextureFormat_R16Float, c.WGPUTextureFormat_Depth16Unorm => 2,
        c.WGPUTextureFormat_RG16Uint, c.WGPUTextureFormat_RG16Sint, c.WGPUTextureFormat_RG16Float, c.WGPUTextureFormat_RGBA8Unorm, c.WGPUTextureFormat_RGBA8UnormSrgb, c.WGPUTextureFormat_RGBA8Snorm, c.WGPUTextureFormat_RGBA8Uint, c.WGPUTextureFormat_RGBA8Sint, c.WGPUTextureFormat_BGRA8Unorm, c.WGPUTextureFormat_BGRA8UnormSrgb, c.WGPUTextureFormat_RGB10A2Unorm, c.WGPUTextureFormat_RG11B10Ufloat, c.WGPUTextureFormat_R32Uint, c.WGPUTextureFormat_R32Sint, c.WGPUTextureFormat_R32Float, c.WGPUTextureFormat_Depth32Float => 4,
        c.WGPUTextureFormat_RG32Uint, c.WGPUTextureFormat_RG32Sint, c.WGPUTextureFormat_RG32Float, c.WGPUTextureFormat_RGBA16Uint, c.WGPUTextureFormat_RGBA16Sint, c.WGPUTextureFormat_RGBA16Float => 8,
        c.WGPUTextureFormat_RGBA32Uint, c.WGPUTextureFormat_RGBA32Sint, c.WGPUTextureFormat_RGBA32Float => 16,
        else => error.PassBytesPerRow,
    };
}

pub fn viewDimension(dimension: resource.TextureViewDimension) c.WGPUTextureViewDimension {
    return switch (dimension) {
        .d1 => c.WGPUTextureViewDimension_1D,
        .d2 => c.WGPUTextureViewDimension_2D,
        .d2_array => c.WGPUTextureViewDimension_2DArray,
        .cube => c.WGPUTextureViewDimension_Cube,
        .cube_array => c.WGPUTextureViewDimension_CubeArray,
        .d3 => c.WGPUTextureViewDimension_3D,
        .d1_array => c.WGPUTextureViewDimension_Undefined, // not in WebGPU; validation reports it
    };
}

pub fn aspect(value: resource.TextureAspect) c.WGPUTextureAspect {
    return switch (value) {
        .all, .color => c.WGPUTextureAspect_All,
        .depth => c.WGPUTextureAspect_DepthOnly,
        .stencil => c.WGPUTextureAspect_StencilOnly,
    };
}

pub fn loadOp(op: command.LoadOp) c.WGPULoadOp {
    return switch (op) {
        .load => c.WGPULoadOp_Load,
        // WebGPU cannot leave contents undefined; clearing is the cheap equivalent.
        .clear, .discard => c.WGPULoadOp_Clear,
    };
}

pub fn storeOp(op: command.StoreOp) c.WGPUStoreOp {
    return wgpuEnum("WGPUStoreOp_", op);
}

pub fn visibility(v: binding.ShaderVisibility) c.WGPUShaderStage {
    var out: c.WGPUShaderStage = c.WGPUShaderStage_None;
    if (v.vertex) out |= c.WGPUShaderStage_Vertex;
    if (v.fragment) out |= c.WGPUShaderStage_Fragment;
    if (v.compute) out |= c.WGPUShaderStage_Compute;
    return out;
}

test "snake_case tags map onto WebGPU's PascalCase names" {
    try std.testing.expectEqualStrings("OneMinusSrcAlpha", comptime pascal("one_minus_src_alpha"));
    try std.testing.expectEqualStrings("Float32x3", comptime pascal("float32x3"));
}
