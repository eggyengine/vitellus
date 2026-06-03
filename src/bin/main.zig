const vit = @import("vitellus");
const sdl3 = vit.windowing.sdl3.sdl;
const std = @import("std");
const emath = @import("eggenvector");
const zigimg = @import("zigimg");
const cam = @import("camera.zig");
const math = @import("math.zig");
const vert = @import("vertex.zig");

const Camera = cam.Camera;
const InputState = cam.InputState;
const Transform = math.Transform;

// const fps = 240;
const screen_width = 640;
const screen_height = 480;

const Tex = struct {
    texture: vit.Texture,
    view: vit.Texture.View,
    sampler: vit.Sampler,

    fn deinit(self: *@This()) void {
        self.sampler.deinit();
        self.view.deinit();
        self.texture.deinit();
    }
};

const texture_layout_entry = vit.DescriptorSetLayout.Entry{
    .binding = 1,
    .visibility = vit.DescriptorSetLayout.ShaderStage.FRAGMENT,
    .combinedImageSampler = .{
        .sampleType = .{ .float = .{ .filterable = true } },
        .viewDimension = .@"2d",
        .multisampled = false,
        .samplerType = .filtering,
    },
};

pub fn main(init: std.process.Init) !void {
    defer sdl3.shutdown();

    // Initialize SDL with subsystems you need here.
    const init_flags = sdl3.InitFlags{ .video = true };
    try sdl3.init(init_flags);
    defer sdl3.quit(init_flags);

    // Initial window setup.
    const window = try sdl3.video.Window.init("Hello SDL3", screen_width, screen_height, .{
        .resizable = true,
        .maximized = true,
    });
    defer window.deinit();

    // Useful for limiting the FPS and getting the delta time.
    var fps_capper = sdl3.extras.FramerateCapper(f32){
        // .mode = .{ .limited = fps },
        .mode = .unlimited,
    };

    const wrapper = vit.windowing.sdl3.Sdl3Window.init(window);
    var state = try initPipeline(wrapper, init);
    defer state.deinit();

    var input_state = InputState{};
    var quit = false;
    while (!quit) {

        // Delay to limit the FPS, returned delta time not needed.
        const dt = fps_capper.delay();

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

                        cam.setCameraKey(&input_state, scan, true);
                    }
                },
                .key_up => |key| {
                    if (key.scancode) |scan| {
                        cam.setCameraKey(&input_state, scan, false);
                    }
                },
                .mouse_button_down => |button| {
                    if (button.button == .right) {
                        input_state.mouse_look = true;
                        try sdl3.mouse.setWindowRelativeMode(window, true);
                    }
                },
                .mouse_button_up => |button| {
                    if (button.button == .right) {
                        input_state.mouse_look = false;
                        try sdl3.mouse.setWindowRelativeMode(window, false);
                    }
                },
                .mouse_motion => |motion| {
                    if (input_state.mouse_look) {
                        state.camera.look(motion.x_rel, motion.y_rel);
                    }
                },
                .window_resized => |res| {
                    if (res.width > 0 and res.height > 0) {
                        state.config.width = @intCast(res.width);
                        state.config.height = @intCast(res.height);
                        state.surface.configure(&state.device, state.config);
                        state.depth_buffer_tex.deinit();
                        try create_depth_buffer(&state);
                        state.isSurfaceConfigured = true;
                    }
                },
                else => {},
            };

        try render_the_pipeline(&state, input_state, dt);
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
    render_pipeline_layout: vit.PipelineLayout,
    camera_descriptor_set_layout: vit.DescriptorSetLayout,
    descriptor_set: vit.DescriptorSet,
    uniform_buffer: vit.Buffer,
    vertex_buffer: vit.Buffer,
    index_buffer: vit.Buffer,
    camera: Camera,
    model_transform: Transform,

    depth_buffer_tex: Tex = undefined,
    tex: Tex,

    fn deinit(self: *@This()) void {
        self.depth_buffer_tex.deinit();
        self.tex.deinit();
        self.index_buffer.deinit();
        self.vertex_buffer.deinit();
        self.uniform_buffer.deinit();
        self.descriptor_set.deinit();
        self.render_pipeline.deinit();
        self.render_pipeline_layout.deinit();
        self.camera_descriptor_set_layout.deinit();

        self.surface.deinit();
        self.device.destroy();
        self.instance.deinit();
    }

    fn updateCamera(self: *@This(), input: InputState, dt: f32) void {
        self.camera.update(input, dt);
        const ubo = self.camera.uniforms(self.model_transform, self.config.width, self.config.height);
        const bytes = std.mem.asBytes(&ubo);
        self.queue.writeBuffer(&self.uniform_buffer, 0, bytes[0..], 0, null);
    }
};

