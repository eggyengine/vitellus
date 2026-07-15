pub const candler = @import("candler");

pub const windowing = struct {
    pub const Window = @import("windowing/windowing.zig").Window;
    pub const sdl3 = @import("windowing/sdl3.zig");
};

pub const backends = struct {
    pub const dx12 = @import("backends/dx12.zig");
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
};

pub const Adapter = hal.adapter.Adapter;
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
pub const Shader = hal.shader.Shader;
pub const ShaderModule = hal.shader.ShaderModule;
pub const HLSLShaderModule = @import("backends/dx12/hlsl_shader_module.zig").HLSLShaderModule;
pub const HLSLProfile = @import("backends/dx12/hlsl_shader_module.zig").HLSLProfile;
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
pub const TextureDescriptor = hal.resource.TextureDescriptor;
pub const Format = hal.resource.Format;
pub const GraphicsPipeline = hal.pipeline.GraphicsPipeline;
pub const GraphicsPipelineDescriptor = hal.pipeline.GraphicsPipelineDescriptor;
pub const CommandPool = hal.command.CommandPool;
pub const CommandBuffer = hal.command.CommandBuffer;
pub const RenderPassDescriptor = hal.command.RenderPassDescriptor;
pub const SubmitDescriptor = hal.sync.SubmitDescriptor;

test {
    _ = @import("backends/dx12/hlsl_shader_module.zig");
    _ = @import("backends/dx12/resource.zig");
    _ = @import("backends/dx12/shader.zig");
}

test "DX12 buffers cover upload, device, and readback memory" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const adapter = try Adapter.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer adapter.deinit();
    const device = try adapter.createDevice(.{});
    defer device.deinit();

    const upload = try device.createBuffer(.{
        .size = 4,
        .usage = .{ .vertex = true },
        .memory = .upload,
        .initial_data = &.{ 1, 2, 3, 4 },
    });
    defer device.destroyBuffer(upload);
    const local = try device.createBuffer(.{
        .size = 4,
        .usage = .{ .vertex = true },
        .initial_data = &.{ 1, 2, 3, 4 },
    });
    defer device.destroyBuffer(local);
    const readback = try device.createBuffer(.{
        .size = 4,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer device.destroyBuffer(readback);
}

test "DX12 indexed draw binds uniforms and a sampled texture" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const adapter = try Adapter.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer adapter.deinit();
    const device = try adapter.createDevice(.{});
    defer device.deinit();
    const queue = try device.createQueue(.{ .kind = .graphics });
    defer queue.deinit();

    const layout = try device.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .fragment = true } },
        .{ .binding = 1, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
        .{ .binding = 2, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
    } });
    defer device.destroyBindGroupLayout(layout);

    const tint = [4]f32{ 1, 1, 1, 1 };
    const uniform = try device.createBuffer(.{
        .size = 256,
        .usage = .{ .uniform = true },
        .memory = .upload,
        .initial_data = std.mem.asBytes(&tint),
    });
    defer device.destroyBuffer(uniform);
    const indices = [3]u16{ 0, 1, 2 };
    const index_buffer = try device.createBuffer(.{
        .size = @sizeOf(@TypeOf(indices)),
        .usage = .{ .index = true },
        .initial_data = std.mem.asBytes(&indices),
    });
    defer device.destroyBuffer(index_buffer);

    const sampled_texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
        .initial_data = &.{ 255, 255, 255, 255 },
    });
    defer device.destroyTexture(sampled_texture);
    const sampled_view = try device.createTextureView(.{ .texture = sampled_texture });
    defer device.destroyTextureView(sampled_view);
    const sampler = try device.createSampler(.{});
    defer device.destroySampler(sampler);
    const group = try device.createBindGroup(.{
        .layout = layout,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniform } } },
            .{ .binding = 1, .resource = .{ .texture_view = sampled_view } },
            .{ .binding = 2, .resource = .{ .sampler = sampler } },
        },
    });
    defer device.destroyBindGroup(group);

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
    const vertex = try device.createShader(.{
        .stage = .vertex,
        .source = HLSLShaderModule.init(.{ .code = source, .entry_point = "vsMain", .profile = .vs_6_7 }),
    });
    defer device.destroyShader(vertex);
    const fragment = try device.createShader(.{
        .stage = .fragment,
        .source = HLSLShaderModule.init(.{ .code = source, .entry_point = "psMain", .profile = .ps_6_7 }),
    });
    defer device.destroyShader(fragment);
    const targets = [_]hal.pipeline.ColorTargetState{.{ .format = .rgba8_unorm }};
    const pipeline_layout = try device.createPipelineLayout(.{ .bind_group_layouts = &.{layout} });
    defer device.destroyPipelineLayout(pipeline_layout);
    const pipeline = try device.createGraphicsPipeline(.{
        .vertex = vertex,
        .fragment = fragment,
        .raster = .{ .cull_mode = .none },
        .color_targets = &targets,
        .layout = pipeline_layout,
    });
    defer device.destroyGraphicsPipeline(pipeline);

    const target = try device.createTexture(.{
        .width = 16,
        .height = 16,
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true },
    });
    defer device.destroyTexture(target);
    const target_view = try device.createTextureView(.{ .texture = target });
    defer device.destroyTextureView(target_view);
    const pool = try device.createCommandPool(.{});
    defer device.destroyCommandPool(pool);
    const commands = try device.createCommandBuffer(pool);
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
    device.destroyCommandBuffer(commands);
}

