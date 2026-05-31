const vit = @import("vitellus");
const sdl3 = vit.windowing.sdl3.sdl;
const std = @import("std");
const emath = @import("eggenvector");
const zigimg = @import("zigimg");

const fps = 60;
const screen_width = 640;
const screen_height = 480;

const Tex = struct {
    texture: vit.Texture,
    view: *vit.Texture.View,
    sampler: vit.Sampler,

    fn deinit(self: *@This()) void {
        self.sampler.deinit();
        self.view.deinit();
        self.texture.deinit();
    }
};

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

const UniformBufferObject = struct { model: emath.Mat4, view: emath.Mat4, proj: emath.Mat4 };

const Camera = struct {
    eye: emath.Vec3 = .{ .x = 0.0, .y = 0.0, .z = 2.0 },
    target: emath.Vec3 = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
    up: emath.Vec3 = emath.Vec3.up,
    fov_y: f32 = std.math.pi / 4.0,
    near: f32 = 0.1,
    far: f32 = 10.0,
    model_rotation: f32 = 0.0,

    fn update(self: *@This(), dt: f32) void {
        self.model_rotation += dt;
        if (self.model_rotation > std.math.tau) {
            self.model_rotation -= std.math.tau;
        }
    }

    fn uniforms(self: @This(), width: u32, height: u32) UniformBufferObject {
        const aspect = if (height == 0) 1.0 else @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        return .{
            .model = emath.rotationZ4x4(f32, self.model_rotation),
            .view = emath.lookAt(self.eye, self.target, self.up),
            .proj = emath.perspective(self.fov_y, aspect, self.near, self.far),
        };
    }
};

const camera_bind_group_layout_entry = vit.BindGroupLayout.Entry{
    .binding = 0,
    .visibility = vit.BindGroupLayout.ShaderStage.VERTEX,
    .buffer = .{
        .type = .uniform,
        .hasDynamicOffset = false,
        .minBindingSize = @sizeOf(UniformBufferObject),
    },
};

const texture_layout_entry = vit.BindGroupLayout.Entry{
    .binding = 1,
    .visibility = vit.BindGroupLayout.ShaderStage.FRAGMENT,
    .texture = .{
        .sampleType = .{ .float = .{ .filterable = true } },
        .viewDimension = .@"2d",
        .multisampled = false,
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
    });
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

        try render_the_pipeline(&state, dt);
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
    camera_bind_group_layout: vit.BindGroupLayout,
    bind_group: vit.BindGroup,
    uniform_buffer: vit.Buffer,
    vertex_buffer: vit.Buffer,
    index_buffer: vit.Buffer,
    camera: Camera,

    tex: Tex,

    fn deinit(self: *@This()) void {
        self.tex.deinit();
        self.index_buffer.deinit();
        self.vertex_buffer.deinit();
        self.uniform_buffer.deinit();
        self.bind_group.deinit();
        self.render_pipeline.deinit();
        self.render_pipeline_layout.deinit();
        self.camera_bind_group_layout.deinit();

        self.surface.deinit();
        self.device.destroy();
        self.instance.deinit();
    }

    fn updateCamera(self: *@This(), dt: f32) void {
        self.camera.update(dt);
        const ubo = self.camera.uniforms(self.config.width, self.config.height);
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
        .camera_bind_group_layout = undefined,
        .bind_group = undefined,
        .uniform_buffer = undefined,
        .vertex_buffer = undefined,
        .index_buffer = undefined,
        .camera = .{},
        .tex = undefined,
    };

    try create_images(&state, init);
    try create_camera_resources(&state);
    try create_render_pipeline(&state);
    try create_buffers(&state);

    return state;
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

    state.queue.writeTexture(
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

    const texture_view = try texture.createView(.{ .label = "bird texture view" });
    const sampler = state.device.createSampler(.{
        .label = "bird sampler",
        .magFilter = .linear,
        .minFilter = .linear,
    });

    state.tex.texture = texture;
    state.tex.view = texture_view;
    state.tex.sampler = sampler;
}

fn create_camera_resources(state: *State) !void {
    state.camera_bind_group_layout = state.device.createBindGroupLayout(.{
        .label = "camera bind group layout",
        .entries = &.{ &camera_bind_group_layout_entry, &texture_layout_entry },
    });

    var uniform_buffer = try state.device.createBuffer(.{
        .label = "Camera Uniform Buffer",
        .size = @sizeOf(UniformBufferObject),
        .usage = vit.Buffer.Usage.UNIFORM | vit.Buffer.Usage.COPY_DST,
        .mappedAtCreation = false,
    });

    const initial_ubo = state.camera.uniforms(state.config.width, state.config.height);
    const initial_bytes = std.mem.asBytes(&initial_ubo);
    state.queue.writeBuffer(&uniform_buffer, 0, initial_bytes[0..], 0, null);
    state.uniform_buffer = uniform_buffer;

    state.bind_group = state.device.createBindGroup(.{
        .label = "camera bind group",
        .layout = &state.camera_bind_group_layout,
        .entries = &.{ .{
            .binding = 0,
            .resource = .{ .bufferBinding = .{ .buffer = &state.uniform_buffer } },
        }, .{
            .binding = 1,
            .resource = .{ .textureView = state.tex.view },
        } },
    });
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

    state.render_pipeline_layout = state.device.createPipelineLayout(.{
        .label = "render pipeline layout",
        .bindGroupLayouts = &.{&state.camera_bind_group_layout},
    });

    const render_pipeline = state.device.createRenderPipeline(.{
        .label = "render pipeline",
        .layout = &state.render_pipeline_layout,
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

fn render_the_pipeline(state: *State, dt: f32) !void {
    if (!state.isSurfaceConfigured) {
        return;
    }

    state.updateCamera(dt);

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
        render_pass.setBindGroup(0, &state.bind_group, &.{});
        render_pass.setVertexBuffer(0, &state.vertex_buffer, 0, null);
        render_pass.setIndexBuffer(&state.index_buffer, .uint16, 0, null);
        render_pass.drawIndexed(.exclusive(0, INDICES.len), .exclusive(0, 1), 0);
    }

    state.queue.submit(&[_]vit.CommandBuffer{encoder.finish()});
    output.present();

    return;
}
