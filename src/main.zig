const vit = @import("vitellus");
const sdl3 = vit.windowing.sdl3.sdl;
const std = @import("std");

const fps = 60;
const screen_width = 640;
const screen_height = 480;

pub fn main(init: std.process.Init) !void {
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

    var quit = false;
    while (!quit) {

        // Delay to limit the FPS, returned delta time not needed.
        const dt = fps_capper.delay();
        _ = dt;

        // Update logic.
        _ = try window.getSurface();
        try window.updateSurface();

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

        try render_pipeline(&state);
    }
}

pub const State = struct {
    surface: vit.Surface,
    device: vit.Device,
    queue: vit.Queue,
    config: vit.Surface.Configuration,
    isSurfaceConfigured: bool,
};

fn initPipeline(wrapper: vit.windowing.sdl3.Sdl3Window, init: std.process.Init) !State {
    const size = try wrapper.window.getSize();
    // initialise the instance
    var instance = try vit.Instance.initFromPotentialBackends(.{ .vulkan = true, .noop = true }, .{ .allocator = init.gpa, .flags = .{ .validation = true } });
    // create the surface from the window
    const surface = try instance.createSurface(try wrapper.asWindow());

    // request the adapter
    var adapterF = instance.requestAdapter(init.io, .{
        .label = "adapter",
        .surface = surface,
    });
    defer _ = adapterF.cancel(init.io) catch {};
    var adapter = try adapterF.await(init.io);

    // request the device and queue
    var deviceF = adapter.requestDevice(init.io, .{
        .label = "device",
    });
    defer _ = deviceF.cancel(init.io) catch {};
    const device, const queue = try deviceF.await(init.io);

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
        .width = @intCast(size.@"0"),
        .height = @intCast(size.@"1"),
        .presentMode = surface_caps.present_modes[0],
        .alphaMode = surface_caps.alpha_modes[0],
        .viewFormats = &.{},
        .desiredMaximumFrameLatency = 2,
    };

    return State{
        .surface = surface,
        .device = device,
        .queue = queue,
        .config = config,
        .isSurfaceConfigured = false,
    };
}

fn render_pipeline(state: *State) !void {
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

    vit.splat.hello();

    var encoder = state.device.createCommandEncoder(.{
        .label = "render encoder",
    });

    {
        const color_attachments = [_]?vit.RenderPassEncoder.ColorAttachment{
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
        };

        var render_pass = encoder.beginRenderPass(.{
            .label = "Render Pass",
            .colorAttachments = &color_attachments,
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .multiviewMask = null,
        });
        defer render_pass.end();
    }

    state.queue.submit(&[_]vit.CommandBuffer{encoder.finish()});
    output.present();

    return;
}