test "DX12 command transfers copy buffers and textures" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    const adapter = try Adapter.init(std.testing.allocator, .{
        .backend = .{ .dx12 = true },
        .validation = .none,
    });
    defer adapter.deinit();
    const device = try adapter.createDevice(.{});
    defer device.deinit();
    const queue = try device.createQueue(.{ .kind = .graphics });
    defer queue.deinit();

    const expected = [4]u8{ 1, 2, 3, 4 };
    const upload = try device.createBuffer(.{
        .size = expected.len,
        .usage = .{ .transfer_src = true },
        .memory = .upload,
    });
    defer device.destroyBuffer(upload);
    const upload_mapping = try device.mapBuffer(upload, .write, .{ .size = expected.len });
    @memcpy(upload_mapping, &expected);
    device.unmapBuffer(upload, .{ .size = expected.len });
    const local = try device.createBuffer(.{
        .size = expected.len,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer device.destroyBuffer(local);
    const readback = try device.createBuffer(.{
        .size = expected.len,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer device.destroyBuffer(readback);

    const pixels = [4]u8{ 10, 20, 30, 255 };
    const texture_upload = try device.createBuffer(.{
        .size = 256,
        .usage = .{ .transfer_src = true },
        .memory = .upload,
        .initial_data = &pixels,
    });
    defer device.destroyBuffer(texture_upload);
    const source_texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer device.destroyTexture(source_texture);
    const destination_texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
    });
    defer device.destroyTexture(destination_texture);
    const texture_readback = try device.createBuffer(.{
        .size = 256,
        .usage = .{ .transfer_dst = true },
        .memory = .readback,
    });
    defer device.destroyBuffer(texture_readback);

    const pool = try device.createCommandPool(.{});
    defer device.destroyCommandPool(pool);
    const commands = try device.createCommandBuffer(pool);
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
    device.destroyCommandBuffer(commands);

    try expectBufferBytes(device, readback, &expected);
    try expectBufferBytes(device, texture_readback, &pixels);
}

fn expectBufferBytes(device: Device, value: Buffer, expected: []const u8) !void {
    const std = @import("std");
    const bytes = try device.mapBuffer(value, .read, .{ .size = expected.len });
    defer device.unmapBuffer(value, null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "DX12 submission signals timeline fences asynchronously" {
    const std = @import("std");
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const adapter = try Adapter.init(std.testing.allocator, .{ .backend = .{ .dx12 = true }, .validation = .none });
    defer adapter.deinit();
    const device = try adapter.createDevice(.{});
    defer device.deinit();
    const queue = try device.createQueue(.{ .kind = .graphics });
    defer queue.deinit();
    const fence = try device.createFence(0);
    defer device.destroyFence(fence);
    const pool = try device.createCommandPool(.{});
    defer device.destroyCommandPool(pool);
    const commands = try device.createCommandBuffer(pool);
    try commands.finish();
    try queue.submit(.{ .command_buffers = &.{commands}, .signal_fences = &.{.{ .fence = fence, .value = 1 }} });
    try std.testing.expect(try device.waitFence(.{ .fence = fence, .value = 1 }, 5 * std.time.ns_per_s));
    try std.testing.expect(device.fenceValue(fence) >= 1);
    device.destroyCommandBuffer(commands);
    try device.resetCommandPool(pool);
}
