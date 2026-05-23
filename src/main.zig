const vit = @import("vitellus");
const sdl3 = vit.windowing.sdl3.sdl;
const std = @import("std");

const fps = 60;
const screen_width = 640;
const screen_height = 480;

const Vertex = struct {
    position: [2]f32,
    color: [3]f32,

    fn desc() vit.VertexBufferLayout {
        return vit.VertexBufferLayout{
            .arrayStride = @sizeOf(Vertex),
            .stepMode = .vertex,
            .attributes = &.{
                vit.VertexAttribute{
                    .format = vit.VertexFormat.float32x2,
                    .offset = @offsetOf(Vertex, "position"),
                    .shaderLocation = 0,
                },
                vit.VertexAttribute{
                    .format = vit.VertexFormat.float32x3,
                    .offset = @offsetOf(Vertex, "color"),
                    .shaderLocation = 1,
                },
            },
        };
    }
};

const VERTICES = [_]Vertex{
    // top-left
    .{
        .position = .{ -0.5, 0.5 },
        .color = .{ 1.0, 0.0, 0.0 },
    },

    // bottom-left
    .{
        .position = .{ -0.5, -0.5 },
        .color = .{ 0.0, 1.0, 0.0 },
    },

    // bottom-right
    .{
        .position = .{ 0.5, -0.5 },
        .color = .{ 0.0, 0.0, 1.0 },
    },

    // top-right
    .{
        .position = .{ 0.5, 0.5 },
        .color = .{ 1.0, 1.0, 0.0 },
    },
};

const INDICES = [_]u16{
    0, 1, 2,
    0, 2, 3,
};

pub fn main(init: std.process.Init) !void {
    try vit.logz.setup(init.io, init.gpa, .{
        .level = .Info,
        .pool_size = 100,
        .buffer_size = 4096,
        .large_buffer_count = 8,
        .large_buffer_size = 16384,
        .output = .stdout,
        .encoding = .logfmt,
    });
    defer vit.logz.deinit();

    defer sdl3.shutdown();

    // Initialize SDL with subsystems you need here.
    const init_flags = sdl3.InitFlags{ .video = true };
    try sdl3.init(init_flags);
    defer sdl3.quit(init_flags);

    // Initial window setup.
    const window = try sdl3.video.Window.init("Hello SDL3", screen_width, screen_height, .{});
    defer window.deinit();

    // Useful for limiting the FPS and getting the delta time.
    var fps_capper = sdl3.extras.FramerateCapper(f32){ .mode = .{ .limited = fps } };

    const wrapper = vit.windowing.sdl3.Sdl3Window.init(window);
    var state = try initPipeline(wrapper, init);
    defer state.deinit();

    var quit = false;
    while (!quit) {

        // Delay to limit the FPS, returned delta time not needed.
        const dt = fps_capper.delay();
        _ = dt;

        // Event logic.
        while (sdl3.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                .key_down => |key| {
                    if (key.scancode) |scan| {
                        if (scan == .escape) {
                            quit = true;
                        }
                    }
                },
                .window_resized => |res| {
                    if (res.width > 0 and res.height > 0) {
                        const max = 2048; // max supported dim is 2048 for webgl
                        state.config.width = @intCast(@min(res.width, max));
                        state.config.height = @intCast(@min(res.height, max));
                        state.surface.configure(&state.device, state.config);
                        state.isSurfaceConfigured = true;
                    }
                },
                else => {},
            };

        try render_the_pipeline(&state);
    }
}

pub const State = struct {
    instance: vit.Instance,
    surface: vit.Surface,
    device: vit.Device,
    queue: vit.Queue,
    config: vit.Surface.Configuration,
    isSurfaceConfigured: bool,

    render_pipeline: vit.RenderPipeline,
    vertex_buffer: vit.Buffer,
    index_buffer: vit.Buffer,

    fn deinit(self: *@This()) void {
        self.index_buffer.deinit();
        self.vertex_buffer.deinit();
        self.render_pipeline.deinit();

        self.surface.deinit();
        self.device.destroy();
        self.instance.deinit();
    }
};

fn initPipeline(wrapper: vit.windowing.sdl3.Sdl3Window, init: std.process.Init) !State {
    const width, const height = try wrapper.window.getSize();

    // initialise the instance
    var instance = try vit.Instance.initFromPotentialBackends(.{ .vulkan = true, .noop = true }, .{ .allocator = init.gpa, .flags = .{ .validation = true } });
    errdefer instance.deinit();

    // create the surface from the window
    var surface = try instance.createSurface(try wrapper.asWindow());
    errdefer surface.deinit();

    // request the adapter
    var adapterF = instance.requestAdapter(init.io, .{
        .label = "custom adapter",
        .surface = surface,
    });
    defer _ = adapterF.cancel(init.io) catch {};
    var adapter = try adapterF.await(init.io);

    // request the device and queue
    var deviceF = adapter.requestDevice(init.io, .{
        .label = "custom device",
    });
    defer _ = deviceF.cancel(init.io) catch {};
    var device, const queue = try deviceF.await(init.io);
    errdefer device.destroy();

    const surface_caps = surface.getCapabilities(&adapter);

    var surface_format = surface_caps.formats[0];
    for (surface_caps.formats) |format| {
        if (format.is_srgb()) {
            surface_format = format;
            break;
        }
    }

    const config = vit.Surface.Configuration{
        .usage = vit.Texture.Usage.RENDER_ATTACHMENT,
        .format = surface_format,
        .width = @intCast(width),
        .height = @intCast(height),
        .presentMode = surface_caps.present_modes[0],
        .alphaMode = surface_caps.alpha_modes[0],
        .viewFormats = &.{},
        .desiredMaximumFrameLatency = 2,
    };

    surface.configure(&device, config);

    var state = State{
        .instance = instance,
        .surface = surface,
        .device = device,
        .queue = queue,
        .config = config,
        .isSurfaceConfigured = true,
        .render_pipeline = undefined,
        .vertex_buffer = undefined,
        .index_buffer = undefined,
    };

    try create_render_pipeline(&state);
    try create_buffers(&state);

    return state;
}

