pub const candler = @import("candler");

pub const windowing = struct {
    pub const Window = @import("windowing/windowing.zig").Window;
    pub const sdl3 = @import("windowing/sdl3.zig");
};

pub const backends = struct {
    pub const dx12 = @import("backends/dx12.zig");
    pub const vk = @import("backends/vulkan.zig");
};

pub const hal = struct {
    pub const adapter = @import("interface/adapter.zig");
    pub const binding = @import("interface/binding.zig");
    pub const command = @import("interface/command.zig");
    pub const device = @import("interface/device.zig");
    pub const pipeline = @import("interface/pipeline.zig");
    pub const queue = @import("interface/queue.zig");
    pub const resource = @import("interface/resource.zig");
    pub const settings = @import("interface/settings.zig");
    pub const shader = @import("interface/shader.zig");
    pub const swapchain = @import("interface/swapchain.zig");
    pub const sync = @import("interface/sync.zig");
    pub const instance = @import("interface/instance.zig");
};

pub const Instance = hal.instance.Instance;
pub const Adapter = hal.adapter.Adapter;
pub const AdapterDescriptor = hal.adapter.AdapterDescriptor;
pub const AdapterInfo = hal.adapter.AdapterInfo;
pub const Device = hal.device.Device;
pub const DeviceDescriptor = hal.device.DeviceDescriptor;
pub const Queue = hal.queue.Queue;
pub const QueueDescriptor = hal.queue.QueueDescriptor;
pub const Swapchain = hal.swapchain.Swapchain;
pub const SwapchainDescriptor = hal.swapchain.SwapchainDescriptor;
pub const SwapchainFormat = hal.swapchain.SwapchainFormat;
pub const SwapchainColorSpace = hal.swapchain.SwapchainColorSpace;
pub const PresentMode = hal.swapchain.PresentMode;
pub const CompositeAlpha = hal.swapchain.CompositeAlpha;
pub const ImageUsage = hal.swapchain.ImageUsage;
pub const Extent2D = hal.swapchain.Extent2D;
pub const Window = windowing.Window;
pub const Config = hal.settings.VitellusConfig;
pub const Backend = hal.settings.Backend;
pub const BackendType = hal.settings.BackendType;
pub const BackendFactory = hal.settings.BackendFactory;
pub const ValidationLevel = hal.settings.ValidationLevel;
pub const VitellusConfig = hal.settings.VitellusConfig;
pub const Shader = hal.shader.Shader;
pub const ShaderModule = hal.shader.ShaderModule;
pub const HLSLShaderModule = backends.dx12.HLSLShaderModule;
pub const HLSLProfile = backends.dx12.HLSLProfile;
pub const BinaryShaderModule = hal.shader.BinaryShaderModule;
pub const CompiledShader = hal.shader.CompiledShader;
pub const ShaderCompileRequest = hal.shader.ShaderCompileRequest;
pub const ShaderBinaryFormat = hal.shader.ShaderBinaryFormat;
pub const ShaderDescriptor = hal.shader.ShaderDescriptor;
pub const ShaderStage = hal.shader.ShaderStage;
pub const Buffer = hal.resource.Buffer;
pub const BufferDescriptor = hal.resource.BufferDescriptor;
pub const Texture = hal.resource.Texture;
pub const TextureView = hal.resource.TextureView;
pub const Sampler = hal.resource.Sampler;
pub const TextureDescriptor = hal.resource.TextureDescriptor;
pub const TextureViewDescriptor = hal.resource.TextureViewDescriptor;
pub const SamplerDescriptor = hal.resource.SamplerDescriptor;
pub const Format = hal.resource.Format;
pub const GraphicsPipeline = hal.pipeline.GraphicsPipeline;
pub const ComputePipeline = hal.pipeline.ComputePipeline;
pub const PipelineLayout = hal.pipeline.PipelineLayout;
pub const GraphicsPipelineDescriptor = hal.pipeline.GraphicsPipelineDescriptor;
pub const ComputePipelineDescriptor = hal.pipeline.ComputePipelineDescriptor;
pub const PipelineLayoutDescriptor = hal.pipeline.PipelineLayoutDescriptor;
pub const CommandPool = hal.command.CommandPool;
pub const CommandBuffer = hal.command.CommandBuffer;
pub const CommandPoolDescriptor = hal.command.CommandPoolDescriptor;
pub const CommandBufferDescriptor = hal.command.CommandBufferDescriptor;
pub const QuerySet = hal.command.QuerySet;
pub const QuerySetDescriptor = hal.command.QuerySetDescriptor;
pub const BindGroupLayout = hal.binding.BindGroupLayout;
pub const BindGroup = hal.binding.BindGroup;
pub const BindGroupLayoutDescriptor = hal.binding.BindGroupLayoutDescriptor;
pub const BindGroupDescriptor = hal.binding.BindGroupDescriptor;
pub const Fence = hal.sync.Fence;
pub const Semaphore = hal.sync.Semaphore;
pub const FenceDescriptor = hal.sync.FenceDescriptor;
pub const SemaphoreDescriptor = hal.sync.SemaphoreDescriptor;
pub const RenderPassDescriptor = hal.command.RenderPassDescriptor;
pub const SubmitDescriptor = hal.sync.SubmitDescriptor;

