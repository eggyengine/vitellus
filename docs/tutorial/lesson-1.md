# Lesson 1
SDL3 is one of the easiest and most feature-rich windowing libraries, and Vitellus uses it internally. For this, we will use [7Games/zig-sdl3](https://codeberg.org/7Games/zig-sdl3).

## importing SDL3
Let's import it to our project:
```bash
zig fetch --save git+https://codeberg.org/7Games/zig-sdl3#master
```

Then, let's add it as a dependency:
```zig
const sdl3 = b.dependency("sdl3", .{
    .target = target,
    .optimize = optimize,
});
```

Lastly, add it to your target (the target name can be different):
```zig
lib.root_module.addImport("sdl3", sdl3.module("sdl3"));
```

Now that is done, let's use it in our project:

---

Analyse this in your own time, as most of this follows the SDL3 docs:
```zig
const sdl3 = @import("sdl3");
const std = @import("std");

const fps = 60;
const screen_width = 640;
const screen_height = 480;

pub fn main() !void {
    defer sdl3.shutdown();

    // Initialise SDL with the subsystems you need here.
    const init_flags = sdl3.InitFlags{ .video = true };
    try sdl3.init(init_flags);
    defer sdl3.quit(init_flags);

    // Initial window setup.
    const window = try sdl3.video.Window.init("Hello SDL3", screen_width, screen_height, .{});
    defer window.deinit();

    // Useful for limiting the FPS and getting the delta time.
    var fps_capper = sdl3.extras.FramerateCapper(f32){ .mode = .{ .limited = fps } };

    var quit = false;
    while (!quit) {

        // Delay to limit the FPS, returned delta time not needed.
        const dt = fps_capper.delay();
        _ = dt;

        // Update logic.
        const surface = try window.getSurface();
        try surface.fillRect(null, surface.mapRgb(128, 30, 255));
        try window.updateSurface();

        // Event logic.
        while (sdl3.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                else => {},
            };
    }
}
```

## importing vitellus

Now, time for the part you've been waiting for. Let's start off by importing vitellus by saving the repository:

```bash
zig fetch --save git+https://github.com/eggyengine/vitellus
```

This will save it into your `build.zig.zon` file.

Then in `build.zig`:
```zig
const vit = b.dependency("vitellus", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("vitellus", vit.module("vitellus"));
```

And now in our `main.zig` file, add `vitellus` as an import:
```zig
const vit = @import("vitellus");
```

## configuring the window

If you run your app now, you should see a purple screen.

SDL's window is not yet connected to Vitellus. First, wrap it in the window
interface expected by the rendering backend:

```zig
const window_adapter = vit.windowing.sdl3.Sdl3Window.init(window);
```

Vitellus needs an adapter, a device, and a graphics queue. The adapter selects a
GPU, the device creates GPU objects, and the queue submits work to that GPU.

Change the entry point to accept `std.process.Init`; its general-purpose
allocator is used to own the backend objects:

```zig
pub fn main(init: std.process.Init) !void {
    // SDL setup from above...

    const adapter = try vit.Adapter.init(init.gpa, .{
        .backend = .{ .dx12 = true },
        .validation = .core,
    });
    defer adapter.deinit();

    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();

const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();
}
```

The backend is explicitly set to DirectX 12 because that is the backend used
throughout this tutorial. `.validation = .core` enables the DirectX debug layer
when it is installed.

## creating the swapchain

A swapchain owns the images displayed by the window. Create it after the queue
so it can present through that queue:

```zig
const swapchain = try vit.Swapchain.init(adapter, .{
    .window = try window_adapter.asWindow(),
    .queue = queue,
    .extent = .{
        .width = screen_width,
        .height = screen_height,
    },
    .format = .bgra8_unorm,
    .present_mode = .fifo,
    .image_count = 2,
});
defer swapchain.deinit();
```

`fifo` waits for the display before presenting and avoids tearing. The two
images allow one image to be displayed while the next one is prepared.

Once you start rendering through the swapchain, remove the SDL surface calls:

```zig
const surface = try window.getSurface();
try surface.fillRect(null, surface.mapRgb(128, 30, 255));
try window.updateSurface();
```

SDL still owns the window and handles events, but Vitellus now owns its rendered
contents.

Next: [Lesson 2 — shaders and the graphics pipeline](lesson-2.md).