fn create_render_pipeline(state: *State) !void {
    var vertex_shader = try state.device.createShaderModule(.{
        .label = "vertex shader",
        .source = .{ .spirv = @embedFile("slang.spv") },
    });
    defer vertex_shader.deinit();

    var fragment_shader = try state.device.createShaderModule(.{
        .label = "fragment shader",
        .source = .{ .spirv = @embedFile("slang.spv") },
    });
    defer fragment_shader.deinit();

    var render_pipeline_layout = state.device.createPipelineLayout(.{
        .label = "render pipeline layout",
        .bindGroupLayouts = &.{},
    });
    defer render_pipeline_layout.deinit();

    const render_pipeline = state.device.createRenderPipeline(.{
        .label = "render pipeline",
        .layout = &render_pipeline_layout,
        .vertex = .{
            .module = vertex_shader,
            .entry_point = "vertMain",
            .buffers = &.{Vertex.desc()},
            // .compilationOptions = .default,
        },
        .fragment = .{
            .module = fragment_shader,
            .entry_point = "fragMain",
            .targets = &.{vit.ColorTargetState{
                .format = state.config.format,
                .blend = .REPLACE,
                .writeMask = vit.ColorWrite.ALL,
            }},
            // .compilationOptions = .default,
        },
        .primitive = .{
            .topology = .triangle_list,
            .stripIndexFormat = null,
            .frontFace = .ccw,
            .cullMode = .none,
            .unclippedDepth = false,
        },
        .depthStencil = null,
        .multisample = .{
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alphaToCoverageEnabled = false,
        },
    });

    state.render_pipeline = render_pipeline;
    return;
}

fn create_buffers(state: *State) !void {
    var vertex_buffer = try state.device.createBuffer(.{
        .label = "Vertex Buffer",
        .size = @sizeOf(@TypeOf(VERTICES)),
        .usage = vit.Buffer.Usage.VERTEX | vit.Buffer.Usage.COPY_DST,
        .mappedAtCreation = false,
    });

    state.queue.writeBuffer(&vertex_buffer, 0, std.mem.sliceAsBytes(VERTICES[0..]), 0, null);

    state.vertex_buffer = vertex_buffer;

    var index_buffer = try state.device.createBuffer(.{
        .label = "Index Buffer",
        .size = @sizeOf(@TypeOf(INDICES)),
        .usage = vit.Buffer.Usage.INDEX | vit.Buffer.Usage.COPY_DST,
        .mappedAtCreation = false,
    });

    state.queue.writeBuffer(&index_buffer, 0, std.mem.sliceAsBytes(INDICES[0..]), 0, null);
    state.index_buffer = index_buffer;

    return;
}

fn render_the_pipeline(state: *State) !void {
    if (!state.isSurfaceConfigured) {
        return;
    }

    var output = switch (try state.surface.getCurrentTexture()) {
        .success => |texture| texture,
        .suboptimal => |texture| texture,
        .timeout, .occluded, .validation => return,
        .outdated => {
            state.surface.configure(&state.device, state.config);
            return;
        },
        .lost => return error.DeviceLost,
    };

    const view = try output.createView(.{});
    defer view.destroy();

    var encoder = state.device.createCommandEncoder(.{
        .label = "render encoder",
    });

    {
        var render_pass = encoder.beginRenderPass(.{
            .label = "Render Pass",
            .colorAttachments = &.{
                .{
                    .view = .{ .texture_view = view },
                    .resolveTarget = null,
                    .depthSlice = null,
                    .clearValue = .{ .dict = .{
                        .r = 0.1,
                        .g = 0.2,
                        .b = 0.3,
                        .a = 1.0,
                    } },
                    .loadOp = .clear,
                    .storeOp = .store,
                },
            },
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .multiviewMask = null,
        });
        defer render_pass.end();

        render_pass.setPipeline(&state.render_pipeline);
        render_pass.setVertexBuffer(0, &state.vertex_buffer, 0, null);
        render_pass.setIndexBuffer(&state.index_buffer, .uint16, 0, null);
        render_pass.drawIndexed(.exclusive(0, INDICES.len), .exclusive(0, 1), 0);
    }

    state.queue.submit(&[_]vit.CommandBuffer{encoder.finish()});
    output.present();

    return;
}