test {
    _ = @import("backends/dx12/hlsl_shader_module.zig");
    _ = @import("backends/dx12/resource.zig");
    _ = @import("backends/dx12/shader.zig");
}

test "DX12 capability queries reflect the live adapter" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try Adapter.init(instance, .{});
    defer adapter.deinit();

    const caps = adapter.capabilities();
    try std.testing.expect(caps.limits.max_buffer_size >= std.math.maxInt(u32));
    try std.testing.expect(caps.limits.max_texture_dimension_2d >= 16384);
    try std.testing.expect(caps.limits.max_bindings_per_group >= 64);
    try std.testing.expect(caps.limits.min_uniform_buffer_offset_alignment == 256);
    try std.testing.expect(caps.features.bc_compression);

    const rgba8 = adapter.formatCapabilities(.rgba8_unorm);
    try std.testing.expect(rgba8.usage.sampled);
    try std.testing.expect(rgba8.usage.color_attachment);
    try std.testing.expect(!rgba8.usage.depth_stencil_attachment);
    try std.testing.expect(rgba8.sample_counts.four);

    const depth = adapter.formatCapabilities(.d32_float);
    try std.testing.expect(depth.usage.depth_stencil_attachment);
    try std.testing.expect(!depth.usage.color_attachment);
    try std.testing.expect(!depth.usage.storage);

    const bc7 = adapter.formatCapabilities(.bc7_rgba_unorm);
    try std.testing.expect(bc7.usage.sampled);
    try std.testing.expect(!bc7.usage.color_attachment);
    try std.testing.expect(!bc7.sample_counts.four);

    try std.testing.expectEqual(hal.adapter.FormatCapabilities{}, adapter.formatCapabilities(.undefined));
}

