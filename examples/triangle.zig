const std = @import("std");
const sdl3 = @import("sdl3");
const vit = @import("vitellus");

const width = 1280;
const height = 720;
const shader_source = @embedFile("triangle.hlsl");

pub fn main(init: std.process.Init) !void {
    defer sdl3.shutdown();

    const init_flags = sdl3.InitFlags{ .video = true };
    try sdl3.init(init_flags);
    defer sdl3.quit(init_flags);

    const window = try sdl3.video.Window.init("Vitellus triangle", width, height, .{
        .resizable = true,
    });
    defer window.deinit();

    const window_adapter = vit.windowing.sdl3.Sdl3Window.init(window);

    const adapter = try vit.Adapter.init(init.gpa, .{
        .backend = .{ .dx12 = true },
        .validation = .core,
    });
    defer adapter.deinit();

    const device = try adapter.createDevice();
    defer device.deinit();

    const queue = try device.createQueue(.{ .kind = .graphics });
    defer queue.deinit();

    const swapchain = try adapter.createSwapchain(.{
        .window = try window_adapter.asWindow(),
        .queue = queue,
        .extent = .{ .width = width, .height = height },
        .format = .bgra8_unorm,
        .present_mode = .fifo,
        .image_count = 2,
    });
    defer swapchain.deinit();

    const vertex_shader = try device.createShader(.{
        .label = "triangle vertex shader",
        .stage = .vertex,
        .source = vit.HLSLShaderModule.init(.{
            .code = shader_source,
            .entry_point = "vsMain",
            .profile = .vs_6_7,
        }),
    });
    defer device.destroyShader(vertex_shader);

    const fragment_shader = try device.createShader(.{
        .label = "triangle fragment shader",
        .stage = .fragment,
        .source = vit.HLSLShaderModule.init(.{
            .code = shader_source,
            .entry_point = "psMain",
            .profile = .ps_6_7,
        }),
    });
    defer device.destroyShader(fragment_shader);

    const color_targets = [_]vit.hal.pipeline.ColorTargetState{
        .{ .format = .bgra8_unorm },
    };
    const pipeline = try device.createGraphicsPipeline(.{
        .label = "triangle pipeline",
        .vertex = vertex_shader,
        .fragment = fragment_shader,
        .topology = .triangle_list,
        .raster = .{ .cull_mode = .none },
        .color_targets = &color_targets,
    });
    defer device.destroyGraphicsPipeline(pipeline);

    const command_pool = try device.createCommandPool(.{
        .transient = false,
        .reset_individually = true,
    });
    defer device.destroyCommandPool(command_pool);

    var quit = false;
    while (!quit) {
        while (sdl3.events.poll()) |event| switch (event) {
            .quit, .terminating => quit = true,
            else => {},
        };
        if (quit) break;

        _ = try swapchain.acquireNextImage(null);
        const back_buffer = try swapchain.currentTextureView();
        const commands = try device.createCommandBuffer(command_pool);

        const color_attachments = [_]vit.hal.command.ColorAttachment{.{
            .view = back_buffer,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.025, .g = 0.035, .b = 0.055, .a = 1.0 },
        }};

        try commands.beginRenderPass(.{
            .label = "triangle render pass",
            .color_attachments = &color_attachments,
        });
        commands.setPipeline(pipeline);
        commands.draw(3, 1, 0, 0);
        commands.endRenderPass();
        try commands.finish();

        const command_buffers = [_]vit.CommandBuffer{commands};
        try queue.submit(.{ .command_buffers = &command_buffers });
        try swapchain.present(&.{});
    }

    try queue.waitIdle();
}
