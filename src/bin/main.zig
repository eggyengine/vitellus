const std = @import("std");
const sdl3 = @import("sdl3");
const vit = @import("vitellus");

const width = 1280;
const height = 720;
const shader_source = @embedFile("triangle.hlsl");

const Vertex = extern struct {
    position: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .position = .{ -0.6, 0.6 }, .color = .{ 1.0, 0.1, 0.1 } },
    .{ .position = .{ 0.6, 0.6 }, .color = .{ 0.1, 1.0, 0.1 } },
    .{ .position = .{ 0.6, -0.6 }, .color = .{ 0.1, 0.3, 1.0 } },
    .{ .position = .{ -0.6, -0.6 }, .color = .{ 1.0, 0.8, 0.1 } },
};

const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

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

    const device = try adapter.createDevice(.{});
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

    const vertex_buffer = try device.createBuffer(.{
        .label = "quad vertices",
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true },
        .initial_data = std.mem.asBytes(&vertices),
    });
    defer device.destroyBuffer(vertex_buffer);

    const index_buffer = try device.createBuffer(.{
        .label = "quad indices",
        .size = @sizeOf(@TypeOf(indices)),
        .usage = .{ .index = true },
        .initial_data = std.mem.asBytes(&indices),
    });
    defer device.destroyBuffer(index_buffer);

    const tint = [4]f32{ 0.45, 0.85, 1.0, 1.0 };
    const uniform_buffer = try device.createBuffer(.{
        .label = "scene uniform",
        .size = 256,
        .usage = .{ .uniform = true },
        .memory = .upload,
        .initial_data = std.mem.asBytes(&tint),
    });
    defer device.destroyBuffer(uniform_buffer);

    const scene_layout = try device.createBindGroupLayout(.{
        .label = "scene layout",
        .entries = &.{.{
            .binding = 0,
            .kind = .{ .buffer = .{ .kind = .uniform, .min_size = @sizeOf(@TypeOf(tint)) } },
            .visibility = .{ .fragment = true },
        }},
    });
    defer device.destroyBindGroupLayout(scene_layout);

    const scene_group = try device.createBindGroup(.{
        .label = "scene resources",
        .layout = scene_layout,
        .entries = &.{.{
            .binding = 0,
            .resource = .{ .buffer = .{ .buffer = uniform_buffer, .size = 256 } },
        }},
    });
    defer device.destroyBindGroup(scene_group);

    const vertex_attributes = [_]vit.hal.pipeline.VertexAttribute{
        .{ .location = 0, .format = .float32x2, .offset = @offsetOf(Vertex, "position") },
        .{ .location = 1, .format = .float32x3, .offset = @offsetOf(Vertex, "color") },
    };
    const vertex_layouts = [_]vit.hal.pipeline.VertexBufferLayout{.{
        .stride = @sizeOf(Vertex),
        .attributes = &vertex_attributes,
    }};
    const color_targets = [_]vit.hal.pipeline.ColorTargetState{
        .{ .format = .bgra8_unorm },
    };
    const pipeline_layout = try device.createPipelineLayout(.{ .bind_group_layouts = &.{scene_layout} });
    defer device.destroyPipelineLayout(pipeline_layout);
    const pipeline = try device.createGraphicsPipeline(.{
        .label = "indexed quad pipeline",
        .vertex = vertex_shader,
        .fragment = fragment_shader,
        .vertex_buffers = &vertex_layouts,
        .topology = .triangle_list,
        .raster = .{ .cull_mode = .none },
        .color_targets = &color_targets,
        .layout = pipeline_layout,
    });
    defer device.destroyGraphicsPipeline(pipeline);

    const command_pool = try device.createCommandPool(.{
        .transient = false,
        .reset_individually = true,
    });
    defer device.destroyCommandPool(command_pool);
    const frame_fence = try device.createFence(0);
    defer device.destroyFence(frame_fence);
    var frame_value: u64 = 0;

    const setup_commands = try device.createCommandBuffer(command_pool);
    try setup_commands.barrier(&.{
        .{ .buffer = .{ .buffer = vertex_buffer, .before = .common, .after = .vertex } },
        .{ .buffer = .{ .buffer = index_buffer, .before = .common, .after = .index } },
    });
    try setup_commands.finish();
    try queue.submit(.{ .command_buffers = &.{setup_commands} });
    try queue.waitIdle();
    device.destroyCommandBuffer(setup_commands);

    var quit = false;
    while (!quit) {
        while (sdl3.events.poll()) |event| switch (event) {
            .quit, .terminating => quit = true,
            else => {},
        };
        if (quit) break;

        const acquired = try swapchain.acquireNextImage(null);
        const back_buffer = acquired.view;
        const commands = try device.createCommandBuffer(command_pool);
        try commands.barrier(&.{.{ .texture_view = .{ .view = back_buffer, .before = .present, .after = .color_attachment } }});

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
        commands.setGraphicsPipeline(pipeline);
        commands.setVertexBuffer(0, vertex_buffer, 0);
        commands.setIndexBuffer(index_buffer, .uint16, 0);
        commands.setBindGroup(0, scene_group, &.{});
        commands.drawIndexed(@intCast(indices.len), 1, 0, 0, 0);
        commands.endRenderPass();
        try commands.barrier(&.{.{ .texture_view = .{ .view = back_buffer, .before = .color_attachment, .after = .present } }});
        try commands.finish();

        const command_buffers = [_]vit.CommandBuffer{commands};
        frame_value += 1;
        try queue.submit(.{ .command_buffers = &command_buffers, .signal_fences = &.{.{ .fence = frame_fence, .value = frame_value }} });
        _ = try swapchain.present(&.{});
        _ = try device.waitFence(.{ .fence = frame_fence, .value = frame_value }, null);
        device.destroyCommandBuffer(commands);
    }

    try queue.waitIdle();
}
