//! DirectX 12 shader entry points.
//!
//! D3D12 does not expose a standalone shader object. Compiled DXIL is retained
//! here and supplied as `D3D12_SHADER_BYTECODE` when a pipeline is created.

const std = @import("std");
const shader = @import("../../interface/shader.zig");
const spirv_reflect = @import("../spirv_reflect.zig");

const log = std.log.scoped(.dx12_shader);

pub const Dx12Shader = struct {
    allocator: std.mem.Allocator,
    bytecode: []u8,
    stage: shader.ShaderStage,
    bindings: []spirv_reflect.ReflectedBinding = &.{},
    label: ?[]u8 = null,

    pub fn fromHandle(value: shader.Shader) !*Dx12Shader {
        if (value.handle == 0) return error.InvalidShader;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const vtable: shader.Shader.VTable = .{ .deinitFn = destroy };

pub fn create(_: *anyopaque, allocator: std.mem.Allocator, desc: shader.ShaderDescriptor) anyerror!shader.Shader {
    var compiled = try desc.source.compile(allocator, .{
        .backend = .dx12,
        .stage = desc.stage,
        .label = desc.label,
    });
    errdefer compiled.deinit(allocator);

    if (!compiled.format.eql(.dxil)) return error.UnsupportedShaderFormat;

    const bindings = if (compiled.reflection_spirv) |spirv|
        try spirv_reflect.reflectBindingsBytes(allocator, spirv, desc.stage)
    else
        @as([]spirv_reflect.ReflectedBinding, &.{});
    errdefer if (bindings.len != 0) allocator.free(bindings);

    const dx_shader = try allocator.create(Dx12Shader);
    errdefer allocator.destroy(dx_shader);
    const label = if (desc.label) |value| try allocator.dupe(u8, value) else null;
    errdefer if (label) |value| allocator.free(value);

    // Take ownership of DXIL bytes; drop optional reflection SPIR-V.
    const bytecode = compiled.bytes;
    if (compiled.reflection_spirv) |spirv| allocator.free(spirv);
    compiled = undefined;

    dx_shader.* = .{
        .allocator = allocator,
        .bytecode = bytecode,
        .stage = desc.stage,
        .bindings = bindings,
        .label = label,
    };

    log.debug("created DX12 {s} shader with {} bytes of DXIL", .{
        @tagName(desc.stage),
        bytecode.len,
    });
    return .{ .handle = @intCast(@intFromPtr(dx_shader)), .vtable = &vtable };
}

pub fn destroy(value: shader.Shader) void {
    const dx_shader = Dx12Shader.fromHandle(value) catch return;
    const allocator = dx_shader.allocator;
    allocator.free(dx_shader.bytecode);
    if (dx_shader.bindings.len != 0) allocator.free(dx_shader.bindings);
    if (dx_shader.label) |label| allocator.free(label);
    log.debug("destroyed DX12 {s} shader", .{@tagName(dx_shader.stage)});
    allocator.destroy(dx_shader);
}

test "DX12 shaders retain compiled bytecode until destroyed" {
    const value = try create(undefined, std.testing.allocator, .{
        .label = "test shader",
        .stage = .vertex,
        .source = shader.BinaryShaderModule.init(.{
            .backend = .dx12,
            .format = .dxil,
            .bytes = "DXBC-test-bytecode",
        }),
    });
    defer value.deinit();

    const dx_shader = try Dx12Shader.fromHandle(value);
    try std.testing.expectEqual(shader.ShaderStage.vertex, dx_shader.stage);
    try std.testing.expectEqualStrings("DXBC-test-bytecode", dx_shader.bytecode);
}
