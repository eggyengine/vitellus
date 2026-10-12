//! HLSL shader module and DX12-oriented shader model profiles.

const std = @import("std");
const builtin = @import("builtin");
const vit = @import("vitellus");
const dxc = @import("dxc.zig");

const CompiledShader = vit.CompiledShader;
const ShaderCompileRequest = vit.ShaderCompileRequest;
const ShaderModule = vit.ShaderModule;
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

    pub fn supportsStage(self: HLSLProfile, stage: vit.ShaderStage) bool {
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
/// Compiles to DXIL for DirectX 12 and SPIR-V for Vulkan. If you do not wish to bundle DXC,
/// precompile and use `vit.BinaryShaderModule` instead.
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
            const format: vit.ShaderBinaryFormat = switch (request.backend) {
                .dx12 => .dxil,
                .vulkan => .spirv,
                .metal, .webgpu => return error.UnsupportedShaderBackend,
            };
            if (!self.profile.supportsStage(request.stage)) return error.ShaderProfileStageMismatch;

            var raw_compiler: ?*anyopaque = null;
            try checkHr(dxc.DxcCreateInstance(
                &dxc.CLSID_DxcCompiler,
                &dxc.IID_IDxcCompiler3,
                &raw_compiler,
            ));
            const compiler: *dxc.IDxcCompiler3 = @ptrCast(@alignCast(raw_compiler orelse return error.ShaderCompilerUnavailable));
            defer _ = compiler.lpVtbl.Release(compiler);

            const entry_point = try wide(allocator, self.entry_point);
            defer allocator.free(entry_point);
            const profile = try wide(allocator, self.profile.name());
            defer allocator.free(profile);

            var arguments = [_][*:0]const dxc.WCHAR{
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

/// DXC's arguments are `wchar_t` strings: UTF-16 on Windows, UTF-32 elsewhere.
fn wide(allocator: std.mem.Allocator, utf8: []const u8) ![:0]dxc.WCHAR {
    if (dxc.WCHAR == u16) return std.unicode.utf8ToUtf16LeAllocZ(allocator, utf8);
    const out = try allocator.allocSentinel(u32, try std.unicode.utf8CountCodepoints(utf8), 0);
    var codepoints = (try std.unicode.Utf8View.init(utf8)).iterator();
    for (out) |*c| c.* = codepoints.nextCodepoint().?;
    return out;
}

/// `wide` for ASCII literals, at compile time.
fn L(comptime ascii: []const u8) [*:0]const dxc.WCHAR {
    const result = comptime blk: {
        var buffer: [ascii.len:0]dxc.WCHAR = undefined;
        for (ascii, 0..) |c, i| buffer[i] = c;
        break :blk buffer;
    };
    return &result;
}

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

    try std.testing.expect(compiled.format == .dxil);
    try std.testing.expectEqualStrings("DXBC", compiled.bytes[0..4]);
}

test "HLSL module compiles SPIR-V" {
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

    try std.testing.expect(compiled.format == .spirv);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, compiled.bytes[0..4]);
}

