//! DirectX 12 shader entry points.
//!
//! D3D12 does not expose a standalone shader object. Compiled DXIL is retained
//! here and supplied as `D3D12_SHADER_BYTECODE` when a pipeline is created.

const std = @import("std");
const shader = @import("../../interface/shader.zig");

const log = std.log.scoped(.dx12_shader);

pub const Dx12Shader = struct {
    allocator: std.mem.Allocator,
    bytecode: []u8,
    stage: shader.ShaderStage,

    pub fn fromHandle(value: shader.Shader) !*Dx12Shader {
        if (value.handle == 0) return error.InvalidShader;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub fn create(_: *anyopaque, allocator: std.mem.Allocator, desc: shader.ShaderDescriptor) anyerror!shader.Shader {
    var compiled = try desc.source.compile(allocator, .{
        .backend = .dx12,
        .stage = desc.stage,
        .label = desc.label,
    });
    errdefer compiled.deinit(allocator);

    if (compiled.format != .dxil) return error.UnsupportedShaderFormat;

    const dx_shader = try allocator.create(Dx12Shader);
    dx_shader.* = .{
        .allocator = allocator,
        .bytecode = compiled.bytes,
        .stage = desc.stage,
    };

    log.debug("created DX12 {s} shader with {} bytes of DXIL", .{
        @tagName(desc.stage),
        compiled.bytes.len,
    });
    return .{ .handle = @intCast(@intFromPtr(dx_shader)) };
}

pub fn destroy(_: *anyopaque, value: shader.Shader) void {
    const dx_shader = Dx12Shader.fromHandle(value) catch return;
    const allocator = dx_shader.allocator;
    allocator.free(dx_shader.bytecode);
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
    defer destroy(undefined, value);

    const dx_shader = try Dx12Shader.fromHandle(value);
    try std.testing.expectEqual(shader.ShaderStage.vertex, dx_shader.stage);
    try std.testing.expectEqualStrings("DXBC-test-bytecode", dx_shader.bytecode);
}