test "DX12 buffers cover upload, device, and readback memory" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try Device.init(adapter, .{});
    defer device.deinit();

    const upload = try Buffer.init(device, .{
        .size = 4,
        .usage = .{ .vertex = true },
        .memory = .upload,
        .initial_data = &.{ 1, 2, 3, 4 },
    });
    defer upload.deinit();
    const local = try Buffer.init(device, .{
        .size = 4,
        .usage = .{ .vertex = true },
        .initial_data = &.{ 1, 2, 3, 4 },
    });
    defer local.deinit();
    const readback = try Buffer.init(device, .{
        .size = 4,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer readback.deinit();
}

test "DX12 indexed draw binds uniforms and a sampled texture" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try Device.init(adapter, .{});
    defer device.deinit();
    const queue = try Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();

    const layout = try hal.binding.BindGroupLayout.init(device, .{ .entries = &.{
        .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .fragment = true } },
        .{ .binding = 1, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
        .{ .binding = 2, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
    } });
    defer layout.deinit();

    const tint = [4]f32{ 1, 1, 1, 1 };
    const uniform = try Buffer.init(device, .{
        .size = 256,
        .usage = .{ .uniform = true },
        .memory = .upload,
        .initial_data = std.mem.asBytes(&tint),
    });
    defer uniform.deinit();
    const indices = [3]u16{ 0, 1, 2 };
    const index_buffer = try Buffer.init(device, .{
        .size = @sizeOf(@TypeOf(indices)),
        .usage = .{ .index = true },
        .initial_data = std.mem.asBytes(&indices),
    });
    defer index_buffer.deinit();

    const sampled_texture = try hal.resource.Texture.init(device, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
        .initial_data = &.{ 255, 255, 255, 255 },
    });
    defer sampled_texture.deinit();
    const sampled_view = try hal.resource.TextureView.init(device, .{ .texture = sampled_texture });
    defer sampled_view.deinit();
    const sampler = try hal.resource.Sampler.init(device, .{});
    defer sampler.deinit();
    const group = try hal.binding.BindGroup.init(device, .{
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
    const vertex = try Shader.init(device, .{
        .stage = .vertex,
        .source = HLSLShaderModule.init(.{ .code = source, .entry_point = "vsMain", .profile = .vs_6_7 }),
    });
    defer vertex.deinit();
    const fragment = try Shader.init(device, .{
        .stage = .fragment,
        .source = HLSLShaderModule.init(.{ .code = source, .entry_point = "psMain", .profile = .ps_6_7 }),
    });
    defer fragment.deinit();
    const targets = [_]hal.pipeline.ColorTargetState{.{ .format = .rgba8_unorm }};
    const pipeline_layout = try hal.pipeline.PipelineLayout.init(device, .{ .bind_group_layouts = &.{layout} });
    defer pipeline_layout.deinit();
    const pipeline = try GraphicsPipeline.init(device, .{
        .vertex = vertex,
        .fragment = fragment,
        .raster = .{ .cull_mode = .none },
        .color_targets = &targets,
        .layout = pipeline_layout,
    });
    defer pipeline.deinit();

    const target = try hal.resource.Texture.init(device, .{
        .width = 16,
        .height = 16,
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true },
    });
    defer target.deinit();
    const target_view = try hal.resource.TextureView.init(device, .{ .texture = target });
    defer target_view.deinit();
    const pool = try CommandPool.init(device, .{});
    defer pool.deinit();
    const commands = try CommandBuffer.init(pool, .{});
    try commands.barrier(&.{
        .{ .texture = .{ .texture = target, .before = .common, .after = .color_attachment } },
        .{ .texture = .{ .texture = sampled_texture, .before = .common, .after = .sampled } },
        .{ .buffer = .{ .buffer = index_buffer, .before = .common, .after = .index } },
    });
    const attachments = [_]hal.command.ColorAttachment{.{ .view = target_view }};
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

test "DX12 command transfers copy buffers and textures" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const instance = try Instance.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer instance.deinit();
    const adapter = try Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try Device.init(adapter, .{});
    defer device.deinit();
    const queue = try Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();

    const expected = [4]u8{ 1, 2, 3, 4 };
    const upload = try Buffer.init(device, .{
        .size = expected.len,
        .usage = .{ .transfer_src = true },
        .memory = .upload,
    });
    defer upload.deinit();
    const upload_mapping = try upload.map(.write, .{ .size = expected.len });
    @memcpy(upload_mapping, &expected);
    upload.unmap(.{ .size = expected.len });
    const local = try Buffer.init(device, .{
        .size = expected.len,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer local.deinit();
    const readback = try Buffer.init(device, .{
        .size = expected.len,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer readback.deinit();

    const pixels = [4]u8{ 10, 20, 30, 255 };
    const texture_upload = try Buffer.init(device, .{
        .size = 256,
        .usage = .{ .transfer_src = true },
        .memory = .upload,
        .initial_data = &pixels,
    });
    defer texture_upload.deinit();
    const source_texture = try hal.resource.Texture.init(device, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer source_texture.deinit();
    const destination_texture = try hal.resource.Texture.init(device, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer destination_texture.deinit();
    const texture_readback = try Buffer.init(device, .{
        .size = 256,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer texture_readback.deinit();

    const pool = try CommandPool.init(device, .{});
    defer pool.deinit();
    const commands = try CommandBuffer.init(pool, .{});
    commands.beginDebugGroup("transfer test");
    try commands.barrier(&.{.{ .buffer = .{ .buffer = local, .before = .common, .after = .copy_destination } }});
    try commands.copyBuffer(.{ .source = upload, .destination = local, .size = expected.len });
    try commands.barrier(&.{.{ .buffer = .{ .buffer = local, .before = .copy_destination, .after = .copy_source } }});
    try commands.copyBuffer(.{ .source = local, .destination = readback, .size = expected.len });
    try commands.barrier(&.{.{ .texture = .{ .texture = source_texture, .before = .common, .after = .copy_destination } }});
    try commands.copyBufferToTexture(.{
        .buffer = texture_upload,
        .texture = .{ .texture = source_texture },
        .extent = .{ .width = 1 },
    });
    try commands.barrier(&.{
        .{ .texture = .{ .texture = source_texture, .before = .copy_destination, .after = .copy_source } },
        .{ .texture = .{ .texture = destination_texture, .before = .common, .after = .copy_destination } },
    });
    try commands.copyTexture(.{
        .source = .{ .texture = source_texture },
        .destination = .{ .texture = destination_texture },
        .extent = .{ .width = 1 },
    });
    try commands.barrier(&.{.{ .texture = .{ .texture = destination_texture, .before = .copy_destination, .after = .copy_source } }});
    try commands.copyTextureToBuffer(.{
        .buffer = texture_readback,
        .texture = .{ .texture = destination_texture },
        .extent = .{ .width = 1 },
    });
    commands.insertDebugMarker("copies recorded");
    commands.endDebugGroup();
    try commands.finish();
    try queue.submit(.{ .command_buffers = &.{commands} });
    try queue.waitIdle();
    commands.deinit();

    try expectBufferBytes(readback, &expected);
    try expectBufferBytes(texture_readback, &pixels);
}

fn expectBufferBytes(value: Buffer, expected: []const u8) !void {
    const std = @import("std");
    const bytes = try value.map(.read, .{ .size = expected.len });
    defer value.unmap(null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "DX12 submission signals timeline fences asynchronously" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const instance = try Instance.init(std.testing.allocator, .{ .backend = .{ .dx12 = true }, .validation = .none });
    defer instance.deinit();
    const adapter = try Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try Device.init(adapter, .{});
    defer device.deinit();
    const queue = try Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();
    const fence = try hal.sync.Fence.init(device, .{});
    defer fence.deinit();
    const pool = try CommandPool.init(device, .{});
    defer pool.deinit();
    const commands = try CommandBuffer.init(pool, .{});
    try commands.finish();
    try queue.submit(.{ .command_buffers = &.{commands}, .signal_fences = &.{.{ .fence = fence, .value = 1 }} });
    try std.testing.expect(try fence.wait(1, 5 * std.time.ns_per_s));
    try std.testing.expect(fence.currentValue() >= 1);
    commands.deinit();
    try pool.reset();
}