fn initPipeline(wrapper: vit.windowing.sdl3.Sdl3Window, init: std.process.Init) !State {
    const width, const height = try wrapper.window.getSize();

    // initialise the instance
    var instance = try vit.Instance.initFromPotentialBackends(.{ .vulkan = true }, .{ .allocator = init.gpa, .flags = .{ .validation = true } });
    errdefer instance.deinit();

    // create the surface from the window
    var surface = try instance.createSurface(try wrapper.asWindow());
    errdefer surface.deinit();

    // request the adapter
    var adapterF = instance.requestAdapter(init.io, .{
        .label = "custom adapter",
        .surface = surface,
        .power_preference = .highPerformance,
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
        .render_pipeline_layout = undefined,
        .camera_descriptor_set_layout = undefined,
        .descriptor_set = undefined,
        .uniform_buffer = undefined,
        .vertex_buffer = undefined,
        .index_buffer = undefined,
        .camera = .{},
        .model_transform = .{},
        .tex = undefined,
    };

    try create_images(&state, init);
    errdefer state.tex.deinit();

    try cam.createResources(&state, &texture_layout_entry);
    errdefer {
        state.descriptor_set.deinit();
        state.uniform_buffer.deinit();
        state.camera_descriptor_set_layout.deinit();
    }

    try create_depth_buffer(&state);

    try create_render_pipeline(&state);
    errdefer {
        state.render_pipeline.deinit();
        state.render_pipeline_layout.deinit();
    }

    try create_buffers(&state);

    return state;
}

fn create_depth_buffer(state: *State) !void {
    const size = vit.Extent3D{
        .width = state.config.width,
        .height = state.config.height,
    };
    const desc = vit.Texture.Descriptor{
        .label = "depth buffer texture",
        .size = size,
        .format = .depth32float,
        .usage = vit.Texture.Usage.RENDER_ATTACHMENT | vit.Texture.Usage.TEXTURE_BINDING,
    };
    var texture = try state.device.createTexture(desc);

    const view = try texture.createView(.{});
    const sampler = try state.device.createSampler(vit.Sampler.Descriptor{
        .label = "depth buffer sampler",
        .compare = .less_equal,
        .minFilter = .linear,
        .magFilter = .linear,
        .lodMaxClamp = 100.0,
    });

    state.depth_buffer_tex = .{ .sampler = sampler, .view = view, .texture = texture };
    return;
}

fn create_images(state: *State, init: std.process.Init) !void {
    const image_data = @embedFile("f08.jpg");

    var image = try zigimg.Image.fromMemory(init.gpa, image_data[0..]);
    defer image.deinit(init.gpa);
    try image.convert(init.gpa, .rgba32);

    const size = vit.Texture.Extent3D{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
    };

    var texture = try state.device.createTexture(.{
        .label = "bird texture",
        .size = size,
        .format = .rgba8unorm_srgb,
        .usage = vit.Texture.Usage.TEXTURE_BINDING | vit.Texture.Usage.COPY_DST,
    });
    errdefer texture.deinit();

    try state.queue.writeTexture(
        .{
            .texture = &texture,
        },
        std.mem.sliceAsBytes(image.pixels.rgba32),
        .{
            .bytesPerRow = @intCast(4 * image.width),
            .rowsPerImage = @intCast(image.height),
        },
        size,
    );

    var texture_view = try texture.createView(.{ .label = "bird texture view" });
    errdefer texture_view.destroy();

    const sampler = try state.device.createSampler(.{
        .label = "bird sampler",
        .magFilter = .linear,
        .minFilter = .linear,
    });
    errdefer sampler.deinit();

    state.tex.texture = texture;
    state.tex.view = texture_view;
    state.tex.sampler = sampler;
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

    state.render_pipeline_layout = try state.device.createPipelineLayout(.{
        .label = "render pipeline layout",
        .descriptorSetLayouts = &.{&state.camera_descriptor_set_layout},
    });
    errdefer state.render_pipeline_layout.deinit();

    const render_pipeline = try state.device.createRenderPipeline(.{
        .label = "render pipeline",
        .layout = &state.render_pipeline_layout,
        .vertex = .{
            .module = vertex_shader,
            .entry_point = "vertMain",
            .buffers = &.{vert.Vertex.desc()},
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
        .depthStencil = .{
            .format = .depth32float,
            .depthWriteEnabled = true,
            .depthCompare = .less_equal,
        },
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
        .size = @sizeOf(@TypeOf(vert.VERTICES)),
        .usage = vit.Buffer.Usage.VERTEX | vit.Buffer.Usage.COPY_DST,
        .mappedAtCreation = false,
    });

    errdefer vertex_buffer.deinit();

    state.queue.writeBuffer(&vertex_buffer, 0, std.mem.sliceAsBytes(vert.VERTICES[0..]), 0, null);

    state.vertex_buffer = vertex_buffer;

    var index_buffer = try state.device.createBuffer(.{
        .label = "Index Buffer",
        .size = @sizeOf(@TypeOf(vert.INDICES)),
        .usage = vit.Buffer.Usage.INDEX | vit.Buffer.Usage.COPY_DST,
        .mappedAtCreation = false,
    });

    state.queue.writeBuffer(&index_buffer, 0, std.mem.sliceAsBytes(vert.INDICES[0..]), 0, null);
    state.index_buffer = index_buffer;

    return;
}

fn render_the_pipeline(state: *State, input: InputState, dt: f32) !void {
    if (!state.isSurfaceConfigured) {
        return;
    }

    state.updateCamera(input, dt);

    var output = switch (try state.surface.getCurrentTexture()) {
        .success => |texture| texture,
        .suboptimal => |texture| texture,
        .timeout, .occluded, .validation => return,
        .outdated => {
            state.surface.configure(&state.device, state.config);
            state.depth_buffer_tex.deinit();
            try create_depth_buffer(state);
            return;
        },
        .lost => return error.DeviceLost,
    };

    var view = try output.createView(.{});
    defer view.destroy();

    var encoder = try state.device.createCommandEncoder(.{
        .label = "render encoder",
    });

    {
        var render_pass = encoder.beginRenderPass(.{
            .label = "Render Pass",
            .colorAttachments = &.{
                .{
                    .view = &view,
                    .resolveTarget = null,
                    .depthSlice = null,
                    .clearValue = .{ .dict = .{
                        .r = 0.1,
                        .g = 0.2,
                        .b = 0.3,
                        .a = 1.0,
                    } },
                    .loadOp = .{ .clear = 0.0 },
                    .storeOp = .store,
                },
            },
            .depthStencilAttachment = .{ .view = &state.depth_buffer_tex.view, .depthOperations = .{
                .loadOp = .{ .clear = 1.0 },
                .storeOp = .store,
            } },
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .multiviewMask = null,
        });
        defer render_pass.end();

        render_pass.setPipeline(&state.render_pipeline);
        render_pass.setDescriptorSet(0, &state.descriptor_set, &.{});
        render_pass.setVertexBuffer(0, &state.vertex_buffer, 0, null);
        render_pass.setIndexBuffer(&state.index_buffer, .uint16, 0, null);
        render_pass.drawIndexed(.exclusive(0, vert.INDICES.len), .exclusive(0, 1), 0);
    }

    state.queue.submit(&[_]vit.CommandBuffer{encoder.finish()});
    output.present();

    return;
}
