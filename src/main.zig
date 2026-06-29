const sdl3 = @import("sdl3");
const std = @import("std");
const vit = @import("vitellus");

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
    const window = try sdl3.video.Window.init("Hello SDL3", screen_width, screen_height, .{ .maximized = true, .resizable = true });
    defer window.deinit();

    const sdl_wrapper = vit.windowing.sdl3.Sdl3Window.init(window);

    const adapter = try vit.Adapter.init(init.gpa, .{ .backend = .all(), .validation = .core });
    defer adapter.deinit();

    const device = try adapter.createDevice();
    defer device.deinit();

    const queue = try device.createQueue(.{
        .kind = .graphics,
    });
    defer queue.deinit();

    const swapchain = try adapter.createSwapchain(.{
        .window = try sdl_wrapper.asWindow(),
        .queue = queue,
    });
    defer swapchain.deinit();

    // Useful for limiting the FPS and getting the delta time.
    var fps_capper = sdl3.extras.FramerateCapper(f32){ .mode = .{ .limited = fps } };

    var quit = false;
    while (!quit) {

        // Delay to limit the FPS, returned delta time not needed.
        const dt = fps_capper.delay();
        _ = dt;

        // Update logic.
        _ = try window.getSurface();

        // Event logic.
        while (sdl3.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                else => {},
            };
    }
}