test "Vulkan device creates SPIR-V compiled from HLSL" {
    const instance = vit.Instance.init(std.testing.allocator, .{
        .backend = .{ .vulkan = true },
        .validation = .none,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer instance.deinit();
    const adapter = try instance.createAdapter(.{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();

    const value = try vit.Shader.init(device, .{
        .stage = .compute,
        .source = HLSLShaderModule.init(.{
            .code = "[numthreads(1, 1, 1)] void main() {}",
            .profile = .cs_6_7,
        }),
    });
    value.deinit();
}

test "DX12 indexed draw binds uniforms and a sampled texture" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try vit.Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();

    const layout = try vit.hal.binding.BindGroupLayout.init(device, .{ .entries = &.{
        .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .fragment = true } },
        .{ .binding = 1, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
        .{ .binding = 2, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
    } });
    defer layout.deinit();

    const tint = [4]f32{ 1, 1, 1, 1 };
    const uniform = try vit.Buffer.init(device, .{
        .size = 256,
        .usage = .{ .uniform = true },
        .memory = .upload,
        .initial_data = std.mem.asBytes(&tint),
    });
    defer uniform.deinit();
    const indices = [3]u16{ 0, 1, 2 };
    const index_buffer = try vit.Buffer.init(device, .{
        .size = @sizeOf(@TypeOf(indices)),
        .usage = .{ .index = true },
        .initial_data = std.mem.asBytes(&indices),
    });
    defer index_buffer.deinit();

    const sampled_texture = try vit.hal.resource.Texture.init(device, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
        .initial_data = &.{ 255, 255, 255, 255 },
    });
    defer sampled_texture.deinit();
    const sampled_view = try vit.hal.resource.TextureView.init(device, .{ .texture = sampled_texture });
    defer sampled_view.deinit();
    const sampler = try vit.hal.resource.Sampler.init(device, .{});
    defer sampler.deinit();
    const group = try vit.hal.binding.BindGroup.init(device, .{
        .layout = layout,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniform } } },
            .{ .binding = 1, .resource = .{ .texture_view = sampled_view } },
            .{ .binding = 2, .resource = .{ .sampler = sampler } },
        },
    });
    defer group.deinit();

    const source =
        \\struct Output { float4 position : SV_Position; float2 uv : TEXCOORD0; };
        \\Output vsMain(uint id : SV_VertexID) {
        \\    float2 p[3] = { float2(0, 0.5), float2(0.5, -0.5), float2(-0.5, -0.5) };
        \\    Output o; o.position = float4(p[id], 0, 1); o.uv = p[id] + 0.5; return o;
        \\}
        \\cbuffer Uniforms : register(b0, space0) { float4 tint; };
        \\Texture2D image : register(t1, space0);
        \\SamplerState image_sampler : register(s2, space0);
        \\float4 psMain(Output input) : SV_Target0 { return image.Sample(image_sampler, input.uv) * tint; }
    ;
    const vertex = try vit.Shader.init(device, .{
        .stage = .vertex,
        .source = HLSLShaderModule.init(.{ .code = source, .entry_point = "vsMain", .profile = .vs_6_7 }),
    });
    defer vertex.deinit();
    const fragment = try vit.Shader.init(device, .{
        .stage = .fragment,
        .source = HLSLShaderModule.init(.{ .code = source, .entry_point = "psMain", .profile = .ps_6_7 }),
    });
    defer fragment.deinit();
    const targets = [_]vit.hal.pipeline.ColorTargetState{.{ .format = .rgba8_unorm }};
    const pipeline_layout = try vit.hal.pipeline.PipelineLayout.init(device, .{ .bind_group_layouts = &.{layout} });
    defer pipeline_layout.deinit();
    const pipeline = try vit.GraphicsPipeline.init(device, .{
        .vertex = vertex,
        .fragment = fragment,
        .raster = .{ .cull_mode = .none },
        .color_targets = &targets,
        .layout = pipeline_layout,
    });
    defer pipeline.deinit();

    const target = try vit.hal.resource.Texture.init(device, .{
        .width = 16,
        .height = 16,
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true },
    });
    defer target.deinit();
    const target_view = try vit.hal.resource.TextureView.init(device, .{ .texture = target });
    defer target_view.deinit();
    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const commands = try vit.CommandBuffer.init(pool, .{});
    try commands.barrier(&.{
        .{ .texture = .{ .texture = target, .before = .common, .after = .color_attachment } },
        .{ .texture = .{ .texture = sampled_texture, .before = .common, .after = .sampled } },
        .{ .buffer = .{ .buffer = index_buffer, .before = .common, .after = .index } },
    });
    const attachments = [_]vit.hal.command.ColorAttachment{.{ .view = target_view }};
    try commands.beginRenderPass(.{ .color_attachments = &attachments });
    commands.setViewport(.{ .width = 16, .height = 16 });
    commands.setScissor(.{ .width = 16, .height = 16 });
    commands.setBlendConstant(.{ .r = 1, .g = 1, .b = 1 });
    commands.setStencilReference(0);
    commands.setGraphicsPipeline(pipeline);
    commands.setBindGroup(0, group, &.{});
    commands.setIndexBuffer(index_buffer, .uint16, 0);
    commands.drawIndexed(3, 2, 0, 0, 0);
    commands.endRenderPass();
    try commands.finish();
    try queue.submit(.{ .command_buffers = &.{commands} });
    try queue.waitIdle();
    commands.deinit();
}
